import Testing
import Foundation
@testable import WellSpentAppCore
import WellSpentCrypto
import WellSpentKeyStore
import WellSpentModel
import WellSpentStore
import WellSpentSync

/// One person's device on a shared in-memory server, signed up, email confirmed.
@MainActor
private struct Person {
    let sync: SyncCoordinator
    let workspace: Workspace
    var model: AppModel { workspace.model }

    init(_ email: String, on server: InMemoryReadableServer) async throws {
        let store = Store(database: try WellSpentDatabase.inMemory())
        let transport = StubReadableTransport(server: server)
        sync = SyncCoordinator(store: store, keyStore: InMemoryKeyStore(), defaults: isolatedDefaults(),
                               makeTransport: { _ in transport })
        workspace = Workspace(model: AppModel(store: store), sync: sync)
        try await sync.signUp(email: email, password: "a-long-password")
        try await sync.verifyEmail(code: try #require(server.lastCode(for: email, purpose: .verify)))
    }
}

/// A member moved down to View: nothing offers adding, anything that tries
/// anyway is refused in words, and leaving promises nothing about changes.
/// From the cross-desktop run, where an entry added at View stayed on that
/// device and its totals quietly differed from the group's.
@Suite("View only", .serialized)
@MainActor
struct ViewOnlyTests {
    @Test func aMemberAtViewIsOfferedNothingToAddAndIsRefusedInWords() async throws {
        let server = InMemoryReadableServer()
        let robin = try await Person("robin@example.com", on: server)
        let household = try #require(robin.model.addGroup(named: "Household"))
        let groceries = try #require(robin.model.addBudget(named: "Groceries", limit: Money(minorUnits: 50_000),
                                                           in: household))
        let share = ShareScreen(actions: robin.sync, group: household, groupName: "Household")
        share.myName = "Robin"
        #expect(await share.create())

        let leslie = try await Person("leslie@example.com", on: server)
        let join = JoinScreen(actions: leslie.sync, linkText: try #require(share.link).url)
        join.myName = "Leslie"
        #expect(await join.join())
        leslie.model.reload()
        #expect(leslie.sync.mayAddEntries(in: household), "at Add")

        let members = MembersScreen(actions: robin.sync, group: household, groupName: "Household")
        await members.refresh()
        let leslieRow = try #require(members.rows.first { !$0.isYou })
        await members.setLevel(.read, for: leslieRow.id)
        await leslie.sync.syncAll()

        #expect(!leslie.sync.mayAddEntries(in: household))
        let summary = try #require(leslie.model.summary(for: groceries))
        #expect(!BudgetScreen(summary: summary, model: leslie.model, me: leslie.sync.userID).mayAdd)

        leslie.model.selectedBudget = groceries
        leslie.model.addTransaction(merchant: "View entry", amount: Money(minorUnits: 300), date: Date(), note: "")
        #expect(leslie.model.errorMessage == "You can view this group but not add to it.")
        #expect(try leslie.sync.store.transactions(in: groceries).isEmpty, "nothing saved that would never sync")

        let theirs = MembersScreen(actions: leslie.sync, group: household, groupName: "Household")
        #expect(theirs.leaveMessage == SyncWording.leaveGroupMessage(sendsChanges: false))
        #expect(!theirs.leaveMessage.contains("still goes to them first"))
        let main = MainScreen(workspace: leslie.workspace)
        let group = try #require(leslie.model.groups.first)
        #expect(main.message(for: .group(group, budgets: 1, reach: .thisMacOnly))
                == "You leave the group, and it is removed from all your devices, with its 1 budget. "
                + "The others in it keep it. Only the person who made it, or an admin, can delete it for everyone. "
                + "To come back, ask for a new invite link.")

        // The owner still adds, and a member at Add is still told changes go first.
        #expect(robin.sync.mayAddEntries(in: household))
        #expect(SyncWording.leaveGroupMessage(sendsChanges: true).contains("still goes to them first"))
    }

    /// A statement cannot be imported into a group this person may only view.
    @Test func importingIsRefusedAtView() throws {
        let model = AppModel(store: Store(database: try WellSpentDatabase.inMemory()))
        model.addGroup(named: "Household")
        model.mayAddEntries = { _ in false }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("wellspent-\(UUID().uuidString).csv")
        try "Date,Description,Amount\n10/02/2026,\"TRADER JOES\",-54.20\n".write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }

        model.prepareImport(from: url)

        #expect(model.errorMessage == "You can view this group but not add to it.")
        #expect(model.pendingImport == nil)
    }

    /// A group the server has never listed is this person's own.
    @Test func aGroupOnlyOnThisDeviceIsYours() throws {
        let store = Store(database: try WellSpentDatabase.inMemory())
        let sync = SyncCoordinator(store: store, keyStore: InMemoryKeyStore(), defaults: isolatedDefaults())
        let workspace = Workspace(model: AppModel(store: store), sync: sync)
        let group = try #require(workspace.model.addGroup(named: "Household"))
        #expect(sync.mayAddEntries(in: group))
        #expect(workspace.model.mayAddEntries(group))
    }
}
