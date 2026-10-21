import Foundation
import XCTest
import WellSpentAppCore
import WellSpentCrypto
import WellSpentModel

/// Opening a transaction to change it, move it to another budget in its
/// group, or delete it, with the Undo bar after a delete, on a phone with no
/// account. No server, so these run on every pull request. Each test starts
/// the app on a fresh data folder and makes its own budgets in the sample
/// Household, so nothing rests on the samples' dates.
final class PhoneEntryEditingTests: XCTestCase {
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

    /// `undoSeconds` keeps the Undo bar up longer than its 10 seconds, so a
    /// slow simulator still reaches its button.
    @MainActor
    private func launched(undoSeconds: Int? = nil) -> PhoneTestApp {
        let run = PhoneTestApp()
        Self.dataRootPath = run.dataRoot.path
        if let undoSeconds { run.app.launchEnvironment[Workspace.undoWindowVariable] = String(undoSeconds) }
        run.launch()
        return run
    }

    /// One launch, with the bar's usual 10 seconds, for opening, changing,
    /// moving and redating a transaction, and the bar going by itself.
    @MainActor
    func testATapOpensATransactionToChangeOrMoveIt() throws {
        let run = launched()
        run.addBudget(named: "Snacks", amount: "50", inGroup: "Household")
        run.goBack()
        run.addBudget(named: "Treats", amount: "100", inGroup: "Household")
        run.addEntry(merchant: "Hilltop", amount: "42.00")
        run.addEntry(merchant: "Market", amount: "9.50")

        // Scenario EDIT-01
        // 1. A row reads as one button with its words, since a tap opens it.
        // A tap on it opens it as "Transaction", filled in, with its budget,
        // and where it came from above, since nobody else is in the group.
        // Delete has no "…", and Save is dimmed.
        let row = run.element(AccessibilityID.entryRow("Hilltop"))
        XCTAssertEqual(row.elementType, .button, "VoiceOver does not read the row as a button")
        XCTAssertTrue(run.row("Hilltop", says: "$42.00"), "the row does not read as one. It says: \(run.rowLabel("Hilltop"))")
        run.openEntry("Hilltop")
        XCTAssertEqual(run.fieldText(AccessibilityID.entryMerchant), "Hilltop")
        XCTAssertEqual(run.fieldText(AccessibilityID.entryAmount), "42.00")
        XCTAssertEqual(run.fieldText(AccessibilityID.entryNote), "")
        XCTAssertTrue(run.budgetShown().contains("Treats"), "the budget is not Treats: \(run.budgetShown())")
        XCTAssertEqual(run.element(AccessibilityID.entryTopLine).label, "Manual")
        XCTAssertEqual(run.button(AccessibilityID.entryDelete).label, PhoneWording.button(EntryEditor.Words.delete))
        XCTAssertTrue(run.button(AccessibilityID.entryCancel).exists, "no Cancel")
        let save = run.button(AccessibilityID.entrySave)
        XCTAssertTrue(save.exists, "no Save")
        XCTAssertFalse(save.isEnabled, "Save lit with nothing changed")

        // Scenario EDIT-02
        // 2. A change lights Save, and putting it back dims it. The same
        // money written another way, an amount that is not a number, and a
        // merchant of spaces keep it dimmed. A note lights it.
        run.type("Hillside", into: AccessibilityID.entryMerchant)
        XCTAssertTrue(run.wait(for: save, until: "isEnabled == true", timeout: 5), "a new merchant left Save dimmed")
        run.type("Hilltop", into: AccessibilityID.entryMerchant)
        XCTAssertTrue(run.wait(for: save, until: "isEnabled == false", timeout: 5), "the merchant put back left Save lit")
        for amount in ["42.0", "1..2"] {
            run.type(amount, into: AccessibilityID.entryAmount)
            XCTAssertFalse(run.wait(for: save, until: "isEnabled == true", timeout: 2), "Save lit at \(amount)")
        }
        run.type("42.00", into: AccessibilityID.entryAmount)
        run.type("gift", into: AccessibilityID.entryNote)
        XCTAssertTrue(run.wait(for: save, until: "isEnabled == true", timeout: 5), "a note left Save dimmed")
        run.type("   ", into: AccessibilityID.entryMerchant)
        XCTAssertTrue(run.wait(for: save, until: "isEnabled == false", timeout: 5), "Save lit with a merchant of spaces")
        run.type("Hilltop", into: AccessibilityID.entryMerchant)
        run.clearField(AccessibilityID.entryNote)
        XCTAssertTrue(run.wait(for: save, until: "isEnabled == false", timeout: 5), "Save lit with everything put back")

        // Scenario EDIT-02, EDIT-03
        // 3. A new amount lights Save. Save closes the sheet, and the row and
        // the page's totals change at once.
        run.type("40.00", into: AccessibilityID.entryAmount)
        XCTAssertTrue(run.wait(for: save, until: "isEnabled == true", timeout: 5), "a new amount left Save dimmed")
        run.tap(AccessibilityID.entrySave)
        run.expectNoSheet()
        XCTAssertTrue(run.row("Hilltop", says: "$40.00"), "the row does not say $40.00. It says: \(run.rowLabel("Hilltop"))")
        XCTAssertTrue(run.shows("$49.50"), "what is spent is not $49.50. On screen: \(run.visibleTexts())")
        XCTAssertTrue(run.shows("$50.50"), "what is left is not $50.50. On screen: \(run.visibleTexts())")

        // Scenario EDIT-08
        // 4. After a delete the bar stays a few seconds, then goes by itself,
        // and the transaction stays deleted.
        run.openEntry("Market")
        run.tap(AccessibilityID.entryDelete)
        run.answer(Self.question(deleting: "Market", cents: 950).confirmLabel)
        run.expectNoSheet()
        let bar = run.element(AccessibilityID.undoBar)
        XCTAssertTrue(bar.waitForExistence(timeout: 5), "no Undo bar. On screen: \(run.visibleTexts())")
        XCTAssertFalse(run.wait(for: bar, until: "exists == false", timeout: 3), "the bar went at once")
        XCTAssertTrue(run.wait(for: bar, until: "exists == false", timeout: 25), "the bar stayed")
        XCTAssertFalse(run.element(AccessibilityID.entryRow("Market")).exists, "Market came back")
        XCTAssertTrue(run.shows("$60.00"), "the total still counts it. On screen: \(run.visibleTexts())")

        // Scenario EDIT-04
        // 5. Budget offers the group's budgets only. Moved to Snacks, Hilltop
        // leaves Treats' list and total, and Snacks lists it and counts it.
        run.openEntry("Hilltop")
        run.tap(AccessibilityID.entryBudget)
        for budget in ["Groceries", "Eating out", "Utilities", "Snacks", "Treats"] {
            XCTAssertTrue(run.menuItem(budget).waitForExistence(timeout: 5),
                          "Budget does not offer \(budget). On screen: \(run.visibleButtons())")
        }
        XCTAssertFalse(run.menuItem("Materials").exists, "Budget offers a budget in another group")
        run.tapMenuItem("Snacks")
        XCTAssertTrue(run.wait(for: save, until: "isEnabled == true", timeout: 5), "a new budget left Save dimmed")
        run.tap(AccessibilityID.entrySave)
        run.expectNoSheet()
        XCTAssertTrue(run.wait(for: run.element(AccessibilityID.entryRow("Hilltop")), until: "exists == false",
                               timeout: 10), "Hilltop is still in Treats")
        XCTAssertTrue(run.shows("$100.00"), "Treats' total still counts it. On screen: \(run.visibleTexts())")
        run.goBack()
        run.scrollTo(AccessibilityID.sidebarBudget("Snacks"))
        run.openBudget(named: "Snacks")
        XCTAssertTrue(run.element(AccessibilityID.entryRow("Hilltop")).waitForExistence(timeout: 10),
                      "Snacks does not list Hilltop. On screen: \(run.visibleTexts())")
        XCTAssertTrue(run.shows("$10.00"), "Snacks does not count it. On screen: \(run.visibleTexts())")

        // Scenario EDIT-05
        // 6. A date in last month says it moves the transaction out of this
        // period, and back to today the line goes. Saved in last month, it
        // leaves this period's list and total.
        let today = Date()
        let calendar = Calendar.current
        let lastMonth = try XCTUnwrap(calendar.date(byAdding: .month, value: -1, to: today))
        var fifteenth = calendar.dateComponents([.year, .month], from: lastMonth)
        fifteenth.day = 15
        let lastMonthsFifteenth = try XCTUnwrap(calendar.date(from: fifteenth))
        let line = run.element(AccessibilityID.entryPeriodLine)
        run.openEntry("Hilltop")
        run.pickDate(lastMonthsFifteenth, showing: today)
        XCTAssertTrue(line.waitForExistence(timeout: 5), "no line under the date. On screen: \(run.visibleTexts())")
        XCTAssertEqual(line.label, EntryEditor.Words.outOfPeriod)
        run.pickDate(today, showing: lastMonthsFifteenth)
        XCTAssertTrue(run.wait(for: line, until: "exists == false", timeout: 5), "the line stayed at today")
        run.pickDate(lastMonthsFifteenth, showing: today)
        XCTAssertTrue(line.waitForExistence(timeout: 5), "no line under the date. On screen: \(run.visibleTexts())")
        run.tap(AccessibilityID.entrySave)
        run.expectNoSheet()
        XCTAssertTrue(run.wait(for: run.element(AccessibilityID.entryRow("Hilltop")), until: "exists == false",
                               timeout: 10), "Hilltop is still in this period's list")
        XCTAssertTrue(run.shows("$50.00"), "this period's total still counts it. On screen: \(run.visibleTexts())")
    }

    @MainActor
    func testDeleteAsksFirstAndTheBarOffersUndo() throws {
        let run = launched(undoSeconds: 300)
        run.addBudget(named: "Treats", amount: "100", inGroup: "Household")
        run.addEntry(merchant: "Hilltop", amount: "40.00")
        run.addEntry(merchant: "Market", amount: "9.50")
        let question = Self.question(deleting: "Hilltop", cents: 4000)
        let hilltopBar = UndoOffer.Words.deleted("Hilltop", "$40.00")
        let edit = PhoneWording.button(MainScreen.Words.edit)
        let delete = PhoneWording.button(MainScreen.Words.delete)

        // Scenario EDIT-06
        // 1. Delete asks first, naming the transaction and its amount, and
        // the budget it comes out of. Cancel keeps the sheet open, and the
        // transaction.
        run.openEntry("Hilltop")
        run.tap(AccessibilityID.entryDelete)
        XCTAssertTrue(run.shows(question.title), "no question. On screen: \(run.visibleTexts())")
        XCTAssertTrue(run.shows(question.message), "\(question.message) does not show. On screen: \(run.visibleTexts())")
        run.cancelQuestion()
        XCTAssertTrue(run.wait(for: run.text(question.title), until: "exists == false", timeout: 10),
                      "the question stayed after Cancel")
        XCTAssertTrue(run.app.navigationBars[EntryEditor.Words.editTitle].exists, "Cancel closed the sheet")
        XCTAssertEqual(run.fieldText(AccessibilityID.entryMerchant), "Hilltop")

        // Scenario EDIT-06, EDIT-07
        // 2. The question's Delete closes the sheet. Hilltop leaves the list
        // and the total, and the bar at the top says what went, with Undo.
        run.tap(AccessibilityID.entryDelete)
        XCTAssertTrue(run.shows(question.title), "no question. On screen: \(run.visibleTexts())")
        run.answer(question.confirmLabel)
        run.expectNoSheet()
        XCTAssertTrue(run.wait(for: run.element(AccessibilityID.entryRow("Hilltop")), until: "exists == false",
                               timeout: 10), "Delete left the row")
        XCTAssertTrue(run.shows("$90.50"), "the total still counts it. On screen: \(run.visibleTexts())")
        XCTAssertTrue(run.shows(hilltopBar), "no Undo bar. On screen: \(run.visibleTexts())")
        XCTAssertTrue(run.element(AccessibilityID.undoButton).exists, "the bar has no Undo")

        // Scenario EDIT-07
        // 3. Undo brings it back as it was, and the bar goes.
        run.tap(AccessibilityID.undoButton)
        XCTAssertTrue(run.element(AccessibilityID.entryRow("Hilltop")).waitForExistence(timeout: 10),
                      "Undo did not bring it back")
        XCTAssertTrue(run.row("Hilltop", says: "$40.00"), "it is not back at $40.00. It says: \(run.rowLabel("Hilltop"))")
        XCTAssertTrue(run.shows("$50.50"), "the total does not count it again. On screen: \(run.visibleTexts())")
        XCTAssertTrue(run.wait(for: run.element(AccessibilityID.undoBar), until: "exists == false", timeout: 5),
                      "the bar stayed after Undo")

        // Scenario EDIT-17, EDIT-06, EDIT-07
        // 4. A swipe to the left offers Edit and Delete. Edit opens the sheet.
        // Delete asks the same question, and its Delete puts up the same bar.
        run.swipeOpen(entry: "Hilltop")
        XCTAssertTrue(run.app.buttons[edit].exists, "the swipe offers no Edit. On screen: \(run.visibleButtons())")
        run.app.buttons[edit].tap()
        XCTAssertTrue(run.app.navigationBars[EntryEditor.Words.editTitle].waitForExistence(timeout: 10),
                      "Edit did not open the sheet. On screen: \(run.visibleTexts())")
        XCTAssertEqual(run.fieldText(AccessibilityID.entryMerchant), "Hilltop")
        run.tap(AccessibilityID.entryCancel)
        run.expectNoSheet()
        run.swipeOpen(entry: "Hilltop")
        run.app.buttons[delete].tap()
        XCTAssertTrue(run.shows(question.title), "no question. On screen: \(run.visibleTexts())")
        XCTAssertTrue(run.shows(question.message), "\(question.message) does not show. On screen: \(run.visibleTexts())")
        run.answer(question.confirmLabel)
        XCTAssertTrue(run.wait(for: run.element(AccessibilityID.entryRow("Hilltop")), until: "exists == false",
                               timeout: 10), "the swipe's Delete left the row")
        XCTAssertTrue(run.shows(hilltopBar), "no Undo bar. On screen: \(run.visibleTexts())")

        // Scenario EDIT-08
        // 5. Another change takes the bar away at once, and the delete stays.
        run.addEntry(merchant: "Bakery", amount: "5.00")
        XCTAssertTrue(run.wait(for: run.element(AccessibilityID.undoBar), until: "exists == false", timeout: 5),
                      "adding left the bar")
        XCTAssertFalse(run.element(AccessibilityID.entryRow("Hilltop")).exists, "Hilltop came back")
        run.addEntry(merchant: "Kiosk", amount: "2.00")

        // Scenario EDIT-17, EDIT-08
        // 6. A long press offers Edit and Delete in a menu. A second delete
        // replaces the bar, so only the last delete can be undone.
        run.longPress(AccessibilityID.entryRow("Market"))
        XCTAssertTrue(run.menuItem(delete).waitForExistence(timeout: 5),
                      "the menu offers no Delete. On screen: \(run.visibleButtons())")
        run.tapMenuItem(edit)
        XCTAssertTrue(run.app.navigationBars[EntryEditor.Words.editTitle].waitForExistence(timeout: 10),
                      "Edit did not open the sheet. On screen: \(run.visibleTexts())")
        XCTAssertEqual(run.fieldText(AccessibilityID.entryMerchant), "Market")
        run.tap(AccessibilityID.entryCancel)
        run.expectNoSheet()
        run.longPress(AccessibilityID.entryRow("Bakery"))
        run.tapMenuItem(delete)
        let bakery = Self.question(deleting: "Bakery", cents: 500)
        XCTAssertTrue(run.shows(bakery.title), "no question. On screen: \(run.visibleTexts())")
        run.answer(bakery.confirmLabel)
        let bakeryBar = UndoOffer.Words.deleted("Bakery", "$5.00")
        XCTAssertTrue(run.shows(bakeryBar), "the bar does not name Bakery. On screen: \(run.visibleTexts())")
        run.openEntry("Kiosk")
        run.tap(AccessibilityID.entryDelete)
        run.answer(Self.question(deleting: "Kiosk", cents: 200).confirmLabel)
        run.expectNoSheet()
        XCTAssertTrue(run.shows(UndoOffer.Words.deleted("Kiosk", "$2.00")),
                      "the bar does not name Kiosk. On screen: \(run.visibleTexts())")
        XCTAssertFalse(run.text(bakeryBar).exists, "the bar still names Bakery")
        run.tap(AccessibilityID.undoButton)
        XCTAssertTrue(run.element(AccessibilityID.entryRow("Kiosk")).waitForExistence(timeout: 10),
                      "Undo did not bring Kiosk back")
        XCTAssertFalse(run.element(AccessibilityID.entryRow("Bakery")).exists, "Bakery came back")
        XCTAssertTrue(run.shows("$88.50"), "the total is wrong. On screen: \(run.visibleTexts())")
    }

    /// The question a delete asks, built from the shared words, for a
    /// transaction in Treats, in Household, which nobody else is in.
    private static func question(deleting merchant: String, cents: Int) -> PendingDelete {
        let entry = Transaction(budgetID: BudgetID(), groupID: GroupID(), date: Date(), merchant: merchant,
                                amount: Money(minorUnits: -cents))
        return .entry(entry, budget: "Treats", group: "Household", shared: false)
    }
}

/// The steps these tests take, beside the ones every iPhone test shares.
extension PhoneTestApp {
    /// A tap on an entry's row, which opens its sheet.
    func openEntry(_ merchant: String) {
        // The wheel above the list can leave a row low on the screen, behind
        // the foot bar, where a tap lands on the bar. So it comes up first.
        _ = scrollTo(AccessibilityID.entryRow(merchant))
        tap(AccessibilityID.entryRow(merchant))
        XCTAssertTrue(app.navigationBars[EntryEditor.Words.editTitle].waitForExistence(timeout: 10),
                      "\(merchant) did not open. On screen: \(visibleTexts())")
    }

    /// Waits for the opened entry's sheet to close.
    func expectNoSheet() {
        XCTAssertTrue(wait(for: app.navigationBars[EntryEditor.Words.editTitle], until: "exists == false",
                           timeout: 10), "the sheet did not close. On screen: \(visibleTexts())")
    }

    /// What a field holds, or nothing when it shows only its placeholder.
    func fieldText(_ identifier: String) -> String {
        let field = element(identifier)
        XCTAssertTrue(field.waitForExistence(timeout: 10), "no field called \(identifier)")
        let value = (field.value as? String) ?? ""
        return value == field.placeholderValue ? "" : value
    }

    /// Empties a field.
    func clearField(_ identifier: String) {
        let field = element(identifier)
        XCTAssertTrue(field.waitForExistence(timeout: 10), "no field called \(identifier)")
        waitUntilHittable(field, identifier)
        field.tap()
        clear(field)
    }

    /// The opened entry's Budget, as its row reads.
    func budgetShown() -> String {
        let picker = element(AccessibilityID.entryBudget)
        XCTAssertTrue(picker.waitForExistence(timeout: 10), "no Budget")
        return "\(picker.label) \((picker.value as? String) ?? "")"
    }

    /// Swipes an entry's row to the left, which shows its swipe buttons.
    func swipeLeft(onEntry merchant: String) {
        let row = element(AccessibilityID.entryRow(merchant))
        XCTAssertTrue(row.waitForExistence(timeout: 10), "no \(merchant) to swipe")
        waitUntilHittable(row, merchant)
        row.swipeLeft()
    }

    /// Swipes an entry's row to the left until its Delete shows. A swipe
    /// made while the list is still settling, such as just after Undo puts a
    /// row back, is lost on CI's slow runners. So it swipes again, three
    /// times at most, and never while the buttons are already out.
    func swipeOpen(entry merchant: String) {
        let delete = app.buttons[PhoneWording.button(MainScreen.Words.delete)].firstMatch
        for _ in 0..<3 where !delete.exists {
            swipeLeft(onEntry: merchant)
            _ = delete.waitForExistence(timeout: 10)
        }
        XCTAssertTrue(delete.exists, "the swipe offers no Delete after three swipes. On screen: \(visibleButtons())")
    }

    /// Taps a button on the question a delete asks. The question is its own
    /// element, so its Delete is never the sheet's own Delete, nor a row's
    /// swipe button of the same name.
    func answer(_ label: String) {
        let button = app.sheets.buttons[label].firstMatch
        XCTAssertTrue(button.waitForExistence(timeout: 5),
                      "the question has no \(label). On screen: \(visibleButtons())")
        button.tap()
    }

    /// Answers the question Cancel. iOS 26 draws it as a popover with no
    /// Cancel, and there a tap outside it is the same answer.
    func cancelQuestion() {
        let cancel = app.sheets.buttons[MainScreen.Words.cancel].firstMatch
        if cancel.waitForExistence(timeout: 2) {
            cancel.tap()
            return
        }
        tapOutsidePopover()
    }

    /// A tap outside a popover, near the top of the screen, which closes it.
    func tapOutsidePopover() {
        let outside = element("PopoverDismissRegion")
        XCTAssertTrue(outside.waitForExistence(timeout: 5), "no popover to tap outside of")
        outside.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.1)).tap()
    }

    /// Picks a day in the opened entry's Date: the calendar opens on the
    /// month it shows, Previous Month and Next Month go to the day's month,
    /// and a tap outside closes it.
    func pickDate(_ date: Date, showing shown: Date) {
        tap(AccessibilityID.entryDate)
        let calendar = Calendar.current
        let months = calendar.dateComponents([.month], from: Self.monthStart(of: shown),
                                             to: Self.monthStart(of: date)).month ?? 0
        let step = app.buttons[months < 0 ? "DatePicker.PreviousMonth" : "DatePicker.NextMonth"]
        XCTAssertTrue(step.waitForExistence(timeout: 5), "the calendar did not open. On screen: \(visibleButtons())")
        for _ in 0..<abs(months) { step.tap() }
        // A day's button reads like "Monday, September 15", or "Today, ..." first.
        let suffix = "\(date.formatted(.dateTime.month(.wide))) \(calendar.component(.day, from: date))"
        let day = app.buttons.matching(NSPredicate(format: "label ENDSWITH %@", suffix)).firstMatch
        XCTAssertTrue(day.waitForExistence(timeout: 5), "no \(suffix) in the calendar. On screen: \(visibleButtons())")
        day.tap()
        tapOutsidePopover()
        XCTAssertTrue(wait(for: step, until: "exists == false", timeout: 5), "the calendar did not close")
    }

    private static func monthStart(of date: Date) -> Date {
        let calendar = Calendar.current
        return calendar.date(from: calendar.dateComponents([.year, .month], from: date)) ?? date
    }
}
