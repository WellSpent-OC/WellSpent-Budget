import Foundation
import XCTest
import WellSpentAppCore
import WellSpentModel

/// The money wheel on a phone, with no account: the card at the top of
/// Home, each budget's row filled as far as it is used, and a budget's own
/// wheel with its figures and pace words. Every word and number a test
/// expects comes from the shared code for today, never typed in, and every
/// colour from the palette for the phone's light or dark setting. Each test
/// starts the app on a fresh data folder.
final class PhoneWheelTests: XCTestCase {
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
    func testHomeStartsWithTheFirstGroupsWheel() throws {
        let run = launched()
        let today = try XCTUnwrap(PhoneTestApp.today(), "no day of the month")
        let card = run.element(AccessibilityID.homeMoney)

        // Scenario WHEEL-13
        // 1. A fresh install: Home starts with Household's wheel, above the
        // groups, with its month and the day of it.
        XCTAssertTrue(card.waitForExistence(timeout: 10), "no card on Home. On screen: \(run.visibleTexts())")
        XCTAssertTrue(card.label.contains(GroupMoney.Words.title("Household", today.month)),
                      "the card does not name Household and the month: \(card.label)")
        XCTAssertTrue(card.label.contains(today.shortLine), "the card does not say \(today.shortLine): \(card.label)")
        let household = run.element(AccessibilityID.sidebarGroup("Household"))
        XCTAssertTrue(household.waitForExistence(timeout: 10), "no Household")
        XCTAssertLessThan(card.frame.minY, household.frame.minY, "the card is not at the top of Home")

        // Scenario WHEEL-13
        // 2. The card shows the first group that still holds a budget, and
        // with no budgets in any group, there is no card.
        deleteGroup("Household", run: run)
        let next = GroupMoney.Words.title("Side Business", today.month)
        XCTAssertTrue(run.waitForLabel(AccessibilityID.homeMoney, toContain: next),
                      "the card does not move on to Side Business: \(card.label)")
        deleteGroup("Side Business", run: run)
        XCTAssertTrue(run.wait(for: card, until: "exists == false", timeout: 10),
                      "the card stayed with no budgets: \(card.label)")

        // Scenario WHEEL-13
        // 3. A new group's first budget brings the card back, with its wheel
        // full and nothing spent of it.
        run.addGroup(named: "Wheel")
        run.addBudget(named: "Treats", amount: "100", inGroup: "Wheel")
        run.goBack()
        let fresh = MoneyWheel(scope: .group, budgeted: Money(minorUnits: 10_000), spent: .zero(), day: today)
        XCTAssertTrue(run.waitForLabel(AccessibilityID.homeMoney, toContain: fresh.spokenSummary),
                      "the card does not say \(fresh.spokenSummary): \(card.label)")
        XCTAssertTrue(card.label.contains(GroupMoney.Words.title("Wheel", today.month)),
                      "the card does not name Wheel: \(card.label)")
        XCTAssertTrue(card.label.contains(GroupMoney.Words.spentLine("$0", "$100")),
                      "the card does not say what is spent: \(card.label)")

        // Scenario WHEEL-12
        // 4. Over the group's budgets, Home's card says how far over.
        run.openBudget(named: "Treats")
        run.addEntry(merchant: "Market", amount: "220.00")
        run.goBack()
        let over = MoneyWheel(scope: .group, budgeted: Money(minorUnits: 10_000), spent: Money(minorUnits: 22_000),
                              day: today)
        XCTAssertEqual(over.spokenSummary, "Over this month $120 of $100")
        XCTAssertTrue(run.waitForLabel(AccessibilityID.homeMoney, toContain: over.spokenSummary),
                      "the card does not say \(over.spokenSummary): \(card.label)")
        XCTAssertTrue(card.label.contains(GroupMoney.Words.spentLine("$220", "$100")),
                      "the card does not say what is spent: \(card.label)")
    }

    @MainActor
    func testRowsFillAndABudgetShowsItsWheel() throws {
        let run = launched()
        let today = try XCTUnwrap(PhoneTestApp.today(), "no day of the month")
        run.addBudget(named: "Treats", amount: "100", inGroup: "Household")
        let wheel = run.element(AccessibilityID.budgetWheel)

        // Scenario WHEEL-05, WHEEL-06
        // 1. A budget's screen says the day of the month, and shows its wheel
        // in place of the bar: full with nothing spent, with its figures.
        let full = PhoneTestApp.budgetWheel(budgeted: 10_000, spent: 0)
        XCTAssertTrue(run.waitForLabel(AccessibilityID.budgetWheel, toBe: full.spokenSummary),
                      "the wheel does not say \(full.spokenSummary): \(wheel.label)")
        XCTAssertEqual(full.spokenSummary, "Left $100 of $100")
        XCTAssertEqual(run.element(AccessibilityID.budgetDayLine).label, today.line)
        expectFigures(full, run: run)
        expectRing(of: full, run: run)

        // Scenario WHEEL-06, WHEEL-07
        // 2. Adding $25.00 empties a quarter of it at once, and the tick and
        // Expected left by today show where an even pace would be.
        run.addEntry(merchant: "Corner Bakery", amount: "25.00")
        let quarter = PhoneTestApp.budgetWheel(budgeted: 10_000, spent: 2_500)
        XCTAssertTrue(run.waitForLabel(AccessibilityID.budgetWheel, toBe: quarter.spokenSummary),
                      "the wheel does not say \(quarter.spokenSummary): \(wheel.label)")
        XCTAssertEqual(quarter.spokenSummary, "Left $75 of $100")
        expectFigures(quarter, run: run)
        expectRing(of: quarter, run: run)

        // Scenario WHEEL-01, WHEEL-04
        // 3. Back on Home, Treats' row is filled a quarter of the way, in the
        // colours for the phone's light or dark setting, and still says what
        // is left. (make iphone-ui-test runs once in light and once in dark.)
        run.goBack()
        let row = run.scrollTo(AccessibilityID.sidebarBudget("Treats"))
        XCTAssertTrue(row.waitForExistence(timeout: 10), "no Treats on Home")
        XCTAssertTrue(run.wait(for: row, until: "value == '\(RowFill.Words.used(25))'", timeout: 10),
                      "Treats' row is not 25 percent used: \(String(describing: row.value))")
        XCTAssertTrue(row.label.contains("$75.00"), "Treats' row does not say $75.00: \(row.label)")
        expectRowFill(row, share: 0.25, fill: PaletteValues.rowUsed, run: run)

        // Scenario WHEEL-10
        // 4. Over its limit, the wheel is orange all the way round with no
        // tick, says how far over, and says nothing about the pace.
        run.openBudget(named: "Treats")
        run.addEntry(merchant: "Market", amount: "90.00")
        let over = PhoneTestApp.budgetWheel(budgeted: 10_000, spent: 11_500)
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
        XCTAssertTrue(run.wait(for: overRow, until: "value == '\(RowFill.Words.overBudget)'", timeout: 10),
                      "Treats' row is not over budget: \(String(describing: overRow.value))")
        XCTAssertTrue(overRow.label.contains(RowFill.Words.over("$15.00")),
                      "Treats' row does not say $15.00 over: \(overRow.label)")
        expectRowFill(overRow, share: 1, fill: PaletteValues.rowOver, run: run)
    }

    @MainActor
    func testThePaceWords() throws {
        let run = launched()

        // Scenario WHEEL-08
        // 1. Spent faster than an even pace, the wheel turns orange and the
        // words say when the money runs out, with Edit Budget beside them.
        run.addBudget(named: "Fuel", amount: "100", inGroup: "Household")
        run.addEntry(merchant: "Gas Station", amount: "99.00")
        let fuel = PhoneTestApp.budgetWheel(budgeted: 10_000, spent: 9_900)
        XCTAssertTrue(run.waitForLabel(AccessibilityID.budgetWheel, toBe: fuel.spokenSummary),
                      "the wheel does not say \(fuel.spokenSummary)")
        expectPace(BudgetPace(wheel: fuel, budgetName: "Fuel", mayEdit: true), run: run)
        expectRing(of: fuel, run: run)

        // Scenario WHEEL-09
        // 2. More left than an even pace would leave asks, in the month's
        // last week only, whether to lower the budget.
        run.goBack()
        run.addBudget(named: "Books", amount: "1000", inGroup: "Household")
        run.addEntry(merchant: "Bookshop", amount: "1.00")
        let books = PhoneTestApp.budgetWheel(budgeted: 100_000, spent: 100)
        XCTAssertTrue(run.waitForLabel(AccessibilityID.budgetWheel, toBe: books.spokenSummary),
                      "the wheel does not say \(books.spokenSummary)")
        expectPace(BudgetPace(wheel: books, budgetName: "Books", mayEdit: true), run: run)
    }

    // MARK: - Checks the tests share

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
