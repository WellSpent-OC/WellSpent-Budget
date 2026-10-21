import Foundation
import XCTest
import WellSpentAppCore
import WellSpentModel

/// The money wheel in the real window, in a group of its own named with the
/// time: a budget's wheel, full and then emptying as money goes out, its
/// tick and figures, the group's MONEY, a budget over its limit and its row
/// in the sidebar, and the pace words.
///
/// The words and amounts it expects come from the shared code, read for
/// today, as the app reads its budgets. So whether the pace words show, and
/// what they say, depends on the day of the month the test runs.
///
/// No account is needed. The run's data folder holds the group, and goes
/// in tearDown.
final class MoneyWheelTests: XCTestCase {
    /// The run's data folder, for tearDown.
    nonisolated(unsafe) private static var dataRootPath: String?

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

        // 1. A group with Treats, $100.00 a month. Saving opens it.
        run.launch()
        run.addGroup(named: groupName)
        run.addBudget(named: treats, amount: "100", inGroup: groupName)

        // Scenario WHEEL-05, WHEEL-06
        // 2. Nothing spent: the wheel is full, the day of the month shows
        // under the name, and the figures beside the wheel say what is spent
        // and left.
        let untouched = TodaysBudget(treats, limit: 10_000, spent: 0)
        run.expect(wheel: AccessibilityID.budgetWheel, reads: untouched.wheel.spokenSummary, "Treats, new")
        let day = try XCTUnwrap(untouched.wheel.day, "a budget made here resets every month")
        XCTAssertTrue(run.wait(for: run.element(AccessibilityID.budgetDayLine), holds: day.line, timeout: 10),
                      "the day line is not \(day.line). On screen: \(run.visibleTexts())")
        run.expect(figures: untouched.wheel.figures, "Treats, new")

        // Scenario WHEEL-06, WHEEL-07
        // 3. $25.00 spent: the wheel at once shows $75 left, and Expected
        // left by today is what an even pace leaves today.
        run.addEntry(merchant: "Bakery", amount: "25.00")
        let quarter = TodaysBudget(treats, limit: 10_000, spent: 2_500)
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
        let over = TodaysBudget(treats, limit: 10_000, spent: 11_500)
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
        // 7. Fuel, $100.00, with $99.00 spent: the pace words are the shared
        // code's for today, or there are none. Edit Budget… beside them opens
        // Fuel's Edit Budget sheet, and Cancel closes it.
        run.addBudget(named: fuel, amount: "100", inGroup: groupName)
        let fuelNew = TodaysBudget(fuel, limit: 10_000, spent: 0)
        run.expect(wheel: AccessibilityID.budgetWheel, reads: fuelNew.wheel.spokenSummary, "Fuel, new")
        run.addEntry(merchant: "Gas station", amount: "99.00")
        let fuelSpent = TodaysBudget(fuel, limit: 10_000, spent: 9_900)
        run.expect(wheel: AccessibilityID.budgetWheel, reads: fuelSpent.wheel.spokenSummary, "Fuel, $99.00 spent")
        run.expect(pace: fuelSpent.pace, "Fuel, $99.00 spent")
        if fuelSpent.pace?.offersEdit == true {
            run.click(AccessibilityID.budgetPaceEdit)
            let name = run.element(AccessibilityID.budgetEditorName)
            XCTAssertTrue(run.wait(for: name, holds: fuel, timeout: 10),
                          "Edit Budget\u{2026} did not open Fuel's sheet. On screen: \(run.visibleTexts())")
            run.click(AccessibilityID.budgetEditorCancel)
            XCTAssertTrue(run.wait(for: name, until: "exists == false", timeout: 10), "the sheet stayed open")
        }

        // Scenario WHEEL-09
        // 8. Books, $1,000.00, with $1.00 spent: in the month's last week the
        // words offer to lower it, and before that week nothing is said, as
        // the shared code says for today.
        run.addBudget(named: books, amount: "1000", inGroup: groupName)
        let booksNew = TodaysBudget(books, limit: 100_000, spent: 0)
        run.expect(wheel: AccessibilityID.budgetWheel, reads: booksNew.wheel.spokenSummary, "Books, new")
        run.addEntry(merchant: "Bookshop", amount: "1.00")
        let booksSpent = TodaysBudget(books, limit: 100_000, spent: 100)
        run.expect(wheel: AccessibilityID.budgetWheel, reads: booksSpent.wheel.spokenSummary, "Books, $1.00 spent")
        run.expect(pace: booksSpent.pace, "Books, $1.00 spent")

        // 9. Tidy: the group goes, with its budgets.
        run.deleteGroup(named: groupName)
    }

    /// Part of each name, so runs never share one.
    private static func stamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: Date())
    }
}
