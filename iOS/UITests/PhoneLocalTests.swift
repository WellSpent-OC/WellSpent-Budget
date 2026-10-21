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
        // 2. Rename from the group's menu.
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
        run.longPress(AccessibilityID.sidebarGroup("Holiday"))
        run.tapMenuItem(MainScreen.Words.newBudget(in: "Holiday"))
        let budgetSave = run.button(AccessibilityID.budgetEditorSave)
        XCTAssertTrue(budgetSave.waitForExistence(timeout: 10))
        run.type("Flights", into: AccessibilityID.budgetEditorName)
        run.type("0", into: AccessibilityID.budgetEditorAmount)
        XCTAssertFalse(budgetSave.isEnabled, "Add lit at 0")
        run.type("800", into: AccessibilityID.budgetEditorAmount)
        XCTAssertTrue(run.wait(for: budgetSave, until: "isEnabled == true", timeout: 5), "Add stayed dimmed")
        run.tap(AccessibilityID.budgetEditorSave)
        XCTAssertTrue(run.app.navigationBars["Flights"].waitForExistence(timeout: 10), "Flights did not open")
        XCTAssertTrue(run.shows("$0.00"), "$0.00 does not show. On screen: \(run.visibleTexts())")
        XCTAssertTrue(run.shows("of $800.00 this period"), "of $800.00 this period does not show. On screen: \(run.visibleTexts())")
        XCTAssertTrue(run.shows("$800.00 left"), "$800.00 left does not show. On screen: \(run.visibleTexts())")

        // Scenario BUDGET-06
        // 4. Edit under ⋯ changes the monthly amount.
        run.openBudgetMenu()
        run.tapMenuItem(MainScreen.Words.edit)
        run.type("650", into: AccessibilityID.budgetEditorAmount)
        run.tap(AccessibilityID.budgetEditorSave)
        XCTAssertTrue(run.shows("of $650.00 this period"),
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
        XCTAssertTrue(run.shows("\(today) · Manual"), "no date and source line. On screen: \(run.visibleTexts())")
        XCTAssertTrue(run.shows("birthday cake"), "birthday cake does not show. On screen: \(run.visibleTexts())")
        XCTAssertTrue(run.shows("$60.00 left"), "what is left is wrong. On screen: \(run.visibleTexts())")
        XCTAssertTrue(run.shows("1 transaction since \(Self.startOfMonth())"), "1 transaction since \(Self.startOfMonth()) does not show. On screen: \(run.visibleTexts())")

        // Scenario ENTRY-05, BUDGET-15
        // 3. The newest is on top. Over the limit, the page says how far
        // over, and Home shows it below zero.
        run.addEntry(merchant: "Market", amount: "75.00")
        let market = run.element(AccessibilityID.entryRow("Market"))
        let bakery = run.element(AccessibilityID.entryRow("Corner Bakery"))
        XCTAssertLessThan(market.frame.minY, bakery.frame.minY, "Market is not on top")
        XCTAssertTrue(run.shows("$115.00"), "$115.00 does not show. On screen: \(run.visibleTexts())")
        XCTAssertTrue(run.shows("$15.00 over"), "no over. On screen: \(run.visibleTexts())")
        XCTAssertTrue(run.shows("2 transactions since \(Self.startOfMonth())"), "2 transactions since \(Self.startOfMonth()) does not show. On screen: \(run.visibleTexts())")
        run.goBack()
        let row = run.element(AccessibilityID.sidebarBudget("Treats"))
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        XCTAssertTrue(row.label.contains("-$15.00"), "Home does not show -$15.00: \(row.label)")
    }

    /// "Oct 1", the way a budget's count line names the start of the month.
    private static func startOfMonth() -> String {
        let calendar = Calendar.current
        let start = calendar.date(from: calendar.dateComponents([.year, .month], from: Date())) ?? Date()
        return start.formatted(.dateTime.day().month(.abbreviated))
    }
}
