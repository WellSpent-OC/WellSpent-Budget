import Foundation
import XCTest
import WellSpentAppCore
import WellSpentModel

/// Repeat expenses on the Mac: setting one, the short list and a repeat's own
/// sheet, which months a change reaches, stopping, the two ways to delete, and
/// Undo. No account. A later month's bill needs a clock this test can't move, so
/// `RepeatsTests` holds that, and who may change a repeat.
final class RepeatTests: XCTestCase {
    private typealias Words = EntryEditor.Words
    nonisolated(unsafe) private static var dataRootPath: String?
    private static let bill = "Phone bill"

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

    /// A budget in a group of its own, open, with no repeats yet.
    @MainActor
    private func started() throws -> TestApp {
        let run = try TestApp()
        Self.dataRootPath = run.dataRoot.path
        // Longer than the Undo bar's 10 seconds, so a slow run reaches it.
        run.app.launchEnvironment[Workspace.undoWindowVariable] = "120"
        run.launch()
        run.addGroup(named: "Home")
        run.addBudget(named: "Utilities", amount: "600", inGroup: "Home")
        return run
    }

    @MainActor
    private func startedWithARepeat() throws -> TestApp {
        let run = try started()
        run.addRepeat(merchant: Self.bill, amount: "85.00")
        return run
    }

    @MainActor
    func testSettingARepeatAndFindingIt() throws {
        let run = try started()

        // Scenario REPEAT-12
        // With none, the count line doesn't mention repeats.
        XCTAssertFalse(run.element(AccessibilityID.budgetRepeats).exists, "a budget with none says it has repeats")

        // Scenario REPEAT-01
        run.addRepeat(merchant: Self.bill, amount: "85.00")
        XCTAssertEqual(run.app.staticTexts.matching(NSPredicate(format: "label == %@ OR value == %@", Self.bill, Self.bill)).count, 1,
                       "the bill is not in the list once. On screen: \(run.visibleTexts())")

        // Scenario REPEAT-12
        run.addRepeat(merchant: "Internet", amount: "60.00")
        let repeats = run.element(AccessibilityID.budgetRepeats)
        XCTAssertTrue(repeats.waitForExistence(timeout: 10), "no count of repeats")
        XCTAssertEqual(run.text(of: repeats), RepeatsList.Words.count(2))
        run.click(AccessibilityID.budgetRepeats)
        run.click(AccessibilityID.repeatRow(Self.bill))
        XCTAssertTrue(run.element(AccessibilityID.repeatStop).waitForExistence(timeout: 10), "no Stop repeating")
        XCTAssertTrue(run.element(AccessibilityID.repeatSave).exists, "the owner has no Save on a repeat's own sheet")
    }

    @MainActor
    func testTheSwitchTellsTheTruthOnSaveAndReopen() throws {
        let run = try started()
        run.addEntry(merchant: "Water", amount: "40.00")
        let repeats = run.element(AccessibilityID.budgetRepeats)

        // Scenario REPEAT-17
        run.clickRow("Water")
        run.expectSheet(for: "Water")
        run.expectSwitch(on: false, "before turning it on")
        run.click(AccessibilityID.entryRepeats)
        run.click(AccessibilityID.entrySave)
        run.expectNoSheet()
        XCTAssertTrue(repeats.waitForExistence(timeout: 10), "no count of repeats")
        XCTAssertEqual(run.text(of: repeats), RepeatsList.Words.count(1))
        XCTAssertEqual(run.app.staticTexts.matching(NSPredicate(format: "label == %@ OR value == %@", "Water", "Water")).count, 1,
                       "the bill is not in the list once. On screen: \(run.visibleTexts())")

        // Scenario REPEAT-18
        // Reopened it reads on. Off and saved, the repeat stops and it reads off.
        run.clickRow("Water")
        run.expectSheet(for: "Water")
        run.expectSwitch(on: true, "reopened after turning it on")
        run.click(AccessibilityID.entryRepeats)
        run.click(AccessibilityID.entrySave)
        run.expectNoSheet()
        XCTAssertTrue(run.wait(for: repeats, until: "exists == false", timeout: 10), "a stopped repeat is still counted")
        run.clickRow("Water")
        run.expectSheet(for: "Water")
        run.expectSwitch(on: false, "reopened after stopping")

        // Scenario REPEAT-18
        // On again is the same repeat: the count is one, not two.
        run.click(AccessibilityID.entryRepeats)
        run.click(AccessibilityID.entrySave)
        run.expectNoSheet()
        XCTAssertTrue(repeats.waitForExistence(timeout: 10), "no count after starting it again")
        XCTAssertEqual(run.text(of: repeats), RepeatsList.Words.count(1))
    }

    @MainActor
    func testMoneyInDoesNotRepeat() throws {
        let run = try started()
        run.click(AccessibilityID.budgetAdd)
        XCTAssertTrue(run.element(AccessibilityID.entryRepeats).waitForExistence(timeout: 10), "no Repeats row")

        // Scenario REPEAT-13
        run.click(AccessibilityID.entryMoneyIn)
        XCTAssertTrue(run.wait(for: run.element(AccessibilityID.entryRepeats), until: "exists == false", timeout: 5),
                      "money in offers Repeats")
    }

    @MainActor
    func testAChangeSaysWhichMonthsItReaches() throws {
        let run = try startedWithARepeat()

        // Scenario REPEAT-06
        // A change to this month only leaves the repeat at its old amount.
        run.clickRow(Self.bill)
        run.expectSheet(for: Self.bill)
        run.replaceAmount(with: "92.00")
        let which = run.element(AccessibilityID.entryWhichMonths)
        XCTAssertTrue(which.waitForExistence(timeout: 10), "Which months? is not on the sheet")
        XCTAssertEqual(run.text(of: which), Words.thisMonthOnly, "it does not start on This month only")
        run.click(AccessibilityID.entrySave)
        run.expectNoSheet()
        XCTAssertTrue(run.listText("$92.00").waitForExistence(timeout: 10), "the bill did not change")
        run.expectRepeat(Self.bill, says: "$85.00", "a change to this month only reached the repeat")

        // Scenario REPEAT-07
        // A change to this month and later changes the repeat too.
        run.clickRow(Self.bill)
        run.expectSheet(for: Self.bill)
        run.replaceAmount(with: "95.00")
        run.click(AccessibilityID.entryWhichMonths)
        let later = run.menuItem(Words.thisMonthAndLater)
        XCTAssertTrue(later.waitForExistence(timeout: 5), "This month and later is not offered")
        later.click()
        run.click(AccessibilityID.entrySave)
        run.expectNoSheet()
        XCTAssertTrue(run.listText("$95.00").waitForExistence(timeout: 10), "the bill did not change")
        run.expectRepeat(Self.bill, says: "$95.00", "the repeat did not change")
    }

    @MainActor
    func testStopRepeatingEndsTheRepeatAndKeepsTheBill() throws {
        let run = try startedWithARepeat()

        // Scenario REPEAT-08
        run.clickRow(Self.bill)
        run.expectSheet(for: Self.bill)
        run.click(AccessibilityID.entryStopRepeating)
        try XCTUnwrap(run.dialogButton(RepeatEditor.Words.stopConfirm), "Stop repeating does not ask").click()
        run.expectNoSheet()
        XCTAssertTrue(run.listText(Self.bill).waitForExistence(timeout: 10), "the bill went with the repeat")
        XCTAssertTrue(run.wait(for: run.element(AccessibilityID.budgetRepeats), until: "exists == false", timeout: 10),
                      "the stopped repeat is still counted")

        // Scenario REPEAT-10
        // Undo carries the repeat on.
        run.click(AccessibilityID.undoButton)
        XCTAssertTrue(run.element(AccessibilityID.budgetRepeats).waitForExistence(timeout: 10), "Undo did not bring the repeat back")
    }

    @MainActor
    func testDeletingAMadeBillAsksBothChoices() throws {
        let run = try startedWithARepeat()

        // Scenario REPEAT-09
        run.clickRow(Self.bill)
        run.expectSheet(for: Self.bill)
        run.click(AccessibilityID.entryDelete)
        XCTAssertNotNil(run.dialogButton(PendingDelete.deleteThisMonthOnly), "no Delete This Month Only")
        try XCTUnwrap(run.dialogButton(PendingDelete.deleteAndStop), "no Delete and Stop Repeating").click()
        run.expectNoSheet()
        XCTAssertTrue(run.rowIsGone(Self.bill), "the bill is still here")
        XCTAssertTrue(run.wait(for: run.element(AccessibilityID.budgetRepeats), until: "exists == false", timeout: 10),
                      "the repeat is still counted")

        // Scenario REPEAT-10
        // Undo brings back both.
        run.click(AccessibilityID.undoButton)
        XCTAssertTrue(run.listText(Self.bill).waitForExistence(timeout: 10), "Undo did not bring the bill back")
        XCTAssertTrue(run.element(AccessibilityID.budgetRepeats).waitForExistence(timeout: 10), "Undo did not bring the repeat back")
    }

    // MARK: - Later months, on the test clock

    /// Utilities in Home on the test clock at `start`, with the $85.00 phone
    /// bill set to repeat that day.
    @MainActor
    private func repeating(from start: String) throws -> TestApp {
        let run = try TestApp()
        Self.dataRootPath = run.dataRoot.path
        try run.setClock(start)
        run.launch()
        run.addGroup(named: "Home")
        run.addBudget(named: "Utilities", amount: "600", inGroup: "Home")
        run.addRepeat(merchant: Self.bill, amount: "85.00")
        return run
    }

    /// Quits, moves the clock to `day`, and opens the app again on Utilities.
    @MainActor
    private func reopen(_ run: TestApp, on day: String) throws {
        run.app.terminate()
        try run.setClock(day)
        run.launch()
        run.openBudget(named: "Utilities")
    }

    /// The open budget's list holds the phone bill once, dated `day`, made by
    /// its repeat, at $85.00.
    @MainActor
    private func expectOneBill(on day: String, in run: TestApp, _ when: String,
                               file: StaticString = #filePath, line: UInt = #line) throws {
        let date = BudgetScreen.shortDate(try TestApp.clockDate(day))
        XCTAssertTrue(run.listText(date).waitForExistence(timeout: 15),
                      "\(when): no bill dated \(date). On screen: \(run.visibleTexts())", file: file, line: line)
        let bills = run.app.staticTexts.matching(NSPredicate(format: "label == %@ OR value == %@", Self.bill, Self.bill))
        XCTAssertEqual(bills.count, 1, "\(when): not one bill. On screen: \(run.visibleTexts())", file: file, line: line)
        XCTAssertTrue(run.listText(BudgetScreen.Words.repeatSource).exists,
                      "\(when): Source does not say Repeat. On screen: \(run.visibleTexts())", file: file, line: line)
        XCTAssertTrue(run.listText("$85.00").exists, "\(when): not $85.00. On screen: \(run.visibleTexts())",
                      file: file, line: line)
    }

    @MainActor
    func testItShowsUpEachMonth() throws {
        let run = try repeating(from: "2026-11-14T09:00:00")

        // Scenario REPEAT-02
        // 1. December 14 comes and the app is opened: a new $85.00 bill is in
        // Utilities, with Source reading Repeat.
        try reopen(run, on: "2026-12-14T09:00:00")
        run.expect(dayLine: "December \u{00B7} day 14 of 31", "on December 14")
        try expectOneBill(on: "2026-12-14T09:00:00", in: run, "on December 14")
    }

    @MainActor
    func testCatchingUpAfterTimeAway() throws {
        let run = try repeating(from: "2026-10-14T09:00:00")

        // Scenario REPEAT-03
        // 1. Away from the app for two months, it's opened on December 20:
        // December has its bill, one.
        try reopen(run, on: "2026-12-20T09:00:00")
        run.expect(dayLine: "December \u{00B7} day 20 of 31", "on December 20")
        try expectOneBill(on: "2026-12-14T09:00:00", in: run, "December, after two months away")

        // Scenario REPEAT-03
        // 2. And so has each month between: the clock goes back to November
        // and October to show their lists, one bill each.
        try run.setClock("2026-11-20T09:00:00")
        run.expect(dayLine: "November \u{00B7} day 20 of 30", "looking at November")
        try expectOneBill(on: "2026-11-14T09:00:00", in: run, "November, after two months away")
        try run.setClock("2026-10-20T09:00:00")
        run.expect(dayLine: "October \u{00B7} day 20 of 31", "looking at October")
        try expectOneBill(on: "2026-10-14T09:00:00", in: run, "October, after two months away")
    }

    @MainActor
    func testAShortMonth() throws {
        let run = try repeating(from: "2026-10-31T09:00:00")

        // Scenario REPEAT-04
        // 1. A bill that repeats on the 31st shows up in November on the 30th,
        // the month's last day.
        try run.setClock("2026-11-30T09:00:00")
        run.expect(dayLine: "November \u{00B7} day 30 of 30", "on November 30")
        try expectOneBill(on: "2026-11-30T09:00:00", in: run, "in November")
    }

    // MARK: - A statement line and a made bill

    /// Utilities with the $85.00 phone bill made this month, and a statement
    /// with an $85.40 line from the phone company today.
    @MainActor
    private func startedWithABillAndAStatementLine(_ bank: String) throws -> (TestApp, URL) {
        let run = try startedWithARepeat()
        let statement = try run.writeStatement([(bank, "-85.40")])
        return (run, statement)
    }

    /// What the review says the line does to this month's bill.
    private func replacesThisMonthsBill() -> String {
        let month = Words.monthName(RepeatRule.month(of: Date(), calendar: AppLocale.calendar))
        return ImportReviewScreen.Words.replaces(month: month, name: Self.bill, amount: "$85.00")
    }

    @MainActor
    func testAStatementLineTakesTheBillsPlaceAndCountsOnce() throws {
        let bank = "VERIZON WIRELESS"
        let (run, statement) = try startedWithABillAndAStatementLine(bank)
        // A second bill, for the exact amount in step 3.
        run.addRepeat(merchant: "Internet", amount: "60.00")

        // Scenario REPEAT-14
        // 1. The review says which bill the line replaces, and Matched counts it.
        run.importStatement(at: statement)
        XCTAssertTrue(run.wait(for: run.element(AccessibilityID.importLineStatus(bank)), holds: replacesThisMonthsBill(),
                               timeout: 10), "the row says: \(run.status(of: bank))")
        XCTAssertEqual(run.count(ImportReviewScreen.Words.matched), "1")

        // Scenario REPEAT-14
        // 2. Going ahead, the bank's line stands in the bill's place, at the
        // bank's amount, in Utilities, and the money counts once: the wheel
        // shows $85.40 and the internet bill, not both phone amounts. The
        // repeat carries on.
        run.click(AccessibilityID.importConfirm)
        XCTAssertTrue(run.wait(for: run.element(AccessibilityID.importConfirm), until: "exists == false", timeout: 10),
                      "the review did not close. On screen: \(run.visibleTexts())")
        XCTAssertTrue(run.listText("Verizon Wireless").waitForExistence(timeout: 10),
                      "the bank's line is not in Utilities. On screen: \(run.visibleTexts())")
        XCTAssertTrue(run.listText("$85.40").exists, "not at the bank's amount. On screen: \(run.visibleTexts())")
        XCTAssertTrue(run.rowIsGone(Self.bill), "the bill is still there. On screen: \(run.visibleTexts())")
        let once = TodaysBudget(limit: 60_000, spent: 14_540)
        run.expect(wheel: AccessibilityID.budgetWheel, reads: once.wheel.spokenSummary, "after the swap")
        XCTAssertEqual(run.text(of: run.element(AccessibilityID.budgetRepeats)), RepeatsList.Words.count(2))

        // Scenario REPEAT-14
        // 3. A line for exactly the internet bill's $60.00 works the same way:
        // the bank's line takes its place, and the wheel doesn't move.
        let internet = "COMCAST"
        let exact = try run.writeStatement([(internet, "-60.00")])
        run.importStatement(at: exact)
        let month = Words.monthName(RepeatRule.month(of: Date(), calendar: AppLocale.calendar))
        let replacesInternet = ImportReviewScreen.Words.replaces(month: month, name: "Internet", amount: "$60.00")
        XCTAssertTrue(run.wait(for: run.element(AccessibilityID.importLineStatus(internet)), holds: replacesInternet,
                               timeout: 10), "the row says: \(run.status(of: internet))")
        run.click(AccessibilityID.importConfirm)
        XCTAssertTrue(run.wait(for: run.element(AccessibilityID.importConfirm), until: "exists == false", timeout: 10),
                      "the review did not close. On screen: \(run.visibleTexts())")
        XCTAssertTrue(run.listText("Comcast").waitForExistence(timeout: 10),
                      "the bank's line is not in Utilities. On screen: \(run.visibleTexts())")
        XCTAssertTrue(run.rowIsGone("Internet"), "the internet bill is still there. On screen: \(run.visibleTexts())")
        run.expect(wheel: AccessibilityID.budgetWheel, reads: once.wheel.spokenSummary, "after the exact swap")
    }

    @MainActor
    func testKeepBothLeavesTheBillAndAddsTheLine() throws {
        let bank = "VERIZON WIRELESS"
        let (run, statement) = try startedWithABillAndAStatementLine(bank)
        let status = run.element(AccessibilityID.importLineStatus(bank))
        let keepBoth = run.element(AccessibilityID.importLineKeepBoth(bank))
        func isOn() -> Bool { (keepBoth.value as? Int) == 1 || (keepBoth.value as? String) == "1" }

        // Scenario REPEAT-15
        // 1. The line that replaces the bill offers Keep both, which starts off.
        run.importStatement(at: statement)
        XCTAssertTrue(run.wait(for: status, holds: replacesThisMonthsBill(), timeout: 10),
                      "the row says: \(run.status(of: bank))")
        XCTAssertTrue(keepBoth.waitForExistence(timeout: 10), "no Keep both. On screen: \(run.visibleTexts())")
        XCTAssertFalse(isOn(), "Keep both did not start off")

        // Scenario REPEAT-15
        // 2. On, the line will be added. Off again, it goes back to replacing.
        keepBoth.click()
        XCTAssertTrue(run.wait(for: status, holds: ImportReviewScreen.Words.willBeAdded, timeout: 5),
                      "the row says: \(run.status(of: bank))")
        keepBoth.click()
        XCTAssertTrue(run.wait(for: status, holds: replacesThisMonthsBill(), timeout: 5),
                      "the row says: \(run.status(of: bank))")

        // Scenario REPEAT-15
        // 3. On and imported, both stay, and neither is changed: the bill at
        // $85.00, the bank's line at $85.40.
        keepBoth.click()
        run.click(AccessibilityID.importConfirm)
        XCTAssertTrue(run.wait(for: run.element(AccessibilityID.importConfirm), until: "exists == false", timeout: 10),
                      "the review did not close. On screen: \(run.visibleTexts())")
        XCTAssertTrue(run.listText("Verizon Wireless").waitForExistence(timeout: 10),
                      "the bank's line was not added. On screen: \(run.visibleTexts())")
        XCTAssertTrue(run.listText(Self.bill).exists, "the bill went. On screen: \(run.visibleTexts())")
        XCTAssertTrue(run.listText("$85.00").exists && run.listText("$85.40").exists,
                      "an amount changed. On screen: \(run.visibleTexts())")
        let both = TodaysBudget(limit: 60_000, spent: 17_040)
        run.expect(wheel: AccessibilityID.budgetWheel, reads: both.wheel.spokenSummary, "with both kept")
    }
}

private extension TestApp {
    /// Adds a bill that repeats every month to the open budget.
    func expectSwitch(on: Bool, _ when: String) {
        let row = element(AccessibilityID.entryRepeats)
        XCTAssertTrue(row.waitForExistence(timeout: 10), "no Repeats row, \(when)")
        XCTAssertEqual((row.value as? Int) == 1 || (row.value as? String) == "1", on, "the switch reads wrong, \(when)")
    }

    func addRepeat(merchant: String, amount: String) {
        click(AccessibilityID.budgetAdd)
        type(merchant, into: AccessibilityID.entryMerchant)
        type(amount, into: AccessibilityID.entryAmount)
        click(AccessibilityID.entryRepeats)
        click(AccessibilityID.entryAdd)
        XCTAssertTrue(listText(merchant).waitForExistence(timeout: 10), "\(merchant) is not in the list. On screen: \(visibleTexts())")
    }

    func replaceAmount(with amount: String) {
        let field = element(AccessibilityID.entryAmount)
        XCTAssertTrue(field.waitForExistence(timeout: 10), "no amount")
        field.click()
        field.typeKey("a", modifierFlags: .command)
        field.typeText(amount)
    }

    /// Opens the short list of repeats, checks what a row says, and closes it.
    func expectRepeat(_ name: String, says amount: String, _ problem: String,
                      file: StaticString = #filePath, line: UInt = #line) {
        click(AccessibilityID.budgetRepeats)
        let row = element(AccessibilityID.repeatRow(name))
        XCTAssertTrue(row.waitForExistence(timeout: 10), "no row for \(name)", file: file, line: line)
        let inRow = NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", amount, amount)
        XCTAssertTrue(row.label.contains(amount) || row.descendants(matching: .any).matching(inRow).firstMatch.exists,
                      "\(problem). The row says: \(row.label), \(row.debugDescription.prefix(600))", file: file, line: line)
        app.buttons[RepeatsList.Words.done].firstMatch.click()
        XCTAssertTrue(wait(for: row, until: "exists == false", timeout: 5), "the short list stayed open", file: file, line: line)
    }
}
