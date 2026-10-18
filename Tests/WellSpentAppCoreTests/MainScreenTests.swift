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
        #expect(pending.message.hasPrefix(
            "You leave the group, and it is removed from all your devices, with its 1 budget. Other members keep it."))

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

    /// A delete that takes entries asks first and says how many. Every
    /// budget counts, and every period, not only this one. Cancel keeps all
    /// of it.
    @Test func deletingAGroupNamesItAndHowManyTransactionsGoAndCancelKeepsThem() async throws {
        let device = try await Device()
        let id = try #require(device.model.addGroup(named: "Household"))
        let groceries = try #require(device.model.addBudget(named: "Groceries", limit: .dollars(500), in: id))
        device.model.addTransaction(merchant: "Hilltop Grocery", amount: .dollars(42), date: Date(), note: "")
        let longAgo = try #require(Calendar.current.date(byAdding: .month, value: -2, to: Date()))
        device.model.addTransaction(merchant: "Costco", amount: .dollars(28.63), date: longAgo, note: "")
        let eatingOut = try #require(device.model.addBudget(named: "Eating out", limit: .dollars(200), in: id))
        device.model.addTransaction(merchant: "Sunrise Cafe", amount: .dollars(12), date: Date(), note: "")
        let group = try #require(device.model.group(named: id))

        device.screen.ask(.deleteGroup(group))
        let pending = try #require(device.screen.pendingDelete)
        #expect(pending.title == "Delete \u{201C}Household\u{201D}?")
        #expect(device.screen.message(for: pending)
                == "Its 2 budgets and 3 transactions will be deleted too. This cannot be undone.")

        device.screen.keepIt()
        #expect(device.screen.pendingDelete == nil)
        #expect(device.model.groups.map(\.id) == [id])
        #expect(try device.model.store.transactions(in: groceries).count == 2)
        #expect(try device.model.store.transactions(in: eatingOut).count == 1)
    }

    /// Robin made Household and shares it, so his delete reaches Leslie too.
    @Test func theOwnerOfASharedGroupIsToldHowManyTransactionsGoForEveryone() async throws {
        let (robin, _, id) = try await household(leslieAt: .add)
        robin.model.selectedBudget = try #require(robin.model.summaries[id]?.first?.budget.id)
        robin.model.addTransaction(merchant: "Hilltop Grocery", amount: .dollars(142.08), date: Date(), note: "")
        robin.model.addTransaction(merchant: "Costco", amount: .dollars(28.63), date: Date(), note: "")
        let group = try #require(robin.model.group(named: id))

        robin.screen.ask(.deleteGroup(group))
        let pending = try #require(robin.screen.pendingDelete)
        #expect(pending.title == "Delete \u{201C}Household\u{201D}?")
        #expect(robin.screen.message(for: pending) == "Everyone you share it with loses it too. "
                + "Its 1 budget and 2 transactions will be deleted too. This cannot be undone.")
    }

    /// Leslie, at Add, may not delete Robin's group for everyone, so Delete is
    /// a leave. The question still says how many go from her devices.
    @Test func leavingSaysHowManyTransactionsGoFromYourDevices() async throws {
        let (robin, leslie, id) = try await household(leslieAt: .add)
        let groceries = try #require(robin.model.summaries[id]?.first?.budget.id)
        robin.model.selectedBudget = groceries
        robin.model.addTransaction(merchant: "Hilltop Grocery", amount: .dollars(142.08), date: Date(), note: "")
        await robin.sync.syncAll()
        await leslie.sync.syncAll()
        leslie.model.selectedBudget = groceries
        leslie.model.addTransaction(merchant: "Costco", amount: .dollars(28.63), date: Date(), note: "")
        let group = try #require(leslie.model.group(named: id))

        leslie.screen.ask(.deleteGroup(group))
        let pending = try #require(leslie.screen.pendingDelete)
        #expect(pending.isLeave)
        #expect(pending.title == "Leave \u{201C}Household\u{201D}?")
        #expect(leslie.screen.message(for: pending).hasPrefix(
            "You leave the group, and it is removed from all your devices, with its 1 budget and 2 transactions. "
            + "Other members keep it."))
    }

    /// What a group's delete counts: live transactions in every budget and
    /// every period, and none from another group.
    @Test func aGroupCountsItsTransactionsInEveryBudgetAndPeriod() async throws {
        let device = try await Device()
        let id = try #require(device.model.addGroup(named: "Household"))
        device.model.addBudget(named: "Groceries", limit: .dollars(500), in: id)
        device.model.addTransaction(merchant: "Hilltop Grocery", amount: .dollars(42), date: Date(), note: "")
        let longAgo = try #require(Calendar.current.date(byAdding: .month, value: -2, to: Date()))
        device.model.addTransaction(merchant: "Costco", amount: .dollars(28.63), date: longAgo, note: "")
        device.model.addBudget(named: "Eating out", limit: .dollars(200), in: id)
        device.model.addTransaction(merchant: "Sunrise Cafe", amount: .dollars(12), date: Date(), note: "")
        let gone = try #require(device.model.transactions.first)
        device.model.deleteEntry(gone.id)
        device.model.addTransaction(merchant: "Riverside Grill", amount: .dollars(30), date: Date(), note: "")
        let other = try #require(device.model.addGroup(named: "Side Business"))
        device.model.addBudget(named: "Materials", limit: .dollars(900), in: other)
        device.model.addTransaction(merchant: "Lumber", amount: .dollars(300), date: Date(), note: "")

        #expect(device.model.transactionCount(inGroup: id) == 3, "the deleted one does not count")
        #expect(device.model.transactionCount(inGroup: other) == 1)
        #expect(device.model.transactionCount(inGroup: GroupID()) == 0)
    }

    /// The question says how many go, and that many go: every transaction
    /// still in the group, in every period, and nothing from another group.
    @Test func aGroupsDeleteTakesAsManyTransactionsAsItsQuestionSaid() async throws {
        let device = try await Device()
        let id = try #require(device.model.addGroup(named: "Household"))
        let groceries = try #require(device.model.addBudget(named: "Groceries", limit: .dollars(500), in: id))
        device.model.addTransaction(merchant: "Hilltop Grocery", amount: .dollars(42), date: Date(), note: "")
        let longAgo = try #require(Calendar.current.date(byAdding: .month, value: -2, to: Date()))
        device.model.addTransaction(merchant: "Costco", amount: .dollars(28.63), date: longAgo, note: "")
        let eatingOut = try #require(device.model.addBudget(named: "Eating out", limit: .dollars(200), in: id))
        device.model.addTransaction(merchant: "Sunrise Cafe", amount: .dollars(12), date: Date(), note: "")
        device.model.deleteEntry(try #require(device.model.transactions.first).id)
        device.model.addTransaction(merchant: "Riverside Grill", amount: .dollars(30), date: Date(), note: "")
        let side = try #require(device.model.addGroup(named: "Side Business"))
        let materials = try #require(device.model.addBudget(named: "Materials", limit: .dollars(900), in: side))
        device.model.addTransaction(merchant: "Lumber", amount: .dollars(300), date: Date(), note: "")
        let store = device.model.store
        let inHousehold = try store.transactions(in: groceries).count + store.transactions(in: eatingOut).count
        #expect(inHousehold == 3)

        device.screen.ask(.deleteGroup(try #require(device.model.group(named: id))))
        let pending = try #require(device.screen.pendingDelete)
        #expect(device.screen.message(for: pending)
                == "Its 2 budgets and 3 transactions will be deleted too. This cannot be undone.")
        device.screen.confirm(pending)

        #expect(try store.transactions(in: groceries).isEmpty && store.transactions(in: eatingOut).isEmpty,
                "all 3 went")
        #expect(try store.budgets(in: id).isEmpty)
        #expect(try store.transactions(in: materials).map(\.merchant) == ["Lumber"], "nothing else went")
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

    // MARK: - A group's page

    /// A click on a group's name, or People… in its menu, opens the group's
    /// page on the right, where a budget opens. A click on a budget opens it
    /// again, even the one that was open before.
    @Test func aGroupsPageOpensInPlaceOfTheBudgetUntilABudgetIsPicked() async throws {
        let device = try await Device()
        let id = try #require(device.model.addGroup(named: "Household"))
        let groceries = try #require(device.model.addBudget(named: "Groceries", limit: .dollars(500), in: id))
        #expect(device.screen.selectedBudget == groceries)
        #expect(device.screen.openGroup == nil)

        device.screen.openPage(of: id)
        #expect(device.screen.openGroup?.id == id)
        #expect(device.screen.openGroup?.name == "Household")
        #expect(device.screen.selectedBudget == nil, "no budget is picked on the left while the page shows")

        device.screen.selectedBudget = groceries
        #expect(device.screen.openGroup == nil)
        #expect(device.screen.selectedBudget == groceries)
        #expect(device.screen.detail == .budget(try #require(device.model.summary(for: groceries))))
    }

    /// The left side marks the group whose page shows, so the person knows
    /// where they are, and marks none once a budget shows instead.
    @Test func theLeftSideMarksTheGroupWhosePageShows() async throws {
        let device = try await Device()
        let household = try #require(device.model.addGroup(named: "Household"))
        let groceries = try #require(device.model.addBudget(named: "Groceries", limit: .dollars(500), in: household))
        let side = try #require(device.model.addGroup(named: "Side Business"))
        #expect(device.screen.sections.filter(\.isPageOpen).isEmpty)

        device.screen.openPage(of: side)
        #expect(device.screen.sections.filter(\.isPageOpen).map(\.id) == [side])

        device.screen.openPage(of: household)
        #expect(device.screen.sections.filter(\.isPageOpen).map(\.id) == [household])

        device.screen.selectedBudget = groceries
        #expect(device.screen.sections.filter(\.isPageOpen).isEmpty, "a budget shows in place of the page")
    }

    /// The list on the left may let go of its pick while the page shows. That
    /// is not a click on a budget, so the page stays.
    @Test func aGroupsPageStaysWhenTheListLetsGoOfItsPick() async throws {
        let device = try await Device()
        let id = try #require(device.model.addGroup(named: "Household"))
        let groceries = try #require(device.model.addBudget(named: "Groceries", limit: .dollars(500), in: id))
        device.screen.openPage(of: id)

        device.screen.selectedBudget = nil
        #expect(device.screen.openGroup?.id == id)
        #expect(device.model.selectedBudget == groceries, "the budget under the page is still the one picked")
    }

    /// A budget that opens on its own, as a new one does once it is saved,
    /// shows in place of the page.
    @Test func aNewBudgetOpensInPlaceOfTheGroupsPage() async throws {
        let device = try await Device()
        let id = try #require(device.model.addGroup(named: "Household"))
        device.model.addBudget(named: "Groceries", limit: .dollars(500), in: id)
        device.screen.openPage(of: id)
        #expect(device.screen.openGroup?.id == id)

        let eatingOut = try #require(device.model.addBudget(named: "Eating out", limit: .dollars(200), in: id))
        #expect(device.screen.openGroup == nil)
        #expect(device.screen.selectedBudget == eatingOut)
    }

    @Test func aGroupsPageClosesOnceTheGroupIsGone() async throws {
        let device = try await Device()
        let id = try #require(device.model.addGroup(named: "Household"))
        let group = try #require(device.model.group(named: id))
        let other = try #require(device.model.addGroup(named: "Side Business"))
        device.screen.openPage(of: other)
        device.screen.openPage(of: id)
        #expect(device.screen.openGroup?.id == id, "the last one asked for")

        device.screen.ask(.deleteGroup(group))
        device.screen.confirm(try #require(device.screen.pendingDelete))
        #expect(device.screen.openGroup == nil)
        #expect(device.model.groups.map(\.id) == [other])
    }

    /// A delete on the left is not a click on a budget, so the page stays.
    /// That holds for the budget that was open before the page, and for
    /// another group with that budget in it.
    @Test func aGroupsPageStaysWhenABudgetOrAnotherGroupIsDeleted() async throws {
        let device = try await Device()
        let household = try #require(device.model.addGroup(named: "Household"))
        device.model.addBudget(named: "Eating out", limit: .dollars(200), in: household)
        let groceries = try #require(device.model.addBudget(named: "Groceries", limit: .dollars(500), in: household))
        let side = try #require(device.model.addGroup(named: "Side Business"))
        let materials = try #require(device.model.addBudget(named: "Materials", limit: .dollars(900), in: side))

        device.screen.selectedBudget = groceries
        device.screen.openPage(of: household)
        device.screen.ask(.deleteBudget(try #require(device.model.budget(for: groceries))))
        device.screen.confirm(try #require(device.screen.pendingDelete))
        #expect(device.model.budget(for: groceries) == nil)
        #expect(device.screen.openGroup?.id == household, "the budget under the page went, and the page stays")
        #expect(device.screen.selectedBudget == nil, "no budget is picked on the left while the page shows")

        device.screen.selectedBudget = materials
        device.screen.openPage(of: household)
        device.screen.ask(.deleteGroup(try #require(device.model.group(named: side))))
        device.screen.confirm(try #require(device.screen.pendingDelete))
        #expect(device.model.groups.map(\.id) == [household])
        #expect(device.screen.openGroup?.id == household, "another group went, with the budget under the page")
    }

    /// Leave Group… on the page is always a leave, never a delete for
    /// everyone, whatever this person's level. Leslie is an admin, so her
    /// group's menu offers Delete…, but the page leaves.
    @Test func leaveGroupOnAGroupsPageAsksFirstAndIsAlwaysALeave() async throws {
        let (robin, leslie, id) = try await household(leslieAt: .manage)
        let owners = MembersScreen(actions: robin.sync, group: id, groupName: "Household")
        await owners.refresh()
        await owners.setLevel(.admin, for: try #require(owners.rows.first { !$0.isYou }).id)
        await leslie.sync.syncAll()
        let group = try #require(leslie.model.group(named: id))
        #expect(titles(leslie.screen.groupMenu(group)).last == ["Delete…"], "her menu deletes it for everyone")

        leslie.screen.openPage(of: id)
        leslie.screen.askToLeave(group)
        let pending = try #require(leslie.screen.pendingDelete)
        #expect(pending.isLeave && pending.confirmLabel == "Leave")
        #expect(pending.title == "Leave \u{201C}Household\u{201D}?")
        #expect(leslie.screen.message(for: pending).hasPrefix(
            "You leave the group, and it is removed from all your devices, with its 1 budget. Other members keep it."))

        leslie.screen.keepIt()
        #expect(leslie.model.groups.map(\.id) == [id], "Cancel keeps it")
        leslie.screen.askToLeave(group)
        leslie.screen.confirm(try #require(leslie.screen.pendingDelete))
        #expect(leslie.model.groups.isEmpty)
        #expect(leslie.screen.openGroup == nil, "the page goes with the group")

        await leslie.sync.syncAll()
        await robin.sync.syncAll()
        #expect(robin.model.groups.map(\.id) == [id], "Robin keeps it: she left, and deleted nothing")
        #expect(robin.sync.members(of: id).count == 1)
    }

    // MARK: - Entries

    /// The row's menu offers Edit and Delete only where the server
    /// would take them. Robin owns Household, and Leslie is at Add.
    @Test func anEntrysMenuOffersEditAndDeleteOnlyToSomeoneWhoMayChangeIt() async throws {
        let (robin, leslie, id) = try await household(leslieAt: .add)
        let groceries = try #require(robin.model.summaries[id]?.first?.budget.id)
        robin.model.selectedBudget = groceries
        robin.model.addTransaction(merchant: "Hilltop Grocery", amount: .dollars(142.08), date: Date(), note: "")
        await robin.sync.syncAll()
        await leslie.sync.syncAll()
        leslie.model.selectedBudget = groceries
        leslie.model.addTransaction(merchant: "Costco", amount: .dollars(28.63), date: Date(), note: "")

        let screen = BudgetScreen(summary: try #require(leslie.model.summary(for: groceries)), model: leslie.model,
                                  me: leslie.sync.userID)
        let hilltop = try #require(screen.rows.first { $0.merchant == "Hilltop Grocery" })
        let costco = try #require(screen.rows.first { $0.merchant == "Costco" })
        #expect(!hilltop.mayChange && costco.mayChange)
        #expect(leslie.screen.entryMenu(hilltop).isEmpty, "Robin's, so no menu")
        let menu = leslie.screen.entryMenu(costco)
        #expect(menu.map { $0.map(\.title) } == [["Edit…"], ["Delete…"]])
        #expect(menu.flatMap { $0 }.map(\.action) == [.open(costco.id), .delete(costco.id)])
        #expect(menu.last?.first?.isDestructive == true && menu.first?.first?.isDestructive == false)

        let owners = BudgetScreen(summary: try #require(robin.model.summary(for: groceries)), model: robin.model,
                                  me: robin.sync.userID)
        let hisRow = try #require(owners.rows.first { $0.merchant == "Hilltop Grocery" })
        #expect(robin.screen.entryMenu(hisRow).count == 2, "the owner changes anyone's")
    }

    /// The question names the entry and its amount, and says who it
    /// comes out for. Cancel keeps it. Delete takes it out and offers Undo.
    @Test func deletingAnEntryFromItsMenuAsksFirst() async throws {
        let (robin, leslie, id) = try await household(leslieAt: .manage)
        let groceries = try #require(robin.model.summaries[id]?.first?.budget.id)
        robin.model.selectedBudget = groceries
        robin.model.addTransaction(merchant: "Hilltop Grocery", amount: .dollars(142.08), date: Date(), note: "")
        await robin.sync.syncAll()
        await leslie.sync.syncAll()
        leslie.model.selectedBudget = groceries
        let hilltop = try #require(leslie.model.transactions.first)

        leslie.screen.ask(.delete(hilltop.id))
        let pending = try #require(leslie.screen.pendingDelete)
        #expect(pending.title == "Delete \u{201C}Hilltop Grocery\u{201D}, $142.08?")
        #expect(leslie.screen.message(for: pending) == "It comes out of Groceries for everyone in Household.")
        #expect(pending.confirmLabel == "Delete" && !pending.isLeave)

        leslie.screen.keepIt()
        #expect(leslie.screen.pendingDelete == nil)
        #expect(leslie.model.transactions.map(\.id) == [hilltop.id], "Cancel changes nothing")

        leslie.screen.ask(.delete(hilltop.id))
        leslie.screen.confirm(try #require(leslie.screen.pendingDelete))
        #expect(leslie.model.transactions.isEmpty)
        #expect(leslie.model.undoOffer?.message == "Deleted \u{201C}Hilltop Grocery\u{201D}, $142.08.")
    }

    @Test func inAGroupNobodyElseIsInTheQuestionSaysOnlyWhereItComesOutOf() async throws {
        let device = try await Device()
        let id = try #require(device.model.addGroup(named: "Household"))
        let budget = try #require(device.model.addBudget(named: "Groceries", limit: .dollars(500), in: id))
        device.screen.selectedBudget = budget
        device.model.addTransaction(merchant: "Hilltop Grocery", amount: .dollars(142.08), date: Date(), note: "")
        let entry = try #require(device.model.transactions.first)

        #expect(MainScreen.EntryAction.delete(entry.id).asksFirst)
        #expect(!MainScreen.EntryAction.open(entry.id).asksFirst)
        device.screen.ask(.open(entry.id))
        #expect(device.screen.pendingDelete == nil, "opening asks nothing")

        device.screen.ask(.delete(entry.id))
        let pending = try #require(device.screen.pendingDelete)
        #expect(device.screen.message(for: pending) == "It comes out of Groceries.")
    }

    /// A delete confirmed after a move down changes nothing, and says why.
    @Test func aDeleteConfirmedAfterAMoveDownChangesNothingAndSaysWhy() async throws {
        let (robin, leslie, id) = try await household(leslieAt: .manage)
        let groceries = try #require(robin.model.summaries[id]?.first?.budget.id)
        robin.model.selectedBudget = groceries
        robin.model.addTransaction(merchant: "Hilltop Grocery", amount: .dollars(142.08), date: Date(), note: "")
        await robin.sync.syncAll()
        await leslie.sync.syncAll()
        leslie.model.selectedBudget = groceries
        let hilltop = try #require(leslie.model.transactions.first)
        leslie.screen.ask(.delete(hilltop.id))
        let pending = try #require(leslie.screen.pendingDelete)

        let members = MembersScreen(actions: robin.sync, group: id, groupName: "Household")
        await members.refresh()
        await members.setLevel(.write, for: try #require(members.rows.first { !$0.isYou }).id)
        await leslie.sync.syncAll()
        leslie.screen.confirm(pending)

        #expect(leslie.model.transactions.map(\.id) == [hilltop.id])
        #expect(leslie.model.errorMessage == "Nothing was changed. Only Robin, or a manager, can change this.")
        #expect(leslie.model.undoOffer == nil)
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

/// The question a group's delete asks first, in the shared words: it names
/// the group and says how many budgets and transactions go with it, at each
/// reach. A group's delete is final on the server, so it never offers Undo
/// and always says it cannot be undone.
@Suite("The group delete question")
struct GroupDeleteQuestionTests {
    private let household = BudgetGroup(name: "Household")

    /// Nobody else is in the group.
    @Test func nobodyElseInItIsToldHowManyTransactionsAreDeleted() {
        let pending = PendingDelete.group(household, budgets: 2, transactions: 14, reach: .justYou)
        #expect(pending.title == "Delete \u{201C}Household\u{201D}?")
        #expect(pending.message == "Its 2 budgets and 14 transactions will be deleted too. This cannot be undone.")
        #expect(pending.confirmLabel == "Delete" && !pending.isLeave)
    }

    /// Shared, and this person may delete it for every member.
    @Test func everyoneItIsSharedWithLosesItAndIsToldHowMany() {
        let pending = PendingDelete.group(household, budgets: 2, transactions: 14, reach: .everyone)
        #expect(pending.title == "Delete \u{201C}Household\u{201D}?")
        #expect(pending.message == "Everyone you share it with loses it too. "
                + "Its 2 budgets and 14 transactions will be deleted too. This cannot be undone.")
        #expect(pending.confirmLabel == "Delete" && !pending.isLeave)
    }

    /// Shared, and only its founder or an admin may delete it for everyone:
    /// this person leaves it. It goes from their devices, and the others keep
    /// it, so nothing is said to be deleted.
    @Test func aLeaveSaysHowManyGoFromYourDevicesAndTheOthersKeepThem() {
        let pending = PendingDelete.group(household, budgets: 1, transactions: 1, reach: .thisMacOnly)
        #expect(pending.title == "Leave \u{201C}Household\u{201D}?")
        #expect(pending.confirmLabel == "Leave" && pending.isLeave)
        #expect(pending.message(sendsChanges: true)
                == "You leave the group, and it is removed from all your devices, with its 1 budget and "
                + "1 transaction. Other members keep it. Anything you changed in it on this device that has "
                + "not synced yet still goes to them first. Changes on your other devices that have not synced "
                + "yet do not reach them. Only the person who made it, or an admin, can delete it for everyone. "
                + "To come back, ask for a new invite link.")
        #expect(pending.message(sendsChanges: false)
                == "You leave the group, and it is removed from all your devices, with its 1 budget and "
                + "1 transaction. Other members keep it. Only the person who made it, or an admin, can delete "
                + "it for everyone. To come back, ask for a new invite link.")
        #expect(!pending.message.contains("deleted"))
    }

    /// One is said as one, and a count of none is left out.
    @Test func oneIsSaidAsOneAndNoneIsLeftOut() {
        func words(_ budgets: Int, _ transactions: Int, _ reach: GroupDeleteReach = .justYou) -> String {
            PendingDelete.group(household, budgets: budgets, transactions: transactions, reach: reach).message
        }
        #expect(words(1, 1) == "Its 1 budget and 1 transaction will be deleted too. This cannot be undone.")
        #expect(words(3, 0) == "Its 3 budgets will be deleted too. This cannot be undone.")
        #expect(words(0, 0) == "This cannot be undone.")
        #expect(words(0, 0, .thisMacOnly)
                == "You leave the group, and it is removed from all your devices. Other members keep it. "
                + "Anything you changed in it on this device that has not synced yet still goes to them first. "
                + "Changes on your other devices that have not synced yet do not reach them. Only the person "
                + "who made it, or an admin, can delete it for everyone. To come back, ask for a new invite link.",
                "today's words, with nothing to count")
    }
}
