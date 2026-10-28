import Foundation
import XCTest
import WellSpentAppCore
import WellSpentCrypto
import WellSpentModel

/// What a person does on a phone without an account: the samples on a fresh
/// install, groups and budgets, and adding entries. No server and no account,
/// so these run on every pull request. Each test starts the app on a fresh
/// data folder.
final class PhoneLocalTests: XCTestCase {
    /// The run's data folder, for tearDown.
    nonisolated(unsafe) private static var dataRootPath: String?

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    override func tearDown() {
        let app = XCUIApplication()
        if app.state != .notRunning { app.terminate() }
        if let path = Self.dataRootPath { try? FileManager.default.removeItem(atPath: path) }
        Self.dataRootPath = nil
        super.tearDown()
    }

    @MainActor
    private func launched() -> PhoneTestApp {
        let run = PhoneTestApp()
        Self.dataRootPath = run.dataRoot.path
        run.launch()
        return run
    }

    @MainActor
    func testAFreshInstallOpensOnHomeWithTheSamples() throws {
        // Scenario ACCT-15
        // 1. A staging build says so across the top.
        let run = launched()

        // Scenario SAMP-01
        // 2. Home shows the two sample groups in capitals, with their
        // budgets, and no budget opens by itself.
        let household = run.element(AccessibilityID.sidebarGroup("Household"))
        XCTAssertTrue(household.waitForExistence(timeout: 10), "no Household. On screen: \(run.visibleTexts())")
        XCTAssertTrue(household.label.contains("HOUSEHOLD"), "the group's name is not in capitals: \(household.label)")
        XCTAssertTrue(run.element(AccessibilityID.sidebarGroup("Side Business")).exists)
        for budget in ["Groceries", "Eating out", "Utilities", "Materials"] {
            XCTAssertTrue(run.element(AccessibilityID.sidebarBudget(budget)).exists, "no \(budget) on Home")
        }
        XCTAssertFalse(run.element(AccessibilityID.budgetAdd).exists, "a budget opened by itself")

        // Scenario ACCT-01
        // 3. The foot says the budgets are kept on this iPhone, with Sign in.
        XCTAssertTrue(run.shows(SyncWording.footer(signedIn: false, device: PhoneTestApp.device)),
                      "the foot does not say where the budgets are kept. On screen: \(run.visibleTexts())")
        XCTAssertTrue(run.element(AccessibilityID.sidebarSignIn).exists, "no Sign in at the foot")
    }

    @MainActor
    func testGroupsAndBudgets() throws {
        let run = launched()

        // Scenario BUDGET-01
        // 1. + then New Group: Add stays dimmed until the group has a name,
        // then the group shows on Home with no budgets.
        run.openAddMenu()
        run.tapMenuItem(MainScreen.Words.newGroup)
        let save = run.button(AccessibilityID.groupEditorSave)
        XCTAssertTrue(save.waitForExistence(timeout: 10))
        XCTAssertFalse(save.isEnabled, "Add lit with no name")
        run.type("Trip", into: AccessibilityID.groupEditorName)
        run.tap(AccessibilityID.groupEditorSave)
        XCTAssertTrue(run.element(AccessibilityID.sidebarGroup("Trip")).waitForExistence(timeout: 10))

        // Scenario BUDGET-02
        // 2. Rename from the group's menu. Home's card above the groups
        // leaves a new group low on the screen, where a long press opens
        // nothing, so it is scrolled up first.
        run.scrollTo(AccessibilityID.sidebarGroup("Trip"))
        run.longPress(AccessibilityID.sidebarGroup("Trip"))
        run.tapMenuItem(MainScreen.Words.rename)
        run.type("Holiday", into: AccessibilityID.groupEditorName)
        run.tap(AccessibilityID.groupEditorSave)
        XCTAssertTrue(run.element(AccessibilityID.sidebarGroup("Holiday")).waitForExistence(timeout: 10))
        XCTAssertFalse(run.element(AccessibilityID.sidebarGroup("Trip")).exists)

        // Scenario BUDGET-03, BUDGET-04
        // 3. New Budget from the group's menu. Add stays dimmed without a
        // name and an amount above zero. Saving opens the new budget, with
        // nothing spent.
        run.scrollTo(AccessibilityID.sidebarGroup("Holiday"))
        run.longPress(AccessibilityID.sidebarGroup("Holiday"))
        run.tapMenuItem(MainScreen.Words.newBudget(in: "Holiday"))
        let budgetSave = run.button(AccessibilityID.budgetEditorSave)
        XCTAssertTrue(budgetSave.waitForExistence(timeout: 10))
        run.type("Flights", into: AccessibilityID.budgetEditorName)
        run.type("0", into: AccessibilityID.budgetEditorAmount)
        XCTAssertFalse(budgetSave.isEnabled, "Add lit at 0")
        run.type("800", into: AccessibilityID.budgetEditorAmount)
        XCTAssertTrue(run.wait(for: budgetSave, until: "isEnabled == true", timeout: 30), "Add stayed dimmed")
        run.tap(AccessibilityID.budgetEditorSave)
        XCTAssertTrue(run.app.navigationBars["Flights"].waitForExistence(timeout: 10), "Flights did not open")
        XCTAssertTrue(run.shows("$0.00"), "$0.00 does not show. On screen: \(run.visibleTexts())")
        XCTAssertTrue(run.waitForLabel(AccessibilityID.budgetWheel, toBe: "Left $800 of $800"),
                      "the wheel does not say Left $800 of $800. On screen: \(run.visibleTexts())")
        XCTAssertTrue(run.shows("$800.00"), "$800.00 does not show. On screen: \(run.visibleTexts())")

        // Scenario BUDGET-06
        // 4. Edit under ⋯ changes the monthly amount.
        run.openBudgetMenu()
        run.tapMenuItem(MainScreen.Words.edit)
        run.type("650", into: AccessibilityID.budgetEditorAmount)
        run.tap(AccessibilityID.budgetEditorSave)
        XCTAssertTrue(run.waitForLabel(AccessibilityID.budgetWheel, toBe: "Left $650 of $650"),
                      "the new amount does not show. On screen: \(run.visibleTexts())")

        // Scenario BUDGET-08
        // 5. Delete under ⋯ asks first. Deleting goes back to Home, without
        // the budget.
        run.openBudgetMenu()
        run.tapMenuItem(MainScreen.Words.delete)
        let question = PendingDelete.budget(Budget(groupID: GroupID(), name: "Flights", limit: .zero()), transactions: 0)
        XCTAssertTrue(run.shows(question.title), "no question. On screen: \(run.visibleTexts())")
        XCTAssertTrue(run.shows(question.message), "\(question.message) does not show. On screen: \(run.visibleTexts())")
        try XCTUnwrap(run.questionButton(question.confirmLabel), "no \(question.confirmLabel) on the question").tap()
        XCTAssertTrue(run.element(AccessibilityID.sidebarGroup("Holiday")).waitForExistence(timeout: 10),
                      "not back on Home")
        XCTAssertFalse(run.element(AccessibilityID.sidebarBudget("Flights")).exists, "Flights is still on Home")

        // Scenario BUDGET-11
        // 6. Deleting the group asks first, then it goes.
        run.scrollTo(AccessibilityID.sidebarGroup("Holiday"))
        run.longPress(AccessibilityID.sidebarGroup("Holiday"))
        run.tapMenuItem(MainScreen.Words.delete)
        let groupQuestion = PendingDelete.group(BudgetGroup(name: "Holiday"), budgets: 0, reach: .justYou)
        XCTAssertTrue(run.shows(groupQuestion.title), "\(groupQuestion.title) does not show. On screen: \(run.visibleTexts())")
        try XCTUnwrap(run.questionButton(groupQuestion.confirmLabel)).tap()
        XCTAssertTrue(run.wait(for: run.element(AccessibilityID.sidebarGroup("Holiday")), until: "exists == false",
                               timeout: 10), "Holiday is still on Home")
    }

    @MainActor
    func testAddingEntries() throws {
        let run = launched()
        run.addBudget(named: "Treats", amount: "100", inGroup: "Household")

        // Scenario ENTRY-02, ENTRY-07
        // 1. Add opens a sheet for a new transaction. Its Add stays dimmed
        // until there is a merchant and an amount. (The phone's number pad
        // has no letters to type an amount that is not a number.) Cancel
        // adds nothing.
        run.tap(AccessibilityID.budgetAdd)
        XCTAssertTrue(run.app.navigationBars[EntryEditor.Words.title].waitForExistence(timeout: 10))
        let add = run.button(AccessibilityID.entryAdd)
        XCTAssertFalse(add.isEnabled, "Add lit with nothing in it")
        run.type("Corner Bakery", into: AccessibilityID.entryMerchant)
        XCTAssertFalse(add.isEnabled, "Add lit with no amount")
        run.type("12.00", into: AccessibilityID.entryAmount)
        XCTAssertTrue(run.wait(for: add, until: "isEnabled == true", timeout: 5), "Add stayed dimmed")
        run.tap(AccessibilityID.entryCancel)
        XCTAssertTrue(run.wait(for: add, until: "exists == false", timeout: 10), "the sheet did not close")
        XCTAssertFalse(run.element(AccessibilityID.entryRow("Corner Bakery")).exists, "Cancel added it")

        // Scenario ENTRY-01, ENTRY-04
        // 2. Add puts it in the open budget, with today, Manual and the
        // amount, and the note under the merchant. The page adds it up.
        run.addEntry(merchant: "Corner Bakery", amount: "40.00", note: "birthday cake")
        let today = BudgetScreen.shortDate(Date())
        XCTAssertTrue(run.row("Corner Bakery", says: "\(today) · Manual"), "no date and source line. The row says: \(run.rowLabel("Corner Bakery"))")
        XCTAssertTrue(run.row("Corner Bakery", says: "birthday cake"), "birthday cake does not show. The row says: \(run.rowLabel("Corner Bakery"))")
        XCTAssertTrue(run.waitForLabel(AccessibilityID.budgetWheel, toBe: "Left $60 of $100"),
                      "what is left is wrong. On screen: \(run.visibleTexts())")
        XCTAssertTrue(run.shows("1 transaction since \(Self.startOfMonth())"), "1 transaction since \(Self.startOfMonth()) does not show. On screen: \(run.visibleTexts())")

        // Scenario ENTRY-05, BUDGET-15
        // 3. The newest is on top. Over the limit, the page says how far
        // over, and Home shows how far over.
        run.addEntry(merchant: "Market", amount: "75.00")
        let market = run.element(AccessibilityID.entryRow("Market"))
        let bakery = run.element(AccessibilityID.entryRow("Corner Bakery"))
        XCTAssertLessThan(market.frame.minY, bakery.frame.minY, "Market is not on top")
        XCTAssertTrue(run.shows("$115.00"), "$115.00 does not show. On screen: \(run.visibleTexts())")
        XCTAssertTrue(run.waitForLabel(AccessibilityID.budgetWheel, toBe: "Over $15 of $100"),
                      "the wheel does not say Over $15 of $100. On screen: \(run.visibleTexts())")
        XCTAssertTrue(run.shows("Over") && run.shows("$15.00"), "no over. On screen: \(run.visibleTexts())")
        XCTAssertTrue(run.shows("2 transactions since \(Self.startOfMonth())"), "2 transactions since \(Self.startOfMonth()) does not show. On screen: \(run.visibleTexts())")
        run.goBack()
        let row = run.element(AccessibilityID.sidebarBudget("Treats"))
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        XCTAssertTrue(row.label.contains("$15.00 over"), "Home does not show $15.00 over: \(row.label)")
    }

    @MainActor
    func testAGroupsPageAndJoiningWhileSignedOut() throws {
        let run = launched()
        let household = AccessibilityID.sidebarGroup("Household")
        XCTAssertTrue(run.element(household).waitForExistence(timeout: 10), "no Household")

        // Scenario PAGE-05
        // 1. The arrow beside a group's name hides its budgets, and shows
        // them again.
        run.tap(AccessibilityID.sidebarGroupToggle("Household"))
        XCTAssertTrue(run.wait(for: run.element(AccessibilityID.sidebarBudget("Groceries")), until: "exists == false",
                               timeout: 10), "Groceries still shows")
        run.tap(AccessibilityID.sidebarGroupToggle("Household"))
        XCTAssertTrue(run.element(AccessibilityID.sidebarBudget("Groceries")).waitForExistence(timeout: 10),
                      "Groceries did not come back")

        // Scenario PAGE-01, PAGE-07
        // 2. A tap on the group's name opens its page. Signed out, it says
        // only that it is not shared, and lists nobody.
        run.openGroupPage(named: "Household")
        let summary = run.element(AccessibilityID.groupSummary)
        XCTAssertTrue(summary.waitForExistence(timeout: 10), "no page. On screen: \(run.visibleTexts())")
        XCTAssertEqual(summary.label, MembersScreen.Words.notShared)
        XCTAssertFalse(run.text(MembersScreen.Words.people).exists, "the page lists people")
        XCTAssertFalse(run.element(AccessibilityID.groupLeave).exists, "the page offers Leave Group")

        // Scenario PAGE-13, SHARE-04
        // 3. Invite Someone opens the Share sheet, which says to sign in
        // first, and Send Invite stays dimmed with all fields filled. Cancel
        // goes back to the page.
        run.tap(AccessibilityID.groupInvite)
        XCTAssertTrue(run.text("Invite someone to “Household”").waitForExistence(timeout: 10),
                      "no Share sheet. On screen: \(run.visibleTexts())")
        XCTAssertTrue(run.text(ShareScreen.Words.signInToShare).exists, "no sign-in notice")
        run.type("Robin", into: AccessibilityID.shareName)
        run.type("Leslie", into: AccessibilityID.shareInviteeName)
        run.type("person@example.com", into: AccessibilityID.shareEmail)
        XCTAssertFalse(run.button(AccessibilityID.shareCreate).isEnabled, "Send Invite is not dimmed")
        run.tap(AccessibilityID.shareCancel)
        XCTAssertTrue(run.wait(for: run.text("Invite someone to “Household”"), until: "exists == false",
                               timeout: 10), "the Share sheet did not close")
        XCTAssertTrue(summary.exists, "the page closed with the sheet")

        // 4. Back goes Home.
        run.goBack()
        XCTAssertTrue(run.element(AccessibilityID.sidebarAdd).waitForExistence(timeout: 10), "not back on Home")

        // Scenario SHARE-08, CLICK-13
        // 5. Join a Group says when a pasted link is cut short, and when it is
        // the other app's.
        run.openAddMenu()
        run.tapMenuItem(MainScreen.Words.join)
        run.paste("wellspent-staging://join#s=abc", into: AccessibilityID.joinLink)
        XCTAssertTrue(run.text(JoinScreen.Words.notWhole).waitForExistence(timeout: 10),
                      "no cut-short notice. On screen: \(run.visibleTexts())")
        run.paste("wellspent://join#s=abc", into: AccessibilityID.joinLink)
        XCTAssertTrue(run.text(JoinScreen.Words.otherApp(AppEnvironment.live.appName)).waitForExistence(timeout: 10),
                      "no other-app notice. On screen: \(run.visibleTexts())")

        // Scenario SHARE-09
        // 6. Signed out, it says joining needs an account, and Sign in opens
        // the account sheet in its place.
        XCTAssertTrue(run.text(JoinScreen.Words.signInToJoin).exists, "no sign-in notice")
        XCTAssertFalse(run.button(AccessibilityID.joinJoin).isEnabled, "Join is not dimmed")
        run.app.buttons[PhoneWording.button(JoinScreen.Words.signIn)].firstMatch.tap()
        XCTAssertTrue(run.element(AccessibilityID.accountEmail).waitForExistence(timeout: 10),
                      "no account sheet. On screen: \(run.visibleTexts())")
        run.tap(AccessibilityID.accountClose)

        // Scenario CLICK-08
        // 7. A tapped link cut short opens a page that says part of it is
        // missing. Back takes the page down.
        run.open(link: "wellspent-staging://join#s=abc")
        XCTAssertTrue(run.text(JoinScreen.Words.notWhole).waitForExistence(timeout: 10),
                      "no page for the link. On screen: \(run.visibleTexts())")
        run.goBack()
        XCTAssertTrue(run.element(AccessibilityID.sidebarAdd).waitForExistence(timeout: 10), "not back on Home")
    }

    @MainActor
    func testPeopleInTheMenuOpensThePageAndANewBudgetTakesItsPlace() throws {
        let run = launched()
        XCTAssertTrue(run.element(AccessibilityID.sidebarGroup("Household")).waitForExistence(timeout: 10), "no Household")

        // Scenario PAGE-02
        // 1. People in Household's menu opens its page, as a tap on its name
        // does.
        run.longPress(AccessibilityID.sidebarGroup("Household"))
        run.tapMenuItem(MembersScreen.Words.menuItem)
        let summary = run.element(AccessibilityID.groupSummary)
        XCTAssertTrue(summary.waitForExistence(timeout: 10), "People did not open the page. On screen: \(run.visibleTexts())")
        XCTAssertTrue(run.app.navigationBars["Household"].exists, "the page is not Household's")

        // Scenario PAGE-03
        // 2. A budget picked after takes the page's place: Back, then
        // Groceries, shows Groceries, and Back from it goes Home, not to the
        // page.
        run.goBack()
        run.openBudget(named: "Groceries")
        run.goBack()
        XCTAssertTrue(run.element(AccessibilityID.sidebarAdd).waitForExistence(timeout: 10), "not back on Home")
        XCTAssertFalse(summary.exists, "the group's page came back")

        // Scenario PAGE-03
        // 3. A new budget, saved from the page's menu, opens in the page's
        // place, and Back from it goes Home.
        run.openGroupPage(named: "Household")
        XCTAssertTrue(summary.waitForExistence(timeout: 10), "no page")
        run.tap(AccessibilityID.groupMenu)
        run.tapMenuItem(MainScreen.Words.newBudget(in: "Household"))
        run.type("Gifts", into: AccessibilityID.budgetEditorName)
        run.type("80", into: AccessibilityID.budgetEditorAmount)
        run.tap(AccessibilityID.budgetEditorSave)
        XCTAssertTrue(run.app.navigationBars["Gifts"].waitForExistence(timeout: 10), "Gifts did not open in the page's place")
        run.goBack()
        XCTAssertTrue(run.element(AccessibilityID.sidebarAdd).waitForExistence(timeout: 10), "not back on Home")
        XCTAssertFalse(summary.exists, "the group's page came back")
    }

    @MainActor
    func testWithNoBudgetsHomeSaysHowToStartAndANewBudgetMakesAGroup() throws {
        let run = launched()
        for group in ["Household", "Side Business"] {
            run.longPress(AccessibilityID.sidebarGroup(group))
            run.tapMenuItem(MainScreen.Words.delete)
            try XCTUnwrap(run.questionButton("Delete"), "no Delete on the question").tap()
            XCTAssertTrue(run.wait(for: run.element(AccessibilityID.sidebarGroup(group)), until: "exists == false",
                                   timeout: 10), "\(group) is still on Home")
        }

        // Scenario BUDGET-10
        // 1. With no budgets, Home says so, says what a budget is, and offers
        // Add Budget, which opens New Budget.
        XCTAssertTrue(run.text(MainScreen.Words.noBudgetsTitle).waitForExistence(timeout: 10),
                      "Home does not say there are no budgets. On screen: \(run.visibleTexts())")
        XCTAssertTrue(run.text(MainScreen.Words.noBudgetsText).exists, "no line saying what a budget is")
        // The empty list's own Add Budget, not the + at the foot, which goes
        // by the same name.
        run.app.buttons.matching(NSPredicate(format: "label == %@ AND identifier != %@", MainScreen.Words.addBudget,
                                             AccessibilityID.sidebarAdd)).firstMatch.tap()

        // Scenario BUDGET-05
        // 2. With no group to put it in, New Budget asks for a group's name,
        // with Personal filled in, and Add stays dimmed while it is empty or
        // only spaces. Added, PERSONAL holds Groceries, and Groceries opens.
        let groupField = run.element(AccessibilityID.budgetEditorGroup)
        XCTAssertTrue(groupField.waitForExistence(timeout: 10), "no group name. On screen: \(run.visibleTexts())")
        XCTAssertEqual(run.fieldText(AccessibilityID.budgetEditorGroup), BudgetEditor.Words.defaultGroupName)
        run.type("Groceries", into: AccessibilityID.budgetEditorName)
        run.type("500", into: AccessibilityID.budgetEditorAmount)
        let save = run.button(AccessibilityID.budgetEditorSave)
        XCTAssertTrue(save.isEnabled, "Add is dimmed with a group name")
        run.type("   ", into: AccessibilityID.budgetEditorGroup)
        XCTAssertTrue(run.wait(for: save, until: "isEnabled == false", timeout: 5), "Add lit with only spaces")
        run.type(BudgetEditor.Words.defaultGroupName, into: AccessibilityID.budgetEditorGroup)
        run.tap(AccessibilityID.budgetEditorSave)
        XCTAssertTrue(run.app.navigationBars["Groceries"].waitForExistence(timeout: 10), "Groceries did not open")
        run.goBack()
        let personal = run.element(AccessibilityID.sidebarGroup(BudgetEditor.Words.defaultGroupName))
        XCTAssertTrue(personal.waitForExistence(timeout: 10), "no PERSONAL on Home")
        XCTAssertTrue(personal.label.contains("PERSONAL"), "the group's name: \(personal.label)")
        XCTAssertTrue(run.element(AccessibilityID.sidebarBudget("Groceries")).exists, "Groceries is not under PERSONAL")
    }

    @MainActor
    func testAnOpenBudgetSaysWhatIsSpentAndLeftThisPeriod() throws {
        let run = launched()
        let budget = "Food Probe"
        run.addBudget(named: budget, amount: "500", inGroup: "Household")
        run.addEntry(merchant: "Hilltop Grocery", amount: "142.08")
        run.addEntry(merchant: "Corner Bakery", amount: "12.00")
        let calendar = Calendar.current
        let today = Date()
        var parts = calendar.dateComponents([.year, .month], from: calendar.date(byAdding: .month, value: -1, to: today) ?? today)
        parts.day = 20
        let lastMonth = try XCTUnwrap(calendar.date(from: parts))
        run.tap(AccessibilityID.budgetAdd)
        run.type("Market", into: AccessibilityID.entryMerchant)
        run.type("9.50", into: AccessibilityID.entryAmount)
        run.pickDate(lastMonth, showing: today)
        run.tap(AccessibilityID.entryAdd)
        XCTAssertTrue(run.wait(for: run.element(AccessibilityID.entryAmount), until: "exists == false", timeout: 10),
                      "the sheet did not close")

        // Scenario BUDGET-14
        // 1. The budget says $154.08 spent and $345.92 left this period, its
        // wheel shows what is left of $500, the line under the figures counts
        // 2 transactions since the 1st, and it lists this month's two and not
        // last month's Market. Home shows $345.92 beside it.
        XCTAssertTrue(run.figure(MoneyWheel.Words.spent, is: "$154.08"), "Spent is not $154.08. On screen: \(run.visibleTexts())")
        XCTAssertTrue(run.figure(MoneyWheel.Words.left, is: "$345.92"), "Left is not $345.92. On screen: \(run.visibleTexts())")
        XCTAssertTrue(run.waitForLabel(AccessibilityID.budgetWheel, toBe: "Left $346 of $500"),
                      "the wheel does not show what is left of $500. On screen: \(run.visibleTexts())")
        XCTAssertTrue(run.shows("2 transactions since \(Self.startOfMonth())"), "no count of 2. On screen: \(run.visibleTexts())")
        XCTAssertTrue(run.hasRow("Hilltop Grocery"), "Hilltop Grocery is not listed")
        XCTAssertTrue(run.hasRow("Corner Bakery"), "Corner Bakery is not listed")
        XCTAssertFalse(run.element(AccessibilityID.entryRow("Market")).exists, "last month's Market is listed")
        run.goBack()
        let row = run.scrollTo(AccessibilityID.sidebarBudget(budget))
        XCTAssertTrue(row.label.contains("$345.92"), "Home does not show $345.92 beside it: \(row.label)")

        // Scenario BUDGET-14
        // 2. With one transaction, the line says 1 transaction.
        run.openBudget(named: budget)
        run.openEntry("Corner Bakery")
        run.tap(AccessibilityID.entryDelete)
        run.answer("Delete")
        run.expectNoSheet()
        XCTAssertTrue(run.shows("1 transaction since \(Self.startOfMonth())"), "no count of 1. On screen: \(run.visibleTexts())")
    }

    /// "Oct 1", the way a budget's count line names the start of the month.
    private static func startOfMonth() -> String {
        let calendar = Calendar.current
        let start = calendar.date(from: calendar.dateComponents([.year, .month], from: Date())) ?? Date()
        return start.formatted(.dateTime.day().month(.abbreviated))
    }
}
