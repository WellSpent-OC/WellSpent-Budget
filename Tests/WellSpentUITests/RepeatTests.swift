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
