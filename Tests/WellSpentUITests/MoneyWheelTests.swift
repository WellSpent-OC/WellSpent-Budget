import AppKit
import Foundation
import XCTest
import WellSpentAppCore
import WellSpentModel

/// The money wheel in the real window, in a group of its own named with the
/// time: a budget's wheel, full and then emptying as money goes out, its
/// tick and figures, the group's MONEY, a budget over its limit and its row
/// in the sidebar, and the pace words.
///
/// The first test launches the app with its wheels on the 18th of this month,
/// and the second on the 26th (`Workspace.pinnedDayVariable`), whatever day
/// the tests run. So the pace words show where the steps check them: spending
/// too fast on the 18th, and more left than expected in the month's last week.
/// Each test launches the app once, as every other UI test does.
/// The words and amounts it expects come from the shared code, read for the
/// same day as the app reads them.
///
/// No account is needed. The run's data folder holds the group, and goes
/// in tearDown.
final class MoneyWheelTests: XCTestCase {
    /// The run's data folder, for tearDown.
    nonisolated(unsafe) private static var dataRootPath: String?
    /// Mid-month, before the last week of any month.
    private static let midMonth = 18
    /// In the last week of every month, February's too.
    private static let lastWeek = 26

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    /// Closes the app and leaves nothing of the run on this Mac.
    override func tearDown() {
        let app = XCUIApplication()
        if app.state != .notRunning { app.terminate() }
        TestApp.wipeSettings()
        if let path = Self.dataRootPath { try? FileManager.default.removeItem(atPath: path) }
        Self.dataRootPath = nil
        super.tearDown()
    }

    @MainActor
    func testRowsWheelsAndAGroupsMoney() throws {
        let run = try TestApp()
        Self.dataRootPath = run.dataRoot.path
        let stamp = Self.stamp()
        let groupName = "Wheel \(stamp)"
        let treats = "Treats \(stamp)", fuel = "Fuel \(stamp)", books = "Books \(stamp)"
        let day = Self.midMonth

        // 1. The wheels on the 18th. A group with Treats, $100.00 a month.
        // Saving opens it.
        run.app.launchEnvironment[Workspace.pinnedDayVariable] = String(day)
        run.launch()
        run.addGroup(named: groupName)
        run.addBudget(named: treats, amount: "100", inGroup: groupName)

        // Scenario WHEEL-05, WHEEL-06
        // 2. Nothing spent: the wheel is full, the day of the month shows
        // under the name, and the figures beside the wheel say what is spent
        // and left.
        let untouched = TodaysBudget(treats, limit: 10_000, spent: 0, pinnedDay: day)
        run.expect(wheel: AccessibilityID.budgetWheel, reads: untouched.wheel.spokenSummary, "Treats, new")
        let dayLine = try XCTUnwrap(untouched.wheel.day?.line, "a budget made here resets every month")
        XCTAssertTrue(run.wait(for: run.element(AccessibilityID.budgetDayLine), holds: dayLine, timeout: 10),
                      "the day line is not \(dayLine). On screen: \(run.visibleTexts())")
        run.expect(figures: untouched.wheel.figures, "Treats, new")

        // Scenario WHEEL-06, WHEEL-07
        // 3. $25.00 spent: the wheel at once shows $75 left, and Expected
        // left by today is what an even pace leaves on the 18th.
        run.addEntry(merchant: "Bakery", amount: "25.00")
        let quarter = TodaysBudget(treats, limit: 10_000, spent: 2_500, pinnedDay: day)
        run.expect(wheel: AccessibilityID.budgetWheel, reads: quarter.wheel.spokenSummary, "Treats, a quarter spent")
        XCTAssertNotNil(quarter.wheel.expectedLeft, "a budget that resets each month has an expected figure")
        run.expect(figures: quarter.wheel.figures, "Treats, a quarter spent")

        // Scenario WHEEL-11
        // 4. A click on the group's name opens its page, with MONEY: the
        // group's wheel, its budgets added up for the month, and the note
        // naming the group.
        run.openGroupPage(named: groupName)
        let month = try XCTUnwrap(TodaysBudget.group(groupName, [quarter]))
        XCTAssertTrue(run.element(AccessibilityID.groupMoney).waitForExistence(timeout: 10),
                      "the page has no MONEY. On screen: \(run.visibleTexts())")
        run.expect(wheel: AccessibilityID.groupWheel, reads: month.wheel.spokenSummary, "the group's wheel")
        XCTAssertTrue(run.listText(month.note).waitForExistence(timeout: 10),
                      "no note saying \(month.note) On screen: \(run.visibleTexts())")
        run.expect(figures: month.wheel.figures, "the group's figures")

        // Scenario WHEEL-10, WHEEL-02
        // 5. $90.00 more puts Treats $15.00 over. Its wheel says Over, the
        // figures say Over $15.00 with no expected figure, and its row in the
        // sidebar says how far over.
        run.openBudget(named: treats)
        run.addEntry(merchant: "Ice cream", amount: "90.00")
        let over = TodaysBudget(treats, limit: 10_000, spent: 11_500, pinnedDay: day)
        run.expect(wheel: AccessibilityID.budgetWheel, reads: over.wheel.spokenSummary, "Treats, over")
        run.expect(figures: over.wheel.figures, "Treats, over")
        XCTAssertFalse(run.listText(MoneyWheel.Words.expectedLeft).exists, "an expected figure while over")
        run.expect(pace: nil, "Treats, over")
        run.expect(row: treats, shows: over.row.amount)

        // Scenario WHEEL-12
        // 6. The group's wheel says how far over its budgets are this month.
        run.openGroupPage(named: groupName)
        let overMonth = try XCTUnwrap(TodaysBudget.group(groupName, [over]))
        run.expect(wheel: AccessibilityID.groupWheel, reads: overMonth.wheel.spokenSummary, "the group, over")

        // Scenario WHEEL-08
        // 7. Fuel, $100.00, with $99.00 spent by the 18th: faster than an
        // even pace, so the words say when its money runs out. Edit Budget…
        // beside them opens Fuel's Edit Budget sheet, and Cancel closes it.
        run.addBudget(named: fuel, amount: "100", inGroup: groupName)
        let fuelNew = TodaysBudget(fuel, limit: 10_000, spent: 0, pinnedDay: day)
        run.expect(wheel: AccessibilityID.budgetWheel, reads: fuelNew.wheel.spokenSummary, "Fuel, new")
        run.addEntry(merchant: "Gas station", amount: "99.00")
        let fuelSpent = TodaysBudget(fuel, limit: 10_000, spent: 9_900, pinnedDay: day)
        let runsOut = try XCTUnwrap(fuelSpent.pace, "on the 18th, $99.00 of $100.00 is faster than an even pace")
        XCTAssertEqual(runsOut.kind, .overPace)
        run.expect(wheel: AccessibilityID.budgetWheel, reads: fuelSpent.wheel.spokenSummary, "Fuel, $99.00 spent")
        run.expect(pace: runsOut, "Fuel, $99.00 spent")
        expectEditBudgetOpens(fuel, in: run)

        // Scenario WHEEL-09
        // 8. Books, $1,000.00, with $1.00 spent: on the 18th, before the
        // month's last week, nothing is said about the pace.
        run.addBudget(named: books, amount: "1000", inGroup: groupName)
        let booksNew = TodaysBudget(books, limit: 100_000, spent: 0, pinnedDay: day)
        run.expect(wheel: AccessibilityID.budgetWheel, reads: booksNew.wheel.spokenSummary, "Books, new")
        run.addEntry(merchant: "Bookshop", amount: "1.00")
        let booksMidMonth = TodaysBudget(books, limit: 100_000, spent: 100, pinnedDay: day)
        XCTAssertNil(booksMidMonth.pace, "the 18th is before the month's last week")
        run.expect(wheel: AccessibilityID.budgetWheel, reads: booksMidMonth.wheel.spokenSummary,
                   "Books, $1.00 spent on the 18th")
        run.expect(pace: nil, "Books, $1.00 spent on the 18th")

        // 9. Tidy: the group goes, with its budgets.
        run.deleteGroup(named: groupName)
    }

    /// The wheel's step 2 on a group's page: money in refills the group's
    /// wheel toward full, its middle says money in against money out, and
    /// borrowed money and savings draws are named without refilling it. One
    /// group with one budget, Rent, $4,080.00 a month, on the 18th. Each
    /// check expects what the shared code says for the same money.
    @MainActor
    func testMoneyInOnAGroupsWheel() throws {
        let run = try TestApp()
        Self.dataRootPath = run.dataRoot.path
        let stamp = Self.stamp()
        let groupName = "Money in \(stamp)", rent = "Rent \(stamp)"
        let day = Self.midMonth
        func month(spent: Int, moneyIn: Int = 0, borrowed: Int = 0, fromSavings: Int = 0) throws -> GroupMoney {
            try XCTUnwrap(TodaysBudget.group(groupName, [
                TodaysBudget(rent, limit: 408_000, spent: spent, moneyIn: moneyIn, borrowed: borrowed,
                             fromSavings: fromSavings, pinnedDay: day),
            ]))
        }
        func expect(_ money: GroupMoney, _ what: String) {
            run.openGroupPage(named: groupName)
            run.expect(wheel: AccessibilityID.groupWheel, reads: money.wheel.spokenSummary, what)
            run.expect(figures: money.wheel.figures, what)
            XCTAssertTrue(run.listText(money.note).waitForExistence(timeout: 10),
                          "\(what): no note saying \(money.note) On screen: \(run.visibleTexts())")
        }
        func addMoneyIn(_ merchant: String, _ amount: String) {
            run.openBudget(named: rent)
            run.click(AccessibilityID.budgetAdd)
            run.type(merchant, into: AccessibilityID.entryMerchant)
            run.type(amount, into: AccessibilityID.entryAmount)
            run.click(AccessibilityID.entryMoneyIn)
            run.click(AccessibilityID.entryAdd)
            run.expectNoSheet()
        }
        func addSpending(_ merchant: String, _ amount: String) {
            run.openBudget(named: rent)
            run.addEntry(merchant: merchant, amount: amount)
        }

        run.app.launchEnvironment[Workspace.pinnedDayVariable] = String(day)
        run.launch()
        run.addGroup(named: groupName)
        run.addBudget(named: rent, amount: "4080", inGroup: groupName)

        // Scenario WHEEL-16
        // 1. $2,777.96 spent and no money in: the wheel is step 1's, with no
        // In figure, and the note ends "added up."
        run.addEntry(merchant: "Landlord", amount: "2777.96")
        let plain = try month(spent: 277_796)
        expect(plain, "no money in")
        XCTAssertFalse(run.listText(MoneyWheel.Words.moneyIn).exists, "an In figure with no money in")

        // Scenario WHEEL-14, WHEEL-15, WHEEL-20
        // 2. $1,230.00 of income: the wheel refills, the middle says money in,
        // money out and the cash flow, In leads the figures, and Expected left
        // by today is what it was, since money in never moves the tick.
        addMoneyIn("Paycheck", "1230")
        let refilled = try month(spent: 277_796, moneyIn: 123_000)
        expect(refilled, "$1,230.00 in")
        XCTAssertEqual(refilled.wheel.expectedLeft, plain.wheel.expectedLeft, "money in moved the tick")

        // Scenario WHEEL-17
        // 3. Spending to $4,500.00 passes the budgets, and the money in covers
        // it: the wheel stays green and one line says so.
        addSpending("Repairs", "1722.04")
        let covered = try month(spent: 450_000, moneyIn: 123_000)
        expect(covered, "over the budgets, covered")
        let coveredLine = try XCTUnwrap(covered.wheel.overBudgetsCoveredLine, "money in covers it")
        XCTAssertTrue(run.listText(coveredLine).waitForExistence(timeout: 10),
                      "no line saying \(coveredLine) On screen: \(run.visibleTexts())")

        // Scenario WHEEL-18
        // 4. $1,030.00 more puts the spending past the budgets and the money
        // in together: the wheel turns orange and says how far over.
        addSpending("Plumber", "1030")
        let over = try month(spent: 553_000, moneyIn: 123_000)
        XCTAssertTrue(over.wheel.isOver, "the test's own numbers are over")
        expect(over, "over the budgets and the money in")
        XCTAssertFalse(run.listText(MoneyWheel.Words.expectedLeft).exists, "an expected figure while over")

        // Scenario WHEEL-14, WHEEL-15
        // 5. $5,000.00 more income: the wheel is full and no fuller, and the
        // cash flow is ahead.
        addMoneyIn("Bonus", "5000")
        let full = try month(spent: 553_000, moneyIn: 623_000)
        XCTAssertEqual(full.wheel.arc, 1, "the test's own numbers fill the wheel")
        expect(full, "full")

        // Scenario WHEEL-19
        // 6. A loan draw and a savings draw from a statement are named under
        // the figures and refill nothing.
        run.openBudget(named: rent)
        let loan = "CREDIT UNION LOAN", savings = "SAVINGS XFER"
        let statement = try run.writeStatement([(loan, "500.00"), (savings, "300.00")])
        run.importStatement(at: statement)
        run.choose(EntryEditor.Words.borrowed, in: AccessibilityID.importLineKind(loan))
        run.choose(EntryEditor.Words.fromSavings, in: AccessibilityID.importLineKind(savings))
        run.choose(rent, in: AccessibilityID.importLineBudget(loan))
        run.choose(rent, in: AccessibilityID.importLineBudget(savings))
        run.click(AccessibilityID.importConfirm)
        XCTAssertTrue(run.wait(for: run.element(AccessibilityID.importConfirm), until: "exists == false", timeout: 10),
                      "the review did not close. On screen: \(run.visibleTexts())")
        let drawn = try month(spent: 553_000, moneyIn: 623_000, borrowed: 50_000, fromSavings: 30_000)
        XCTAssertEqual(drawn.wheel, full.wheel, "borrowed money or a savings draw changed the wheel")
        expect(drawn, "after the draws")
        for line in drawn.otherMoneyLines {
            XCTAssertTrue(run.listText(line).waitForExistence(timeout: 10),
                          "no line saying \(line) On screen: \(run.visibleTexts())")
        }

        // 7. Tidy: the group goes, with its budget.
        run.deleteGroup(named: groupName)
    }

    /// The month's last week, in a launch of its own on the 26th.
    @MainActor
    func testTheLastWeekOffersToLowerABudget() throws {
        let run = try TestApp()
        Self.dataRootPath = run.dataRoot.path
        let stamp = Self.stamp()
        let groupName = "Wheel \(stamp)"
        let books = "Books \(stamp)"

        // 1. The wheels on the 26th, in the month's last week. A group with
        // Books, $1,000.00 a month. Saving opens it. Then $1.00 spent.
        run.app.launchEnvironment[Workspace.pinnedDayVariable] = String(Self.lastWeek)
        run.launch()
        run.addGroup(named: groupName)
        run.addBudget(named: books, amount: "1000", inGroup: groupName)
        run.addEntry(merchant: "Bookshop", amount: "1.00")

        // Scenario WHEEL-09
        // 2. More is left of Books than expected by the 26th, so the words
        // offer to lower it, and Edit Budget… beside them opens its sheet.
        let booksLastWeek = TodaysBudget(books, limit: 100_000, spent: 100, pinnedDay: Self.lastWeek)
        let moreLeft = try XCTUnwrap(booksLastWeek.pace, "the 26th is in the month's last week")
        XCTAssertEqual(moreLeft.kind, .underPace)
        run.expect(wheel: AccessibilityID.budgetWheel, reads: booksLastWeek.wheel.spokenSummary,
                   "Books, $1.00 spent on the 26th")
        run.expect(pace: moreLeft, "Books, $1.00 spent on the 26th")
        expectEditBudgetOpens(books, in: run)

        // 3. Tidy: the group goes, with its budget.
        run.deleteGroup(named: groupName)
    }

    /// Edit Budget… beside the pace words shows its whole name, opens the
    /// budget's Edit Budget sheet, and Cancel closes it.
    @MainActor
    private func expectEditBudgetOpens(_ budget: String, in run: TestApp,
                                       file: StaticString = #filePath, line: UInt = #line) {
        // The whole name shows: the button is at least as wide as its words
        // in the system font, which a bordered button of the usual size uses.
        // Cut short, it read "E…" beside long pace words.
        let button = run.element(AccessibilityID.budgetPaceEdit)
        XCTAssertTrue(button.waitForExistence(timeout: 10), "no Edit Budget\u{2026} beside the pace words",
                      file: file, line: line)
        let words = BudgetPace.Words.editBudget(onPhone: false)
        let wordsWidth = (words as NSString)
            .size(withAttributes: [.font: NSFont.systemFont(ofSize: NSFont.systemFontSize)]).width
        XCTAssertGreaterThanOrEqual(button.frame.width, wordsWidth,
                                    "\(words) is cut short: it is \(button.frame.width) points wide, "
                                    + "and its words need \(wordsWidth)", file: file, line: line)
        run.click(AccessibilityID.budgetPaceEdit)
        let name = run.element(AccessibilityID.budgetEditorName)
        XCTAssertTrue(run.wait(for: name, holds: budget, timeout: 10),
                      "Edit Budget\u{2026} did not open \(budget)'s sheet. On screen: \(run.visibleTexts())",
                      file: file, line: line)
        run.click(AccessibilityID.budgetEditorCancel)
        XCTAssertTrue(run.wait(for: name, until: "exists == false", timeout: 10), "the sheet stayed open",
                      file: file, line: line)
    }

    /// Part of each name, so runs never share one.
    private static func stamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: Date())
    }
}
