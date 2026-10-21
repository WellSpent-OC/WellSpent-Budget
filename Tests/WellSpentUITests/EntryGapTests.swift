import Foundation
import XCTest
import WellSpentAppCore
import WellSpentCrypto
import WellSpentModel
import WellSpentStore

/// Adding a transaction by hand, a date outside this period, and the Undo
/// bar after a delete, in the real window. Each test launches the app once,
/// on a fresh data folder, and makes a group of its own named with the time:
/// - the New transaction sheet: what it asks for, when Add lights, an amount
///   that can't be read clearly, Cancel, and the keyboard
/// - amounts typed in four ways and with a thousands comma, and a note
/// - a date before this period, in a new transaction and in an opened one
/// - the Undo bar going by itself after about 10 seconds
/// - the Undo bar going at the next change, and a second delete replacing it
/// - an amount with a decimal comma, in a region that writes one
///
/// Each test launches the app in the region it needs, whatever region this
/// Mac is set to: the United States, which writes 12.50, or Germany, which
/// writes 12,50. `-AppleLocale` sets it for the app alone, as a change of
/// region in System Settings would. A line the test expects with a date in
/// it is built in that same region, not in this Mac's.
///
/// What needs someone else's change to arrive by sync is not here: a sync
/// that leaves the Undo bar (EDIT-08), an Undo after a move down or after
/// its budget was deleted (EDIT-09), and a Save or Delete… after a move down
/// (EDIT-13). Those need a signed-in test.
///
/// No account is needed. The run's data folder holds everything, and goes
/// in tearDown.
final class EntryGapTests: XCTestCase {
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

    // MARK: - The New transaction sheet

    @MainActor
    func testTheNewTransactionSheet() throws {
        let run = try start(region: "en_US")
        let stamp = Self.stamp()
        let groupName = "Entries \(stamp)", groceries = "Groceries \(stamp)"
        let sheet = run.app.sheets.firstMatch
        let title = sheet.staticTexts[EntryEditor.Words.title]
        let add = run.element(AccessibilityID.entryAdd)
        let nothingSpent = TodaysBudget(limit: 50_000, spent: 0)

        // 1. A group with Groceries, $500.00 a month. Saving opens it.
        run.addGroup(named: groupName)
        run.addBudget(named: groceries, amount: "500", inGroup: groupName)

        // Scenario ENTRY-02
        // 2. Add opens a sheet titled New transaction. It asks for Merchant,
        // Amount, Date and Note, each named on its field's line, with Cancel
        // and Add. Date starts at today, and there is no budget to choose.
        run.click(AccessibilityID.budgetAdd)
        XCTAssertTrue(title.waitForExistence(timeout: 10),
                      "no sheet titled \(EntryEditor.Words.title). On screen: \(run.visibleTexts())")
        for (words, field) in [(EntryEditor.Words.merchant, AccessibilityID.entryMerchant),
                               (EntryEditor.Words.amount, AccessibilityID.entryAmount),
                               (EntryEditor.Words.date, AccessibilityID.entryDate),
                               (EntryEditor.Words.note, AccessibilityID.entryNote)] {
            run.expect(label: words, beside: field)
        }
        XCTAssertEqual(run.element(AccessibilityID.entryCancel).label, EntryEditor.Words.cancel)
        XCTAssertEqual(add.label, EntryEditor.Words.add)
        let startsAt = try XCTUnwrap(run.shownDate(), "Date shows no date: \(run.element(AccessibilityID.entryDate))")
        XCTAssertTrue(Calendar.current.isDateInToday(startsAt), "Date starts at \(startsAt), not today")
        XCTAssertFalse(run.element(AccessibilityID.entryBudget).exists, "the sheet offers a budget to choose")
        XCTAssertFalse(sheet.staticTexts[EntryEditor.Words.budget].exists, "the sheet asks for a budget")
        XCTAssertEqual(sheet.popUpButtons.count, 0, "the sheet has a list to choose from")

        // Scenario ENTRY-02
        // 3. Add stays dimmed with nothing typed, with no amount, with a
        // merchant of only spaces or none, and with an amount that is not a
        // number. A merchant and an amount light it.
        run.expectStaysDimmed(AccessibilityID.entryAdd, "Add, with nothing typed")
        run.type("Hilltop Grocery", into: AccessibilityID.entryMerchant)
        run.expectStaysDimmed(AccessibilityID.entryAdd, "Add, with no amount")
        run.type("42.00", into: AccessibilityID.entryAmount)
        run.expect(AccessibilityID.entryAdd, enabled: true, "Add, with a merchant and an amount")
        run.type("   ", into: AccessibilityID.entryMerchant)
        run.expect(AccessibilityID.entryAdd, enabled: false, "Add, with a merchant of only spaces")
        run.type("Hilltop Grocery", into: AccessibilityID.entryMerchant)
        run.expect(AccessibilityID.entryAdd, enabled: true, "Add, with the merchant typed again")
        run.clear(AccessibilityID.entryMerchant)
        run.expect(AccessibilityID.entryAdd, enabled: false, "Add, with no merchant")
        run.type("Hilltop Grocery", into: AccessibilityID.entryMerchant)
        run.expect(AccessibilityID.entryAdd, enabled: true, "Add, with the merchant typed again")
        run.type("twelve", into: AccessibilityID.entryAmount)
        run.expect(AccessibilityID.entryAdd, enabled: false, "Add, with twelve as the amount")

        // Scenario ENTRY-13
        // 4. In the United States region, 12,50 can't be read clearly. Add
        // dims, and the line under the amount says how to type it. Typed as
        // 12.50, the line goes and Add lights.
        let unclear = TypedAmount.Words.unclear(locale: Locale(identifier: "en_US"))
        let problem = run.element(AccessibilityID.entryAmountProblem)
        run.type("42.00", into: AccessibilityID.entryAmount)
        run.expect(AccessibilityID.entryAdd, enabled: true, "Add, with 42.00 as the amount")
        XCTAssertFalse(problem.exists, "a line under 42.00: \(run.text(of: problem))")
        run.type("12,50", into: AccessibilityID.entryAmount)
        run.expect(AccessibilityID.entryAdd, enabled: false, "Add, with 12,50 as the amount")
        XCTAssertTrue(run.wait(for: problem, holds: unclear, timeout: 5),
                      "no line saying \(unclear) On screen: \(run.visibleTexts())")
        run.expect(problem, under: AccessibilityID.entryAmount)
        run.type("12.50", into: AccessibilityID.entryAmount)
        XCTAssertTrue(run.wait(for: problem, until: "exists == false", timeout: 5), "the line stayed at 12.50")
        run.expect(AccessibilityID.entryAdd, enabled: true, "Add, with 12.50 as the amount")

        // Scenario ENTRY-07
        // 5. With Hilltop and 42.00 filled in, Cancel closes the sheet, and
        // nothing is added.
        run.type("Hilltop", into: AccessibilityID.entryMerchant)
        run.type("42.00", into: AccessibilityID.entryAmount)
        run.click(AccessibilityID.entryCancel)
        run.expectNoSheet()
        run.expectNoRow("Hilltop", "Cancel added it")
        run.expect(wheel: AccessibilityID.budgetWheel, reads: nothingSpent.wheel.spokenSummary, "after Cancel")
        run.expect(figures: nothingSpent.wheel.figures, "after Cancel")
        let noneYet = try TestApp.countLine(nothingSpent, region: "en_US")
        XCTAssertTrue(run.listText(noneYet).waitForExistence(timeout: 5),
                      "no line saying \(noneYet) On screen: \(run.visibleTexts())")

        // Scenario ENTRY-11
        // 6. Command-N opens the New transaction sheet. Return adds what is
        // filled in, and the sheet closes.
        run.app.typeKey("n", modifierFlags: .command)
        XCTAssertTrue(title.waitForExistence(timeout: 10),
                      "Command-N opened no sheet. On screen: \(run.visibleTexts())")
        run.type("Market", into: AccessibilityID.entryMerchant)
        run.type("9.50", into: AccessibilityID.entryAmount)
        run.app.typeKey(.return, modifierFlags: [])
        run.expectNoSheet()
        run.expect(entry: "Market", shows: "$9.50")
        let market = TodaysBudget(limit: 50_000, spent: 950)
        run.expect(wheel: AccessibilityID.budgetWheel, reads: market.wheel.spokenSummary, "after Return")
        run.expect(figures: market.wheel.figures, "after Return")

        // Scenario ENTRY-11
        // 7. Escape closes the sheet without adding anything.
        run.app.typeKey("n", modifierFlags: .command)
        XCTAssertTrue(title.waitForExistence(timeout: 10),
                      "Command-N opened no sheet. On screen: \(run.visibleTexts())")
        run.type("Corner Bakery", into: AccessibilityID.entryMerchant)
        run.type("12.00", into: AccessibilityID.entryAmount)
        run.app.typeKey(.escape, modifierFlags: [])
        run.expectNoSheet()
        run.expectNoRow("Corner Bakery", "Escape added it")
        run.expect(wheel: AccessibilityID.budgetWheel, reads: market.wheel.spokenSummary, "after Escape")
        run.expect(figures: market.wheel.figures, "after Escape")
    }

    // MARK: - Amounts and notes

    @MainActor
    func testEveryAmountIsMoneySpentAndANoteShowsUnderTheMerchant() throws {
        let run = try start(region: "en_US")
        let stamp = Self.stamp()
        let groupName = "Entries \(stamp)", groceries = "Groceries \(stamp)"

        // 1. A group with Groceries, $2,000.00 a month. Saving opens it.
        run.addGroup(named: groupName)
        run.addBudget(named: groceries, amount: "2000", inGroup: groupName)

        // Scenario ENTRY-03
        // 2. 42.50 typed four ways: plain, with a minus, in brackets and with
        // a dollar sign. Each row shows $42.50, and each adds $42.50 to what
        // is spent.
        let typed = [("Hilltop Grocery", "42.50"), ("Market", "-42.50"), ("Sunrise Cafe", "(42.50)"),
                     ("Riverside Grill", "$42.50")]
        for (index, (merchant, amount)) in typed.enumerated() {
            run.addEntry(merchant: merchant, amount: amount)
            run.expect(entry: merchant, shows: "$42.50")
            let spent = TodaysBudget(limit: 200_000, spent: 4_250 * (index + 1))
            run.expect(wheel: AccessibilityID.budgetWheel, reads: spent.wheel.spokenSummary, "after \(amount)")
            run.expect(figures: spent.wheel.figures, "after \(amount)")
        }

        // Scenario ENTRY-03
        // 3. $1,234.56, with its thousands comma, shows as $1234.56, and is
        // counted in full.
        run.addEntry(merchant: "Costco", amount: "$1,234.56")
        run.expect(entry: "Costco", shows: "$1234.56")
        let withCostco = TodaysBudget(limit: 200_000, spent: 4_250 * 4 + 123_456)
        run.expect(wheel: AccessibilityID.budgetWheel, reads: withCostco.wheel.spokenSummary, "after $1,234.56")
        run.expect(figures: withCostco.wheel.figures, "after $1,234.56")

        // Scenario ENTRY-04
        // 4. Corner Bakery, 12.00, with birthday cake in Note: its row shows
        // birthday cake under the merchant.
        run.click(AccessibilityID.budgetAdd)
        run.type("Corner Bakery", into: AccessibilityID.entryMerchant)
        run.type("12.00", into: AccessibilityID.entryAmount)
        run.type("birthday cake", into: AccessibilityID.entryNote)
        run.click(AccessibilityID.entryAdd)
        run.expectNoSheet()
        run.expect(note: "birthday cake", under: "Corner Bakery")
    }

    // MARK: - A date before this period

    @MainActor
    func testADateBeforeThisPeriodKeepsItOutOfThisPeriod() throws {
        let run = try start(region: "en_US")
        let stamp = Self.stamp()
        let groupName = "Entries \(stamp)", groceries = "Groceries \(stamp)"
        let lastMonth = try Self.twentyEighthOfLastMonth()
        let nothingSpent = TodaysBudget(limit: 50_000, spent: 0)
        let noneThisPeriod = try TestApp.countLine(nothingSpent, region: "en_US")

        // 1. A group with Groceries, $500.00 a month, holding nothing.
        run.addGroup(named: groupName)
        run.addBudget(named: groceries, amount: "500", inGroup: groupName)

        // Scenario ENTRY-06
        // 2. Hilltop, 42.00, dated the 28th of last month. Groceries does not
        // list it, and still says nothing is spent this period.
        run.click(AccessibilityID.budgetAdd)
        run.type("Hilltop", into: AccessibilityID.entryMerchant)
        run.type("42.00", into: AccessibilityID.entryAmount)
        run.pick(day: lastMonth)
        run.click(AccessibilityID.entryAdd)
        run.expectNoSheet()
        run.expectNoRow("Hilltop", "a transaction dated last month is in this period's list")
        run.expect(wheel: AccessibilityID.budgetWheel, reads: nothingSpent.wheel.spokenSummary, "after Hilltop")
        run.expect(figures: nothingSpent.wheel.figures, "after Hilltop")
        XCTAssertTrue(run.listText(noneThisPeriod).waitForExistence(timeout: 5),
                      "no line saying \(noneThisPeriod) On screen: \(run.visibleTexts())")

        // Scenario ENTRY-06
        // 3. It is kept all the same: Delete… on Groceries asks first, and
        // says its 1 transaction goes with it. Cancel keeps Groceries.
        let question = PendingDelete.budget(Budget(groupID: GroupID(), name: groceries, limit: .zero()),
                                            transactions: 1)
        run.openMenu(on: run.sidebarBudget(groceries), AccessibilityID.sidebarBudget(groceries),
                     offering: MainScreen.Words.delete)
        run.clickMenuItem(MainScreen.Words.delete)
        XCTAssertTrue(run.app.staticTexts[question.title].waitForExistence(timeout: 5),
                      "no question. On screen: \(run.visibleTexts())")
        XCTAssertTrue(run.app.staticTexts[question.message].waitForExistence(timeout: 5),
                      "the question does not say \(question.message) On screen: \(run.visibleTexts())")
        try XCTUnwrap(run.dialogButton(MainScreen.Words.cancel), "no Cancel on the question").click()
        XCTAssertTrue(run.wait(for: run.app.staticTexts[question.title], until: "exists == false", timeout: 5),
                      "the question stayed after Cancel")
        XCTAssertTrue(run.sidebarBudget(groceries).exists, "Cancel did not keep Groceries")

        // 4. Hilltop Grocery, $142.08, today.
        run.addEntry(merchant: "Hilltop Grocery", amount: "142.08")
        let spent = TodaysBudget(limit: 50_000, spent: 14_208)
        run.expect(wheel: AccessibilityID.budgetWheel, reads: spent.wheel.spokenSummary, "with Hilltop Grocery")

        // Scenario EDIT-05
        // 5. Opened, and with its date set to the 28th of last month, a line
        // under the date says this moves it out of this period. Set back to
        // its own date, the line goes.
        run.clickRow("Hilltop Grocery")
        run.expectSheet(for: "Hilltop Grocery")
        let ownDay = try XCTUnwrap(run.shownDate(), "Date shows no date: \(run.element(AccessibilityID.entryDate))")
        let line = run.element(AccessibilityID.entryPeriodLine)
        XCTAssertFalse(line.exists, "a line under its own date: \(run.text(of: line))")
        run.pick(day: lastMonth)
        XCTAssertTrue(run.wait(for: line, holds: EntryEditor.Words.outOfPeriod, timeout: 5),
                      "no line saying \(EntryEditor.Words.outOfPeriod) On screen: \(run.visibleTexts())")
        run.expect(line, under: AccessibilityID.entryDate)
        run.pick(day: ownDay)
        XCTAssertTrue(run.wait(for: line, until: "exists == false", timeout: 5), "the line stayed at its own date")

        // Scenario EDIT-05
        // 6. Set to the 28th of last month again and saved, Hilltop Grocery
        // leaves Groceries' list and this period's total.
        run.pick(day: lastMonth)
        XCTAssertTrue(run.wait(for: line, holds: EntryEditor.Words.outOfPeriod, timeout: 5),
                      "no line saying \(EntryEditor.Words.outOfPeriod) On screen: \(run.visibleTexts())")
        run.click(AccessibilityID.entrySave)
        run.expectNoSheet()
        XCTAssertTrue(run.rowIsGone("Hilltop Grocery"), "Hilltop Grocery is still in this period's list")
        run.expect(wheel: AccessibilityID.budgetWheel, reads: nothingSpent.wheel.spokenSummary, "after the move")
        run.expect(figures: nothingSpent.wheel.figures, "after the move")
        XCTAssertTrue(run.listText(noneThisPeriod).waitForExistence(timeout: 5),
                      "no line saying \(noneThisPeriod) On screen: \(run.visibleTexts())")
    }

    // MARK: - The Undo bar

    /// The bar's own 10 seconds, as a person gets them.
    @MainActor
    func testTheUndoBarGoesAfterAboutTenSeconds() throws {
        let run = try start(region: "en_US")
        let stamp = Self.stamp()
        let groupName = "Entries \(stamp)", groceries = "Groceries \(stamp)"
        let bar = run.element(AccessibilityID.undoBar)

        // 1. A group with Groceries, $500.00 a month, holding Hilltop Grocery
        // at $142.08 and Market at $9.50.
        run.addGroup(named: groupName)
        run.addBudget(named: groceries, amount: "500", inGroup: groupName)
        run.addEntry(merchant: "Hilltop Grocery", amount: "142.08")
        run.addEntry(merchant: "Market", amount: "9.50")

        // 2. Hilltop Grocery opened, and Delete… asks first. The question's
        // Delete takes it out, and the bar offers Undo. The clock starts as
        // Delete is pressed, since each check that follows takes a second
        // or more of its own.
        let question = TestApp.question(deleting: "Hilltop Grocery", cents: 14_208, budget: groceries,
                                        group: groupName)
        run.clickRow("Hilltop Grocery")
        run.expectSheet(for: "Hilltop Grocery")
        run.click(AccessibilityID.entryDelete)
        XCTAssertTrue(run.app.staticTexts[question.title].waitForExistence(timeout: 5),
                      "no question. On screen: \(run.visibleTexts())")
        let confirm = try XCTUnwrap(run.dialogButton(question.confirmLabel), "no Delete on the question")
        let deletedAt = Date()
        confirm.click()
        let deleted = UndoOffer.Words.deleted("Hilltop Grocery", "$142.08")
        XCTAssertTrue(run.app.staticTexts[deleted].waitForExistence(timeout: 5),
                      "no bar saying \(deleted) On screen: \(run.visibleTexts())")
        XCTAssertEqual(run.element(AccessibilityID.undoButton).label, UndoOffer.Words.undo)

        // Scenario EDIT-08
        // 3. The bar is still up 7 seconds after the delete, and has gone by
        // itself 15 seconds after it. Hilltop Grocery stays deleted.
        run.pause(until: deletedAt.addingTimeInterval(7))
        XCTAssertTrue(bar.exists, "the bar went within 7 seconds of the delete")
        XCTAssertTrue(run.wait(for: bar, until: "exists == false",
                               timeout: max(deletedAt.addingTimeInterval(15).timeIntervalSinceNow, 0)),
                      "the bar stayed past 15 seconds after the delete")
        run.expectNoSheet()
        run.expectNoRow("Hilltop Grocery", "it came back when the bar went")
        let market = TodaysBudget(limit: 50_000, spent: 950)
        run.expect(wheel: AccessibilityID.budgetWheel, reads: market.wheel.spokenSummary, "after the bar went")
        run.expect(figures: market.wheel.figures, "after the bar went")
    }

    /// The bar held for 300 seconds, so only a change, or Undo, takes it.
    @MainActor
    func testAnotherChangeTakesTheUndoBarAwayAndASecondDeleteReplacesIt() throws {
        let run = try start(region: "en_US", undoSeconds: 300)
        let stamp = Self.stamp()
        let groupName = "Entries \(stamp)", groceries = "Groceries \(stamp)"
        let bar = run.element(AccessibilityID.undoBar)
        func question(_ merchant: String, _ cents: Int) -> PendingDelete {
            TestApp.question(deleting: merchant, cents: cents, budget: groceries, group: groupName)
        }
        let hilltopBar = UndoOffer.Words.deleted("Hilltop Grocery", "$142.08")
        let marketBar = UndoOffer.Words.deleted("Market", "$9.50")
        let bakeryBar = UndoOffer.Words.deleted("Corner Bakery", "$12.00")

        // 1. A group with Groceries, $500.00 a month, holding Hilltop Grocery
        // at $142.08, Market at $9.50 and Corner Bakery at $12.00.
        run.addGroup(named: groupName)
        run.addBudget(named: groceries, amount: "500", inGroup: groupName)
        run.addEntry(merchant: "Hilltop Grocery", amount: "142.08")
        run.addEntry(merchant: "Market", amount: "9.50")
        run.addEntry(merchant: "Corner Bakery", amount: "12.00")

        // 2. Hilltop Grocery deleted from its sheet. The bar names it.
        run.deleteFromSheet("Hilltop Grocery", asking: question("Hilltop Grocery", 14_208))
        XCTAssertTrue(run.app.staticTexts[hilltopBar].waitForExistence(timeout: 5),
                      "no bar saying \(hilltopBar) On screen: \(run.visibleTexts())")

        // Scenario EDIT-08
        // 3. The bar stays while a new transaction is filled in, and its Add
        // takes the bar away at once. Hilltop Grocery stays deleted.
        run.click(AccessibilityID.budgetAdd)
        run.type("Sunrise Cafe", into: AccessibilityID.entryMerchant)
        run.type("4.25", into: AccessibilityID.entryAmount)
        XCTAssertTrue(bar.exists, "the bar went before the change")
        run.click(AccessibilityID.entryAdd)
        run.expectNoSheet()
        XCTAssertTrue(run.wait(for: bar, until: "exists == false", timeout: 3), "adding left the bar")
        run.expect(entry: "Sunrise Cafe", shows: "$4.25")
        run.expectNoRow("Hilltop Grocery", "the change brought it back")

        // 4. Market deleted. The bar names it.
        run.deleteFromSheet("Market", asking: question("Market", 950))
        XCTAssertTrue(run.app.staticTexts[marketBar].waitForExistence(timeout: 5),
                      "no bar saying \(marketBar) On screen: \(run.visibleTexts())")

        // Scenario EDIT-08
        // 5. A second delete replaces the bar: it names Corner Bakery, not
        // Market, and its Undo brings back Corner Bakery only.
        run.deleteFromSheet("Corner Bakery", asking: question("Corner Bakery", 1_200))
        XCTAssertTrue(run.app.staticTexts[bakeryBar].waitForExistence(timeout: 5),
                      "no bar saying \(bakeryBar) On screen: \(run.visibleTexts())")
        XCTAssertFalse(run.app.staticTexts[marketBar].exists, "the bar still names Market")
        run.click(AccessibilityID.undoButton)
        XCTAssertTrue(run.entryRow("Corner Bakery").waitForExistence(timeout: 10),
                      "Undo did not bring Corner Bakery back")
        XCTAssertTrue(run.wait(for: bar, until: "exists == false", timeout: 5), "the bar stayed after Undo")
        run.expectNoRow("Market", "Undo brought back the first delete too")
        let left = TodaysBudget(limit: 50_000, spent: 1_200 + 425)
        run.expect(wheel: AccessibilityID.budgetWheel, reads: left.wheel.spokenSummary, "after Undo")
        run.expect(figures: left.wheel.figures, "after Undo")
    }

    // MARK: - A decimal comma

    @MainActor
    func testACommaMarksDecimalsWhereTheRegionWritesOne() throws {
        let run = try start(region: "de_DE")
        let stamp = Self.stamp()
        let groupName = "Entries \(stamp)", groceries = "Groceries \(stamp)"

        // 1. In Germany's region, a group with Groceries, 500 a month.
        // Saving opens it.
        run.addGroup(named: groupName)
        run.addBudget(named: groceries, amount: "500", inGroup: groupName)

        // Scenario ENTRY-12
        // 2. Hilltop Grocery at 12,50 is twelve fifty: its row shows $12.50,
        // and Groceries counts $12.50.
        run.addEntry(merchant: "Hilltop Grocery", amount: "12,50")
        run.expect(entry: "Hilltop Grocery", shows: "$12.50")
        let spent = TodaysBudget(limit: 50_000, spent: 1_250)
        run.expect(wheel: AccessibilityID.budgetWheel, reads: spent.wheel.spokenSummary, "after 12,50")
        run.expect(figures: spent.wheel.figures, "after 12,50")

        // Scenario ENTRY-12
        // 3. Opened again, its amount reads 12,50.
        run.clickRow("Hilltop Grocery")
        run.expectSheet(for: "Hilltop Grocery")
        let amount = run.element(AccessibilityID.entryAmount)
        XCTAssertTrue(run.wait(for: amount, holds: "12,50", timeout: 5), "the amount reads \(run.text(of: amount))")
        run.click(AccessibilityID.entryCancel)
        run.expectNoSheet()
    }

    /// Launches the app with a data folder of its own, for tearDown to
    /// remove, in a region: "en_US" writes 12.50 and "de_DE" writes 12,50.
    /// `undoSeconds` keeps the Undo bar up longer than its 10 seconds.
    @MainActor
    private func start(region: String, undoSeconds: Int? = nil) throws -> TestApp {
        let run = try TestApp()
        Self.dataRootPath = run.dataRoot.path
        run.app.launchArguments += ["-AppleLocale", region]
        if let undoSeconds { run.app.launchEnvironment[Workspace.undoWindowVariable] = String(undoSeconds) }
        run.launch()
        return run
    }

    /// The 28th of last month, at noon: before this period whatever day the
    /// test runs, as Sep 28 is on Oct 18 in the scenarios. Every month has a
    /// 28th.
    private static func twentyEighthOfLastMonth() throws -> Date {
        let calendar = Calendar.current
        let lastMonth = try XCTUnwrap(calendar.date(byAdding: .month, value: -1, to: Date()))
        var parts = calendar.dateComponents([.year, .month], from: lastMonth)
        parts.day = 28
        parts.hour = 12
        return try XCTUnwrap(calendar.date(from: parts))
    }

    /// Part of each name, so runs never share one.
    private static func stamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: Date())
    }
}

/// The steps these tests take, beside the ones every Mac test shares.
private extension TestApp {
    /// The day the sheet's Date shows. Its value reaches the test as text,
    /// such as "2026-10-21 14:50:28 +0000", or as a date.
    func shownDate() -> Date? {
        let picker = element(AccessibilityID.entryDate)
        guard picker.exists, let value = picker.value else { return nil }
        if let date = value as? Date { return date }
        let text = String(describing: value)
        guard let found = text.range(of: #"\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2} [+-]\d{4}"#,
                                     options: .regularExpression) else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss Z"
        return formatter.date(from: String(text[found]))
    }

    /// Sets the sheet's Date to `day` with the keyboard, the way a person
    /// moves through the form: Tab from Amount into Date, the arrow keys one
    /// part at a time, then Tab on to Note. Date's field is never clicked:
    /// on the first runs a click on it left the sheet's buttons unclickable,
    /// and the next click elsewhere unanswered. The date is read back after
    /// each key. The tests that call this launch in the United States
    /// region, where the parts are month, day and year, in that order. The
    /// day goes first when it is the 28th or before, and last otherwise, so
    /// no step lands on a day the month lacks. No part is stepped past its
    /// end, so whether a part wraps round never matters.
    func pick(day target: Date, file: StaticString = #filePath, line: UInt = #line) {
        let picker = element(AccessibilityID.entryDate), amount = element(AccessibilityID.entryAmount)
        XCTAssertTrue(picker.waitForExistence(timeout: 10), "no Date. On screen: \(visibleTexts())",
                      file: file, line: line)
        waitUntilHittable(amount, AccessibilityID.entryAmount)
        amount.click()
        app.typeKey(.tab, modifierFlags: [])
        let calendar = Calendar.current
        let places: [Calendar.Component] = [.month, .day, .year]
        // Which part has the keyboard: one step up shows it, and one step
        // down puts it back.
        guard let before = shownDate() else {
            XCTFail("Date shows no date: \(picker)", file: file, line: line)
            return
        }
        step(.upArrow, from: before)
        var after = shownDate() ?? before
        if after == before {
            // Tab went elsewhere, so the arrow beside Date steps it up
            // instead.
            picker.incrementArrows.firstMatch.click()
            let moved = NSPredicate { _, _ in self.shownDate() != before }
            _ = XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: moved, object: nil)], timeout: 2)
            after = shownDate() ?? before
        }
        let changed = { (part: Calendar.Component) in
            calendar.component(part, from: after) != calendar.component(part, from: before)
        }
        guard var at = places.firstIndex(where: changed) else {
            XCTFail("neither Tab from Amount nor the arrow beside Date changed it. On screen: \(visibleTexts())",
                    file: file, line: line)
            return
        }
        step(.downArrow, from: after)
        let order: [Calendar.Component] = calendar.component(.day, from: target) <= 28
            ? [.day, .month, .year] : [.month, .year, .day]
        for part in order {
            guard let place = places.firstIndex(of: part) else { continue }
            while at < place {
                app.typeKey(.rightArrow, modifierFlags: [])
                at += 1
            }
            while at > place {
                app.typeKey(.leftArrow, modifierFlags: [])
                at -= 1
            }
            let wanted = calendar.component(part, from: target)
            for _ in 0..<40 {
                guard let shown = shownDate() else { break }
                let now = calendar.component(part, from: shown)
                if now == wanted { break }
                step(now < wanted ? .upArrow : .downArrow, from: shown)
            }
        }
        app.typeKey(.tab, modifierFlags: [])
        let shown = shownDate()
        XCTAssertTrue(shown.map { calendar.isDate($0, inSameDayAs: target) } ?? false,
                      "Date shows \(shown.map { "\($0)" } ?? "nothing"), not \(target)", file: file, line: line)
    }

    /// One arrow key in Date, then up to two seconds for the date it shows
    /// to change.
    private func step(_ key: XCUIKeyboardKey, from shown: Date) {
        app.typeKey(key, modifierFlags: [])
        let moved = NSPredicate { _, _ in self.shownDate() != shown }
        _ = XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: moved, object: nil)], timeout: 2)
    }

    /// The row in the budget's list that holds an entry, found by the cell
    /// with its merchant: a row of an outline, or of a table, whichever the
    /// list reaches the test as.
    func listRow(_ merchant: String) -> XCUIElement {
        let rows = app.windows.firstMatch.descendants(matching: .any).matching(NSPredicate(
            format: "elementType == %d OR elementType == %d", XCUIElement.ElementType.outlineRow.rawValue,
            XCUIElement.ElementType.tableRow.rawValue))
        let identified = rows.containing(.any, identifier: AccessibilityID.entryRow(merchant)).firstMatch
        if identified.waitForExistence(timeout: 10) { return identified }
        return rows.containing(NSPredicate(format: "label == %@ OR value == %@", merchant, merchant)).firstMatch
    }

    /// Waits for an entry's row to show an amount, in the row's own Amount
    /// column, since the figures beside the wheel can show the same amount.
    func expect(entry merchant: String, shows amount: String, file: StaticString = #filePath, line: UInt = #line) {
        let row = listRow(merchant)
        XCTAssertTrue(row.waitForExistence(timeout: 10), "no row for \(merchant). On screen: \(visibleTexts())",
                      file: file, line: line)
        XCTAssertTrue(row.staticTexts[amount].waitForExistence(timeout: 10),
                      "\(merchant)'s row does not show \(amount). It shows: "
                      + "\(row.staticTexts.allElementsBoundByIndex.map { text(of: $0) })", file: file, line: line)
    }

    /// Checks an entry's row shows a note, under its merchant.
    func expect(note: String, under merchant: String, file: StaticString = #filePath, line: UInt = #line) {
        let row = listRow(merchant)
        let shown = row.staticTexts[note], name = row.staticTexts[merchant]
        XCTAssertTrue(shown.waitForExistence(timeout: 10),
                      "\(merchant)'s row does not show \(note). On screen: \(visibleTexts())", file: file, line: line)
        XCTAssertTrue(name.exists, "\(merchant)'s row does not show its merchant", file: file, line: line)
        let below = shown.frame.minY >= name.frame.maxY - 1
        let sameColumn = shown.frame.minX < name.frame.maxX && shown.frame.maxX > name.frame.minX
        XCTAssertTrue(below && sameColumn, "\(note) is not under \(merchant): it is at \(shown.frame), "
                      + "and \(merchant) at \(name.frame)", file: file, line: line)
    }

    /// Checks no row holds this merchant, giving it three seconds to show.
    func expectNoRow(_ merchant: String, _ what: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertFalse(element(AccessibilityID.entryRow(merchant)).waitForExistence(timeout: 3),
                       "\(what): \(merchant) is in the list", file: file, line: line)
        XCTAssertFalse(listText(merchant).exists, "\(what): \(merchant) is in the list", file: file, line: line)
    }

    /// Checks a field's name shows in the sheet, on its field's line and
    /// before it.
    func expect(label words: String, beside identifier: String, file: StaticString = #filePath, line: UInt = #line) {
        let label = app.sheets.firstMatch.staticTexts[words], field = element(identifier)
        XCTAssertTrue(label.waitForExistence(timeout: 5),
                      "the sheet does not say \(words). On screen: \(visibleTexts())", file: file, line: line)
        XCTAssertTrue(field.exists, "no field called \(identifier)", file: file, line: line)
        let sameLine = label.frame.midY >= field.frame.minY && label.frame.midY <= field.frame.maxY
        XCTAssertTrue(sameLine && label.frame.maxX <= field.frame.minX,
                      "\(words) is not on its field's line: it is at \(label.frame), and the field at \(field.frame)",
                      file: file, line: line)
    }

    /// Checks a line shows under a field.
    func expect(_ shown: XCUIElement, under identifier: String, file: StaticString = #filePath, line: UInt = #line) {
        let field = element(identifier)
        XCTAssertTrue(shown.frame.minY >= field.frame.maxY - 1,
                      "\(text(of: shown)) is not under \(identifier): it is at \(shown.frame), and the field at "
                      + "\(field.frame)", file: file, line: line)
    }

    /// Does nothing until a moment has come. A waiter on an expectation
    /// nobody fulfils is XCTest's way to pause, as in TestApp.deleteGroup.
    func pause(until moment: Date) {
        let wait = moment.timeIntervalSinceNow
        guard wait > 0 else { return }
        _ = XCTWaiter().wait(for: [XCTestExpectation(description: "a pause")], timeout: wait)
    }

    /// Checks a button stays dimmed for two seconds.
    func expectStaysDimmed(_ identifier: String, _ what: String, file: StaticString = #filePath, line: UInt = #line) {
        let button = element(identifier)
        XCTAssertTrue(button.waitForExistence(timeout: 5), "\(what): no \(identifier)", file: file, line: line)
        XCTAssertFalse(wait(for: button, until: "isEnabled == true", timeout: 2), "\(what): it lit",
                       file: file, line: line)
    }

    /// Empties a field: Command-A, then Delete.
    func clear(_ identifier: String) {
        let field = element(identifier)
        XCTAssertTrue(field.waitForExistence(timeout: 10), "no field called \(identifier)")
        waitUntilHittable(field, identifier)
        field.click()
        field.typeKey("a", modifierFlags: .command)
        field.typeKey(.delete, modifierFlags: [])
        XCTAssertTrue(wait(for: field, holds: "", timeout: 5), "\(identifier) still shows \(text(of: field))")
    }

    /// Delete… in an entry's sheet, which asks `question` first, then the
    /// question's Delete. The sheet closes and the row goes.
    func deleteFromSheet(_ merchant: String, asking question: PendingDelete,
                         file: StaticString = #filePath, line: UInt = #line) {
        clickRow(merchant)
        expectSheet(for: merchant, file: file, line: line)
        click(AccessibilityID.entryDelete)
        XCTAssertTrue(app.staticTexts[question.title].waitForExistence(timeout: 5),
                      "no question. On screen: \(visibleTexts())", file: file, line: line)
        guard let confirm = dialogButton(question.confirmLabel) else {
            XCTFail("no \(question.confirmLabel) on the question. On screen: \(visibleTexts())", file: file, line: line)
            return
        }
        confirm.click()
        expectNoSheet(file: file, line: line)
        XCTAssertTrue(rowIsGone(merchant), "Delete left \(merchant) in the list", file: file, line: line)
    }

    /// The question a delete asks about one entry, in a group nobody else
    /// is in, built from the shared words.
    static func question(deleting merchant: String, cents: Int, budget: String, group: String) -> PendingDelete {
        let entry = Transaction(budgetID: BudgetID(), groupID: GroupID(), date: Date(), merchant: merchant,
                                amount: Money(minorUnits: -cents))
        return .entry(entry, budget: budget, group: group, shared: false)
    }

    /// The line under a budget's wheel that counts its transactions this
    /// period, such as "0 transactions since Oct 1", from the shared code.
    /// It is built in `region`, the one the app was launched in, so its date
    /// reads as the app writes it whatever region this Mac is set to.
    static func countLine(_ budget: TodaysBudget, region: String) throws -> String {
        let model = AppModel(store: Store(database: try WellSpentDatabase.inMemory()))
        return AppLocale.$override.withValue(Locale(identifier: region)) {
            BudgetScreen(summary: budget.summary, model: model, me: nil).countLine
        }
    }
}
