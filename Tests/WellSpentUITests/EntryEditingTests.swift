import AppKit
import Foundation
import XCTest
import WellSpentAppCore
import WellSpentCrypto
import WellSpentModel
import WellSpentSync

/// Opening a transaction to change, move or delete it, in the real window.
///
/// Three runs, each with a group of its own on staging, named with the
/// time, and deleted at the end:
/// - a click opens a row, then a change, a move, a delete and Undo
/// - a row this person can't change opens read-only, with no menu
/// - a statement imported again after one of its lines was deleted
///
/// Needs the four WELLSPENT_UI_TEST_ variables (see UITestSupport.swift) and
/// skips without them.
final class EntryEditingTests: XCTestCase {
    /// The run's data folder, for tearDown.
    nonisolated(unsafe) private static var dataRootPath: String?

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    /// Runs after each test, passed or halted, with no await in it. The app
    /// is closed, and nothing of the run stays on this Mac, the clipboard
    /// included: the keyboard pass copies with Command-C.
    override func tearDown() {
        let app = XCUIApplication()
        if app.state != .notRunning { app.terminate() }
        TestApp.wipeSettings()
        if let path = Self.dataRootPath { try? FileManager.default.removeItem(atPath: path) }
        Self.dataRootPath = nil
        NSPasteboard.general.clearContents()
        super.tearDown()
    }

    // MARK: - Edit, move, delete and undo

    @MainActor
    func testEditMoveDeleteAndUndo() throws {
        let accounts = try TestAccounts.fromEnvironment()
        let run = try TestApp()
        Self.dataRootPath = run.dataRoot.path
        let stamp = Self.stamp()
        let groupName = "UI Edit \(stamp)"
        let groceries = "Groceries \(stamp)", eatingOut = "Eating out \(stamp)"
        // Steps 7 to 9 must finish inside the Undo window, even on a slow runner.
        run.app.launchEnvironment[Workspace.undoWindowVariable] = "300"

        // 1. Signed in, a group with two budgets, and two entries in Groceries.
        // Saving a budget opens it, so Groceries is made last.
        run.launch()
        try run.signIn(email: accounts.email, password: accounts.password, server: accounts.server)
        run.addGroup(named: groupName)
        run.addBudget(named: eatingOut, amount: "200", inGroup: groupName)
        run.addBudget(named: groceries, amount: "500", inGroup: groupName)
        run.addEntry(merchant: "Hilltop", amount: "42.00")
        run.addEntry(merchant: "Market", amount: "9.50")

        // 2. One click opens a row. The arrow keys only move the selection,
        // and Return opens the selected row. The newest row, Market, is on top.
        run.clickRow("Market")
        run.expectSheet(for: "Market")
        run.app.typeKey(.escape, modifierFlags: [])
        run.expectNoSheet()
        run.app.typeKey(.downArrow, modifierFlags: [])
        XCTAssertFalse(run.element(AccessibilityID.entryMerchant).waitForExistence(timeout: 2),
                       "an arrow key opened a row")
        run.app.typeKey(.return, modifierFlags: [])
        run.expectSheet(for: "Hilltop")
        let save = run.element(AccessibilityID.entrySave)
        XCTAssertTrue(run.wait(for: run.element(AccessibilityID.entryAmount), holds: "42.00", timeout: 5))
        XCTAssertFalse(save.isEnabled, "nothing has changed yet")

        // 3. The keyboard in each text field. Tab from Merchant reaches
        // Amount, whose pass then types without a click.
        run.keyboardPass(AccessibilityID.entryMerchant, holding: "Hilltop")
        run.keyboardPass(AccessibilityID.entryAmount, holding: "42.00", clicking: false)
        run.keyboardPass(AccessibilityID.entryNote, holding: "")
        XCTAssertTrue(run.wait(for: save, until: "isEnabled == false", timeout: 5),
                      "every field is back as it was, so Save stays dimmed")

        // 4. A real change lights Save, and Return saves it.
        run.type("40.00", into: AccessibilityID.entryAmount)
        XCTAssertTrue(run.wait(for: save, until: "isEnabled == true", timeout: 5), "Save did not light")
        run.app.typeKey(.return, modifierFlags: [])
        run.expectNoSheet()
        XCTAssertTrue(run.listText("$40.00").waitForExistence(timeout: 10),
                      "the row says $40.00. On screen: \(run.visibleTexts())")
        XCTAssertTrue(run.app.staticTexts["$450.50 left"].waitForExistence(timeout: 10),
                      "the header counts $40.00 and $9.50. On screen: \(run.visibleTexts())")

        // 5. Moved to Eating out: gone from Groceries' list and total, in
        // Eating out's. A click opens the row that is already selected.
        run.clickRow("Hilltop")
        run.expectSheet(for: "Hilltop")
        run.choose(eatingOut, in: AccessibilityID.entryBudget)
        run.click(AccessibilityID.entrySave)
        run.expectNoSheet()
        XCTAssertTrue(run.rowIsGone("Hilltop"), "Hilltop is still in Groceries")
        XCTAssertTrue(run.app.staticTexts["$490.50 left"].waitForExistence(timeout: 10), "Groceries' total")
        run.openBudget(named: eatingOut)
        XCTAssertTrue(run.entryRow("Hilltop").waitForExistence(timeout: 10), "Hilltop is not in Eating out")
        XCTAssertTrue(run.app.staticTexts["$160.00 left"].waitForExistence(timeout: 10), "Eating out's total")

        // 6. The row's menu offers Edit… and Delete…. Delete… asks first,
        // naming the entry and its amount, and Cancel keeps it.
        let hilltop = Transaction(budgetID: BudgetID(), groupID: GroupID(), date: Date(), merchant: "Hilltop",
                                  amount: Money(minorUnits: -4000))
        let question = PendingDelete.entry(hilltop, budget: eatingOut, group: groupName, shared: false)
        run.rightClick(run.entryRow("Hilltop"), "the Hilltop row")
        XCTAssertTrue(run.menuItem(MainScreen.Words.edit).waitForExistence(timeout: 5),
                      "no Edit… in the row's menu. Menu items on screen: \(run.visibleMenuItems())")
        run.clickMenuItem(MainScreen.Words.delete)
        XCTAssertTrue(run.app.staticTexts[question.title].waitForExistence(timeout: 5),
                      "no question. On screen: \(run.visibleTexts())")
        try XCTUnwrap(run.dialogButton(MainScreen.Words.cancel), "no Cancel on the question").click()
        XCTAssertTrue(run.entryRow("Hilltop").waitForExistence(timeout: 5), "Cancel deleted it")

        // 7. Delete… in the sheet asks the same question. Delete takes the
        // row, and the bar at the top says what went.
        run.clickRow("Hilltop")
        run.click(AccessibilityID.entryDelete)
        XCTAssertTrue(run.app.staticTexts[question.title].waitForExistence(timeout: 5),
                      "no question over the sheet. On screen: \(run.visibleTexts())")
        try XCTUnwrap(run.dialogButton(question.confirmLabel), "no Delete on the question").click()
        run.expectNoSheet()
        XCTAssertTrue(run.rowIsGone("Hilltop"), "Delete left the row")
        let bar = UndoOffer.Words.deleted("Hilltop", "$40.00")
        XCTAssertTrue(run.app.staticTexts[bar].waitForExistence(timeout: 5), "no Undo bar. On screen: \(run.visibleTexts())")

        // 8. Command-Z leaves the delete alone: the bar is the only undo.
        run.app.typeKey("z", modifierFlags: .command)
        XCTAssertFalse(run.entryRow("Hilltop").waitForExistence(timeout: 2), "Command-Z brought it back")
        XCTAssertTrue(run.app.staticTexts[bar].exists, "Command-Z took the bar away")

        // 9. Undo brings it back, as it was, and the bar goes.
        run.click(AccessibilityID.undoButton)
        XCTAssertTrue(run.entryRow("Hilltop").waitForExistence(timeout: 10), "Undo did not bring it back")
        XCTAssertTrue(run.listText("$40.00").waitForExistence(timeout: 5),
                      "the row says $40.00. On screen: \(run.visibleTexts())")
        XCTAssertTrue(run.wait(for: run.element(AccessibilityID.undoBar), until: "exists == false", timeout: 5),
                      "the bar stayed after Undo")

        // 10. Delete… in the row's menu, confirmed, deletes it.
        run.rightClick(run.entryRow("Hilltop"), "the Hilltop row")
        run.clickMenuItem(MainScreen.Words.delete)
        try XCTUnwrap(run.dialogButton(question.confirmLabel), "no Delete on the question").click()
        XCTAssertTrue(run.rowIsGone("Hilltop"), "the menu's Delete… left the row")

        // 11. Tidy: the group goes for everyone, and the session ends.
        run.deleteGroup(named: groupName)
        run.signOut()
    }

    // MARK: - A row you can't change

    @MainActor
    func testARowYouCannotChangeOpensReadOnly() async throws {
        let accounts = try TestAccounts.fromEnvironment()
        let run = try TestApp()
        Self.dataRootPath = run.dataRoot.path
        let second = try SecondAccount(server: accounts.server)
        let stamp = Self.stamp()
        let groupName = "UI Locked \(stamp)", budget = "Bulk \(stamp)"

        // 1. The second account, with no window, makes a group with a budget
        // and Costco in it, and a link that invites at Add.
        try await second.signIn(email: accounts.secondEmail, password: accounts.secondPassword)
        let link = try await second.shareNewGroup(groupName, budget: budget, entry: "Costco",
                                                  amount: Money(minorUnits: 2863), myName: "Leslie", role: .add)

        // 2. The window joins with the link, which takes the group in.
        run.launch()
        try run.signIn(email: accounts.email, password: accounts.password, server: accounts.server)
        run.join(link.url, as: "Robin")
        run.openBudget(named: budget)
        run.syncNow()

        // 3. A click opens Costco read-only: plain text, the line saying
        // why, and only Done.
        run.clickRow("Costco")
        let line = EntryAccess.someoneElses(name: "Leslie").line ?? ""
        XCTAssertTrue(run.element(AccessibilityID.entryDone).waitForExistence(timeout: 10),
                      "no read-only sheet. On screen: \(run.visibleTexts())")
        XCTAssertTrue(run.app.staticTexts[line].exists, "no line saying why. On screen: \(run.visibleTexts())")
        XCTAssertEqual(run.text(of: run.element(AccessibilityID.entryDetail(EntryEditor.Words.merchant))), "Costco")
        XCTAssertFalse(run.element(AccessibilityID.entryMerchant).exists, "a field, not plain text")
        XCTAssertFalse(run.element(AccessibilityID.entrySave).exists, "Save on a read-only sheet")
        XCTAssertFalse(run.element(AccessibilityID.entryDelete).exists, "Delete… on a read-only sheet")
        run.click(AccessibilityID.entryDone)
        run.expectNoSheet()

        // 4. Its row has no menu.
        run.rightClick(run.entryRow("Costco"), "the Costco row")
        XCTAssertFalse(run.menuItem(MainScreen.Words.edit).waitForExistence(timeout: 3),
                       "Edit… on a row this person can't change")
        XCTAssertFalse(run.menuItem(MainScreen.Words.delete).exists, "Delete… on a row this person can't change")
        run.app.typeKey(.escape, modifierFlags: [])

        // 5. Tidy: the second account deletes its group, and both sessions end.
        await second.deleteGroup(named: groupName)
        run.signOut()
        await second.cleanUp()
    }

    // MARK: - Importing again after a delete

    @MainActor
    func testImportingAgainLeavesADeletedLineDeleted() throws {
        let accounts = try TestAccounts.fromEnvironment()
        let run = try TestApp()
        Self.dataRootPath = run.dataRoot.path
        let stamp = Self.stamp()
        let groupName = "UI Import \(stamp)"
        let groceries = "Groceries \(stamp)", eatingOut = "Eating out \(stamp)"
        let joes = "TRADER JOES #123", bakery = "CORNER BAKERY"
        let statement = try run.writeStatement([(joes, "-54.20"), (bakery, "-12.00")])
        let alreadyImported = ImportReviewScreen.Words.alreadyImported
        let needsBudget = ImportReviewScreen.Words.needsBudget
        let line = Transaction(budgetID: BudgetID(), groupID: GroupID(), date: Date(), merchant: "Corner Bakery",
                               amount: Money(minorUnits: -1200))
        let question = PendingDelete.entry(line, budget: groceries, group: groupName, shared: false)

        // 1. Signed in, a group with two budgets, and both lines of a
        // statement filed in Groceries.
        run.launch()
        try run.signIn(email: accounts.email, password: accounts.password, server: accounts.server)
        run.addGroup(named: groupName)
        run.addBudget(named: eatingOut, amount: "200", inGroup: groupName)
        run.addBudget(named: groceries, amount: "500", inGroup: groupName)
        run.importStatement(at: statement)
        run.choose(groceries, in: AccessibilityID.importLineBudget(joes))
        run.choose(groceries, in: AccessibilityID.importLineBudget(bakery))
        run.click(AccessibilityID.importConfirm)
        XCTAssertTrue(run.entryRow("Trader Joes").waitForExistence(timeout: 10), "the first line is not in Groceries")
        XCTAssertTrue(run.entryRow("Corner Bakery").waitForExistence(timeout: 10), "the second line is not in Groceries")

        // 2. One line deleted, from its sheet.
        run.clickRow("Corner Bakery")
        run.click(AccessibilityID.entryDelete)
        XCTAssertTrue(run.app.staticTexts[question.title].waitForExistence(timeout: 5),
                      "no question. On screen: \(run.visibleTexts())")
        try XCTUnwrap(run.dialogButton(question.confirmLabel), "no Delete on the question").click()
        XCTAssertTrue(run.rowIsGone("Corner Bakery"), "the line was not deleted")

        // 3. Imported again: the deleted line counts as imported, the import
        // finishes with no error, and the line stays gone.
        run.importStatement(at: statement)
        XCTAssertTrue(run.wait(for: run.element(AccessibilityID.importLineStatus(bakery)), holds: alreadyImported,
                               timeout: 5), "the deleted line is offered again")
        run.click(AccessibilityID.importConfirm)
        XCTAssertFalse(run.app.staticTexts[MainScreen.Words.errorTitle].waitForExistence(timeout: 3),
                       "the import stopped with an error. On screen: \(run.visibleTexts())")
        XCTAssertTrue(run.rowIsGone("Corner Bakery"), "the deleted line came back")
        XCTAssertTrue(run.entryRow("Trader Joes").exists)

        // 4. With Groceries deleted, both lines are offered again, and file
        // in Eating out.
        run.deleteBudget(named: groceries)
        run.openBudget(named: eatingOut)
        run.importStatement(at: statement)
        for bank in [joes, bakery] {
            XCTAssertTrue(run.wait(for: run.element(AccessibilityID.importLineStatus(bank)), holds: needsBudget,
                                   timeout: 5), "\(bank) is not offered again")
            run.choose(eatingOut, in: AccessibilityID.importLineBudget(bank))
        }
        run.click(AccessibilityID.importConfirm)
        XCTAssertFalse(run.app.staticTexts[MainScreen.Words.errorTitle].waitForExistence(timeout: 3),
                       "the import stopped with an error. On screen: \(run.visibleTexts())")
        XCTAssertTrue(run.entryRow("Trader Joes").waitForExistence(timeout: 10), "the first line is not in Eating out")
        XCTAssertTrue(run.entryRow("Corner Bakery").waitForExistence(timeout: 10),
                      "the second line is not in Eating out")

        // 5. Tidy: the group goes for everyone, and the session ends.
        run.deleteGroup(named: groupName)
        run.signOut()
    }

    /// Part of each name, so runs never share one.
    private static func stamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: Date())
    }
}
