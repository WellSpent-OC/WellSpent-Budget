import Testing
import Foundation
@testable import WellSpentAppCore
import WellSpentKeyStore
import WellSpentModel
import WellSpentPlans
import WellSpentStore
import WellSpentSync

private func answer(_ tier: PlanTier, source: PlanAnswer.Source) -> PlanAnswer {
    PlanAnswer(tier: tier, period: tier == .free ? .none : .monthly, state: tier == .free ? .free : .active,
               source: source, paidUntil: nil, renews: tier != .free, nextTier: nil,
               limits: .init(properties: 5, groups: nil, invitedPerGroup: nil),
               used: .init(properties: 1, groups: 1, invitedPerGroup: 0), extensionsOpen: [],
               canSyncPriceLabs: false, refreshMinutes: 60, appleAccountToken: nil)
}

private typealias Words = DeleteAccountScreen.Words

@MainActor
@Suite("Deleting an account", .serialized)
struct DeleteAccountTests {
    // Scenario ACCT-18
    @Test func everyVersionSaysWhatGoesAndWhatStays() {
        let free = DeleteAccountScreen(answer: answer(.free, source: .none), device: "Mac") { _ in }
        #expect(free.lines == [Words.server, Words.shared, Words.records,
                               "This Mac keeps its own copy of your budgets. To remove it, delete the app."])
        #expect(free.appleLine == nil && !free.showsOpenAppleSettings)
        #expect(DeleteAccountScreen(answer: nil, device: "iPhone") { _ in }.lines.last
                == "This iPhone keeps its own copy of your budgets. To remove it, delete the app.")
    }

    // Scenario ACCT-19
    @Test func anApplePlanSaysDeletingDoesntStopIt() {
        let apple = DeleteAccountScreen(answer: answer(.growth, source: .apple), device: "Mac") { _ in }
        let line = "Your Growth plan was bought through Apple, so deleting your account doesn't stop it. "
            + "Cancel it in your Apple account settings first."
        #expect(apple.appleLine == line && apple.showsOpenAppleSettings)
        #expect(apple.lines == [Words.server, Words.shared, line, Words.records,
                                "This Mac keeps its own copy of your budgets. To remove it, delete the app."])
        let web = DeleteAccountScreen(answer: answer(.starter, source: .paddle), device: "computer") { _ in }
        #expect(web.appleLine == nil)
        #expect(web.lines.contains("Your Starter plan, bought on our website, is canceled for you."))
    }

    @Test func itNeedsThePasswordAndSaysWhyItDidntGoThrough() async {
        var said: SyncCoordinator.DeleteFailure? = .wrongPassword
        let screen = DeleteAccountScreen(answer: nil, device: "Mac") { _ in if let said { throw said } }
        #expect(!screen.canDelete)
        await screen.submit()
        #expect(screen.failure == nil, "nothing is sent without a password")
        screen.password = "typo"
        await screen.submit()
        #expect(screen.failure == Words.wrongPassword && !screen.isDone)
        said = .planNotCanceled
        await screen.submit()
        #expect(screen.failure == Words.planNotCanceled)
        said = .unreachable
        await screen.submit()
        #expect(screen.failure == Words.unreachable)
        said = nil
        await screen.submit()
        #expect(screen.isDone && screen.failure == nil)
    }

    /// Against the server: a wrong password changes nothing; the right one
    /// deletes the account and signs this device out, and its budgets stay.
    @Test func deletingSignsOutAndKeepsThisDevicesBudgets() async throws {
        let server = InMemoryReadableServer()
        server.seedAccount(email: "robin@example.com", password: "a-long-password")
        let store = Store(database: try WellSpentDatabase.inMemory())
        let transport = StubReadableTransport(server: server)
        let sync = SyncCoordinator(store: store, keyStore: InMemoryKeyStore(), defaults: isolatedDefaults(),
                                   makeTransport: { _ in transport })
        try await sync.signIn(email: "robin@example.com", password: "a-long-password")
        let model = AppModel(store: store)
        model.addGroup(named: "Household")

        await #expect(throws: SyncCoordinator.DeleteFailure.wrongPassword) {
            try await sync.deleteAccount(password: "typo")
        }
        #expect(sync.account == "robin@example.com")

        try await sync.deleteAccount(password: "a-long-password")
        #expect(sync.account == nil && sync.state == .signedOut)
        #expect(try store.groups().contains { $0.name == "Household" }, "this device keeps its copy")
        await #expect(throws: (any Error).self) {
            try await sync.signIn(email: "robin@example.com", password: "a-long-password")
        }
    }
}
