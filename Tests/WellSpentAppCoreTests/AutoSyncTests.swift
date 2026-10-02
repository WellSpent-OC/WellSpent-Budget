import Testing
import Foundation
@testable import WellSpentAppCore
import WellSpentKeyStore
import WellSpentModel
import WellSpentStore
import WellSpentSync

/// A workspace with one group and one budget, a stand-in server, and an
/// `AutoSync` with short waits so the tests do not sit through real ones.
@MainActor
private struct Setup {
    let workspace: Workspace
    let transport: StubAccountTransport

    var model: AppModel { workspace.model }
    var sync: SyncCoordinator { workspace.sync }
    var autoSync: AutoSync { workspace.autoSync }

    init(interval: Duration = .seconds(3600)) throws {
        let store = Store(database: try WellSpentDatabase.inMemory())
        let transport = StubAccountTransport()
        let sync = SyncCoordinator(store: store, keyStore: InMemoryKeyStore(),
                                   defaults: isolatedDefaults(),
                                   makeTransport: { _ in transport })
        let model = AppModel(store: store)
        model.addGroup(named: "Household")
        let group = try #require(model.groups.first)
        model.addBudget(named: "Groceries", limit: Money(minorUnits: 100_000), in: group.id)

        self.transport = transport
        workspace = Workspace(model: model, sync: sync,
                              autoSync: AutoSync(sync: sync, quietPeriod: .milliseconds(50),
                                                 interval: interval))
    }

    func spend(_ merchant: String) {
        model.addTransaction(merchant: merchant, amount: Money(minorUnits: 1_000),
                             date: Date(), note: "")
    }
}

@Suite("Auto sync", .serialized)
@MainActor
struct AutoSyncTests {

    /// Five edits in a row are one sync, not five, and it sends all of them.
    @Test func aBurstOfEditsIsOneSync() async throws {
        let s = try Setup()
        try await s.sync.signUp(email: "robin@example.com", password: "a-long-password")

        s.spend("Hilltop")
        s.spend("Sunny's")
        s.spend("Costco")
        await s.autoSync.pending?.value

        #expect(s.autoSync.runs == 1)
        let group = try #require(s.model.groups.first)
        #expect(try s.model.store.outboxCount(in: group.id) == 0)
        #expect(s.sync.state == .signedIn(email: "robin@example.com"))
    }

    @Test func nothingSyncsWhenSignedOut() async throws {
        let s = try Setup()

        s.spend("Hilltop")
        await s.autoSync.pending?.value

        #expect(s.autoSync.runs == 0)
        #expect(s.transport.appended.isEmpty)
        #expect(s.sync.state == .signedOut, "a sync nobody asked for must not say \"Sign in first\"")
    }

    /// A server that is down for a minute should not turn the button into an
    /// error every two minutes. A click still says why.
    @Test func aBackgroundSyncThatFailsKeepsQuiet() async throws {
        let s = try Setup()
        try await s.sync.signUp(email: "robin@example.com", password: "a-long-password")
        s.transport.failLogRead = .http(status: 503, reason: "database unreachable")

        await s.autoSync.syncIfIdle()
        #expect(s.sync.state == .signedIn(email: "robin@example.com"))

        await s.sync.syncAll()
        guard case .failed = s.sync.state else {
            Issue.record("a clicked sync should show the failure, got \(s.sync.state)")
            return
        }
    }

    /// Once the server is back, a background sync clears an earlier error.
    @Test func aBackgroundSyncThatWorksClearsAnOldError() async throws {
        let s = try Setup()
        try await s.sync.signUp(email: "robin@example.com", password: "a-long-password")
        s.transport.failLogRead = .http(status: 503, reason: "database unreachable")
        await s.sync.syncAll()

        s.transport.failLogRead = nil
        await s.autoSync.syncIfIdle()

        #expect(s.sync.state == .signedIn(email: "robin@example.com"))
    }

    /// Other people's changes only reach this Mac by asking, so the timer has to
    /// actually fire.
    @Test func theTimerKeepsSyncing() async throws {
        let s = try Setup(interval: .milliseconds(50))
        try await s.sync.signUp(email: "robin@example.com", password: "a-long-password")

        s.autoSync.start()
        let deadline = Date().addingTimeInterval(5)
        while s.autoSync.runs < 2, Date() < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        s.autoSync.stop()

        #expect(s.autoSync.runs >= 2)
    }

    /// Signing in to another account replaces the model. Edits on the new one
    /// must still sync.
    @Test func editsStillSyncAfterTheModelIsReplaced() async throws {
        let s = try Setup()
        let other = Store(database: try WellSpentDatabase.inMemory())
        s.sync.didSwitchStore?(other)
        #expect(s.model.store.database === other.database)

        s.model.addGroup(named: "Business")

        #expect(s.autoSync.pending != nil)
    }
}

@Suite("Edits announce themselves")
@MainActor
struct AppModelChangeTests {

    /// Every edit says so, and a reload does not. A reload also runs after a sync
    /// brings changes in, and if it announced a change, every sync would set off
    /// another one forever.
    @Test func editsCallDidChangeAndReloadsDoNot() throws {
        let model = AppModel(store: Store(database: try WellSpentDatabase.inMemory()))
        final class Count { var value = 0 }
        let changes = Count()
        model.didChange = { changes.value += 1 }

        let group = try #require(model.addGroup(named: "Household"))
        let budget = try #require(model.addBudget(named: "Groceries",
                                                  limit: Money(minorUnits: 100_000), in: group))
        model.selectedBudget = budget
        model.addTransaction(merchant: "Hilltop", amount: Money(minorUnits: 1_000),
                             date: Date(), note: "")
        model.updateBudget(budget, name: "Food", limit: Money(minorUnits: 90_000))
        model.renameGroup(group, to: "Home")
        let transaction = try #require(model.transactions.first)
        model.trash(transaction)
        model.deleteBudget(budget)
        model.deleteGroup(group, reach: .justYou)
        #expect(changes.value == 8)

        model.reload()
        #expect(changes.value == 8)
    }
}

@Suite("The sync button spins")
@MainActor
struct SpinningSyncButtonTests {

    @Test func itSpinsOnlyWhileASyncRuns() {
        #expect(SyncButton.isSpinning(for: .busy("Syncing")))
        #expect(!SyncButton.isSpinning(for: .signedIn(email: "robin@example.com")))
        #expect(!SyncButton.isSpinning(for: .signedOut))
        #expect(!SyncButton.isSpinning(for: .failed("no route to host")))
    }

    /// One turn a second, clockwise.
    @Test func itTurnsOnceASecond() {
        let start = Date(timeIntervalSinceReferenceDate: 1_000)
        #expect(SpinningIcon.angle(at: start) == 0)
        #expect(SpinningIcon.angle(at: start.addingTimeInterval(0.25)) == 90)
        #expect(SpinningIcon.angle(at: start.addingTimeInterval(1)) == 0)
    }
}
