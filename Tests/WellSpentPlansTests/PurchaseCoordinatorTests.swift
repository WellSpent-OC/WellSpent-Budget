import Foundation
import Testing
import WellSpentPlans

/// What the fakes saw, in order, so a test can check the server heard about a
/// purchase before the store was told it was done.
private final class Log: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []
    func add(_ line: String) { lock.withLock { lines.append(line) } }
    var all: [String] { lock.withLock { lines } }
}

private final class FakeStore: PlanStore, @unchecked Sendable {
    let log: Log
    var result: PurchaseResult = .cancelled
    var held: [StoreTransaction] = []
    var syncFails = false
    var purchaseFails = false
    var tokens: [UUID] = []
    private var continuation: AsyncStream<StoreTransaction>.Continuation?
    private let stream: AsyncStream<StoreTransaction>

    init(log: Log) {
        self.log = log
        var made: AsyncStream<StoreTransaction>.Continuation?
        stream = AsyncStream { made = $0 }
        continuation = made
    }

    func offers() async throws -> [StoreOffer] {
        PlanProduct.all.map { StoreOffer(product: $0, displayPrice: "$\($0.tier.rawValue)") }
    }

    func purchase(_ product: PlanProduct, accountToken: UUID) async throws -> PurchaseResult {
        log.add("purchase \(product.id)")
        tokens.append(accountToken)
        if purchaseFails { throw CocoaError(.featureUnsupported) }
        return result
    }

    func current() async -> [StoreTransaction] { held }

    func sync() async throws {
        log.add("sync")
        if syncFails { throw CocoaError(.featureUnsupported) }
    }

    func finish(_ transactionID: UInt64) async { log.add("finish \(transactionID)") }

    func updates() -> AsyncStream<StoreTransaction> { stream }

    func send(_ transaction: StoreTransaction) { continuation?.yield(transaction) }
    func end() { continuation?.finish() }

    func storefrontCountry() async -> String? { "USA" }
}

private final class FakeService: PlanService, @unchecked Sendable {
    let log: Log
    var answer: PlanAnswer
    var submitError: PlanServiceError?
    var planError: PlanServiceError?

    init(log: Log, answer: PlanAnswer) {
        self.log = log
        self.answer = answer
    }

    func plan() async throws -> PlanAnswer {
        log.add("plan")
        if let planError { throw planError }
        return answer
    }

    func submitApple(signedTransaction: String) async throws -> PlanAnswer {
        log.add("submit \(signedTransaction)")
        if let submitError { throw submitError }
        return answer
    }
}

private final class MemoryCache: PlanCache, @unchecked Sendable {
    var stored: PlanAnswer?
    init(_ stored: PlanAnswer? = nil) { self.stored = stored }
    func load() -> PlanAnswer? { stored }
    func save(_ answer: PlanAnswer) { stored = answer }
}

private let token = UUID(uuidString: "6F9619FF-8B86-D011-B42D-00C04FC964FF")!

private func answer(_ tier: PlanTier, token: UUID? = token, source: PlanAnswer.Source? = nil) -> PlanAnswer {
    PlanAnswer(tier: tier, period: tier == .free ? .none : .monthly, state: tier == .free ? .free : .active,
               source: source ?? (tier == .free ? .none : .apple), paidUntil: nil, renews: tier != .free, nextTier: nil,
               limits: .init(properties: tier == .free ? 1 : 5, groups: tier == .free ? 1 : nil,
                             invitedPerGroup: tier == .free ? 1 : nil),
               used: .init(properties: 1, groups: 1, invitedPerGroup: 0),
               extensionsOpen: tier == .free ? [] : ["wellspent.properties", "wellspent.tax"],
               canSyncPriceLabs: tier != .free, refreshMinutes: 60, appleAccountToken: token)
}

private let growthMonthly = StoreTransaction(id: 7, productID: "app.wellspent.pro.growth.monthly", signed: "jws-7")

@MainActor
struct PurchaseCoordinatorTests {
    @Test func aPurchaseReachesTheServerBeforeTheStoreIsToldItIsDone() async {
        let log = Log()
        let store = FakeStore(log: log)
        store.result = .purchased(growthMonthly)
        let service = FakeService(log: log, answer: answer(.growth))
        let coordinator = PurchaseCoordinator(store: store, service: service, cache: MemoryCache(answer(.free)))

        await coordinator.buy(PlanProduct(.growth, .monthly))

        #expect(log.all == ["purchase app.wellspent.pro.growth.monthly", "submit jws-7", "finish 7"])
        #expect(store.tokens == [token])
        #expect(coordinator.answer?.tier == .growth)
        #expect(coordinator.status == .idle)
    }

    @Test func aPurchaseTheServerCannotHearStaysUnfinished() async {
        let log = Log()
        let store = FakeStore(log: log)
        store.result = .purchased(growthMonthly)
        let service = FakeService(log: log, answer: answer(.growth))
        service.submitError = .unreachable
        let coordinator = PurchaseCoordinator(store: store, service: service, cache: MemoryCache(answer(.free)))

        await coordinator.buy(PlanProduct(.growth, .monthly))

        #expect(!log.all.contains("finish 7"))
        #expect(coordinator.answer?.tier == .free)
        #expect(coordinator.status == .failed(.unreachable))
    }

    @Test(arguments: [(PlanServiceError.paddlePlanLive, PurchaseCoordinator.Failure.paddlePlanLive),
                      (.notGenuine, .notGenuine)])
    func theServerSaysWhyItRefused(_ error: PlanServiceError, _ failure: PurchaseCoordinator.Failure) async {
        let log = Log()
        let store = FakeStore(log: log)
        store.result = .purchased(growthMonthly)
        let service = FakeService(log: log, answer: answer(.growth))
        service.submitError = error
        let coordinator = PurchaseCoordinator(store: store, service: service, cache: MemoryCache(answer(.free)))

        await coordinator.buy(PlanProduct(.growth, .monthly))

        #expect(coordinator.status == .failed(failure))
        #expect(!log.all.contains("finish 7"))
    }

    @Test func someonePayingOnTheWebsiteIsNeverShownApplesSheet() async {
        let log = Log()
        let store = FakeStore(log: log)
        store.result = .purchased(growthMonthly)
        let coordinator = PurchaseCoordinator(store: store, service: FakeService(log: log, answer: answer(.growth)),
                                              cache: MemoryCache(answer(.starter, source: .paddle)))

        await coordinator.buy(PlanProduct(.growth, .monthly))

        #expect(log.all.isEmpty)
        #expect(coordinator.status == .failed(.paddlePlanLive))
    }

    @Test func closingTheSheetSendsNothing() async {
        let log = Log()
        let store = FakeStore(log: log)
        let coordinator = PurchaseCoordinator(store: store, service: FakeService(log: log, answer: answer(.growth)),
                                              cache: MemoryCache(answer(.free)))

        await coordinator.buy(PlanProduct(.starter, .yearly))

        #expect(log.all == ["purchase app.wellspent.pro.starter.yearly"])
        #expect(coordinator.status == .idle)
    }

    @Test func aPurchaseWaitingForApprovalSaysSo() async {
        let log = Log()
        let store = FakeStore(log: log)
        store.result = .pending
        let coordinator = PurchaseCoordinator(store: store, service: FakeService(log: log, answer: answer(.growth)),
                                              cache: MemoryCache(answer(.free)))

        await coordinator.buy(PlanProduct(.starter, .monthly))

        #expect(coordinator.status == .waitingForApproval)
        #expect(coordinator.answer?.tier == .free)
    }

    @Test func aStoreErrorSaysTheStoreFailed() async {
        let log = Log()
        let store = FakeStore(log: log)
        store.purchaseFails = true
        let coordinator = PurchaseCoordinator(store: store, service: FakeService(log: log, answer: answer(.growth)),
                                              cache: MemoryCache(answer(.free)))

        await coordinator.buy(PlanProduct(.starter, .monthly))

        #expect(coordinator.status == .failed(.storeFailed))
    }

    @Test func withNoPlanAnswerYetNothingIsBought() async {
        let log = Log()
        let store = FakeStore(log: log)
        let coordinator = PurchaseCoordinator(store: store, service: FakeService(log: log, answer: answer(.growth)),
                                              cache: MemoryCache())

        await coordinator.buy(PlanProduct(.starter, .monthly))

        #expect(log.all.isEmpty)
        #expect(coordinator.status == .failed(.notReady))
    }

    @Test func withNoStoreBuyingAndRestoringPointToTheWebsite() async {
        let log = Log()
        let coordinator = PurchaseCoordinator(store: nil, service: FakeService(log: log, answer: answer(.free)),
                                              cache: MemoryCache(answer(.free)))

        #expect(!coordinator.canBuyInApp)
        #expect(await coordinator.offers().isEmpty)
        await coordinator.buy(PlanProduct(.starter, .monthly))
        #expect(coordinator.status == .failed(.noStore))
        await coordinator.restore()
        #expect(coordinator.status == .failed(.noStore))
        await coordinator.listen()
        #expect(log.all.isEmpty)
    }

    @Test func restoreHandsTheServerEverySubscriptionHeld() async {
        let log = Log()
        let store = FakeStore(log: log)
        store.held = [growthMonthly]
        let coordinator = PurchaseCoordinator(store: store, service: FakeService(log: log, answer: answer(.growth)),
                                              cache: MemoryCache(answer(.free)))

        await coordinator.restore()

        #expect(log.all == ["sync", "submit jws-7", "finish 7"])
        #expect(coordinator.answer?.tier == .growth)
        #expect(coordinator.status == .idle)
    }

    @Test func restoreWithNothingHeldAsksTheServerAgain() async {
        let log = Log()
        let store = FakeStore(log: log)
        let coordinator = PurchaseCoordinator(store: store, service: FakeService(log: log, answer: answer(.starter)),
                                              cache: MemoryCache(answer(.free)))

        await coordinator.restore()

        #expect(log.all == ["sync", "plan"])
        #expect(coordinator.answer?.tier == .starter)
    }

    @Test func restoreStopsAtTheFirstRefusal() async {
        let log = Log()
        let store = FakeStore(log: log)
        store.held = [growthMonthly, StoreTransaction(id: 8, productID: "app.wellspent.pro.starter.yearly", signed: "jws-8")]
        let service = FakeService(log: log, answer: answer(.growth))
        service.submitError = .notGenuine
        let coordinator = PurchaseCoordinator(store: store, service: service, cache: MemoryCache(answer(.free)))

        await coordinator.restore()

        #expect(log.all == ["sync", "submit jws-7"])
        #expect(coordinator.status == .failed(.notGenuine))
    }

    @Test func aStoreThatCannotSyncSaysTheStoreFailed() async {
        let log = Log()
        let store = FakeStore(log: log)
        store.syncFails = true
        let coordinator = PurchaseCoordinator(store: store, service: FakeService(log: log, answer: answer(.growth)),
                                              cache: MemoryCache(answer(.free)))

        await coordinator.restore()

        #expect(coordinator.status == .failed(.storeFailed))
    }

    @Test func aPurchaseFromAnotherDeviceIsHandedOnWhileTheAppRuns() async {
        let log = Log()
        let store = FakeStore(log: log)
        let coordinator = PurchaseCoordinator(store: store, service: FakeService(log: log, answer: answer(.growth)),
                                              cache: MemoryCache(answer(.free)))

        store.send(growthMonthly)
        store.end()
        await coordinator.listen()

        #expect(log.all == ["submit jws-7", "finish 7"])
        #expect(coordinator.answer?.tier == .growth)
    }

    @Test func offlineTheLastAnswerStays() async {
        let log = Log()
        let service = FakeService(log: log, answer: answer(.growth))
        service.planError = .unreachable
        let cache = MemoryCache(answer(.starter))
        let coordinator = PurchaseCoordinator(store: FakeStore(log: log), service: service, cache: cache)

        await coordinator.refresh()

        #expect(coordinator.answer?.tier == .starter)
    }

    @Test func aNewAnswerIsKeptForNextTime() async {
        let log = Log()
        let cache = MemoryCache()
        let coordinator = PurchaseCoordinator(store: FakeStore(log: log),
                                              service: FakeService(log: log, answer: answer(.portfolio)), cache: cache)

        await coordinator.refresh()

        #expect(cache.stored?.tier == .portfolio)
        #expect(await coordinator.offers().count == 6)
    }
}
