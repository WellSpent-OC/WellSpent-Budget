import Foundation
import XCTest
import WellSpentAppCore
import WellSpentModel

/// Money coming in on a phone (card INC-B, the iPhone half): an entry marked
/// as money in shows in the list with a plus sign, and a statement line that
/// is money in is offered as Income or Refund. How the wheel draws money in
/// is INC-C's, so no wheel is checked here. No account and no server, so
/// these run on every pull request, in light and in dark.
final class PhoneMoneyInTests: XCTestCase {
    /// Mid-month, before the last week of any month.
    private static let midMonth = 18

    nonisolated(unsafe) private static var dataRootPath: String?
    nonisolated(unsafe) private static var statementsPath: String?

    private typealias Words = EntryEditor.Words
    private typealias ImportWords = ImportReviewScreen.Words

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
    private func launched(pinnedDay day: Int) -> PhoneTestApp {
        let run = PhoneTestApp()
        Self.dataRootPath = run.dataRoot.path
        run.launch(pinnedDay: day)
        return run
    }

    /// A fresh app on Groceries, with Import statement reading this file.
    @MainActor
    private func launched(importing statement: URL) -> PhoneTestApp {
        let run = PhoneTestApp()
        Self.dataRootPath = run.dataRoot.path
        run.launch(importing: statement)
        return run
    }

    /// A folder for the test's statements, removed in tearDown.
    private func statements() throws -> StatementFolder {
        let folder = try StatementFolder()
        Self.statementsPath = folder.url.path
        return folder
    }

    // MARK: - INC-01

    @MainActor
    func testAnEntryCanBeMoneyComingIn() throws {
        let run = launched(pinnedDay: Self.midMonth)

        // Scenario INC-01
        // Given: a group called Pool House with a budget called Bookings.
        // A spending entry sits beside it, so the plus sign can be seen to
        // mark only the money in.
        run.addGroup(named: "Pool House")
        run.addBudget(named: "Bookings", amount: "2000", inGroup: "Pool House")
        run.addEntry(merchant: "Cleaner", amount: "400.00")
        XCTAssertTrue(run.row("Cleaner", says: "$400.00"),
                      "the spending row does not say $400.00: \(run.rowLabel("Cleaner"))")
        XCTAssertFalse(run.element(AccessibilityID.budgetMoneyInLine).exists,
                       "a budget with no money in says something about it: \(run.visibleTexts())")

        // When: an entry of $1,310.00 is added and marked as money in. With
        // the switch on, the help line names the budget.
        run.addMoneyIn(merchant: "Airbnb", amount: "1310.00", intoBudget: "Bookings")

        // Then: the entry shows in the list with a plus sign, the spending
        // row still has none, and the count line gains the money in.
        XCTAssertTrue(run.row("Airbnb", says: "+$1310.00"),
                      "no plus sign on the money-in row: \(run.rowLabel("Airbnb"))")
        XCTAssertFalse(run.row("Cleaner", says: "+", timeout: 1),
                       "the spending row gained a plus sign: \(run.rowLabel("Cleaner"))")
        XCTAssertTrue(run.waitForLabel(AccessibilityID.budgetMoneyInLine, toContain: "$1310.00 in"),
                      "the count line does not say the money in: \(run.visibleTexts())")

        // Opened again, it is still marked as money in, and the top line
        // says what it is rather than Refund.
        run.openEntry("Airbnb")
        let moneyIn = run.element(AccessibilityID.entryMoneyIn)
        XCTAssertTrue(moneyIn.waitForExistence(timeout: 10), "no Money in switch on the opened entry")
        XCTAssertEqual(moneyIn.value as? String, "1", "the opened entry is not marked as money in")
        XCTAssertTrue(run.waitForLabel(AccessibilityID.entryTopLine, toContain: Words.income),
                      "the top line does not say \(Words.income): \(run.element(AccessibilityID.entryTopLine).label)")
        run.tap(AccessibilityID.entryCancel)
        run.expectNoSheet()
    }

    // MARK: - INC-02

    @MainActor
    func testAStatementLineThatIsMoneyInIsOfferedAsIncomeOrRefund() throws {
        let airbnb = "AIRBNB PAYOUT", cleaning = "CLEANING CO"
        let folder = try statements()
        // The first payout is dated yesterday, so the second, today, is the
        // payer's latest money-in entry for step 4.
        let first = try folder.write([(airbnb, "1310.00", 1), (cleaning, "-120.00", 1)])
        let run = launched(importing: first)

        // Scenario INC-02
        // 1. The payout is offered as money in, Income first, with Refund and
        // More… beside it. The charge has no such choice.
        run.importStatement()
        XCTAssertEqual(run.kind(of: airbnb), Words.income, "the payout is not offered as \(Words.income)")
        XCTAssertFalse(run.element(AccessibilityID.importLineKind(cleaning)).exists, "money out offers a kind")
        for part in [Words.income, Words.refund, ImportWords.more] {
            XCTAssertTrue(run.kindPart(part, of: airbnb).exists, "the choice has no \(part) part. On screen: \(run.visibleButtons())")
        }

        // 2. Taken as Income into Groceries, it lands with its plus sign and
        // the count line says the money in. The charge, left at Choose, is
        // not added.
        run.choose("Groceries", for: airbnb)
        run.tap(AccessibilityID.importConfirm)
        run.waitForTheReviewToClose()
        XCTAssertTrue(run.row("Airbnb Payout", says: "+$1310.00"),
                      "the payout did not land as money in: \(run.rowLabel("Airbnb Payout"))")
        XCTAssertTrue(run.waitForLabel(AccessibilityID.budgetMoneyInLine, toContain: "$1310.00 in"),
                      "the count line does not say the money in: \(run.visibleTexts())")
        XCTAssertFalse(run.element(AccessibilityID.entryRow("Cleaning")).exists, "a line left at Choose was added")

        // 3. The next payout is offered as Income again. Chosen as Refund,
        // it lands with its plus sign, and the money in does not grow: a
        // refund lowers what is spent instead.
        let second = try folder.write([(airbnb, "980.00", 0)])
        run.relaunch(importing: second)
        run.importStatement()
        XCTAssertEqual(run.kind(of: airbnb), Words.income, "the second payout is not offered as \(Words.income)")
        run.chooseKind(Words.refund, for: airbnb)
        run.tap(AccessibilityID.importConfirm)
        run.waitForTheReviewToClose()
        XCTAssertTrue(run.row("Airbnb Payout", says: "+$980.00"),
                      "the refund did not land: \(run.rowLabel("Airbnb Payout"))")
        XCTAssertTrue(run.waitForLabel(AccessibilityID.budgetMoneyInLine, toContain: "$1310.00 in"),
                      "a refund counted as money in: \(run.visibleTexts())")

        // 4. The next line from the same payer is offered the same way: as
        // Refund, since that is what its last payout was marked.
        let third = try folder.write([(airbnb, "500.00", 0)])
        run.relaunch(importing: third)
        run.importStatement()
        XCTAssertEqual(run.kind(of: airbnb), Words.refund, "the same payer's next line is not offered as \(Words.refund)")
        run.tap(AccessibilityID.importCancel)
        run.waitForTheReviewToClose()
    }
}

/// The steps these tests take, beside the ones every iPhone test shares.
extension PhoneTestApp {
    /// Add, at the foot of the open budget, with the Money in switch turned
    /// on before Add. With the switch on, the help line names the budget.
    func addMoneyIn(merchant: String, amount: String, intoBudget budget: String) {
        tap(AccessibilityID.budgetAdd)
        type(merchant, into: AccessibilityID.entryMerchant)
        type(amount, into: AccessibilityID.entryAmount)
        let moneyIn = element(AccessibilityID.entryMoneyIn)
        XCTAssertTrue(moneyIn.waitForExistence(timeout: 10), "no Money in switch. On screen: \(visibleTexts())")
        XCTAssertFalse(element(AccessibilityID.entryMoneyInLine).exists, "the help line shows while the switch is off")
        // A SwiftUI Toggle reaches the test as a switch whose value is "0"
        // or "1". A tap on it flips it.
        // The decimal keypad is up after the amount, so the row may sit
        // under it. The switch itself is the thing to tap, not its label.
        waitUntilHittable(moneyIn, AccessibilityID.entryMoneyIn)
        let control = moneyIn.switches.firstMatch.exists ? moneyIn.switches.firstMatch : moneyIn
        if (moneyIn.value as? String) != "1" { control.tap() }
        XCTAssertTrue(wait(for: moneyIn, until: "value == '1'", timeout: 5), "Money in did not turn on")
        XCTAssertTrue(waitForLabel(AccessibilityID.entryMoneyInLine, toBe: EntryEditor.Words.moneyInHelp(budget: budget)),
                      "the help line does not name \(budget): \(visibleTexts())")
        tap(AccessibilityID.entryAdd)
        XCTAssertTrue(element(AccessibilityID.entryRow(merchant)).waitForExistence(timeout: 10),
                      "\(merchant) is not in the list. On screen: \(visibleTexts())")
    }

    /// What a money-in line is offered as, from its choice's value.
    func kind(of bank: String) -> String? {
        let choice = element(AccessibilityID.importLineKind(bank))
        XCTAssertTrue(choice.waitForExistence(timeout: 5), "\(bank) has no kind choice. On screen: \(visibleTexts())")
        return choice.value as? String
    }

    /// One part of a line's kind choice, by its words.
    func kindPart(_ title: String, of bank: String) -> XCUIElement {
        element(AccessibilityID.importLineKind(bank)).buttons[title].firstMatch
    }

    /// Chooses Income or Refund for a money-in line, and waits for it to show.
    func chooseKind(_ title: String, for bank: String) {
        let part = kindPart(title, of: bank)
        XCTAssertTrue(part.waitForExistence(timeout: 5), "no \(title) part for \(bank). On screen: \(visibleButtons())")
        part.tap()
        XCTAssertTrue(wait(for: element(AccessibilityID.importLineKind(bank)), until: "value == '\(title)'", timeout: 5),
                      "\(title) was not chosen for \(bank): \(kind(of: bank) ?? "nothing")")
    }

    /// Relaunches on the same data folder, with Import statement reading
    /// another file, so a second statement can follow the first.
    func relaunch(importing statement: URL) {
        if app.state != .notRunning { app.terminate() }
        launch(importing: statement)
    }
}
