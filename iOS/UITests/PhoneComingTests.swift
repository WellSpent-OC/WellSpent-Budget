import Foundation
import XCTest
import WellSpentAppCore
import WellSpentModel

/// Bills dated later this month, on a phone with no account: they count once
/// their date arrives, and until then they are on a "Coming by" line. Each bill
/// is given its own date, because the wheel is pinned to a day of the month and
/// a new entry otherwise takes the real date.
final class PhoneComingTests: XCTestCase {
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
    private func launched(pinnedDay day: Int) -> PhoneTestApp {
        let run = PhoneTestApp()
        Self.dataRootPath = run.dataRoot.path
        run.launch(pinnedDay: day)
        return run
    }

    /// That day of this month.
    private func thisMonth(day: Int) throws -> Date {
        let calendar = Calendar.current
        var parts = calendar.dateComponents([.year, .month], from: Date())
        parts.day = day
        return try XCTUnwrap(calendar.date(from: parts))
    }

    private func comingBy(day: Int) throws -> String {
        MoneyWheel.Words.comingBy(try thisMonth(day: day).formatted(.dateTime.month(.abbreviated).day()))
    }

    @MainActor
    private func addBill(_ merchant: String, amount: String, day: Int, run: PhoneTestApp) throws {
        run.tap(AccessibilityID.budgetAdd)
        run.type(merchant, into: AccessibilityID.entryMerchant)
        run.type(amount, into: AccessibilityID.entryAmount)
        run.pickDate(try thisMonth(day: day), showing: Date())
        run.tap(AccessibilityID.entryAdd)
        XCTAssertTrue(run.wait(for: run.element(AccessibilityID.entryAmount), until: "exists == false", timeout: 10),
                      "the sheet did not close. On screen: \(run.visibleTexts())")
    }

    @MainActor
    private func expectFigure(_ label: String, _ amount: String, run: PhoneTestApp, line: UInt = #line) {
        XCTAssertTrue(run.figure(label, is: amount), "\(label) is not \(amount). On screen: \(run.visibleTexts())",
                      line: line)
    }

    @MainActor
    func testABillDatedLaterCountsWhenItsDateArrives() throws {
        // Scenario WHEEL-21
        // 1. On the 6th, Pool has a $475.00 bill dated the 28th. Nothing is
        // spent yet, the wheel is full with no pace words, and the bill is on
        // the Coming by line and in the list with its own date.
        let run = launched(pinnedDay: 6)
        run.addBudget(named: "Pool", amount: "500", inGroup: "Household")
        try addBill("Pool Service", amount: "475.00", day: 28, run: run)

        expectFigure(MoneyWheel.Words.spent, "$0.00", run: run)
        expectFigure(MoneyWheel.Words.left, "$500.00", run: run)
        expectFigure(try comingBy(day: 28), "$475.00", run: run)
        let early = TodaysBudget("Pool", limit: 50_000, spent: 0, pinnedDay: 6)
        XCTAssertTrue(run.waitForLabel(AccessibilityID.budgetWheel, toBe: early.wheel.spokenSummary),
                      "the wheel does not say \(early.wheel.spokenSummary)")
        XCTAssertTrue(run.lacks(AccessibilityID.budgetPace), "a bill still to come brought pace words")
        XCTAssertTrue(run.hasRow("Pool Service"), "the bill is not in the list. On screen: \(run.visibleTexts())")
        let shortDate = try thisMonth(day: 28).formatted(.dateTime.month(.abbreviated).day())
        XCTAssertTrue(run.rowLabel("Pool Service").contains(shortDate),
                      "the row does not say \(shortDate): \(run.rowLabel("Pool Service"))")

        // 2. On the 28th, the bill counts and the Coming by line is gone.
        run.app.terminate()
        run.launch(pinnedDay: 28)
        run.openBudget(named: "Pool")
        expectFigure(MoneyWheel.Words.spent, "$475.00", run: run)
        expectFigure(MoneyWheel.Words.left, "$25.00", run: run)
        XCTAssertFalse(run.shows(try comingBy(day: 28), timeout: 2), "the Coming by line is still there")
    }

    @MainActor
    func testComingMoreThanWhatIsLeftIsInTheWarningColour() throws {
        // Scenario WHEEL-22
        // $300.00 spent leaves $200.00, and the $475.00 still to come is more
        // than that, so its amount is drawn in the warning colour.
        let run = launched(pinnedDay: 6)
        run.addBudget(named: "Pool", amount: "500", inGroup: "Household")
        try addBill("Pool Shop", amount: "300.00", day: 2, run: run)
        try addBill("Pool Service", amount: "475.00", day: 28, run: run)

        expectFigure(MoneyWheel.Words.left, "$200.00", run: run)
        expectFigure(try comingBy(day: 28), "$475.00", run: run)
        let amount = run.app.staticTexts.matching(NSPredicate(format: "label == %@", "$475.00")).firstMatch
        XCTAssertTrue(run.draws(amount, in: PaletteValues.warning), "$475.00 is not in the warning colour")
    }

    @MainActor
    func testAGroupsWheelCountsBillsDatedLaterTheSameWay() throws {
        // Scenario WHEEL-23
        // Two budgets' bills add up on the group's line, under the latest date.
        let run = launched(pinnedDay: 6)
        run.addGroup(named: "Yard")
        run.addBudget(named: "Pool", amount: "500", inGroup: "Yard")
        try addBill("Pool Service", amount: "475.00", day: 28, run: run)
        run.goBack()
        run.addBudget(named: "Lawn", amount: "200", inGroup: "Yard")
        try addBill("Mower", amount: "100.00", day: 20, run: run)
        run.goBack()
        run.openGroupPage(named: "Yard")

        expectFigure(try comingBy(day: 28), "$575.00", run: run)
        expectFigure(MoneyWheel.Words.left, "$700.00", run: run)
    }
}

private extension PhoneTestApp {
    /// Whether any pixel across the middle of the element is in this colour,
    /// for the phone's light or dark setting. Text is thin, so one point could
    /// fall between its strokes.
    func draws(_ element: XCUIElement, in colour: ColorPair) -> Bool {
        let screen = screenColours()
        let expected = isDark ? colour.dark : colour.light
        let frame = element.frame
        return stride(from: frame.minX, through: frame.maxX, by: 0.5).contains { x in
            stride(from: frame.minY, through: frame.maxY, by: 1).contains { y in
                ScreenColours.isClose(screen.colour(at: CGPoint(x: x, y: y)), expected)
            }
        }
    }
}
