import AppKit
import Foundation
import XCTest
import WellSpentAppCore
import WellSpentCrypto
import WellSpentModel
import WellSpentStore

/// Groups and budgets in the real window, with no account: the samples on a
/// first opening, a budget opening by itself, making, renaming, changing and
/// deleting, what an open budget says about this period, each row's fill and
/// the open budget's outline, a budget over its limit, an amount in a region
/// that writes decimals with a comma, and the Edit menu with its keys.
///
/// Each test opens the app as it opens the first time on a Mac
/// (`launchAsFirstOpening`), so it starts with the two sample groups and
/// nothing else. A test that uses the scenarios' own names, such as
/// Household and Groceries, deletes the samples first, since a sample of the
/// same name would be a second line with that name.
///
/// What a test expects comes from the shared code, never typed in: the
/// screens' words, `TodaysBudget` for what a budget shows, `PendingDelete`
/// for a delete's question, and `MacMenu` for the Edit menu. A row's fill
/// and the open budget's outline are read the way a screen reader reads
/// them: the share used, and which row is selected. Colours are not read:
/// XCUITest takes no picture of a window on a display other than the main
/// one, and the window may open there.
///
/// Not here: the samples coming only once (SAMP-07). It needs an account
/// made on this computer, which a run without signing in cannot make.
///
/// No account is needed. The run's data folder holds everything, and goes
/// in tearDown, with what the Edit menu test leaves on the clipboard.
final class BudgetGapTests: XCTestCase {
    /// The run's data folder, for tearDown.
    nonisolated(unsafe) private static var dataRootPath: String?
    /// The day the scenarios' "October 18" stands for, before the last week
    /// of any month.
    private static let midMonth = 18

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    /// Closes the app and leaves nothing of the run on this Mac, the
    /// clipboard included.
    override func tearDown() {
        let app = XCUIApplication()
        if app.state != .notRunning { app.terminate() }
        TestApp.wipeSettings()
        if let path = Self.dataRootPath { try? FileManager.default.removeItem(atPath: path) }
        Self.dataRootPath = nil
        NSPasteboard.general.clearContents()
        super.tearDown()
    }

    // MARK: - The samples, and a budget always open

    @MainActor
    func testAFirstOpeningShowsTheSamplesAndABudgetOpensByItself() throws {
        let run = try start()
        let opened = Date()

        // 1. WellSpent opened for the first time on this Mac, signed out.
        run.launchAsFirstOpening()

        // Scenario SAMP-01
        // 2. The list shows two groups, Household and Side Business, their
        // names in capitals, each with its sample budgets.
        XCTAssertEqual(run.groupLines(), ["Household", "Side Business"].map(AccessibilityID.sidebarGroup),
                       "the groups in the list")
        run.expectGroupLine("Household")
        run.expectGroupLine("Side Business")
        run.expect(budgets: ["Groceries", "Eating out", "Utilities"], under: "Household")
        run.expect(budgets: ["Materials"], under: "Side Business")

        // Scenario SAMP-01
        // 3. Each sample budget's wheel says its limit, and its list holds
        // the sample entries dated this month, each 3 to 12 days before the
        // first opening. Early in a month the ones from the month before are
        // not listed, so all six are listed from the 13th on. Before the 13th
        // only the listed ones are checked, since the seed keeps each
        // sample's day to itself.
        let samples: [(budget: String, limit: Int, entries: [String])] = [
            ("Groceries", 100_000, ["Hilltop Grocery", "Costco", "Sunny's"]),
            ("Eating out", 30_000, ["Sunrise Cafe", "Riverside Grill"]),
            ("Utilities", 45_000, ["Regional Power"]),
            ("Materials", 500_000, []),
        ]
        let days = Self.sampleDays(before: opened)
        var listed = 0
        for sample in samples {
            run.openBudget(named: sample.budget)
            run.expect(wheel: AccessibilityID.budgetWheel, endsWith: Self.limitWords(sample.limit), sample.budget)
            for merchant in sample.entries where run.isListed(merchant) {
                run.expect(entry: merchant, datedOneOf: days.thisMonth)
                listed += 1
            }
        }
        if days.allThisMonth {
            XCTAssertEqual(listed, 6, "from the 13th on, all six sample entries are this month's")
        }

        // Scenario SAMP-01
        // 4. Household's delete question counts six entries, whichever month
        // each is in. Cancel keeps it.
        run.askToDelete(group: "Household",
                        expecting: .group(BudgetGroup(name: "Household"), budgets: 3, transactions: 6, reach: .justYou))
        run.answer(MainScreen.Words.cancel)

        // 5. Household is the only group, with Groceries and Eating out, and
        // Groceries is open.
        run.deleteGroup(named: "Side Business", holding: 1)
        run.deleteBudget(named: "Utilities", holding: 1)
        run.openBudget(named: "Groceries")
        run.expectOpen("Groceries", limit: 100_000)

        // Scenario BUDGET-09
        // 6. Deleting Groceries opens Eating out in its place.
        run.deleteBudget(named: "Groceries", holding: 3)
        run.expectOpen("Eating out", limit: 30_000)

        // Scenario BUDGET-10
        // 7. With Eating out deleted too there are no budgets, and the right
        // side says how to start. Its Add Budget opens the New Budget sheet,
        // and Cancel closes it.
        run.deleteBudget(named: "Eating out", holding: 2)
        XCTAssertTrue(run.listText(MainScreen.Words.noBudgetsTitle).waitForExistence(timeout: 10),
                      "the right side does not say \(MainScreen.Words.noBudgetsTitle). On screen: \(run.visibleTexts())")
        XCTAssertTrue(run.listText(MainScreen.Words.noBudgetsText).exists,
                      "the right side does not say \(MainScreen.Words.noBudgetsText) On screen: \(run.visibleTexts())")
        let start = try XCTUnwrap(run.rightSideButton(MainScreen.Words.addBudget),
                                  "no \(MainScreen.Words.addBudget) on the right side. On screen: \(run.visibleTexts())")
        start.click()
        XCTAssertTrue(run.app.staticTexts[BudgetEditor.Words.newTitle].waitForExistence(timeout: 10),
                      "\(MainScreen.Words.addBudget) did not open the New Budget sheet. On screen: \(run.visibleTexts())")
        run.click(AccessibilityID.budgetEditorCancel)
        XCTAssertTrue(run.wait(for: run.element(AccessibilityID.budgetEditorName), until: "exists == false",
                               timeout: 10), "the sheet stayed open")

        // Scenario BUDGET-05
        // 8. With Household deleted there is no group to put a budget in.
        // Add Budget asks for a new group's name in place of a list of
        // groups, with Personal filled in, and Add stays dimmed while that
        // name is empty or only spaces.
        run.deleteGroup(named: "Household", holding: 0)
        run.openNewBudget()
        let group = run.element(AccessibilityID.budgetEditorGroup)
        XCTAssertTrue(group.waitForExistence(timeout: 10), "no Group on the sheet. On screen: \(run.visibleTexts())")
        XCTAssertEqual(group.elementType, .textField, "the sheet offers a list of groups, not a new group's name")
        XCTAssertTrue(run.wait(for: group, holds: BudgetEditor.Words.defaultGroupName, timeout: 5),
                      "Group says \(run.text(of: group)), not \(BudgetEditor.Words.defaultGroupName)")
        run.type("Groceries", into: AccessibilityID.budgetEditorName)
        run.type("500", into: AccessibilityID.budgetEditorAmount)
        run.expect(AccessibilityID.budgetEditorSave, enabled: true, "Add, with a name, an amount and a group")
        run.clear(AccessibilityID.budgetEditorGroup)
        run.expect(AccessibilityID.budgetEditorSave, enabled: false, "Add, with no group name")
        run.type("   ", into: AccessibilityID.budgetEditorGroup)
        run.expect(AccessibilityID.budgetEditorSave, enabled: false, "Add, with only spaces for the group name")
        run.type(BudgetEditor.Words.defaultGroupName, into: AccessibilityID.budgetEditorGroup)
        run.expect(AccessibilityID.budgetEditorSave, enabled: true, "Add, with Personal again")

        // Scenario BUDGET-05
        // 9. Add makes the group, with Groceries under it, and Groceries
        // opens.
        run.click(AccessibilityID.budgetEditorSave)
        run.expectGroupLine(BudgetEditor.Words.defaultGroupName)
        run.expect(budgets: ["Groceries"], under: BudgetEditor.Words.defaultGroupName)
        run.expectOpen("Groceries", limit: 50_000)

        // Scenario BUDGET-09
        // 10. Quit and opened again, WellSpent has a budget open already:
        // Groceries, the only one.
        run.quitAndOpenAgain()
        run.expectOpen("Groceries", limit: 50_000)
    }

    // MARK: - A budget's changes, its period, and its delete

    @MainActor
    func testABudgetsChangesItsPeriodAndItsDelete() throws {
        let run = try start()
        let day = Self.midMonth

        // 1. The wheels on the 18th. The samples go, then Household, with
        // Groceries at $500.00 a month and Hilltop Grocery, $142.08, in it.
        run.launchAsFirstOpening(pinnedDay: day)
        run.deleteTheSamples()
        run.addGroup(named: "Household")
        run.addBudget(named: "Groceries", amount: "500", inGroup: "Household")
        run.addEntry(merchant: "Hilltop Grocery", amount: "142.08")

        // Scenario BUDGET-06
        // 2. Edit… for Groceries opens Edit Budget, with its name and its
        // monthly amount, and no choice of group.
        run.openEditBudget("Groceries")
        XCTAssertTrue(run.app.staticTexts[BudgetEditor.Words.editTitle].waitForExistence(timeout: 10),
                      "the sheet is not \(BudgetEditor.Words.editTitle). On screen: \(run.visibleTexts())")
        let name = run.element(AccessibilityID.budgetEditorName)
        let amount = run.element(AccessibilityID.budgetEditorAmount)
        XCTAssertTrue(run.wait(for: name, holds: "Groceries", timeout: 5), "Name says \(run.text(of: name))")
        let monthly = TypedAmount.text(Money(minorUnits: 50_000))
        XCTAssertTrue(run.wait(for: amount, holds: monthly, timeout: 5),
                      "Each month says \(run.text(of: amount)), not \(monthly)")
        XCTAssertFalse(run.element(AccessibilityID.budgetEditorGroup).exists, "Edit Budget offers a choice of group")

        // Scenario BUDGET-06
        // 3. Saved at 650, Groceries says what is left of $650.00, its wheel
        // says of $650, and the list shows what is left beside it.
        run.type("650", into: AccessibilityID.budgetEditorAmount)
        run.click(AccessibilityID.budgetEditorSave)
        let raised = TodaysBudget("Groceries", limit: 65_000, spent: 14_208, pinnedDay: day)
        run.expect(wheel: AccessibilityID.budgetWheel, reads: raised.wheel.spokenSummary, "Groceries at $650.00")
        run.expect(figures: raised.wheel.figures, "Groceries at $650.00")
        run.expect(row: "Groceries", endsWith: raised.row.amount)

        // 4. Back to $500.00 a month, then Corner Bakery, $12.00, and
        // Market, $9.50, dated the 15th of last month.
        run.openEditBudget("Groceries")
        run.type("500", into: AccessibilityID.budgetEditorAmount)
        run.click(AccessibilityID.budgetEditorSave)
        run.addEntry(merchant: "Corner Bakery", amount: "12.00")
        run.addEntry(merchant: "Market", amount: "9.50", dated: try Self.fifteenthOfLastMonth())

        // Scenario BUDGET-14
        // 5. Picked in the list, Groceries says what is spent and left this
        // period, counts this period's two entries and lists only those, and
        // the list shows what is left beside it.
        run.openGroupPage(named: "Household")
        run.openBudget(named: "Groceries")
        let thisPeriod = TodaysBudget("Groceries", limit: 50_000, spent: 15_408, pinnedDay: day)
        run.expect(wheel: AccessibilityID.budgetWheel, reads: thisPeriod.wheel.spokenSummary, "Groceries")
        run.expect(figures: thisPeriod.wheel.figures, "Groceries")
        let two = try Self.countLine(thisPeriod, entries: 2)
        XCTAssertTrue(run.listText(two).waitForExistence(timeout: 10),
                      "no line saying \(two). On screen: \(run.visibleTexts())")
        XCTAssertTrue(run.isListed("Hilltop Grocery"), "Hilltop Grocery is not listed")
        XCTAssertTrue(run.isListed("Corner Bakery"), "Corner Bakery is not listed")
        XCTAssertTrue(run.rowIsGone("Market"), "Market, from last month, is listed")
        run.expect(row: "Groceries", endsWith: thisPeriod.row.amount)

        // Scenario BUDGET-14
        // 6. Eating out, $200.00 a month, with one entry: its line counts
        // one transaction.
        run.addBudget(named: "Eating out", amount: "200", inGroup: "Household")
        run.addEntry(merchant: "Sunrise Cafe", amount: "42.50")
        let one = try Self.countLine(TodaysBudget("Eating out", limit: 20_000, spent: 4_250, pinnedDay: day),
                                     entries: 1)
        XCTAssertTrue(run.listText(one).waitForExistence(timeout: 10),
                      "no line saying \(one). On screen: \(run.visibleTexts())")

        // 7. Utilities, $450.00 a month, with nothing in it.
        run.addBudget(named: "Utilities", amount: "450", inGroup: "Household")

        // Scenario BUDGET-08
        // 8. Delete… for Groceries asks first, counting its 3 entries, the
        // one from last month too, and offers Delete and Cancel. Cancel
        // changes nothing.
        let three = PendingDelete.budget(Self.budget("Groceries"), transactions: 3)
        run.askToDelete(budget: "Groceries", expecting: three)
        XCTAssertNotNil(run.dialogButton(three.confirmLabel), "no \(three.confirmLabel) on the question")
        run.answer(MainScreen.Words.cancel)
        run.expect(row: "Groceries", shows: thisPeriod.row.amount)
        run.openBudget(named: "Groceries")
        run.expect(figures: thisPeriod.wheel.figures, "Groceries, after Cancel")
        XCTAssertTrue(run.isListed("Hilltop Grocery") && run.isListed("Corner Bakery"), "Cancel took entries away")

        // Scenario BUDGET-08
        // 9. Asked again, Delete takes Groceries and its 3 entries: the
        // group's own question then counts only Eating out's one.
        run.askToDelete(budget: "Groceries", expecting: three)
        run.answer(three.confirmLabel)
        XCTAssertTrue(run.wait(for: run.element(AccessibilityID.sidebarBudget("Groceries")), until: "exists == false",
                               timeout: 10), "Groceries is still in the list")
        run.askToDelete(group: "Household",
                        expecting: .group(BudgetGroup(name: "Household"), budgets: 2, transactions: 1, reach: .justYou))
        run.answer(MainScreen.Words.cancel)

        // Scenario BUDGET-08
        // 10. With 1 entry the question says so, and with none it says only
        // that a delete cannot be undone.
        run.deleteBudget(named: "Eating out", holding: 1, checkingTheQuestion: true)
        run.deleteBudget(named: "Utilities", holding: 0, checkingTheQuestion: true)
    }

    // MARK: - The rows, the open budget's outline, a new name, and over a limit

    @MainActor
    func testRowsTheOpenBudgetsOutlineANewNameAndOverALimit() throws {
        let run = try start()
        let save = AccessibilityID.budgetEditorSave

        // 1. The samples go, then Household.
        run.launchAsFirstOpening()
        run.deleteTheSamples()
        run.addGroup(named: "Household")

        // Scenario BUDGET-04
        // 2. On the New Budget sheet, Add stays dimmed with no name, or only
        // spaces, and with no amount above zero.
        run.openMenu(on: run.element(AccessibilityID.sidebarGroup("Household")),
                     AccessibilityID.sidebarGroup("Household"), offering: MainScreen.Words.newBudget(in: "Household"))
        run.clickMenuItem(MainScreen.Words.newBudget(in: "Household"))
        XCTAssertTrue(run.app.staticTexts[BudgetEditor.Words.newTitle].waitForExistence(timeout: 10),
                      "the New Budget sheet did not open. On screen: \(run.visibleTexts())")
        run.type("500", into: AccessibilityID.budgetEditorAmount)
        run.expect(save, enabled: false, "Add, with no name")
        run.type("   ", into: AccessibilityID.budgetEditorName)
        run.expect(save, enabled: false, "Add, with only spaces for a name")
        run.type("Groceries", into: AccessibilityID.budgetEditorName)
        run.clear(AccessibilityID.budgetEditorAmount)
        run.expect(save, enabled: false, "Add, with no amount")
        for typed in ["0", "lots"] {
            run.type(typed, into: AccessibilityID.budgetEditorAmount)
            run.expect(save, enabled: false, "Add, with \(typed) each month")
        }

        // Scenario BUDGET-04
        // 3. Groceries, at 500 or at 500.00, lights Add. Add makes it.
        for typed in ["500", "500.00"] {
            run.clear(AccessibilityID.budgetEditorAmount)
            run.expect(save, enabled: false, "Add, with no amount")
            run.type(typed, into: AccessibilityID.budgetEditorAmount)
            run.expect(save, enabled: true, "Add, with Groceries at \(typed)")
        }
        run.click(save)
        run.expectOpen("Groceries", limit: 50_000)

        // 4. Eating out, $200.00 a month, then $125.00 spent from Groceries.
        run.addBudget(named: "Eating out", amount: "200", inGroup: "Household")
        run.openBudget(named: "Groceries")
        run.addEntry(merchant: "Hilltop Grocery", amount: "125.00")

        // Scenario WHEEL-01
        // 5. Groceries' row is filled a quarter of the way, and still ends
        // with what is left. Eating out, with nothing spent, has no fill.
        let quarter = TodaysBudget("Groceries", limit: 50_000, spent: 12_500).row
        run.expectRow("Groceries", fills: quarter)
        run.expect(row: "Groceries", endsWith: quarter.amount)
        run.expectRow("Eating out", fills: TodaysBudget("Eating out", limit: 20_000, spent: 0).row)

        // 6. Groceries half used, and Eating out a quarter.
        run.addEntry(merchant: "Corner Bakery", amount: "125.00")
        run.openBudget(named: "Eating out")
        run.addEntry(merchant: "Sunrise Cafe", amount: "50.00")
        let half = TodaysBudget("Groceries", limit: 50_000, spent: 25_000).row
        let eatingOut = TodaysBudget("Eating out", limit: 20_000, spent: 5_000).row

        // Scenario WHEEL-03
        // 7. Picked in the list, Groceries' row is the outlined one, and
        // keeps its fill. Eating out's is not outlined, and keeps its own.
        run.openBudget(named: "Groceries")
        run.expectOutline(on: "Groceries", notOn: ["Eating out"])
        run.expectRow("Groceries", fills: half)
        run.expectRow("Eating out", fills: eatingOut)

        // Scenario WHEEL-03
        // 8. Picking Eating out moves the outline to it, and Groceries keeps
        // its fill.
        run.openBudget(named: "Eating out")
        run.expectOutline(on: "Eating out", notOn: ["Groceries"])
        run.expectRow("Groceries", fills: half)
        run.expectRow("Eating out", fills: eatingOut)

        // Scenario WHEEL-03
        // 9. While the group's page is open, no budget's row has the
        // outline.
        run.openGroupPage(named: "Household")
        run.expectOutline(on: nil, notOn: ["Groceries", "Eating out"])

        // Scenario BUDGET-02
        // 10. Rename… from Household's menu opens Rename Group with
        // Household in Name. Save stays dimmed while Name is empty or only
        // spaces.
        run.openMenu(on: run.element(AccessibilityID.sidebarGroup("Household")),
                     AccessibilityID.sidebarGroup("Household"), offering: MainScreen.Words.rename)
        run.clickMenuItem(MainScreen.Words.rename)
        XCTAssertTrue(run.app.staticTexts[GroupEditor.Words.renameTitle].waitForExistence(timeout: 10),
                      "the sheet is not \(GroupEditor.Words.renameTitle). On screen: \(run.visibleTexts())")
        let groupName = run.element(AccessibilityID.groupEditorName)
        XCTAssertTrue(run.wait(for: groupName, holds: "Household", timeout: 5), "Name says \(run.text(of: groupName))")
        run.clear(AccessibilityID.groupEditorName)
        run.expect(AccessibilityID.groupEditorSave, enabled: false, "Save, with no name")
        run.type("   ", into: AccessibilityID.groupEditorName)
        run.expect(AccessibilityID.groupEditorSave, enabled: false, "Save, with only spaces for a name")

        // Scenario BUDGET-02
        // 11. Saved as Home, the list shows HOME in place of HOUSEHOLD.
        run.type("Home", into: AccessibilityID.groupEditorName)
        run.expect(AccessibilityID.groupEditorSave, enabled: true, "Save, with Home")
        run.click(AccessibilityID.groupEditorSave)
        run.expectGroupLine("Home")
        XCTAssertTrue(run.wait(for: run.element(AccessibilityID.sidebarGroup("Household")), until: "exists == false",
                               timeout: 10), "HOUSEHOLD is still in the list")

        // 12. A new Groceries, $100.00 a month, in place of the first.
        run.deleteBudget(named: "Groceries", holding: 2)
        run.addBudget(named: "Groceries", amount: "100", inGroup: "Home")

        // Scenario BUDGET-15
        // 13. $40.00, then $75.00: Groceries says Spent $115.00, and Over
        // $15.00 in place of what is left. Its wheel says how far over, and
        // so does the list, beside Groceries.
        run.addEntry(merchant: "Market", amount: "40.00")
        run.addEntry(merchant: "Costco", amount: "75.00")
        let over = TodaysBudget("Groceries", limit: 10_000, spent: 11_500)
        run.expect(wheel: AccessibilityID.budgetWheel, reads: over.wheel.spokenSummary, "Groceries, over")
        run.expect(figures: over.wheel.figures, "Groceries, over")
        XCTAssertFalse(run.listText(MoneyWheel.Words.left).exists, "Groceries says what is left as well as Over")
        run.expect(row: "Groceries", shows: over.row.amount)
    }

    // MARK: - The Edit menu

    @MainActor
    func testTheEditMenuItsKeysAndCut() throws {
        let run = try start()
        let menu = try XCTUnwrap(Self.editMenu, "the shared code builds no Edit menu")
        func command(_ action: String) throws -> String {
            try XCTUnwrap(menu.items.first { $0.action == NSSelectorFromString(action) }?.title,
                          "no \(action) in the shared code's \(menu.title) menu")
        }

        // 1. A first opening, which opens a budget, then Add: a new
        // transaction's sheet.
        run.launchAsFirstOpening()
        run.click(AccessibilityID.budgetAdd)
        XCTAssertTrue(run.element(AccessibilityID.entryMerchant).waitForExistence(timeout: 10),
                      "no new transaction's sheet. On screen: \(run.visibleTexts())")

        // Scenario PASTE-08
        // 2. The Edit menu in the menu bar offers Undo, Redo, Cut, Copy,
        // Paste and Select All.
        let edit = run.app.menuBars.menuBarItems[menu.title]
        XCTAssertTrue(edit.waitForExistence(timeout: 5), "no \(menu.title) menu in the menu bar")
        edit.click()
        for action in Self.editActions {
            let title = try command(action)
            XCTAssertTrue(edit.menuItems[title].waitForExistence(timeout: 5),
                          "the \(menu.title) menu offers no \(title). Menu items on screen: \(run.visibleMenuItems())")
        }
        run.app.typeKey(.escape, modifierFlags: [])

        // Scenario PASTE-06
        // 3. Note holds weekly shop. Select all, then cut, leaves it empty,
        // and paste puts weekly shop back.
        let note = run.element(AccessibilityID.entryNote)
        run.type("weekly shop", into: AccessibilityID.entryNote)
        run.app.typeKey("a", modifierFlags: .command)
        run.app.typeKey("x", modifierFlags: .command)
        XCTAssertTrue(run.wait(for: note, holds: "", timeout: 5), "cut left Note saying \(run.text(of: note))")
        run.app.typeKey("v", modifierFlags: .command)
        XCTAssertTrue(run.wait(for: note, holds: "weekly shop", timeout: 5),
                      "paste did not put it back: Note says \(run.text(of: note))")

        // Scenario PASTE-08
        // 4. Each command's key, in Merchant: Command-A selects all,
        // Command-C copies, Command-V pastes, Command-Z takes the paste back,
        // Shift-Command-Z does it again, and Command-X cuts.
        let merchant = run.element(AccessibilityID.entryMerchant)
        func expectMerchant(_ shown: String, _ what: String) {
            XCTAssertTrue(run.wait(for: merchant, holds: shown, timeout: 5),
                          "\(what): Merchant says \(run.text(of: merchant)), not \(shown)")
        }
        run.type("Probe", into: AccessibilityID.entryMerchant)
        run.app.typeKey("a", modifierFlags: .command)
        run.app.typeKey("c", modifierFlags: .command)
        run.app.typeText("X")
        expectMerchant("X", "typing over what Command-A selected")
        run.app.typeKey("a", modifierFlags: .command)
        run.app.typeKey("v", modifierFlags: .command)
        expectMerchant("Probe", "Command-V, after Command-C")
        run.app.typeKey("z", modifierFlags: .command)
        expectMerchant("X", "Command-Z, taking the paste back")
        run.app.typeKey("z", modifierFlags: [.command, .shift])
        expectMerchant("Probe", "Shift-Command-Z, doing the paste again")
        run.app.typeKey("a", modifierFlags: .command)
        run.app.typeKey("x", modifierFlags: .command)
        expectMerchant("", "Command-X")
        run.app.typeKey("v", modifierFlags: .command)
        expectMerchant("Probe", "Command-V, after Command-X")

        // Scenario PASTE-08
        // 5. From the Edit menu itself: Corner Bakery typed in Merchant, then
        // Select All and Copy there, and Paste with the cursor in an empty
        // Note puts Corner Bakery there. The clipboard still holds Probe from
        // step 4, so only the menu's Copy can bring Corner Bakery.
        run.type("Corner Bakery", into: AccessibilityID.entryMerchant)
        expectMerchant("Corner Bakery", "typing new words over Probe")
        run.pick(try command("selectAll:"), from: menu.title)
        run.pick(try command("copy:"), from: menu.title)
        run.clear(AccessibilityID.entryNote)
        run.pick(try command("paste:"), from: menu.title)
        XCTAssertTrue(run.wait(for: note, holds: "Corner Bakery", timeout: 5),
                      "Paste from the \(menu.title) menu: Note says \(run.text(of: note))")
        run.click(AccessibilityID.entryCancel)
        run.expectNoSheet()
    }

    // MARK: - A region that writes decimals with a comma

    @MainActor
    func testARegionThatWritesDecimalsWithAComma() throws {
        let run = try start()
        let germany = Locale(identifier: "de_DE")

        // 1. Opened with the region set to Germany, which writes decimals
        // with a comma, then New Budget.
        run.launchAsFirstOpening(arguments: ["-AppleLocale", germany.identifier])
        run.openNewBudget()

        // Scenario BUDGET-16
        // 2. The empty Each month shows its example the region's way.
        let amount = run.element(AccessibilityID.budgetEditorAmount)
        XCTAssertTrue(amount.waitForExistence(timeout: 10), "no Each month. On screen: \(run.visibleTexts())")
        XCTAssertEqual(amount.placeholderValue, TypedAmount.text(Money(minorUnits: 50_000), locale: germany),
                       "the empty Each month's example")

        // Scenario BUDGET-16
        // 3. 500.00 can't be read clearly there: Add stays dimmed, and the
        // line under the amount says how to type it.
        run.type("Groceries", into: AccessibilityID.budgetEditorName)
        run.type("500.00", into: AccessibilityID.budgetEditorAmount)
        run.expect(AccessibilityID.budgetEditorSave, enabled: false, "Add, with 500.00 where a comma marks decimals")
        let problem = run.element(AccessibilityID.budgetEditorAmountProblem)
        let unclear = TypedAmount.Words.unclear(locale: germany)
        XCTAssertTrue(run.wait(for: problem, holds: unclear, timeout: 5),
                      "the line under the amount says \(run.text(of: problem)), not \(unclear)")

        // Scenario BUDGET-16
        // 4. 1.500,00 lights Add, and Add makes Groceries $1,500.00 a month.
        run.type("1.500,00", into: AccessibilityID.budgetEditorAmount)
        run.expect(AccessibilityID.budgetEditorSave, enabled: true, "Add, with 1.500,00")
        run.click(AccessibilityID.budgetEditorSave)
        let made = TodaysBudget("Groceries", limit: 150_000, spent: 0)
        run.expect(wheel: AccessibilityID.budgetWheel, reads: made.wheel.spokenSummary, "Groceries, made")
        run.expect(figures: made.wheel.figures, "Groceries, made")
    }

    // MARK: - What the tests share

    /// A fresh TestApp, its data folder noted for tearDown.
    @MainActor
    private func start() throws -> TestApp {
        let run = try TestApp()
        Self.dataRootPath = run.dataRoot.path
        return run
    }

    /// A budget by its name, for the words of a question about it.
    private static func budget(_ name: String) -> Budget {
        Budget(groupID: GroupID(), name: name, limit: .zero())
    }

    /// What a budget's wheel ends with for its limit: "of $1,000".
    private static func limitWords(_ limit: Int) -> String {
        MoneyWheel(scope: .budget, budgeted: Money(minorUnits: limit), spent: .zero(), day: nil).middleOf
    }

    /// The line under a budget's figures that counts its entries this
    /// period, "2 transactions since Oct 1", in the shared code's words.
    @MainActor
    private static func countLine(_ budget: TodaysBudget, entries: Int) throws -> String {
        let summary = BudgetSummary(budget: budget.summary.budget, period: budget.summary.period,
                                    spent: budget.summary.spent, transactionCount: entries)
        let model = AppModel(store: Store(database: try WellSpentDatabase.inMemory()))
        return BudgetScreen(summary: summary, model: model, me: nil).countLine
    }

    /// The days the samples can be dated, 3 to 12 days before the first
    /// opening: as the list shows the ones in this month, and whether every
    /// one of them is.
    private static func sampleDays(before opened: Date) -> (thisMonth: [String], allThisMonth: Bool) {
        let calendar = Calendar.autoupdatingCurrent
        let days = (3 ... 12).compactMap { calendar.date(byAdding: .day, value: -$0, to: opened) }
        let thisMonth = days.filter { calendar.isDate($0, equalTo: opened, toGranularity: .month) }
        return (thisMonth.map(BudgetScreen.shortDate), thisMonth.count == days.count)
    }

    /// The 15th of last month, at noon: before this period, whatever day the
    /// test runs, as September is on October 18 in the scenarios.
    private static func fifteenthOfLastMonth() throws -> Date {
        let calendar = Calendar.autoupdatingCurrent
        let lastMonth = try XCTUnwrap(calendar.date(byAdding: .month, value: -1, to: Date()))
        var parts = calendar.dateComponents([.year, .month], from: lastMonth)
        parts.day = 15
        parts.hour = 12
        return try XCTUnwrap(calendar.date(from: parts))
    }

    /// The six commands the scenario names, by the actions AppKit gives
    /// them: Undo, Redo, Cut, Copy, Paste and Select All.
    private static let editActions = ["undo:", "redo:", "cut:", "copy:", "paste:", "selectAll:"]

    /// The Edit menu, as the shared code builds the menu bar.
    @MainActor
    private static var editMenu: NSMenu? {
        MacMenu.make(appName: AppEnvironment.staging.appName).items.compactMap(\.submenu)
            .first { menu in menu.items.contains { $0.action == #selector(NSText.paste(_:)) } }
    }
}

// MARK: - What these tests need beside TestApp's own steps

private extension TestApp {
    /// Opens the app as it opens the first time on a Mac. A run's first
    /// launch into its folder starts the app's settings afresh
    /// (`AccountDirectory.testing(at:)`), so the app puts in the sample
    /// groups. The app must keep its data in the run's folder, so once it is
    /// open the folder must not be empty.
    func launchAsFirstOpening(pinnedDay: Int? = nil, arguments: [String] = []) {
        if let pinnedDay { app.launchEnvironment[Workspace.pinnedDayVariable] = String(pinnedDay) }
        app.launchArguments += arguments
        launch()
        let kept = (try? FileManager.default.contentsOfDirectory(atPath: dataRoot.path)) ?? []
        XCTAssertFalse(kept.isEmpty, "the app keeps nothing in the run's folder, so it may be using this Mac's own")
    }

    /// Quits the app and opens it again, on the same folder and settings.
    func quitAndOpenAgain() {
        app.terminate()
        launch()
    }

    /// Waits for a condition, with its arguments, on an element.
    func wait(for element: XCUIElement, _ predicate: NSPredicate, timeout: TimeInterval = 10) -> Bool {
        XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: predicate, object: element)],
                         timeout: timeout) == .completed
    }

    // MARK: The list on the left

    /// The identifiers of the groups' lines in the list, sorted.
    func groupLines() -> [String] {
        Set(app.windows.firstMatch.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", AccessibilityID.sidebarGroup("")))
            .allElementsBoundByIndex.map(\.identifier)).sorted()
    }

    /// A group's line, showing its name in capitals.
    func expectGroupLine(_ name: String, file: StaticString = #filePath, line: UInt = #line) {
        let found = element(AccessibilityID.sidebarGroup(name))
        XCTAssertTrue(found.waitForExistence(timeout: 10), "no line for \(name). The sidebar: \(sidebarIdentifiers())",
                      file: file, line: line)
        XCTAssertEqual(found.label, name.uppercased(), "\(name)'s line", file: file, line: line)
    }

    /// Each budget's row sits under the group's line, and above the next
    /// group's.
    func expect(budgets: [String], under group: String, file: StaticString = #filePath, line: UInt = #line) {
        let top = element(AccessibilityID.sidebarGroup(group)).frame.minY
        let next = groupLines().map { element($0).frame.minY }.filter { $0 > top }.min() ?? .infinity
        for budget in budgets {
            let row = element(AccessibilityID.sidebarBudget(budget))
            XCTAssertTrue(row.waitForExistence(timeout: 10), "no row for \(budget). The sidebar: \(sidebarIdentifiers())",
                          file: file, line: line)
            XCTAssertTrue(row.frame.minY > top && row.frame.minY < next,
                          "\(budget) is not under \(group): it is at \(row.frame.minY), and \(group) runs from \(top) "
                          + "to \(next)", file: file, line: line)
        }
    }

    /// The budget open on the right: its row is the one picked in the list,
    /// and its wheel says its limit.
    func expectOpen(_ name: String, limit: Int, file: StaticString = #filePath, line: UInt = #line) {
        let row = element(AccessibilityID.sidebarBudget(name))
        XCTAssertTrue(row.waitForExistence(timeout: 10), "no row for \(name)", file: file, line: line)
        XCTAssertTrue(wait(for: row, NSPredicate(format: "isSelected == true")),
                      "\(name) is not the open budget", file: file, line: line)
        let of = MoneyWheel(scope: .budget, budgeted: Money(minorUnits: limit), spent: .zero(), day: nil).middleOf
        expect(wheel: AccessibilityID.budgetWheel, endsWith: of, name, file: file, line: line)
    }

    /// Waits for a wheel to end with these words, such as "of $1,000".
    func expect(wheel identifier: String, endsWith words: String, _ what: String,
                file: StaticString = #filePath, line: UInt = #line) {
        let wheel = element(identifier)
        XCTAssertTrue(wheel.waitForExistence(timeout: 10), "\(what): no wheel. On screen: \(visibleTexts())",
                      file: file, line: line)
        XCTAssertTrue(wait(for: wheel, NSPredicate(format: "label ENDSWITH %@", words)),
                      "\(what): the wheel reads \(wheel.label), not ending \(words)", file: file, line: line)
    }

    /// Add Budget itself, at the foot of the list. A click on its middle
    /// may open its menu instead, which is closed and its left part clicked.
    func openNewBudget(file: StaticString = #filePath, line: UInt = #line) {
        let add = element(AccessibilityID.sidebarAdd)
        XCTAssertTrue(add.waitForExistence(timeout: 10), "no Add Budget control", file: file, line: line)
        waitUntilHittable(add, AccessibilityID.sidebarAdd)
        add.click()
        if !element(AccessibilityID.budgetEditorName).waitForExistence(timeout: 3) {
            app.typeKey(.escape, modifierFlags: [])
            add.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.5)).click()
        }
        XCTAssertTrue(element(AccessibilityID.budgetEditorName).waitForExistence(timeout: 5),
                      "New Budget did not open. On screen: \(visibleTexts())", file: file, line: line)
    }

    /// Edit… from a budget's menu in the list.
    func openEditBudget(_ name: String, file: StaticString = #filePath, line: UInt = #line) {
        let identifier = AccessibilityID.sidebarBudget(name)
        openMenu(on: element(identifier), identifier, offering: MainScreen.Words.edit)
        clickMenuItem(MainScreen.Words.edit)
        XCTAssertTrue(element(AccessibilityID.budgetEditorName).waitForExistence(timeout: 10),
                      "Edit\u{2026} opened no sheet. On screen: \(visibleTexts())", file: file, line: line)
    }

    /// A button on the right side of the window, past the list, by its
    /// words. The list's own Add Budget has the same words.
    func rightSideButton(_ label: String) -> XCUIElement? {
        let listEdge = element(AccessibilityID.sidebarAdd).frame.maxX
        return app.buttons.matching(NSPredicate(format: "label == %@", label)).allElementsBoundByIndex
            .first { $0.frame.minX > listEdge }
    }

    // MARK: Deleting

    /// Delete… from a budget's menu, and the question it asks, in the
    /// shared code's words. The question stays up for `answer`.
    func askToDelete(budget name: String, expecting question: PendingDelete,
                     file: StaticString = #filePath, line: UInt = #line) {
        ask(AccessibilityID.sidebarBudget(name), expecting: question, file: file, line: line)
    }

    /// The same, from a group's menu.
    func askToDelete(group name: String, expecting question: PendingDelete,
                     file: StaticString = #filePath, line: UInt = #line) {
        ask(AccessibilityID.sidebarGroup(name), expecting: question, file: file, line: line)
    }

    private func ask(_ identifier: String, expecting question: PendingDelete, file: StaticString, line: UInt) {
        openMenu(on: element(identifier), identifier, offering: MainScreen.Words.delete)
        clickMenuItem(MainScreen.Words.delete)
        XCTAssertTrue(app.staticTexts[question.title].waitForExistence(timeout: 5),
                      "no question \(question.title) On screen: \(visibleTexts())", file: file, line: line)
        XCTAssertTrue(app.staticTexts[question.message].waitForExistence(timeout: 5),
                      "the question does not say \(question.message) On screen: \(visibleTexts())",
                      file: file, line: line)
    }

    /// Presses a button on the question that is up, and waits for it to go.
    func answer(_ label: String, file: StaticString = #filePath, line: UInt = #line) {
        guard let button = dialogButton(label) else {
            XCTFail("no \(label) on the question. On screen: \(visibleTexts())", file: file, line: line)
            return
        }
        button.click()
        XCTAssertTrue(wait(for: button, until: "exists == false", timeout: 10), "the question stayed up",
                      file: file, line: line)
    }

    /// Deletes a budget holding this many entries, from its menu, and waits
    /// for its row to go. With `checkingTheQuestion`, the question's words
    /// are checked first.
    func deleteBudget(named name: String, holding entries: Int, checkingTheQuestion: Bool = false,
                      file: StaticString = #filePath, line: UInt = #line) {
        let identifier = AccessibilityID.sidebarBudget(name)
        let question = PendingDelete.budget(Budget(groupID: GroupID(), name: name, limit: .zero()),
                                            transactions: entries)
        if checkingTheQuestion {
            askToDelete(budget: name, expecting: question, file: file, line: line)
        } else {
            openMenu(on: element(identifier), identifier, offering: MainScreen.Words.delete)
            clickMenuItem(MainScreen.Words.delete)
        }
        answer(question.confirmLabel, file: file, line: line)
        XCTAssertTrue(wait(for: element(identifier), until: "exists == false", timeout: 10),
                      "\(name) is still in the list", file: file, line: line)
    }

    /// Deletes a group nobody else is in, holding this many budgets, and
    /// waits for its line to go.
    func deleteGroup(named name: String, holding budgets: Int, file: StaticString = #filePath, line: UInt = #line) {
        let identifier = AccessibilityID.sidebarGroup(name)
        openMenu(on: element(identifier), identifier, offering: MainScreen.Words.delete)
        clickMenuItem(MainScreen.Words.delete)
        answer(PendingDelete.group(BudgetGroup(name: name), budgets: budgets, reach: .justYou).confirmLabel,
               file: file, line: line)
        XCTAssertTrue(wait(for: element(identifier), until: "exists == false", timeout: 10),
                      "\(name) is still in the list", file: file, line: line)
    }

    /// Takes the two sample groups away, so the scenarios' own names are
    /// the only ones in the list.
    func deleteTheSamples() {
        deleteGroup(named: "Household", holding: 3)
        deleteGroup(named: "Side Business", holding: 1)
    }

    // MARK: Entries

    /// Whether the open budget's list holds this entry, giving it three
    /// seconds to show.
    func isListed(_ merchant: String) -> Bool {
        element(AccessibilityID.entryRow(merchant)).waitForExistence(timeout: 3)
    }

    /// The row in the budget's list that holds an entry, found by the cell
    /// with its merchant: a row of an outline or of a table, whichever the
    /// list reaches the test as.
    func listRow(_ merchant: String) -> XCUIElement {
        app.windows.firstMatch.descendants(matching: .any).matching(NSPredicate(
            format: "elementType == %d OR elementType == %d", XCUIElement.ElementType.outlineRow.rawValue,
            XCUIElement.ElementType.tableRow.rawValue))
            .containing(.any, identifier: AccessibilityID.entryRow(merchant)).firstMatch
    }

    /// The entry's row in the list is dated one of these days.
    func expect(entry merchant: String, datedOneOf dates: [String], file: StaticString = #filePath, line: UInt = #line) {
        let row = listRow(merchant)
        XCTAssertTrue(row.waitForExistence(timeout: 10), "no row for \(merchant). On screen: \(visibleTexts())",
                      file: file, line: line)
        let shown = row.staticTexts.allElementsBoundByIndex.map { text(of: $0) }
        XCTAssertTrue(shown.contains { dates.contains($0) }, "\(merchant)'s row shows \(shown), with no date 3 to 12 "
                      + "days before the first opening in this month: \(dates)", file: file, line: line)
    }

    /// Add, in the budget's toolbar, for an entry dated `day`. The date is
    /// set last, since a click in another field after the arrow keys in
    /// Date can leave the keyboard in Date. A click on Date also opens a
    /// calendar, which lies over the sheet's buttons, so a click on the
    /// sheet's title closes it before Add.
    func addEntry(merchant: String, amount: String, dated day: Date,
                  file: StaticString = #filePath, line: UInt = #line) {
        click(AccessibilityID.budgetAdd)
        type(merchant, into: AccessibilityID.entryMerchant)
        type(amount, into: AccessibilityID.entryAmount)
        setDate(to: day, file: file, line: line)
        let title = app.sheets.firstMatch.staticTexts[EntryEditor.Words.title]
        XCTAssertTrue(title.waitForExistence(timeout: 5), "the sheet has no title \(EntryEditor.Words.title)",
                      file: file, line: line)
        title.click()
        XCTAssertTrue(wait(for: app.dialogs.firstMatch, until: "exists == false", timeout: 5),
                      "the calendar stayed over the sheet", file: file, line: line)
        click(AccessibilityID.entryAdd)
        expectNoSheet(file: file, line: line)
    }

    /// The day the sheet's Date shows. Its value reaches the test as text,
    /// such as "2026-10-21 14:50:28 +0000", or as a date.
    func shownDate() -> Date? {
        let picker = element(AccessibilityID.entryDate)
        guard picker.exists, let value = picker.value else { return nil }
        if let date = value as? Date { return date }
        let text = String(describing: value)
        guard let found = text.range(of: #"\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2} [+-]\d{4}"#,
                                     options: .regularExpression) else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss Z"
        return formatter.date(from: String(text[found]))
    }

    /// Sets the sheet's Date to `target` with the keyboard, the way a person
    /// does: a click on its first part, then the arrow keys, one part at a
    /// time, reading the date back after each key. The parts come in the
    /// region's order, such as month, day and year in the United States. The
    /// day is set first, and `target` is the 28th or before, so no step lands
    /// on a day the month lacks, and no part is stepped past its end.
    func setDate(to target: Date, file: StaticString = #filePath, line: UInt = #line) {
        let picker = element(AccessibilityID.entryDate)
        XCTAssertTrue(picker.waitForExistence(timeout: 10), "no Date. On screen: \(visibleTexts())",
                      file: file, line: line)
        waitUntilHittable(picker, AccessibilityID.entryDate)
        let calendar = Calendar.autoupdatingCurrent
        XCTAssertLessThanOrEqual(calendar.component(.day, from: target), 28, "a day every month has",
                                 file: file, line: line)
        let format = DateFormatter.dateFormat(fromTemplate: "yMd", options: 0, locale: .autoupdatingCurrent) ?? "M/d/y"
        func place(_ part: Calendar.Component) -> Int {
            let letters: Set<Character> = part == .month ? ["M", "L"] : part == .day ? ["d"] : ["y"]
            return format.firstIndex { letters.contains($0) }.map { format.distance(from: format.startIndex, to: $0) }
                ?? 0
        }
        let places = [Calendar.Component.month, .day, .year].sorted { place($0) < place($1) }
        picker.coordinate(withNormalizedOffset: CGVector(dx: 0.05, dy: 0.5)).click()
        var at = 0
        for part in [Calendar.Component.day, .month, .year] {
            guard let wanted = places.firstIndex(of: part) else { continue }
            while at < wanted {
                app.typeKey(.rightArrow, modifierFlags: [])
                at += 1
            }
            while at > wanted {
                app.typeKey(.leftArrow, modifierFlags: [])
                at -= 1
            }
            let goal = calendar.component(part, from: target)
            for _ in 0 ..< 40 {
                guard let shown = shownDate() else { break }
                let now = calendar.component(part, from: shown)
                if now == goal { break }
                app.typeKey(now < goal ? .upArrow : .downArrow, modifierFlags: [])
                let moved = NSPredicate { _, _ in self.shownDate() != shown }
                _ = XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: moved, object: nil)], timeout: 2)
            }
        }
        let shown = shownDate()
        XCTAssertTrue(shown.map { calendar.isDate($0, inSameDayAs: target) } ?? false,
                      "Date shows \(shown.map { "\($0)" } ?? "nothing"), not \(target)", file: file, line: line)
    }

    // MARK: Menus and fields

    /// Picks a command from a menu in the menu bar.
    func pick(_ command: String, from menu: String, file: StaticString = #filePath, line: UInt = #line) {
        let title = app.menuBars.menuBarItems[menu]
        XCTAssertTrue(title.waitForExistence(timeout: 5), "no \(menu) menu in the menu bar", file: file, line: line)
        title.click()
        let item = title.menuItems[command]
        XCTAssertTrue(item.waitForExistence(timeout: 5), "no \(command) in the \(menu) menu", file: file, line: line)
        XCTAssertTrue(wait(for: item, until: "isEnabled == true", timeout: 5), "\(command) is dimmed",
                      file: file, line: line)
        item.click()
    }

    /// Clicks into a field and empties it.
    func clear(_ identifier: String, file: StaticString = #filePath, line: UInt = #line) {
        let field = element(identifier)
        XCTAssertTrue(field.waitForExistence(timeout: 10), "no field called \(identifier)", file: file, line: line)
        waitUntilHittable(field, identifier)
        field.click()
        field.typeKey("a", modifierFlags: .command)
        field.typeKey(.delete, modifierFlags: [])
        XCTAssertTrue(wait(for: field, holds: "", timeout: 5), "\(identifier) did not empty: \(text(of: field))",
                      file: file, line: line)
    }

    // MARK: The rows' fill and the outline

    /// A budget's row is filled as far as `fill` says, as a screen reader
    /// hears it: "25 percent used". The row draws its fill from that share,
    /// and its words from the same RowFill.
    func expectRow(_ name: String, fills fill: RowFill, file: StaticString = #filePath, line: UInt = #line) {
        let row = element(AccessibilityID.sidebarBudget(name))
        XCTAssertTrue(row.waitForExistence(timeout: 10), "no row for \(name)", file: file, line: line)
        XCTAssertTrue(wait(for: row, NSPredicate(format: "value == %@", fill.spokenValue)),
                      "\(name)'s row is not \(fill.spokenValue): \(String(describing: row.value))", file: file, line: line)
    }

    /// The row says its name first and the amount last, at its right.
    func expect(row name: String, endsWith amount: String, file: StaticString = #filePath, line: UInt = #line) {
        let row = element(AccessibilityID.sidebarBudget(name))
        XCTAssertTrue(row.waitForExistence(timeout: 10), "no row for \(name)", file: file, line: line)
        XCTAssertTrue(wait(for: row, NSPredicate(format: "label BEGINSWITH %@ AND label ENDSWITH %@", name, amount)),
                      "\(name)'s row does not end with \(amount): it says \(row.label)", file: file, line: line)
    }

    /// The open budget's row: the outline round it marks it as the one
    /// picked, which a screen reader hears as selected. Only `picked`'s row
    /// is, and with no `picked` none is.
    func expectOutline(on picked: String?, notOn others: [String], file: StaticString = #filePath, line: UInt = #line) {
        for name in [picked].compactMap({ $0 }) + others {
            let row = element(AccessibilityID.sidebarBudget(name))
            XCTAssertTrue(row.waitForExistence(timeout: 10), "no row for \(name)", file: file, line: line)
            let outlined = name == picked
            XCTAssertTrue(wait(for: row, NSPredicate(format: "isSelected == %@", NSNumber(value: outlined))),
                          "\(name)'s row is \(outlined ? "not " : "")marked as the open budget", file: file, line: line)
        }
    }
}
