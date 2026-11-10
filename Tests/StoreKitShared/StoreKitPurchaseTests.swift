// Buying through Apple's real StoreKit, against StoreKit Testing's local store
// and WellSpent.storekit (the same six products as App Store Connect). The
// server is a stand-in that records what it's handed: StoreKit Testing signs
// with Xcode's own certificate, which the real server rightly refuses. The
// Mac and the iPhone each compile this folder into a test hosted in an app.
import Foundation
import StoreKit
import StoreKitTest
import XCTest
import WellSpentPlans

/// The server's side: records every signed purchase and answers with the plan
/// the purchase names.
private final class RecordingService: PlanService, @unchecked Sendable {
    private let lock = NSLock()
    private var handed: [String] = []
    let token = UUID()

    var submitted: [String] { lock.withLock { handed } }

    func plan() async throws -> PlanAnswer { Self.answer(.free, token: token) }

    func submitApple(signedTransaction: String) async throws -> PlanAnswer {
        lock.withLock { handed.append(signedTransaction) }
        let product = StoreKitPurchaseTests.payload(signedTransaction)["productId"] as? String ?? ""
        let tier = PlanProduct.all.first { $0.id == product }?.tier.tier ?? .free
        return Self.answer(tier, token: token)
    }

    static func answer(_ tier: PlanTier, token: UUID) -> PlanAnswer {
        let free = tier == .free
        return PlanAnswer(tier: tier, period: free ? .none : .monthly, state: free ? .free : .active,
                          source: free ? .none : .apple, paidUntil: free ? nil : Date().addingTimeInterval(30 * 86_400),
                          renews: !free, nextTier: nil, limits: .init(properties: free ? 1 : 2, groups: nil, invitedPerGroup: nil),
                          used: .init(properties: 1, groups: 1, invitedPerGroup: 0), extensionsOpen: [],
                          canSyncPriceLabs: !free, refreshMinutes: 60, appleAccountToken: token)
    }
}

private final class MemoryCache: PlanCache, @unchecked Sendable {
    private var answer: PlanAnswer?
    private var pending: UUID?
    func load() -> PlanAnswer? { answer }
    func save(_ answer: PlanAnswer) { self.answer = answer }
    func loadPendingGroup() -> UUID? { pending }
    func savePendingGroup(_ id: UUID?) { pending = id }
    func clear() { answer = nil; pending = nil }
}

@MainActor
final class StoreKitPurchaseTests: XCTestCase {
    private var session: SKTestSession!
    private let starter = PlanProduct(.starter, .monthly)

    override func setUp() async throws {
        session = try SKTestSession(configurationFileNamed: "WellSpent")
        session.resetToDefaultState()
        session.disableDialogs = true
        session.clearTransactions()
    }

    override func tearDown() async throws {
        session.clearTransactions()
        session = nil
    }

    /// A coordinator on the real Apple store, signed in on the free plan.
    private func coordinator() async -> (PurchaseCoordinator, RecordingService) {
        let service = RecordingService()
        let plans = PurchaseCoordinator(store: AppleStore(), service: service, cache: MemoryCache())
        await plans.refresh()
        return (plans, service)
    }

    /// The JSON inside a signed record, as the server reads it.
    nonisolated static func payload(_ signed: String) -> [String: Any] {
        let parts = signed.split(separator: ".")
        guard parts.count == 3 else { return [:] }
        var text = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while text.count % 4 != 0 { text += "=" }
        guard let data = Data(base64Encoded: text),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return json
    }

    private func waitUntil(_ timeout: TimeInterval = 15, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline { try await Task.sleep(for: .milliseconds(200)) }
    }

    func testTheStoreSellsTheSixPlansAtTheirPrices() async throws {
        let (plans, _) = await coordinator()
        let offers = await plans.offers()
        XCTAssertEqual(offers.map(\.product.id), PlanProduct.all.map(\.id))
        XCTAssertEqual(offers.first { $0.product == starter }?.displayPrice, "$19.00")
        XCTAssertEqual(offers.first { $0.product == PlanProduct(.portfolio, .yearly) }?.displayPrice, "$990.00")
    }

    func testBuyingHandsTheSignedPurchaseToTheServerThenFinishesIt() async throws {
        let (plans, service) = await coordinator()
        await plans.buy(starter)
        XCTAssertEqual(plans.status, .idle)
        XCTAssertEqual(service.submitted.count, 1, "the purchase didn't reach the server")
        let signed = Self.payload(try XCTUnwrap(service.submitted.first))
        XCTAssertEqual(signed["productId"] as? String, starter.id)
        XCTAssertEqual((signed["appAccountToken"] as? String)?.lowercased(), service.token.uuidString.lowercased(),
                       "the purchase isn't tagged with the account")
        XCTAssertEqual(plans.answer?.tier, .starter)
        // Finished with the store, so it isn't offered again.
        let unfinished = try session.allTransactions().filter { $0.productIdentifier == starter.id && $0.pendingAskToBuyConfirmation }
        XCTAssertTrue(unfinished.isEmpty)
    }

    func testAskToBuyWaitsThenThePurchaseArrivesWhenApproved() async throws {
        session.askToBuyEnabled = true
        let (plans, service) = await coordinator()
        let listening = Task { await plans.listen() }
        defer { listening.cancel() }
        await plans.buy(starter)
        XCTAssertEqual(plans.status, .waitingForApproval)
        XCTAssertTrue(service.submitted.isEmpty, "nothing is sent before approval")
        let asked = try XCTUnwrap(session.allTransactions().first { $0.pendingAskToBuyConfirmation })
        try session.approveAskToBuyTransaction(identifier: asked.identifier)
        try await waitUntil { !service.submitted.isEmpty }
        XCTAssertEqual(service.submitted.count, 1, "the approved purchase didn't reach the server")
        XCTAssertEqual(plans.answer?.tier, .starter)
    }

    func testAStoreFailureSaysSoAndSendsNothing() async throws {
        session.failTransactionsEnabled = true
        session.failureError = .unknown
        let (plans, service) = await coordinator()
        await plans.buy(starter)
        XCTAssertEqual(plans.status, .failed(.storeFailed))
        XCTAssertTrue(service.submitted.isEmpty)
    }

    func testRestoreHandsEveryHeldPlanToTheServer() async throws {
        let (plans, service) = await coordinator()
        _ = try await session.buyProduct(identifier: PlanProduct(.growth, .yearly).id)
        await plans.restore()
        XCTAssertEqual(plans.status, .idle)
        let products = service.submitted.map { Self.payload($0)["productId"] as? String }
        XCTAssertTrue(products.contains(PlanProduct(.growth, .yearly).id), "Restore didn't hand over the held plan: \(products)")
        XCTAssertEqual(plans.answer?.tier, .growth)
    }

    func testARenewalWhileTheAppRunsReachesTheServer() async throws {
        let (plans, service) = await coordinator()
        await plans.buy(starter)
        XCTAssertEqual(service.submitted.count, 1)
        let listening = Task { await plans.listen() }
        defer { listening.cancel() }
        try session.forceRenewalOfSubscription(productIdentifier: starter.id)
        try await waitUntil { service.submitted.count >= 2 }
        XCTAssertGreaterThanOrEqual(service.submitted.count, 2, "the renewal didn't reach the server")
    }
}
