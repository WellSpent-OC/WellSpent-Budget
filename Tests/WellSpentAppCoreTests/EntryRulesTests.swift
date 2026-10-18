import Testing
import Foundation
@testable import WellSpentAppCore
import WellSpentCrypto
import WellSpentKeyStore
import WellSpentModel
import WellSpentStore
import WellSpentSync

/// Leslie, signed in, at `level` in Household, as a sync leaves it: the
/// server's word on her level, and Robin's name. Four entries: one she
/// added, one Robin added, one by someone who set no name, and one nobody
/// owns yet because it has never synced.
@MainActor
private struct AtLevel {
    let workspace: Workspace
    let own: Transaction
    let robins: Transaction
    let unnamed: Transaction
    let unowned: Transaction
    var model: AppModel { workspace.model }

    init(_ level: AccessLevel) async throws {
        let server = InMemoryReadableServer()
        let store = Store(database: try WellSpentDatabase.inMemory())
        let transport = StubReadableTransport(server: server)
        let sync = SyncCoordinator(store: store, keyStore: InMemoryKeyStore(), defaults: isolatedDefaults(),
                                   makeTransport: { _ in transport })
        workspace = Workspace(model: AppModel(store: store), sync: sync)
        try await sync.signUp(email: "leslie@example.com", password: "a-long-password")
        let leslie = try #require(sync.userID)
        let robin = UserID(), stranger = UserID()
        let group = try #require(workspace.model.addGroup(named: "Household"))
        let budget = try #require(workspace.model.addBudget(named: "Groceries", limit: .dollars(500), in: group))
        try store.saveServerGroup(ServerGroupInfo(groupID: group, founderID: robin, level: level, importKey: Data()))
        try store.save(MemberProfile(groupID: group, userID: robin, displayName: "Robin"), queue: false)

        func entry(_ merchant: String, by owner: UserID?) throws -> Transaction {
            let made = Transaction(budgetID: budget, groupID: group, date: Date(), merchant: merchant,
                                   amount: Money(minorUnits: -14208), createdBy: owner)
            try store.save(made, queue: false)
            return made
        }
        own = try entry("Costco", by: leslie)
        robins = try entry("Hilltop Grocery", by: robin)
        unnamed = try entry("Sunny's", by: stranger)
        unowned = try entry("Corner Shop", by: nil)
    }

    var everyEntry: [Transaction] { [own, robins, unnamed, unowned] }
}

/// The server's rule for one entry: View changes nothing, Add changes only
/// what that person added, and Manage, Admin and Owner change anyone's. Each
/// answer carries the line a read-only sheet shows.
@Suite("Who may change one entry", .serialized)
@MainActor
struct EntryRulesTests {
    @Test func atViewNothingCanBeChanged() async throws {
        let s = try await AtLevel(.read)
        #expect(s.model.access(to: s.own) == .viewOnlyOwn)
        #expect(s.model.access(to: s.unowned) == .viewOnlyOwn, "never synced, so it is hers")
        #expect(s.model.access(to: s.robins) == .viewOnly)
        #expect(s.model.access(to: s.unnamed) == .viewOnly)

        #expect(s.model.access(to: s.own).line
                == "You can only view this group now, so you can't change what you added.")
        #expect(s.model.access(to: s.robins).line == "You can view this group but not change it.")
        #expect(s.everyEntry.allSatisfy { !s.model.access(to: $0).mayChange })
    }

    @Test func atAddOnlyTheirOwnCanBeChanged() async throws {
        let s = try await AtLevel(.write)
        #expect(s.model.access(to: s.own) == .change)
        #expect(s.model.access(to: s.unowned) == .change, "never synced, so it is hers")
        #expect(s.model.access(to: s.robins) == .someoneElses(name: "Robin"))
        #expect(s.model.access(to: s.unnamed) == .someoneElses(name: nil))

        #expect(s.model.access(to: s.own).line == nil)
        #expect(s.model.access(to: s.robins).line == "Only Robin, or a manager, can change this.")
        #expect(s.model.access(to: s.unnamed).line
                == "Only the person who added this, or a manager, can change this.")
        #expect(s.model.access(to: s.own).mayChange && !s.model.access(to: s.robins).mayChange)
    }

    @Test(arguments: [AccessLevel.manage, .admin, .superadmin])
    func atManageAndAboveAnyonesCanBeChanged(level: AccessLevel) async throws {
        let s = try await AtLevel(level)
        for entry in s.everyEntry {
            #expect(s.model.access(to: entry) == .change, "\(entry.merchant)")
            #expect(s.model.access(to: entry).line == nil)
        }
    }

    /// With no account and no server, everything here is this person's own.
    @Test func aModelOnItsOwnAllowsEverything() throws {
        let model = AppModel(store: Store(database: try WellSpentDatabase.inMemory()))
        let group = try #require(model.addGroup(named: "Household"))
        let budget = try #require(model.addBudget(named: "Groceries", limit: .dollars(500), in: group))
        let synced = Transaction(budgetID: budget, groupID: group, date: Date(), merchant: "Hilltop Grocery",
                                 amount: Money(minorUnits: -14208), createdBy: UserID())
        #expect(model.access(to: synced) == .change)
    }

    /// The Share window says what the server lets Manage do: delete too.
    @Test func theLevelsSayWhoEditsOrDeletesWhat() {
        #expect(InviteRole.view.explanation == "Sees every budget and transaction. Changes nothing.")
        #expect(InviteRole.add.explanation == "Adds transactions, and edits or deletes their own.")
        #expect(InviteRole.manage.explanation
                == "Edits budgets, edits or deletes anyone's transactions, and invites other people.")
    }
}
