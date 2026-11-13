import Testing
import Foundation
@testable import WellSpentAppCore
import WellSpentKeyStore
import WellSpentPlans
import WellSpentStore
import WellSpentSync

/// The server's plans switch (WELLSPENT_PLANS) off, as on live today: GET
/// /plan answers 404. The app asks, gets no answer, and shows nothing about
/// plans. No error, no card, no locks, no pick, no held group.
@MainActor
@Suite("Plans off on the server", .serialized)
struct PlansOffTests {
    /// The server with plans off.
    private struct PlansOff: PlanService {
        func plan() async throws -> PlanAnswer {
            throw ReadableTransportError.http(status: 404, reason: "Not Found")
        }
        func submitApple(signedTransaction: String) async throws -> PlanAnswer {
            throw ReadableTransportError.http(status: 404, reason: "Not Found")
        }
    }

    @Test func askingGetsNoAnswerAndNoError() async {
        let plans = PurchaseCoordinator(store: nil, service: PlansOff(),
                                        cache: DefaultsPlanCache(defaults: isolatedDefaults()))
        await plans.refresh()
        #expect(plans.answer == nil)
        #expect(plans.status == .idle, "a 404 is plans off, not a failure to show")
    }

    /// Signed in, with two groups and no plan answer: nothing is locked,
    /// there is no pick, and no group says it's only on this device.
    @Test func theScreensShowNothingAboutPlans() async throws {
        let server = InMemoryReadableServer()
        server.seedAccount(email: "robin@example.com", password: "a-long-password")
        let store = Store(database: try WellSpentDatabase.inMemory())
        let transport = StubReadableTransport(server: server)
        let sync = SyncCoordinator(store: store, keyStore: InMemoryKeyStore(), defaults: isolatedDefaults(),
                                   makeTransport: { _ in transport })
        let workspace = Workspace(model: AppModel(store: store), sync: sync)
        let model = workspace.model
        model.addGroup(named: "Home")
        model.addGroup(named: "Beach")
        try await sync.signIn(email: "robin@example.com", password: "a-long-password")
        await sync.syncAll()
        await workspace.plans.refresh()

        #expect(workspace.plans.answer == nil)
        #expect(workspace.pickScreen() == nil)
        for group in model.groups {
            #expect(workspace.lockedScreen(group: group.id) == nil)
            #expect(!workspace.planLocks.isLocked(group: group.id.uuid))
            #expect(workspace.heldScreen(group: group.id, device: .mac) == nil)
        }
        #expect(sync.planSheet == nil)
    }
}
