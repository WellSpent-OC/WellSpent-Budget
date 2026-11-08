import Foundation
import XCTest
import WellSpentAppCore
import WellSpentModel

/// Repeat expenses on the phone: setting one, the short list and a repeat's own
/// sheet, which months a change reaches, and the two ways to delete. No account.
/// A later month's bill needs a clock this test can't move, so `RepeatsTests`
/// holds that.
final class PhoneRepeatTests: XCTestCase {
    private typealias Words = EntryEditor.Words
    nonisolated(unsafe) private static var dataRootPath: String?
    /// The Keep both test's statements, for tearDown.
    nonisolated(unsafe) private static var statementsPath: String?
    private static let bill = "Phone bill"

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    override func tearDown() {
        let app = XCUIApplication()
        if app.state != .notRunning { app.terminate() }
        if let path = Self.dataRootPath { try? FileManager.default.removeItem(atPath: path) }
        Self.dataRootPath = nil
        if let path = Self.statementsPath { try? FileManager.default.removeItem(atPath: path) }
        Self.statementsPath = nil
        super.tearDown()
    }

    /// A budget, with a bill that repeats every month on it.
    @MainActor
    private func launchedWithARepeat() -> PhoneTestApp {
        let run = PhoneTestApp()
        Self.dataRootPath = run.dataRoot.path
        // Longer than the Undo bar's 10 seconds, so a slow simulator reaches it.
        run.app.launchEnvironment[Workspace.undoWindowVariable] = "120"
        run.launch(pinnedDay: 18)
        run.addGroup(named: "Home")
        run.addBudget(named: "Utilities", amount: "600", inGroup: "Home")
        run.tap(AccessibilityID.budgetAdd)
        run.type(Self.bill, into: AccessibilityID.entryMerchant)
        run.type("85.00", into: AccessibilityID.entryAmount)
        run.turnOnRepeats()
        // A new entry's date is the real day, whatever day the wheel is pinned to.
        XCTAssertTrue(run.showsLine(containing: "of each month"), "no line says when it shows up: \(run.visibleTexts())")
        run.tap(AccessibilityID.entryAdd)
        XCTAssertTrue(run.hasRow(Self.bill), "\(Self.bill) is not in the list. On screen: \(run.visibleTexts())")
        return run
    }

    @MainActor
    func testTurningItOnForABillAlreadyThereReadsAsARepeat() throws {
        let run = PhoneTestApp()
        Self.dataRootPath = run.dataRoot.path
        run.launch(pinnedDay: 18)
        run.addGroup(named: "Home")
        run.addBudget(named: "Utilities", amount: "600", inGroup: "Home")
        run.addEntry(merchant: "Water", amount: "40.00")

        // Scenario REPEAT-17
        run.openEntry("Water")
        run.turnOnRepeats()
        run.tap(AccessibilityID.entrySave)
        run.bringToMiddle(run.scrollTo(AccessibilityID.budgetRepeats))
        XCTAssertEqual(run.element(AccessibilityID.budgetRepeats).label, RepeatsList.Words.count(1))

        // Scenario REPEAT-18
        // Reopened it reads on. Off and saved, it stops and reads off.
        run.openEntry("Water")
        run.bringUpInSheet(AccessibilityID.entryRepeats)
        XCTAssertEqual(run.switchValue(), "1", "not on when reopened")
        run.flipRepeats()
        run.tap(AccessibilityID.entrySave)
        XCTAssertTrue(run.lacks(AccessibilityID.budgetRepeats), "a stopped repeat is still counted")
        run.openEntry("Water")
        run.bringUpInSheet(AccessibilityID.entryRepeats)
        XCTAssertEqual(run.switchValue(), "0", "not off after stopping")

        // Scenario REPEAT-18
        // On again is the same repeat: the count is one, not two.
        run.flipRepeats()
        run.tap(AccessibilityID.entrySave)
        run.bringToMiddle(run.scrollTo(AccessibilityID.budgetRepeats))
        XCTAssertEqual(run.element(AccessibilityID.budgetRepeats).label, RepeatsList.Words.count(1))
    }

    @MainActor
    func testAStatementLineTakesTheBillsPlaceAndCountsOnce() throws {
        let bank = "VERIZON WIRELESS"
        let run = try launchedWithABillAndAStatementLine(bank)
        let counted = run.transactionCount()

        // Scenario REPEAT-14
        // 1. The review says which bill the line replaces, under Matched.
        run.importStatement()
        let status = AccessibilityID.importLineStatus(bank)
        let month = EntryEditor.Words.monthName(RepeatRule.month(of: Date(), calendar: AppLocale.calendar))
        let replaces = ImportReviewScreen.Words.replaces(month: month, name: Self.bill, amount: "$85.00")
        XCTAssertTrue(run.waitForLabel(status, toBe: replaces), "the row says: \(run.element(status).label)")
        XCTAssertEqual(run.count(ImportReviewScreen.Words.matched), "1")

        // 2. Going ahead, the bank's line stands in the bill's place, at the
        // bank's amount, and the count doesn't move. The repeat carries on.
        run.tap(AccessibilityID.importConfirm)
        run.waitForTheReviewToClose()
        XCTAssertTrue(run.row("Verizon Wireless", says: "$85.40", timeout: 10),
                      "the line is not there at the bank's amount. On screen: \(run.visibleTexts())")
        XCTAssertFalse(run.hasRow(Self.bill), "the bill is still there. On screen: \(run.visibleTexts())")
        XCTAssertEqual(run.transactionCount(), counted, "not counted once. The page says: " + run.countLine())
        run.bringToMiddle(run.scrollTo(AccessibilityID.budgetRepeats))
        XCTAssertEqual(run.element(AccessibilityID.budgetRepeats).label, RepeatsList.Words.count(1))
    }

    @MainActor
    func testKeepBothLeavesTheBillAndAddsTheLine() throws {
        let bank = "VERIZON WIRELESS"
        let run = try launchedWithABillAndAStatementLine(bank)

        // Scenario REPEAT-15
        // 1. The line close to the bill says it replaces it, and offers Keep
        // both, which starts off.
        run.importStatement()
        let status = AccessibilityID.importLineStatus(bank)
        let month = EntryEditor.Words.monthName(RepeatRule.month(of: Date(), calendar: AppLocale.calendar))
        let replaces = ImportReviewScreen.Words.replaces(month: month, name: Self.bill, amount: "$85.00")
        XCTAssertTrue(run.waitForLabel(status, toBe: replaces), "the row says: \(run.element(status).label)")
        let keepBoth = run.element(AccessibilityID.importLineKeepBoth(bank))
        XCTAssertTrue(keepBoth.waitForExistence(timeout: 10), "no Keep both. On screen: \(run.visibleTexts())")
        XCTAssertEqual(run.switchValue(of: AccessibilityID.importLineKeepBoth(bank)), "0", "Keep both did not start off")

        // 2. On, the line will be added. Off again, it goes back to replacing.
        run.flip(AccessibilityID.importLineKeepBoth(bank))
        XCTAssertTrue(run.waitForLabel(status, toBe: ImportReviewScreen.Words.willBeAdded),
                      "the row says: \(run.element(status).label)")
        run.flip(AccessibilityID.importLineKeepBoth(bank))
        XCTAssertTrue(run.waitForLabel(status, toBe: replaces), "the row says: \(run.element(status).label)")

        // 3. On and imported, the bill stays and the line is added beside it.
        run.flip(AccessibilityID.importLineKeepBoth(bank))
        XCTAssertTrue(run.waitForLabel(status, toBe: ImportReviewScreen.Words.willBeAdded),
                      "the row says: \(run.element(status).label)")
        run.tap(AccessibilityID.importConfirm)
        XCTAssertTrue(run.wait(for: run.element(AccessibilityID.importConfirm), until: "exists == false", timeout: 10),
                      "the review did not close. On screen: \(run.visibleTexts())")
        XCTAssertTrue(run.row(Self.bill, says: "$85.00"),
                      "the bill is gone or changed. On screen: \(run.visibleTexts())")
        XCTAssertTrue(run.row("Verizon Wireless", says: "$85.40"),
                      "the line was not added at the bank's amount. On screen: \(run.visibleTexts())")
    }

    /// This month's $85.00 repeat, and a statement with a line close to it.
    @MainActor
    private func launchedWithABillAndAStatementLine(_ bank: String) throws -> PhoneTestApp {
        let folder = try StatementFolder()
        Self.statementsPath = folder.url.path
        let statement = try folder.write([(bank, "-85.40", 0)])
        let run = PhoneTestApp()
        Self.dataRootPath = run.dataRoot.path
        run.launch(importing: statement)
        run.tap(AccessibilityID.budgetAdd)
        run.type(Self.bill, into: AccessibilityID.entryMerchant)
        run.type("85.00", into: AccessibilityID.entryAmount)
        run.turnOnRepeats()
        run.tap(AccessibilityID.entryAdd)
        XCTAssertTrue(run.hasRow(Self.bill), "\(Self.bill) is not in the list. On screen: \(run.visibleTexts())")
        return run
    }

    @MainActor
    func testSettingARepeatShowsInTheListAndOnTheCountLine() throws {
        let run = launchedWithARepeat()
        run.bringToMiddle(run.scrollTo(AccessibilityID.budgetRepeats))
        XCTAssertEqual(run.element(AccessibilityID.budgetRepeats).label, RepeatsList.Words.count(1))

        // The count line opens the list, and a row opens the repeat's own sheet.
        run.tap(AccessibilityID.budgetRepeats)
        XCTAssertTrue(run.showsLine(containing: "of each month"), "no list. On screen: \(run.visibleTexts())")
        run.tap(AccessibilityID.repeatRow(Self.bill))
        XCTAssertTrue(run.shows(RepeatEditor.Words.note), "no sheet. On screen: \(run.visibleTexts())")
        XCTAssertTrue(run.has(AccessibilityID.repeatStop), "no Stop repeating")
    }

    @MainActor
    func testMoneyInDoesNotRepeat() throws {
        let run = PhoneTestApp()
        Self.dataRootPath = run.dataRoot.path
        run.launch(pinnedDay: 18)
        run.addGroup(named: "Home")
        run.addBudget(named: "Utilities", amount: "600", inGroup: "Home")
        run.tap(AccessibilityID.budgetAdd)
        XCTAssertTrue(run.has(AccessibilityID.entryRepeats), "no Repeats row")
        let moneyIn = run.element(AccessibilityID.entryMoneyIn)
        (moneyIn.switches.firstMatch.exists ? moneyIn.switches.firstMatch : moneyIn).tap()
        XCTAssertTrue(run.lacks(AccessibilityID.entryRepeats), "money in offers Repeats")
    }

    @MainActor
    func testAChangeSaysWhichMonthsItReaches() throws {
        let run = launchedWithARepeat()
        run.openEntry(Self.bill)
        run.type("92.00", into: AccessibilityID.entryAmount)

        // It starts on This month only, each choice saying what it would do.
        let only = run.element(AccessibilityID.entryWhichMonth(Words.thisMonthOnly))
        let later = run.element(AccessibilityID.entryWhichMonth(Words.thisMonthAndLater))
        run.bringUpInSheet(AccessibilityID.entryWhichMonth(Words.thisMonthAndLater))
        XCTAssertTrue(only.isSelected, "it does not start on This month only")
        XCTAssertTrue((only.value as? String)?.contains("goes back to") == true, "only says: \(String(describing: only.value))")
        XCTAssertTrue((later.value as? String)?.contains("every month after") == true,
                      "later says: \(String(describing: later.value))")
        later.tap()
        XCTAssertTrue(later.isSelected, "This month and later did not take")
        run.tap(AccessibilityID.entrySave)
        run.expectNoSheet()
        XCTAssertTrue(run.shows("$92.00"), "the bill did not change. On screen: \(run.visibleTexts())")

        // The repeat itself changed, so the list says the new amount.
        run.bringToMiddle(run.scrollTo(AccessibilityID.budgetRepeats))
        run.tap(AccessibilityID.budgetRepeats)
        XCTAssertTrue(run.shows("$92.00"), "the repeat did not change. On screen: \(run.visibleTexts())")
    }

    @MainActor
    func testStopRepeatingEndsTheRepeatAndKeepsTheBill() throws {
        let run = launchedWithARepeat()
        run.openEntry(Self.bill)
        run.bringUpInSheet(AccessibilityID.entryStopRepeating)
        run.tap(AccessibilityID.entryStopRepeating)
        XCTAssertNotNil(run.questionButton(RepeatEditor.Words.stopConfirm), "Stop repeating does not ask")
        run.questionButton(RepeatEditor.Words.stopConfirm)?.tap()
        run.expectNoSheet()
        XCTAssertTrue(run.hasRow(Self.bill), "the bill went with the repeat")
        XCTAssertTrue(run.has(AccessibilityID.undoButton), "stopping offers no Undo")

        // Stopped, the bill's sheet no longer offers it.
        run.openEntry(Self.bill)
        XCTAssertTrue(run.lacks(AccessibilityID.entryStopRepeating), "Stop repeating is still offered")
    }

    @MainActor
    func testDeletingAMadeBillAsksBothChoices() throws {
        let run = launchedWithARepeat()
        run.openEntry(Self.bill)
        run.bringUpInSheet(AccessibilityID.entryDelete)
        run.tap(AccessibilityID.entryDelete)
        XCTAssertNotNil(run.questionButton(PendingDelete.deleteAndStop), "no Delete and Stop Repeating")
        run.questionButton(PendingDelete.deleteAndStop)?.tap()
        run.expectNoSheet()
        XCTAssertTrue(run.lacksRow(Self.bill), "the bill is still here")

        // Undo brings the bill back, as it does for any delete.
        run.tap(AccessibilityID.undoButton)
        XCTAssertTrue(run.hasRow(Self.bill), "Undo did not bring the bill back. On screen: \(run.visibleTexts())")
    }
}

private extension PhoneTestApp {
    func showsLine(containing words: String) -> Bool {
        app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", words)).firstMatch.waitForExistence(timeout: 10)
    }

    /// The Repeats switch, under the number pad after the amount.
    func turnOnRepeats() {
        bringUpInSheet(AccessibilityID.entryRepeats)
        let row = element(AccessibilityID.entryRepeats)
        (row.switches.firstMatch.exists ? row.switches.firstMatch : row).tap()
        XCTAssertTrue(wait(for: row, until: "value == '1'", timeout: 5), "Repeats did not turn on")
    }

    func switchValue() -> String? {
        switchValue(of: AccessibilityID.entryRepeats)
    }

    func flipRepeats() {
        bringUpInSheet(AccessibilityID.entryRepeats)
        flip(AccessibilityID.entryRepeats)
    }

    func switchValue(of identifier: String) -> String? {
        let row = element(identifier)
        return ((row.switches.firstMatch.exists ? row.switches.firstMatch : row).value as? String)
    }

    func flip(_ identifier: String) {
        let row = element(identifier)
        (row.switches.firstMatch.exists ? row.switches.firstMatch : row).tap()
    }

    /// The number pad can cover a sheet's lower rows. A drag from the screen
    /// moves the sheet's form, where `scrollTo` would move the list behind it.
    func bringUpInSheet(_ identifier: String) {
        let row = element(identifier)
        let low = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        let high = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.25))
        var drags = 0
        while !(row.exists && row.isHittable), drags < 5 {
            low.press(forDuration: 0.05, thenDragTo: high)
            drags += 1
        }
    }
}
