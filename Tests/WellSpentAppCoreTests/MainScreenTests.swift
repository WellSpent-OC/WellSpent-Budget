import Testing
import Foundation
@testable import WellSpentAppCore
import WellSpentCrypto
import WellSpentKeyStore
import WellSpentModel
import WellSpentStore
import WellSpentSync

/// One person's device on a shared in-memory server, its window included.
/// Signed out unless an email is given; signed up and confirmed if one is.
@MainActor
private struct Device {
    let sync: SyncCoordinator
    let workspace: Workspace
    let screen: MainScreen
    var model: AppModel { workspace.model }

    init(_ email: String? = nil, on server: InMemoryReadableServer = InMemoryReadableServer(),
         defaults: UserDefaults = isolatedDefaults()) async throws {
        let store = Store(database: try WellSpentDatabase.inMemory())
        let transport = StubReadableTransport(server: server)
        sync = SyncCoordinator(store: store, keyStore: InMemoryKeyStore(), defaults: defaults,
                               makeTransport: { _ in transport })
        workspace = Workspace(model: AppModel(store: store), sync: sync)
        screen = MainScreen(workspace: workspace)
        if let email {
            try await sync.signUp(email: email, password: "a-long-password")
            try await sync.verifyEmail(code: try #require(server.lastCode(for: email, purpose: .verify)))
        }
    }
}

/// Robin's Household with a Groceries budget, shared with Leslie at `level`,
/// both synced since.
@MainActor
private func household(leslieAt level: InviteRole) async throws -> (robin: Device, leslie: Device, group: GroupID) {
    let server = InMemoryReadableServer()
    let robin = try await Device("robin@example.com", on: server)
    let group = try #require(robin.model.addGroup(named: "Household"))
    robin.model.addBudget(named: "Groceries", limit: .dollars(500), in: group)
    await robin.sync.syncAll()

    let share = ShareScreen(actions: robin.sync, group: group, groupName: "Household")
    share.myName = "Robin"
    share.role = level
    #expect(await share.create())
    let leslie = try await Device("leslie@example.com", on: server)
    let join = JoinScreen(actions: leslie.sync, linkText: try #require(share.link).url)
    join.myName = "Leslie"
    #expect(await join.join())
    await leslie.sync.syncAll()
    await robin.sync.syncAll()
    return (robin, leslie, group)
}

private func titles(_ menu: [[MainScreen.MenuItem]]) -> [[String]] {
    menu.map { $0.map(\.title) }
}

@Suite("Main screen", .serialized)
@MainActor
struct MainScreenTests {
    // MARK: - The left side

    @Test func aGroupListsItsBudgetsAndHidingThemIsRemembered() async throws {
        let defaults = isolatedDefaults()
        let device = try await Device(defaults: defaults)
        let group = try #require(device.model.addGroup(named: "Household"))
        device.model.addBudget(named: "Groceries", limit: .dollars(500), in: group)

        let household = try #require(device.screen.sections.first { $0.id == group })
        #expect(household.title == "Household")
        #expect(household.budgets.map(\.budget.name) == ["Groceries"])
        #expect(!household.isCollapsed && household.toggleHelp == "Hide budgets")

        device.screen.toggle(group)
        let hidden = try #require(device.screen.sections.first { $0.id == group })
        #expect(hidden.isCollapsed && hidden.budgets.isEmpty && hidden.toggleHelp == "Show budgets")

        // A new window on the same settings, as after a restart.
        let again = MainScreen(workspace: device.workspace)
        #expect(again.sections.first { $0.id == group }?.isCollapsed == true)
        #expect(defaults.string(forKey: MainScreen.collapsedKey) == group.uuid.uuidString,
                "the Mac's sidebar setting, so its hidden groups carry over")
    }

    @Test func theRightSideSaysWhatToDoUntilABudgetIsPicked() async throws {
        let device = try await Device()
        // A fresh device seeds no samples here: that is Workspace.launch's job.
        #expect(device.screen.detail == .noBudgets)
        let group = try #require(device.model.addGroup(named: "Household"))
        let budget = try #require(device.model.addBudget(named: "Groceries", limit: .dollars(500), in: group))
        device.screen.selectedBudget = nil
        #expect(device.screen.detail == .noneSelected)
        device.screen.selectedBudget = budget
        #expect(device.screen.detail == .budget(try #require(device.model.summary(for: budget))))
    }

    // MARK: - Menus

    /// A group only on this device is its owner's: every item, and a delete.
    @Test func anOwnerIsOfferedEverything() async throws {
        let device = try await Device()
        let id = try #require(device.model.addGroup(named: "Household"))
        let budgetID = try #require(device.model.addBudget(named: "Groceries", limit: .dollars(500), in: id))
        let group = try #require(device.model.group(named: id))
        let budget = try #require(device.model.budget(for: budgetID))

        #expect(titles(device.screen.groupMenu(group))
            == [["Share…", "People…"], ["New Budget in Household…", "Rename…"], ["Delete…"]])
        #expect(titles(device.screen.budgetMenu(budget)) == [["Edit…"], ["Delete…"]])
        #expect(device.screen.groupMenu(group).last?.first?.isDestructive == true)
        #expect(device.screen.groupsForNewBudget.map(\.id) == [id])
        #expect(device.screen.addButton.title == "Add Budget")
        #expect(device.screen.addMenu.map(\.action) == [.newGroup, .join])
    }

    /// Below Manage, the server refuses budget changes, so none are offered,
    /// and a shared group is left rather than deleted.
    @Test func aMemberAtAddMayShareListAndLeave() async throws {
        let (_, leslie, id) = try await household(leslieAt: .add)
        let group = try #require(leslie.model.group(named: id))
        let budget = try #require(leslie.model.summaries[id]?.first?.budget)

        #expect(titles(leslie.screen.groupMenu(group)) == [["Share…", "People…"], ["Leave…"]])
        #expect(leslie.screen.budgetMenu(budget).isEmpty)
        #expect(leslie.screen.groupsForNewBudget.isEmpty)
    }

    /// The owner of a shared group deletes it for everyone, and is told so.
    @Test func theOwnerOfASharedGroupDeletesItForEveryone() async throws {
        let (robin, _, id) = try await household(leslieAt: .add)
        let group = try #require(robin.model.group(named: id))
        #expect(titles(robin.screen.groupMenu(group)).last == ["Delete…"])

        robin.screen.ask(.deleteGroup(group))
        let pending = try #require(robin.screen.pendingDelete)
        #expect(!pending.isLeave && pending.confirmLabel == "Delete")
        #expect(pending.message.hasPrefix("Everyone you share it with loses it too."))
        robin.screen.keepIt()
        #expect(robin.screen.pendingDelete == nil)
        #expect(robin.model.groups.map(\.id) == [id])
    }

    // MARK: - Deleting and leaving

    @Test func leavingAsksFirstAndTheGroupGoesFromThisDevice() async throws {
        let (robin, leslie, id) = try await household(leslieAt: .add)
        let group = try #require(leslie.model.group(named: id))

        leslie.screen.ask(.deleteGroup(group))
        let pending = try #require(leslie.screen.pendingDelete)
        #expect(pending.isLeave)
        #expect(pending.title == "Leave \u{201C}Household\u{201D}?")
        #expect(pending.confirmLabel == "Leave")
        #expect(pending.message == SyncWording.leaveGroupMessage)

        // The dialog may clear its question before its button runs.
        leslie.screen.keepIt()
        leslie.screen.confirm(pending)
        #expect(leslie.screen.pendingDelete == nil)
        #expect(leslie.model.groups.isEmpty)

        await leslie.sync.syncAll()
        await robin.sync.syncAll()
        #expect(robin.sync.members(of: id).count == 1, "Leslie left on the server too")
        #expect(robin.model.groups.map(\.id) == [id], "Robin keeps the group")
    }

    @Test func deletingABudgetSaysWhatGoesWithIt() async throws {
        let device = try await Device()
        let id = try #require(device.model.addGroup(named: "Household"))
        let budgetID = try #require(device.model.addBudget(named: "Groceries", limit: .dollars(500), in: id))
        device.screen.selectedBudget = budgetID
        device.model.addTransaction(merchant: "Hilltop Grocery", amount: .dollars(42), date: Date(), note: "")
        let budget = try #require(device.model.budget(for: budgetID))

        device.screen.ask(.deleteBudget(budget))
        let pending = try #require(device.screen.pendingDelete)
        #expect(pending.title == "Delete \u{201C}Groceries\u{201D}?")
        #expect(pending.message == "Its 1 transaction will be deleted too. This cannot be undone.")
        #expect(pending.confirmLabel == "Delete")

        device.screen.confirm(pending)
        #expect(device.model.summaries[id]?.isEmpty ?? true)
        #expect(device.screen.detail == .noBudgets)
    }

    /// Only the two deletes ask first; the rest are sheets.
    @Test func onlyDeletesAskFirst() async throws {
        let device = try await Device()
        let id = try #require(device.model.addGroup(named: "Household"))
        let group = try #require(device.model.group(named: id))
        #expect(MainScreen.Action.deleteGroup(group).asksFirst)
        #expect(!MainScreen.Action.renameGroup(group).asksFirst)
        device.screen.ask(.renameGroup(group))
        #expect(device.screen.pendingDelete == nil)
    }

    // MARK: - The footer

    /// A wrong password at sign-in leaves the state failed, but saying so is
    /// the sign-in sheet's job: signed out, the footer shows no failure.
    @Test func aFailedSignInIsNotAFooterFailure() async throws {
        let device = try await Device()
        try? await device.sync.signIn(email: "nobody@example.com", password: "a-wrong-password")
        guard case .failed = device.sync.state else {
            Issue.record("a wrong sign-in should leave the state failed, or this test proves nothing")
            return
        }
        #expect(device.screen.syncFailure == nil)
        #expect(device.screen.footer == "Kept on this computer only")
    }

    @Test func theFooterFollowsTheAccount() async throws {
        let server = InMemoryReadableServer()
        let device = try await Device(on: server)
        #expect(device.screen.footer == "Kept on this computer only")
        #expect(device.screen.accountTitle == "Sign in")
        #expect(!device.screen.showsSync)
        await device.screen.syncNow()
        #expect(device.screen.syncFailure == nil, "signed out, a sync is not even tried")

        try await device.sync.signUp(email: "robin@example.com", password: "a-long-password")
        #expect(device.screen.footer == "Syncs through WellSpent's server")
        #expect(device.screen.accountTitle == "Account")
        #expect(device.screen.accountHelp == "Signed in as robin@example.com.")
        #expect(device.screen.showsSync)
        await device.screen.syncNow()
        #expect(device.screen.syncFailure == nil)
        #expect(!device.screen.isBusy && !device.screen.syncShowsProgress)
    }
}
