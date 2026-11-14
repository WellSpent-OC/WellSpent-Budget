import Foundation
import XCTest
import WellSpentAppCore
import WellSpentModel

/// Repeat expenses on the phone: setting one, the short list and a repeat's own
/// sheet, which months a change reaches, stopping, the two ways to delete, and
/// Undo. No account. A later month's bill needs a clock this test can't move,
/// so `RepeatsTests` holds that.
final class PhoneRepeatTests: XCTestCase {
    private typealias Words = EntryEditor.Words
    nonisolated(unsafe) private static var dataRootPath: String?
    /// The Keep both test's statements, for tearDown.
    nonisolated(unsafe) private static var statementsPath: String?
    nonisolated(unsafe) private static var cleanups: [() async -> Void] = []
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

    override func tearDown() async throws {
        for cleanup in Self.cleanups { await cleanup() }
        Self.cleanups = []
        try await super.tearDown()
    }

    /// Utilities in Home on the test clock at `start`, with the $85.00 phone
    /// bill set to repeat that day.
    @MainActor
    private func launchedWithARepeat(on start: String = "2026-12-14T09:00:00") throws -> PhoneTestApp {
        let run = PhoneTestApp()
        Self.dataRootPath = run.dataRoot.path
        // Longer than the Undo bar's 10 seconds, so a slow simulator reaches it.
        run.app.launchEnvironment[Workspace.undoWindowVariable] = "120"
        try run.setClock(start)
        run.launch()
        run.addGroup(named: "Home")
        run.addBudget(named: "Utilities", amount: "600", inGroup: "Home")
        run.tap(AccessibilityID.budgetAdd)
        run.type(Self.bill, into: AccessibilityID.entryMerchant)
        run.type("85.00", into: AccessibilityID.entryAmount)
        run.turnOnRepeats()
        // A new entry is dated the clock's day, and the line names it.
        let day = RepeatsList.Words.ordinal(AppLocale.calendar.component(.day, from: try PhoneTestApp.clockDate(start)))
        XCTAssertTrue(run.showsLine(containing: "\(day) of each month"),
                      "no line says it shows up on the \(day): \(run.visibleTexts())")
        run.tap(AccessibilityID.entryAdd)
        XCTAssertTrue(run.hasRow(Self.bill), "\(Self.bill) is not in the list. On screen: \(run.visibleTexts())")
        XCTAssertEqual(run.app.descendants(matching: .any).matching(identifier: AccessibilityID.entryRow(Self.bill)).count, 1,
                       "the bill is not in the list once. On screen: \(run.visibleTexts())")
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
        let bank = "VERIZON WIRELESS", internet = "COMCAST"
        let folder = try StatementFolder()
        Self.statementsPath = folder.url.path
        let statement = try folder.write([(bank, "-85.40", 0)])
        let run = PhoneTestApp()
        Self.dataRootPath = run.dataRoot.path
        run.launch(importing: statement)
        run.goBack()
        run.addGroup(named: "Home")
        run.addBudget(named: "Utilities", amount: "600", inGroup: "Home")
        run.addRepeat(merchant: Self.bill, amount: "85.00")
        // A second bill, for the exact amount in step 3.
        run.addRepeat(merchant: "Internet", amount: "60.00")
        let month = EntryEditor.Words.monthName(RepeatRule.month(of: Date(), calendar: AppLocale.calendar))
        let once = TodaysBudget(limit: 60_000, spent: 14_540).wheel.spokenSummary

        // Scenario REPEAT-14
        // 1. The review says which bill the line replaces, under Matched.
        run.importStatement()
        let status = AccessibilityID.importLineStatus(bank)
        let replaces = ImportReviewScreen.Words.replaces(month: month, name: Self.bill, amount: "$85.00")
        XCTAssertTrue(run.waitForLabel(status, toBe: replaces), "the row says: \(run.element(status).label)")
        XCTAssertEqual(run.count(ImportReviewScreen.Words.matched), "1")

        // Scenario REPEAT-14
        // 2. Going ahead, the bank's line stands in the bill's place, at the
        // bank's amount, in Utilities, and the money counts once: the wheel
        // shows $85.40 and the internet bill, not both phone amounts. The
        // repeat carries on.
        run.tap(AccessibilityID.importConfirm)
        run.waitForTheReviewToClose()
        XCTAssertTrue(run.app.navigationBars["Utilities"].exists, "not on Utilities. On screen: \(run.visibleTexts())")
        XCTAssertTrue(run.row("Verizon Wireless", says: "$85.40", timeout: 10),
                      "the line is not there at the bank's amount. On screen: \(run.visibleTexts())")
        XCTAssertFalse(run.hasRow(Self.bill, timeout: 2), "the bill is still there. On screen: \(run.visibleTexts())")
        XCTAssertTrue(run.waitForLabel(AccessibilityID.budgetWheel, toBe: once),
                      "after the swap the wheel says: \(run.element(AccessibilityID.budgetWheel).label)")
        run.bringToMiddle(run.scrollTo(AccessibilityID.budgetRepeats))
        XCTAssertEqual(run.element(AccessibilityID.budgetRepeats).label, RepeatsList.Words.count(2))

        // Scenario REPEAT-14
        // 3. A line for exactly the internet bill's $60.00 works the same way:
        // the bank's line takes its place, and the wheel doesn't move.
        // The folder writes one file, so the second statement replaces the
        // first only now.
        let exact = try folder.write([(internet, "-60.00", 0)])
        run.app.terminate()
        run.app.launchEnvironment[UITestStatement.variable] = exact.path
        run.launch()
        // The app opens again where it was, on Utilities.
        if !run.app.navigationBars["Utilities"].waitForExistence(timeout: 5) { run.openBudget(named: "Utilities") }
        run.importStatement()
        let replacesInternet = ImportReviewScreen.Words.replaces(month: month, name: "Internet", amount: "$60.00")
        XCTAssertTrue(run.waitForLabel(AccessibilityID.importLineStatus(internet), toBe: replacesInternet),
                      "the row says: \(run.element(AccessibilityID.importLineStatus(internet)).label)")
        run.tap(AccessibilityID.importConfirm)
        run.waitForTheReviewToClose()
        XCTAssertTrue(run.row("Comcast", says: "$60.00", timeout: 10),
                      "the line is not there. On screen: \(run.visibleTexts())")
        XCTAssertFalse(run.hasRow("Internet", timeout: 2), "the internet bill is still there. On screen: \(run.visibleTexts())")
        XCTAssertTrue(run.waitForLabel(AccessibilityID.budgetWheel, toBe: once),
                      "after the exact swap the wheel says: \(run.element(AccessibilityID.budgetWheel).label)")
    }

    @MainActor
    func testFindingThemAll() async throws {
        let accounts = try TestAccounts.fromEnvironment()
        let home = SecondAccount.phoneRunPrefix + PhoneTestApp.stamp() + " Repeats"
        let run = PhoneTestApp()
        Self.dataRootPath = run.dataRoot.path
        run.launch()
        try run.signIn(email: accounts.email, password: accounts.password, server: accounts.server)
        run.addGroup(named: home)
        run.addBudget(named: "Utilities", amount: "600", inGroup: home)
        Self.cleanups.append {
            let robin = try? SecondAccount(server: accounts.server, settingsSuite: "\(SecondAccount.settingsSuite).robin")
            try? await robin?.signIn(email: accounts.email, password: accounts.password)
            await robin?.deleteGroup(named: home)
            await robin?.cleanUp()
        }

        // Scenario REPEAT-12
        // 1. A budget with no repeats doesn't mention them.
        XCTAssertTrue(run.lacks(AccessibilityID.budgetRepeats), "a budget with none says it has repeats")

        // Scenario REPEAT-12
        // 2. With two, the count line says "2 repeats" and opens a short list.
        // A row opens that repeat's own sheet, which changes this month and
        // later, or stops it.
        run.addRepeat(merchant: Self.bill, amount: "85.00")
        run.addRepeat(merchant: "Internet", amount: "60.00")
        openRepeat(Self.bill, in: run)
        XCTAssertTrue(run.shows(RepeatEditor.Words.note), "the sheet doesn't say what a change reaches")
        XCTAssertTrue(run.has(AccessibilityID.repeatSave), "the owner has no Save on the repeat's sheet")
        XCTAssertTrue(run.has(AccessibilityID.repeatStop), "the owner has no Stop repeating on the repeat's sheet")
        run.app.buttons[RepeatEditor.Words.cancel].firstMatch.tap()
        run.app.buttons[RepeatsList.Words.done].firstMatch.tap()
        run.goBack()

        // Leslie joins at Add level.
        let link = try await run.legacyInvite(home, as: "Robin", role: .add)
        let leslie = try SecondAccount(server: accounts.server)
        Self.cleanups.insert({ await leslie.cleanUp() }, at: 0)
        try await leslie.signIn(email: accounts.secondEmail, password: accounts.secondPassword)
        _ = try await leslie.join(link, as: "Leslie")
        run.signOut()
        try run.signIn(email: accounts.secondEmail, password: accounts.secondPassword, server: accounts.server)
        run.syncAndWait()
        run.openBudget(named: "Utilities")

        // Scenario REPEAT-12
        // 3. Leslie, neither the owner nor a manager, finds them the same way,
        // and the repeat's sheet has nothing to change.
        openRepeat(Self.bill, in: run)
        XCTAssertTrue(run.shows(RepeatEditor.Words.onlyOwner("Robin")),
                      "the sheet doesn't say who can change it. On screen: \(run.visibleTexts())")
        XCTAssertTrue(run.lacks(AccessibilityID.repeatSave), "Leslie has Save on the repeat's sheet")
        XCTAssertTrue(run.lacks(AccessibilityID.repeatStop), "Leslie has Stop repeating on the repeat's sheet")
        let name = run.app.textFields[RepeatEditor.Words.merchant].firstMatch
        XCTAssertTrue(name.exists && !name.isEnabled, "Leslie can type in the repeat's name")
    }

    /// From the open budget: the count line says "2 repeats", opens the short
    /// list, and the row opens that repeat's own sheet.
    @MainActor
    private func openRepeat(_ name: String, in run: PhoneTestApp) {
        run.bringToMiddle(run.scrollTo(AccessibilityID.budgetRepeats))
        XCTAssertEqual(run.element(AccessibilityID.budgetRepeats).label, RepeatsList.Words.count(2))
        run.tap(AccessibilityID.budgetRepeats)
        run.tap(AccessibilityID.repeatRow(name))
        XCTAssertTrue(run.app.navigationBars[name].waitForExistence(timeout: 10),
                      "no sheet for \(name). On screen: \(run.visibleTexts())")
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
        // Scenario REPEAT-01
        // The bill is in Utilities once, and the line under the switch says
        // the day of each month it shows up on.
        let run = try launchedWithARepeat()
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

        // Scenario REPEAT-13
        let moneyIn = run.element(AccessibilityID.entryMoneyIn)
        (moneyIn.switches.firstMatch.exists ? moneyIn.switches.firstMatch : moneyIn).tap()
        XCTAssertTrue(run.lacks(AccessibilityID.entryRepeats), "money in offers Repeats")
    }

    @MainActor
    func testThisMonthOnlyChangesDecemberAndNotJanuary() throws {
        let run = try launchedWithARepeat(on: "2026-12-14T09:00:00")
        let only = run.element(AccessibilityID.entryWhichMonth(Words.thisMonthOnly))
        let later = run.element(AccessibilityID.entryWhichMonth(Words.thisMonthAndLater))

        // Scenario REPEAT-06
        // 1. December's $85.00 bill changed to $92.00: Which months? is on the
        // sheet with its other fields, starting on This month only. Saved that
        // way, December is $92.00 and the repeat stays at $85.00.
        run.openEntry(Self.bill)
        run.type("92.00", into: AccessibilityID.entryAmount)
        run.bringUpInSheet(AccessibilityID.entryWhichMonth(Words.thisMonthAndLater))
        XCTAssertTrue(run.app.navigationBars[EntryEditor.Words.editTitle].exists,
                      "Which months? is not on the bill's own sheet. On screen: \(run.visibleTexts())")
        XCTAssertTrue(only.isSelected, "it does not start on This month only")
        XCTAssertTrue((only.value as? String)?.contains("goes back to") == true, "only says: \(String(describing: only.value))")
        XCTAssertTrue((later.value as? String)?.contains("every month after") == true,
                      "later says: \(String(describing: later.value))")
        run.tap(AccessibilityID.entrySave)
        run.expectNoSheet()
        XCTAssertTrue(run.row(Self.bill, says: "$92.00"), "December did not change: \(run.rowLabel(Self.bill))")
        run.expectRepeat(Self.bill, says: "$85.00", "a change to this month only reached the repeat")

        // Scenario REPEAT-06
        // 2. January is $85.00, and December is still $92.00.
        try run.reopen(on: "2027-01-14T09:00:00", budget: "Utilities")
        try run.expectOneBill(Self.bill, on: "2027-01-14T09:00:00", at: "$85.00", "in January")
        try run.reopen(on: "2026-12-20T09:00:00", budget: "Utilities")
        try run.expectOneBill(Self.bill, on: "2026-12-14T09:00:00", at: "$92.00", "back in December")
    }

    @MainActor
    func testThisMonthAndLaterChangesDecemberOnward() throws {
        let run = try launchedWithARepeat(on: "2026-11-14T09:00:00")
        try run.reopen(on: "2026-12-14T09:00:00", budget: "Utilities")
        try run.expectOneBill(Self.bill, on: "2026-12-14T09:00:00", at: "$85.00", "in December")
        let later = run.element(AccessibilityID.entryWhichMonth(Words.thisMonthAndLater))

        // Scenario REPEAT-07
        // 1. December's bill changed to $92.00 for this month and later:
        // December and the repeat are $92.00.
        run.openEntry(Self.bill)
        run.type("92.00", into: AccessibilityID.entryAmount)
        run.bringUpInSheet(AccessibilityID.entryWhichMonth(Words.thisMonthAndLater))
        later.tap()
        XCTAssertTrue(later.isSelected, "This month and later did not take")
        run.tap(AccessibilityID.entrySave)
        run.expectNoSheet()
        XCTAssertTrue(run.row(Self.bill, says: "$92.00"), "December did not change: \(run.rowLabel(Self.bill))")
        run.expectRepeat(Self.bill, says: "$92.00", "the repeat did not change")

        // Scenario REPEAT-07
        // 2. A later month is $92.00, and November, before December, stays
        // at $85.00.
        try run.reopen(on: "2027-01-14T09:00:00", budget: "Utilities")
        try run.expectOneBill(Self.bill, on: "2027-01-14T09:00:00", at: "$92.00", "in January")
        try run.reopen(on: "2026-11-20T09:00:00", budget: "Utilities")
        try run.expectOneBill(Self.bill, on: "2026-11-14T09:00:00", at: "$85.00", "back in November")
    }

    @MainActor
    func testStopRepeatingEndsTheRepeatAndKeepsTheBill() throws {
        let run = try launchedWithARepeat(on: "2026-11-14T09:00:00")
        try run.reopen(on: "2026-12-14T09:00:00", budget: "Utilities")
        try run.expectOneBill(Self.bill, on: "2026-12-14T09:00:00", at: "$85.00", "in December")

        // Scenario REPEAT-08
        // 1. Stop repeating asks, then keeps December's bill and leaves the
        // count of repeats, and the short list behind it, at once.
        stop(run)
        XCTAssertTrue(run.hasRow(Self.bill), "the bill went with the repeat")
        XCTAssertTrue(run.lacks(AccessibilityID.budgetRepeats), "the stopped repeat is still counted")

        // Stopped, the bill's sheet no longer offers it.
        run.openEntry(Self.bill)
        XCTAssertTrue(run.lacks(AccessibilityID.entryStopRepeating), "Stop repeating is still offered")
        run.tap(AccessibilityID.entryCancel)
        run.expectNoSheet()

        // Scenario REPEAT-10
        // 2. Undo carries the repeat on.
        run.tap(AccessibilityID.undoButton)
        run.bringToMiddle(run.scrollTo(AccessibilityID.budgetRepeats))
        XCTAssertEqual(run.element(AccessibilityID.budgetRepeats).label, RepeatsList.Words.count(1),
                       "Undo did not bring the repeat back. On screen: \(run.visibleTexts())")

        // Scenario REPEAT-08
        // 3. Stopped again: no later month is made, and the months already
        // made stay.
        stop(run)
        try run.reopen(on: "2027-01-14T09:00:00", budget: "Utilities")
        run.expectNoBill(Self.bill, "in January, after stopping")
        try run.reopen(on: "2026-12-20T09:00:00", budget: "Utilities")
        try run.expectOneBill(Self.bill, on: "2026-12-14T09:00:00", at: "$85.00", "back in December")
        try run.reopen(on: "2026-11-20T09:00:00", budget: "Utilities")
        try run.expectOneBill(Self.bill, on: "2026-11-14T09:00:00", at: "$85.00", "back in November")
    }

    @MainActor
    func testDeletingAMadeBillAsksBothChoices() throws {
        let run = try launchedWithARepeat(on: "2026-11-14T09:00:00")
        try run.reopen(on: "2026-12-14T09:00:00", budget: "Utilities")
        try run.expectOneBill(Self.bill, on: "2026-12-14T09:00:00", at: "$85.00", "in December")

        // Scenario REPEAT-09
        // 1. Deleting December's bill asks which: Delete This Month Only, or
        // Delete and Stop Repeating. The second takes both.
        deleteBill(run, choosing: PendingDelete.deleteAndStop, offersBoth: true)
        XCTAssertTrue(run.lacksRow(Self.bill), "the bill is still here")
        XCTAssertTrue(run.lacks(AccessibilityID.budgetRepeats), "the repeat is still counted")

        // Scenario REPEAT-10
        // 2. Undo brings back both.
        run.tap(AccessibilityID.undoButton)
        XCTAssertTrue(run.hasRow(Self.bill), "Undo did not bring the bill back. On screen: \(run.visibleTexts())")
        run.bringToMiddle(run.scrollTo(AccessibilityID.budgetRepeats))
        XCTAssertEqual(run.element(AccessibilityID.budgetRepeats).label, RepeatsList.Words.count(1),
                       "Undo did not bring the repeat back. On screen: \(run.visibleTexts())")

        // Scenario REPEAT-09
        // 3. Delete This Month Only takes December's bill and leaves the
        // repeat. A month deleted this way doesn't come back.
        deleteBill(run, choosing: PendingDelete.deleteThisMonthOnly)
        XCTAssertTrue(run.lacksRow(Self.bill), "the bill is still here")
        try run.reopen(on: "2026-12-20T09:00:00", budget: "Utilities")
        run.bringToMiddle(run.scrollTo(AccessibilityID.budgetRepeats))
        XCTAssertEqual(run.element(AccessibilityID.budgetRepeats).label, RepeatsList.Words.count(1),
                       "Delete This Month Only stopped the repeat. On screen: \(run.visibleTexts())")
        run.expectNoBill(Self.bill, "December, deleted this month only")

        // Scenario REPEAT-09
        // 4. January's bill deleted with Delete and Stop Repeating: no later
        // month is made, and the months before stay.
        try run.reopen(on: "2027-01-14T09:00:00", budget: "Utilities")
        try run.expectOneBill(Self.bill, on: "2027-01-14T09:00:00", at: "$85.00", "in January")
        deleteBill(run, choosing: PendingDelete.deleteAndStop)
        XCTAssertTrue(run.lacksRow(Self.bill), "January's bill is still here")
        try run.reopen(on: "2027-02-14T09:00:00", budget: "Utilities")
        run.expectNoBill(Self.bill, "in February, after Delete and Stop Repeating")
        try run.reopen(on: "2026-11-20T09:00:00", budget: "Utilities")
        try run.expectOneBill(Self.bill, on: "2026-11-14T09:00:00", at: "$85.00", "back in November")
    }

    /// Stop repeating from the open bill's sheet, confirmed.
    @MainActor
    private func stop(_ run: PhoneTestApp) {
        run.openEntry(Self.bill)
        run.bringUpInSheet(AccessibilityID.entryStopRepeating)
        run.tap(AccessibilityID.entryStopRepeating)
        XCTAssertNotNil(run.questionButton(RepeatEditor.Words.stopConfirm), "Stop repeating does not ask")
        run.questionButton(RepeatEditor.Words.stopConfirm)?.tap()
        run.expectNoSheet()
    }

    /// Deletes the open bill from its sheet with one of the two choices.
    @MainActor
    private func deleteBill(_ run: PhoneTestApp, choosing choice: String, offersBoth: Bool = false) {
        run.openEntry(Self.bill)
        run.bringUpInSheet(AccessibilityID.entryDelete)
        run.tap(AccessibilityID.entryDelete)
        if offersBoth {
            XCTAssertNotNil(run.questionButton(PendingDelete.deleteThisMonthOnly), "no Delete This Month Only")
            XCTAssertNotNil(run.questionButton(PendingDelete.deleteAndStop), "no Delete and Stop Repeating")
        }
        guard let button = run.questionButton(choice) else { return XCTFail("no \(choice)") }
        button.tap()
        run.expectNoSheet()
    }
}
