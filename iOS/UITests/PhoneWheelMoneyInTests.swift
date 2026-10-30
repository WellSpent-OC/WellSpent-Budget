import Foundation
import XCTest
import WellSpentAppCore
import WellSpentModel

/// The wheel's step 2 on a phone (card INC-C, the iPhone half): money in
/// refills a group's wheel toward full, its middle says money in against
/// money out, and borrowed money and savings draws are named under the
/// figures without refilling it. The same steps as the Mac's
/// `testMoneyInOnAGroupsWheel`: one group with one budget, Rent, $4,080.00 a
/// month, on the 18th. Every word and number expected comes from the shared
/// code for the same money. No account, so it runs in light and in dark.
final class PhoneWheelMoneyInTests: XCTestCase {
    /// Mid-month, before the last week of any month.
    private static let midMonth = 18

    nonisolated(unsafe) private static var dataRootPath: String?
    nonisolated(unsafe) private static var statementsPath: String?

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    override func tearDown() {
        let app = XCUIApplication()
        if app.state != .notRunning { app.terminate() }
        for path in [Self.dataRootPath, Self.statementsPath].compactMap({ $0 }) {
            try? FileManager.default.removeItem(atPath: path)
        }
        Self.dataRootPath = nil
        Self.statementsPath = nil
        super.tearDown()
    }

    @MainActor
    func testMoneyInOnAGroupsWheel() throws {
        let group = "Home Money", rent = "Rent"
        let loan = "CREDIT UNION LOAN", savings = "SAVINGS XFER"
        let day = Self.midMonth
        func month(spent: Int, moneyIn: Int = 0, borrowed: Int = 0, fromSavings: Int = 0) throws -> GroupMoney {
            try XCTUnwrap(TodaysBudget.group(group, [
                TodaysBudget(rent, limit: 408_000, spent: spent, moneyIn: moneyIn, borrowed: borrowed,
                             fromSavings: fromSavings, pinnedDay: day),
            ]))
        }

        // The draws arrive by statement in step 6. Import statement reads a
        // file named at launch, so it is written now.
        let folder = try StatementFolder()
        Self.statementsPath = folder.url.path
        let statement = try folder.write([(loan, "500.00", 0), (savings, "300.00", 0)])
        let run = PhoneTestApp()
        Self.dataRootPath = run.dataRoot.path
        run.app.launchEnvironment[Workspace.pinnedDayVariable] = String(day)
        run.launch(importing: statement)
        run.goBack()
        run.addGroup(named: group)
        run.addBudget(named: rent, amount: "4080", inGroup: group)

        func expect(_ money: GroupMoney, _ what: String, line: UInt = #line) {
            run.goBack()
            run.openGroupPage(named: group)
            XCTAssertTrue(run.waitForLabel(AccessibilityID.groupWheel, toBe: money.wheel.spokenSummary),
                          "\(what): the wheel does not say \(money.wheel.spokenSummary): "
                              + run.element(AccessibilityID.groupWheel).label, line: line)
            for figure in money.wheel.figures {
                XCTAssertTrue(run.shows(figure.label), "\(what): no \(figure.label). On screen: \(run.visibleTexts())",
                              line: line)
                XCTAssertTrue(run.shows(figure.amount),
                              "\(what): no \(figure.amount) for \(figure.label). On screen: \(run.visibleTexts())",
                              line: line)
            }
            XCTAssertTrue(run.shows(money.note), "\(what): no note saying \(money.note). On screen: \(run.visibleTexts())",
                          line: line)
            run.goBack()
            run.openBudget(named: rent)
        }

        // Scenario WHEEL-16
        // 1. $2,777.96 spent and no money in: the wheel is step 1's, with no
        // In figure, and the note ends "added up."
        run.addEntry(merchant: "Landlord", amount: "2777.96")
        let plain = try month(spent: 277_796)
        expect(plain, "no money in")
        XCTAssertFalse(plain.wheel.hasMoneyIn)
        run.goBack()
        run.openGroupPage(named: group)
        XCTAssertFalse(run.shows(MoneyWheel.Words.moneyIn, timeout: 2), "an In figure is drawn with no money in")
        run.goBack()
        run.openBudget(named: rent)

        // Scenario WHEEL-14, WHEEL-15, WHEEL-20
        // 2. $1,230.00 of income: the wheel refills, the middle says money in,
        // money out and the cash flow, In leads the figures, and Expected left
        // by today is what it was, since money in never moves the tick.
        run.addMoneyIn(merchant: "Paycheck", amount: "1230", intoBudget: rent)
        let refilled = try month(spent: 277_796, moneyIn: 123_000)
        XCTAssertEqual(refilled.wheel.figures.first?.label, MoneyWheel.Words.moneyIn, "In does not lead the figures")
        XCTAssertEqual(refilled.wheel.expectedLeft, plain.wheel.expectedLeft, "money in moved the tick")
        expect(refilled, "$1,230.00 in")

        // Scenario WHEEL-17
        // 3. Spending to $4,500.00 passes the budgets, and the money in covers
        // it: the wheel stays green and one line says so.
        run.addEntry(merchant: "Repairs", amount: "1722.04")
        let covered = try month(spent: 450_000, moneyIn: 123_000)
        let coveredLine = try XCTUnwrap(covered.wheel.overBudgetsCoveredLine, "money in covers it")
        run.goBack()
        run.openGroupPage(named: group)
        XCTAssertTrue(run.waitForLabel(AccessibilityID.groupOverBudgetsCovered, toBe: coveredLine),
                      "no line saying \(coveredLine). On screen: \(run.visibleTexts())")
        run.goBack()
        run.openBudget(named: rent)
        expect(covered, "over the budgets, covered")

        // Scenario WHEEL-18
        // 4. $1,030.00 more puts the spending past the budgets and the money
        // in together: the wheel turns orange and says how far over, with no
        // Expected left by today.
        run.addEntry(merchant: "Plumber", amount: "1030")
        let over = try month(spent: 553_000, moneyIn: 123_000)
        XCTAssertTrue(over.wheel.isOver, "the test's own numbers are over")
        expect(over, "over the budgets and the money in")
        XCTAssertFalse(over.wheel.figures.contains { $0.label == MoneyWheel.Words.expectedLeft })

        // Scenario WHEEL-14, WHEEL-15
        // 5. $5,000.00 more income: the wheel is full and no fuller, and the
        // cash flow is ahead.
        run.addMoneyIn(merchant: "Bonus", amount: "5000", intoBudget: rent)
        let full = try month(spent: 553_000, moneyIn: 623_000)
        XCTAssertEqual(full.wheel.arc, 1, "the test's own numbers fill the wheel")
        expect(full, "full")

        // Scenario WHEEL-19
        // 6. A loan draw and a savings draw from a statement are named under
        // the figures and refill nothing.
        run.importStatement()
        run.chooseOtherKind(EntryEditor.Words.borrowed, for: loan)
        run.chooseOtherKind(EntryEditor.Words.fromSavings, for: savings)
        run.choose(rent, for: loan)
        run.choose(rent, for: savings)
        run.tap(AccessibilityID.importConfirm)
        run.waitForTheReviewToClose()
        let drawn = try month(spent: 553_000, moneyIn: 623_000, borrowed: 50_000, fromSavings: 30_000)
        XCTAssertEqual(drawn.wheel, full.wheel, "borrowed money or a savings draw changed the wheel")
        expect(drawn, "after the draws")
        run.goBack()
        run.openGroupPage(named: group)
        for line in drawn.otherMoneyLines {
            XCTAssertTrue(run.shows(line), "no line saying \(line). On screen: \(run.visibleTexts())")
        }
    }
}

extension PhoneTestApp {
    /// Chooses a kind from behind More… for a money-in line, and waits for
    /// it to take the third part's place.
    func chooseOtherKind(_ title: String, for bank: String) {
        let more = kindPart(ImportReviewScreen.Words.more, of: bank)
        XCTAssertTrue(more.waitForExistence(timeout: 5), "no More… for \(bank). On screen: \(visibleButtons())")
        more.tap()
        let item = app.buttons[title].firstMatch
        XCTAssertTrue(item.waitForExistence(timeout: 5), "More… does not offer \(title). On screen: \(visibleButtons())")
        item.tap()
        XCTAssertTrue(wait(for: element(AccessibilityID.importLineKind(bank)), until: "value == '\(title)'", timeout: 5),
                      "\(title) was not chosen for \(bank): \(kind(of: bank) ?? "nothing")")
    }
}
