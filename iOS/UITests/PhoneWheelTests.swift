import Foundation
import XCTest
import WellSpentAppCore
import WellSpentModel

/// The money wheel on a phone, with no account: group and budget pages,
/// each budget's row filled as far as it is used, and a budget's own
/// figures and pace words. Every word and number a test
/// expects comes from the shared code, as `TodaysBudget` builds it, never
/// typed in, and every colour from the palette for the phone's light or dark
/// setting. Each test starts the app on a fresh data folder, with its wheels
/// on a set day of this month (`Workspace.pinnedDayVariable`), so it checks
/// the same things on any day it runs.
final class PhoneWheelTests: XCTestCase {
    /// Mid-month, before the last week of any month.
    private static let midMonth = 18
    /// In the last week of every month, February's too.
    private static let lastWeek = 26

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

    /// The app on a fresh data folder, with its wheels on `day` of this
    /// month.
    @MainActor
    private func launched(pinnedDay day: Int) -> PhoneTestApp {
        let run = PhoneTestApp()
        Self.dataRootPath = run.dataRoot.path
        run.launch(pinnedDay: day)
        return run
    }

    @MainActor
    func testGroupPageAddsUpEveryBudget() throws {
        let day = Self.midMonth
        let run = launched(pinnedDay: day)
        run.addGroup(named: "Trip")
        run.openGroupPage(named: "Trip")
        XCTAssertFalse(run.element(AccessibilityID.groupWheel).exists, "an empty group has no wheel")
        run.goBack()

        run.addBudget(named: "Food", amount: "100", inGroup: "Trip")
        run.addEntry(merchant: "Bakery", amount: "25.00")
        run.goBack()
        run.addBudget(named: "Travel", amount: "200", inGroup: "Trip")
        run.addEntry(merchant: "Train", amount: "50.00")
        run.goBack()
        run.openGroupPage(named: "Trip")

        // Scenario WHEEL-11: both budgets count on the group's own page.
        let expected = try money("Trip",
                                 TodaysBudget("Food", limit: 10_000, spent: 2_500, pinnedDay: day),
                                 TodaysBudget("Travel", limit: 20_000, spent: 5_000, pinnedDay: day))
        XCTAssertTrue(run.waitForLabel(AccessibilityID.groupWheel, toBe: expected.wheel.spokenSummary))
        expectFigures(expected.wheel, run: run)
        XCTAssertTrue(run.shows(expected.note))

        run.goBack()
        run.openBudget(named: "Travel")
        run.addEntry(merchant: "Hotel", amount: "300.00")
        run.goBack()
        run.openGroupPage(named: "Trip")

        // Scenario WHEEL-12: opening again reads the updated totals.
        let over = try money("Trip",
                             TodaysBudget("Food", limit: 10_000, spent: 2_500, pinnedDay: day),
                             TodaysBudget("Travel", limit: 20_000, spent: 35_000, pinnedDay: day))
        XCTAssertTrue(run.waitForLabel(AccessibilityID.groupWheel, toBe: over.wheel.spokenSummary))
        expectFigures(over.wheel, run: run)
        XCTAssertFalse(run.text(MoneyWheel.Words.expectedLeft).exists)
    }

    @MainActor
    func testHomeShowsWheelsOnlyAfterOpeningAGroupOrBudget() throws {
        let run = launched(pinnedDay: Self.midMonth)
        // Scenario WHEEL-13
        XCTAssertTrue(run.element(AccessibilityID.sidebarGroup("Household")).waitForExistence(timeout: 10))
        XCTAssertFalse(run.element(AccessibilityID.homeMoney).exists)
        XCTAssertFalse(run.element(AccessibilityID.groupWheel).exists)
        XCTAssertFalse(run.element(AccessibilityID.budgetWheel).exists)

        run.openGroupPage(named: "Household")
        XCTAssertTrue(run.element(AccessibilityID.groupWheel).waitForExistence(timeout: 10))
        run.goBack()
        XCTAssertFalse(run.element(AccessibilityID.groupWheel).exists)
        XCTAssertFalse(run.element(AccessibilityID.homeMoney).exists)

        run.addBudget(named: "Treats", amount: "100", inGroup: "Household")
        XCTAssertTrue(run.element(AccessibilityID.budgetWheel).waitForExistence(timeout: 10))
        run.goBack()
        XCTAssertFalse(run.element(AccessibilityID.budgetWheel).exists)
        XCTAssertFalse(run.element(AccessibilityID.homeMoney).exists)
    }

    @MainActor
    func testRowsFillAndABudgetShowsItsWheel() throws {
        let day = Self.midMonth
        let run = launched(pinnedDay: day)
        run.addBudget(named: "Treats", amount: "100", inGroup: "Household")
        let wheel = run.element(AccessibilityID.budgetWheel)

        // Scenario WHEEL-05, WHEEL-06
        // 1. A budget's screen says the day of the month, and shows its wheel
        // in place of the bar: full with nothing spent, with its figures.
        let full = TodaysBudget("Treats", limit: 10_000, spent: 0, pinnedDay: day).wheel
        XCTAssertTrue(run.waitForLabel(AccessibilityID.budgetWheel, toBe: full.spokenSummary),
                      "the wheel does not say \(full.spokenSummary): \(wheel.label)")
        XCTAssertEqual(full.spokenSummary, "Left $100 of $100")
        let dayLine = try XCTUnwrap(full.day?.line, "a budget made here resets every month")
        XCTAssertEqual(run.element(AccessibilityID.budgetDayLine).label, dayLine)
        expectFigures(full, run: run)
        expectRing(of: full, run: run)

        // Scenario WHEEL-06, WHEEL-07
        // 2. Adding $25.00 empties a quarter of it at once. In the middle of
        // the month that leaves more than an even pace would, so the green
        // reaches past the tick, and Expected left by today says where an
        // even pace would be.
        run.addEntry(merchant: "Corner Bakery", amount: "25.00")
        let quarterSpent = TodaysBudget("Treats", limit: 10_000, spent: 2_500, pinnedDay: day)
        let quarter = quarterSpent.wheel
        XCTAssertTrue(run.waitForLabel(AccessibilityID.budgetWheel, toBe: quarter.spokenSummary),
                      "the wheel does not say \(quarter.spokenSummary): \(wheel.label)")
        XCTAssertEqual(quarter.spokenSummary, "Left $75 of $100")
        XCTAssertGreaterThan(quarter.arc, try XCTUnwrap(quarter.tick),
                             "on day \(Self.midMonth) the green does not reach past the tick")
        expectFigures(quarter, run: run)
        expectRing(of: quarter, run: run)

        // Scenario WHEEL-01, WHEEL-04
        // 3. Back on Home, Treats' row is filled a quarter of the way, in the
        // colours for the phone's light or dark setting, and still says what
        // is left. (make iphone-ui-test runs once in light and once in dark.)
        run.goBack()
        let row = run.scrollTo(AccessibilityID.sidebarBudget("Treats"))
        XCTAssertTrue(row.waitForExistence(timeout: 10), "no Treats on Home")
        let quarterRow = quarterSpent.row
        XCTAssertTrue(run.wait(for: row, until: "value == '\(quarterRow.spokenValue)'", timeout: 10),
                      "Treats' row is not \(quarterRow.spokenValue): \(String(describing: row.value))")
        XCTAssertTrue(row.label.contains(quarterRow.amount),
                      "Treats' row does not say \(quarterRow.amount): \(row.label)")
        expectRowFill(row, share: quarterRow.share, fill: quarterRow.fillColor, run: run)

        // Scenario WHEEL-10
        // 4. Over its limit, the wheel is orange all the way round with no
        // tick, says how far over, and says nothing about the pace.
        run.openBudget(named: "Treats")
        run.addEntry(merchant: "Market", amount: "90.00")
        let overSpent = TodaysBudget("Treats", limit: 10_000, spent: 11_500, pinnedDay: day)
        let over = overSpent.wheel
        XCTAssertTrue(run.waitForLabel(AccessibilityID.budgetWheel, toBe: over.spokenSummary),
                      "the wheel does not say \(over.spokenSummary): \(wheel.label)")
        XCTAssertEqual(over.spokenSummary, "Over $15 of $100")
        expectFigures(over, run: run)
        XCTAssertFalse(run.text(MoneyWheel.Words.expectedLeft).exists, "an over budget shows an expected figure")
        XCTAssertFalse(run.element(AccessibilityID.budgetPace).exists, "an over budget shows pace words")
        expectRing(of: over, run: run, noTickAt: quarter.tick)

        // Scenario WHEEL-02, WHEEL-04
        // 5. Back on Home, the row is filled all the way in the over colour,
        // and says how far over.
        run.goBack()
        let overRow = run.scrollTo(AccessibilityID.sidebarBudget("Treats"))
        let overFill = overSpent.row
        XCTAssertTrue(run.wait(for: overRow, until: "value == '\(overFill.spokenValue)'", timeout: 10),
                      "Treats' row is not \(overFill.spokenValue): \(String(describing: overRow.value))")
        XCTAssertTrue(overRow.label.contains(overFill.amount),
                      "Treats' row does not say \(overFill.amount): \(overRow.label)")
        expectRowFill(overRow, share: overFill.share, fill: overFill.fillColor, run: run)
    }

    @MainActor
    func testThePaceWordsInTheMiddleOfAMonth() throws {
        let day = Self.midMonth
        let run = launched(pinnedDay: day)

        // Scenario WHEEL-08
        // 1. Fuel, $100.00, with $99.00 spent by the middle of the month:
        // spent faster than an even pace, its wheel turns orange and the
        // words say when the money runs out, with Edit Budget beside them.
        run.addBudget(named: "Fuel", amount: "100", inGroup: "Household")
        run.addEntry(merchant: "Gas Station", amount: "99.00")
        let fuel = TodaysBudget("Fuel", limit: 10_000, spent: 9_900, pinnedDay: day)
        XCTAssertEqual(fuel.pace?.kind, .overPace, "on day \(Self.midMonth) Fuel is not over pace")
        XCTAssertTrue(run.waitForLabel(AccessibilityID.budgetWheel, toBe: fuel.wheel.spokenSummary),
                      "the wheel does not say \(fuel.wheel.spokenSummary)")
        expectPace(fuel.pace, run: run)
        expectRing(of: fuel.wheel, run: run)

        // Scenario WHEEL-09
        // 2. Books, $1,000.00, with $1.00 spent: more is left than an even
        // pace would leave, but before the month's last week nothing is said.
        run.goBack()
        run.addBudget(named: "Books", amount: "1000", inGroup: "Household")
        run.addEntry(merchant: "Bookshop", amount: "1.00")
        let books = TodaysBudget("Books", limit: 100_000, spent: 100, pinnedDay: day)
        XCTAssertNil(books.pace, "on day \(Self.midMonth) Books has pace words")
        XCTAssertTrue(run.waitForLabel(AccessibilityID.budgetWheel, toBe: books.wheel.spokenSummary),
                      "the wheel does not say \(books.wheel.spokenSummary)")
        expectPace(books.pace, run: run)
    }

    @MainActor
    func testThePaceWordsInTheMonthsLastWeek() throws {
        let day = Self.lastWeek
        let run = launched(pinnedDay: day)

        // Scenario WHEEL-09
        // 1. Books, $1,000.00, with $1.00 spent in the month's last week:
        // more is left than an even pace would leave, so the words ask
        // whether to lower it, with Edit Budget beside them.
        run.addBudget(named: "Books", amount: "1000", inGroup: "Household")
        run.addEntry(merchant: "Bookshop", amount: "1.00")
        let books = TodaysBudget("Books", limit: 100_000, spent: 100, pinnedDay: day)
        XCTAssertEqual(books.pace?.kind, .underPace, "on day \(Self.lastWeek) Books is not under pace")
        XCTAssertTrue(run.waitForLabel(AccessibilityID.budgetWheel, toBe: books.wheel.spokenSummary),
                      "the wheel does not say \(books.wheel.spokenSummary)")
        expectPace(books.pace, run: run)
        expectRing(of: books.wheel, run: run)
    }

    // MARK: - Checks the tests share

    /// A group's money on the day the budgets count as today.
    private func money(_ group: String, _ budgets: TodaysBudget..., line: UInt = #line) throws -> GroupMoney {
        try XCTUnwrap(TodaysBudget.group(group, budgets), "no money for \(group)", line: line)
    }

    /// The figures under the wheel, each label and amount as plain words.
    @MainActor
    private func expectFigures(_ wheel: MoneyWheel, run: PhoneTestApp, line: UInt = #line) {
        for figure in wheel.figures {
            XCTAssertTrue(run.shows(figure.label), "no \(figure.label). On screen: \(run.visibleTexts())", line: line)
            XCTAssertTrue(run.shows(figure.amount), "no \(figure.amount) for \(figure.label). On screen: \(run.visibleTexts())",
                          line: line)
        }
    }

    /// The wheel's ring as drawn: its colour as far round as the wheel says,
    /// the empty track after that, and the tick where the wheel puts it. Or
    /// no tick, where `noTickAt` says one stood before.
    @MainActor
    private func expectRing(of wheel: MoneyWheel, run: PhoneTestApp, noTickAt oldTick: Double? = nil,
                            line: UInt = #line) {
        let element = run.element(AccessibilityID.budgetWheel)
        XCTAssertTrue(element.waitForExistence(timeout: 10), "no wheel", line: line)
        let g = WheelGeometry.budgetPhone
        func onRing(_ share: Double, _ radius: Double) -> CGPoint {
            PhoneTestApp.point(on: element, share: share, radius: radius)
        }
        var checks: [ColourCheck] = []
        // Along the drawn part, or at its middle when it is too short to
        // read along.
        let drawn = wheel.arc >= 0.06
            ? PhoneTestApp.shares(in: 0.02 ... wheel.arc - 0.02, clearOf: wheel.tick)
            : PhoneTestApp.shares(in: wheel.arc / 2 ... wheel.arc / 2, clearOf: wheel.tick)
        if wheel.arc > 0 {
            let part = "the wheel's \(wheel.isWarning ? "orange" : "green")"
            checks += drawn.map { ColourCheck(part: part, colour: wheel.arcColor, point: onRing($0, g.radius)) }
        }
        if wheel.arc < 0.96 {
            checks += PhoneTestApp.shares(in: min(wheel.arc + 0.02, 0.98) ... 0.98, clearOf: wheel.tick).map {
                ColourCheck(part: "the wheel's empty track", colour: PaletteValues.wheelTrack, point: onRing($0, g.radius))
            }
        }
        // Inside the band, the tick crosses the page alone.
        let inside = (g.tickInner + g.innerEdge - WheelGeometry.edgeWidth / 2) / 2
        if let tick = wheel.tick {
            checks.append(ColourCheck(part: "the tick", colour: PaletteValues.wheelEdge, point: onRing(tick, inside)))
        }
        if let oldTick, wheel.tick == nil {
            checks.append(ColourCheck(part: "the page where the tick was", colour: PaletteValues.ground,
                                      point: onRing(oldTick, inside)))
        }
        run.expectColours(checks, line: line)
    }

    /// A row on Home: the fill from the left as far as the share, in its
    /// colour, then the empty track. Read along the row's top, clear of its
    /// words.
    @MainActor
    private func expectRowFill(_ row: XCUIElement, share: Double, fill: ColorPair, run: PhoneTestApp,
                               line: UInt = #line) {
        let frame = row.frame
        func along(_ share: Double) -> CGPoint { CGPoint(x: frame.minX + frame.width * share, y: frame.minY + 3) }
        let filled = [0.1, share - 0.05].filter { $0 < share }
            .map { ColourCheck(part: "the row's fill", colour: fill, point: along($0)) }
        let track = [share + 0.1, 0.9].filter { $0 > share && $0 < 1 }
            .map { ColourCheck(part: "the row's empty track", colour: PaletteValues.rowTrack, point: along($0)) }
        run.expectColours(filled + track, line: line)
    }

    /// The pace words today, exactly as the shared code words them, or none
    /// when it has none. Edit Budget beside them opens the Edit Budget sheet,
    /// and Cancel closes it.
    @MainActor
    private func expectPace(_ pace: BudgetPace?, run: PhoneTestApp, line: UInt = #line) {
        let words = run.element(AccessibilityID.budgetPace)
        guard let pace else {
            XCTAssertFalse(words.waitForExistence(timeout: 2), "pace words show: \(words.label)", line: line)
            return
        }
        XCTAssertTrue(words.waitForExistence(timeout: 10), "no pace words. On screen: \(run.visibleTexts())", line: line)
        XCTAssertEqual(words.label, pace.text, line: line)
        let edit = run.button(AccessibilityID.budgetPaceEdit)
        guard pace.offersEdit else {
            XCTAssertFalse(edit.exists, "Edit Budget shows", line: line)
            return
        }
        XCTAssertTrue(edit.waitForExistence(timeout: 5), "no Edit Budget beside the pace words", line: line)
        XCTAssertEqual(edit.label, BudgetPace.Words.editBudget(onPhone: true), line: line)
        run.tap(AccessibilityID.budgetPaceEdit)
        XCTAssertTrue(run.app.navigationBars[BudgetEditor.Words.editTitle].waitForExistence(timeout: 10),
                      "Edit Budget did not open its sheet. On screen: \(run.visibleTexts())", line: line)
        run.tap(AccessibilityID.budgetEditorCancel)
        XCTAssertTrue(run.wait(for: run.element(AccessibilityID.budgetEditorCancel), until: "exists == false",
                               timeout: 10), "the sheet did not close", line: line)
    }

    /// Deletes a group from its menu on Home, and waits until it has gone.
    @MainActor
    private func deleteGroup(_ name: String, run: PhoneTestApp, line: UInt = #line) {
        run.scrollTo(AccessibilityID.sidebarGroup(name))
        run.longPress(AccessibilityID.sidebarGroup(name))
        run.tapMenuItem(MainScreen.Words.delete)
        let question = PendingDelete.group(BudgetGroup(name: name), budgets: 0, reach: .justYou)
        guard let confirm = run.questionButton(question.confirmLabel) else {
            XCTFail("no \(question.confirmLabel) on the question. On screen: \(run.visibleButtons())", line: line)
            return
        }
        confirm.tap()
        XCTAssertTrue(run.wait(for: run.element(AccessibilityID.sidebarGroup(name)), until: "exists == false",
                               timeout: 10), "\(name) is still on Home", line: line)
    }
}
