import Foundation
import UIKit
import XCTest
import WellSpentAppCore
import WellSpentCrypto
import WellSpentModel
import WellSpentSync

/// Money and data with two people in one group, on a phone, signed in:
/// entries reaching the other person, an entry changed or deleted by someone
/// else while it is open, a move down while it is open or before an Undo, a
/// change that lost to a newer one, a statement one person imported counting
/// for the other, and deleting a group for everyone against leaving it.
/// Leslie, and Robin's other device, have no window: each is a coordinator
/// inside this process, against the same staging server
/// (SecondAccountSteps.swift).
///
/// Needs the four WELLSPENT_UI_TEST_ variables (see UITestAccounts.swift)
/// and skips without them. Both accounts must exist on staging with their
/// addresses confirmed. Runs in light only, as every signed-in class does,
/// and takes the shared sign-in lock (make iphone-ui-test). Each test makes a
/// group of its own, named with the time, and deletes it at the end.
final class PhoneSharedEntriesTests: XCTestCase {
    nonisolated(unsafe) private static var dataRootPath: String?
    nonisolated(unsafe) private static var statementsPath: String?

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    /// No await in it, as in PhoneSignInSyncTests. A halted run can leave a
    /// group named "UI Phone <time>" on staging, which a later run clears.
    override func tearDown() {
        let app = XCUIApplication()
        if app.state != .notRunning { app.terminate() }
        for path in [Self.dataRootPath, Self.statementsPath].compactMap({ $0 }) {
            try? FileManager.default.removeItem(atPath: path)
        }
        Self.dataRootPath = nil
        Self.statementsPath = nil
        UIPasteboard.general.items = []
        super.tearDown()
    }

    // MARK: - Robin's group, shared with Leslie

    @MainActor
    func testEntriesReachTheOtherAndOneDeletedWhileOpenStaysDeleted() async throws {
        let accounts = try TestAccounts.fromEnvironment()
        let run = PhoneTestApp()
        Self.dataRootPath = run.dataRoot.path
        let leslie = try SecondAccount(server: accounts.server)
        let robinsOtherDevice = try SecondAccount(server: accounts.server, settingsSuite: "app.wellspent.uitest.robin")
        let stamp = PhoneTestApp.stamp()
        let groupName = SecondAccount.phoneRunPrefix + stamp
        let budget = "Groceries \(stamp)"
        run.launch()
        try run.signIn(email: accounts.email, password: accounts.password, server: accounts.server)
        run.addGroup(named: groupName)
        run.addBudget(named: budget, amount: "500", inGroup: groupName)
        run.addEntry(merchant: "Bakery", amount: "4.00")

        // Scenario SHARE-14
        // 1. Before anyone else is in the group, a row says nothing of who
        // added it.
        XCTAssertFalse(run.row("Bakery", says: "You", timeout: 2),
                       "an unshared group's row says who added it: \(run.rowLabel("Bakery"))")
        run.goBack()

        // Scenario SHARE-14
        // 2. Leslie joins at Add and adds Costco, $99.00. Pulling Home down
        // brings it in, with Leslie on its row and You on Robin's own. The
        // total counts it on both their screens.
        let link = try run.shareAndCopyLink(groupName, as: "Robin")
        try await leslie.signIn(email: accounts.secondEmail, password: accounts.secondPassword)
        await leslie.deleteLeftoverRuns()
        _ = try await leslie.join(link, as: "Leslie")
        try await leslie.addEntry("Costco", amount: Money(minorUnits: -9900), inBudget: budget, group: groupName)
        run.syncAndWait()
        run.scrollTo(AccessibilityID.sidebarBudget(budget))
        run.openBudget(named: budget)
        XCTAssertTrue(run.row("Costco", says: "Leslie", timeout: 20),
                      "Leslie's Costco did not arrive with her name. The row says: \(run.rowLabel("Costco"))")
        // The model writes "You" for this person's own entries.
        XCTAssertTrue(run.row("Bakery", says: "You"), "Robin's own row does not say You: \(run.rowLabel("Bakery"))")
        XCTAssertTrue(run.figure(MoneyWheel.Words.spent, is: "$103.00"), "Spent is not $103.00. On screen: \(run.visibleTexts())")
        let lesliesBudget = try leslie.budget(named: budget, inGroup: groupName)
        try await leslie.syncAll()
        XCTAssertEqual(AppModel(store: leslie.sync.store).summary(for: lesliesBudget.id)?.spent.minorUnits, 10_300,
                       "Leslie's total is not $103.00")

        // Scenario EDIT-12
        // 3. Robin moves Leslie up to Manage. Bakery is open on the phone
        // with a new amount typed, and Leslie deletes it. After the sync,
        // Save saves nothing: the sheet turns read-only, says Leslie deleted
        // it while it was open, and offers Done alone. Bakery stays deleted.
        run.goBack()
        run.openGroupPage(named: groupName)
        run.tap(AccessibilityID.groupPerson("Leslie"))
        let manage = run.app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@",
                                                          MembersScreen.Words.levelTitle(.manage))).firstMatch
        XCTAssertTrue(manage.waitForExistence(timeout: 15), "no Manage on Leslie's page. On screen: \(run.visibleButtons())")
        run.waitUntilHittable(manage, "Manage")
        manage.tap()
        XCTAssertTrue(run.wait(for: run.app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@",
                                                                         MembersScreen.Words.levelTitle(.manage))).firstMatch,
                               until: "selected == true", timeout: 20), "Leslie is not at Manage")
        run.goBack()
        run.goBack()
        run.openBudget(named: budget)
        run.openEntry("Bakery")
        run.clearField(AccessibilityID.entryAmount)
        run.type("6.00", into: AccessibilityID.entryAmount)
        try await leslie.syncAll()
        try await leslie.deleteEntry("Bakery", inGroup: groupName)
        run.syncFromTheBackground()
        run.tap(AccessibilityID.entrySave)
        XCTAssertTrue(run.shows(EntryEditor.Words.deleted(by: .someone(name: "Leslie"))),
                      "the sheet does not say Leslie deleted it. On screen: \(run.visibleTexts())")
        XCTAssertTrue(run.button(AccessibilityID.entryDone).exists, "no Done")
        XCTAssertFalse(run.element(AccessibilityID.entrySave).exists, "Save is still offered")
        run.tap(AccessibilityID.entryDone)
        run.expectNoSheet()
        XCTAssertFalse(run.element(AccessibilityID.entryRow("Bakery")).waitForExistence(timeout: 3), "Bakery came back")

        // Scenario EDIT-12
        // 4. Bread is open with a new amount typed, and Leslie changes its
        // note instead. Save keeps her note and takes Robin's amount.
        run.addEntry(merchant: "Bread", amount: "5.00")
        run.syncFromTheBackground()
        let lesliesBreadCame = try await leslie.syncUntilEntry("Bread", inGroup: groupName)
        XCTAssertTrue(lesliesBreadCame, "Leslie never got the phone's Bread")
        run.openEntry("Bread")
        run.clearField(AccessibilityID.entryAmount)
        run.type("7.00", into: AccessibilityID.entryAmount)
        try await leslie.changeEntry("Bread", inGroup: groupName, note: "from Leslie")
        run.syncFromTheBackground()
        run.tap(AccessibilityID.entrySave)
        run.expectNoSheet()
        run.openEntry("Bread")
        XCTAssertEqual(run.fieldText(AccessibilityID.entryNote), "from Leslie", "Leslie's note was lost")
        XCTAssertEqual(run.fieldText(AccessibilityID.entryAmount), "7.00", "Robin's amount was lost")
        run.tap(AccessibilityID.entryCancel)
        run.expectNoSheet()

        // Scenario EDIT-12
        // 5. Bread is open again, and Robin deletes it on his other device.
        // The sheet says he deleted it on another computer.
        run.openEntry("Bread")
        run.clearField(AccessibilityID.entryAmount)
        run.type("8.00", into: AccessibilityID.entryAmount)
        try await robinsOtherDevice.signIn(email: accounts.email, password: accounts.password)
        try await robinsOtherDevice.deleteEntry("Bread", inGroup: groupName)
        run.syncFromTheBackground()
        run.tap(AccessibilityID.entrySave)
        XCTAssertTrue(run.shows(EntryEditor.Words.deleted(by: .you)),
                      "the sheet does not say he deleted it elsewhere. On screen: \(run.visibleTexts())")
        run.tap(AccessibilityID.entryDone)
        run.expectNoSheet()
        run.goBack()

        // Scenario BUDGET-12
        // 6. The owner's Delete on a shared group asks first, and says it goes
        // for everyone, with its budget and transactions.
        try await leslie.syncAll()
        let transactions = AppModel(store: leslie.sync.store).transactionCount(inGroup: try leslie.group(named: groupName).id)
        run.longPress(AccessibilityID.sidebarGroup(groupName))
        run.tapMenuItem(MainScreen.Words.delete)
        let question = PendingDelete.group(BudgetGroup(name: groupName), budgets: 1, transactions: transactions,
                                           reach: .everyone)
        XCTAssertTrue(run.text(question.title).waitForExistence(timeout: 5), "no question. On screen: \(run.visibleTexts())")
        XCTAssertTrue(run.text(question.message).exists, "the question's words are wrong. On screen: \(run.visibleTexts())")
        try XCTUnwrap(run.questionButton(question.confirmLabel)).tap()
        XCTAssertTrue(run.wait(for: run.element(AccessibilityID.sidebarGroup(groupName)), until: "exists == false",
                               timeout: 10), "the group is still on Home")

        // 7. Tidy: the delete is on the server before every session ends.
        run.syncAndWait()
        run.signOut()
        await robinsOtherDevice.cleanUp()
        await leslie.cleanUp()
    }

    // MARK: - Leslie's group, and moves down

    @MainActor
    func testMovesDownStopAnOpenSaveAnUndoAndChangeTheLeaveQuestion() async throws {
        let accounts = try TestAccounts.fromEnvironment()
        let run = PhoneTestApp()
        Self.dataRootPath = run.dataRoot.path
        // A long Undo bar, so the steps between a delete and its Undo fit.
        run.app.launchEnvironment[Workspace.undoWindowVariable] = "600"
        let leslie = try SecondAccount(server: accounts.server)
        let stamp = PhoneTestApp.stamp()
        let groupName = SecondAccount.phoneRunPrefix + stamp
        let budget = "Costs \(stamp)"
        run.launch()
        try run.signIn(email: accounts.email, password: accounts.password, server: accounts.server)
        try await leslie.signIn(email: accounts.secondEmail, password: accounts.secondPassword)
        await leslie.deleteLeftoverRuns()
        let link = try await leslie.shareNewGroup(groupName, budget: budget, entry: "Costco",
                                                  amount: Money(minorUnits: 9900), myName: "Leslie", role: .manage)
        run.join(link, as: "Robin")
        run.scrollTo(AccessibilityID.sidebarBudget(budget))
        run.openBudget(named: budget)
        XCTAssertTrue(run.element(AccessibilityID.entryRow("Costco")).waitForExistence(timeout: 20),
                      "Leslie's Costco is not in the list. On screen: \(run.visibleTexts())")

        // Scenario EDIT-13
        // 1. Robin, at Manage, has Leslie's Costco open with a new amount
        // typed, and Leslie moves him down to View. After the sync, Save saves
        // nothing: the sheet turns read-only, shows Costco as it was, and
        // says why.
        run.openEntry("Costco")
        run.clearField(AccessibilityID.entryAmount)
        run.type("80.00", into: AccessibilityID.entryAmount)
        try await leslie.setLevelOfTheOther(.read, in: groupName)
        run.syncFromTheBackground()
        run.tap(AccessibilityID.entrySave)
        XCTAssertTrue(run.shows(EntryEditor.Words.notAllowed(.viewOnly)),
                      "the sheet does not say why at View. On screen: \(run.visibleTexts())")
        XCTAssertEqual(run.element(AccessibilityID.entryDetail(EntryEditor.Words.amount)).value as? String, "$99.00",
                       "the sheet shows what was typed, not Costco as it was")
        XCTAssertFalse(run.element(AccessibilityID.entrySave).exists, "Save is still offered")
        run.tap(AccessibilityID.entryDone)
        run.expectNoSheet()

        // Scenario EDIT-13
        // 2. The same at Manage again, moved down to Add instead: it says only
        // Leslie, or a manager, can change it.
        try await leslie.setLevelOfTheOther(.manage, in: groupName)
        run.syncFromTheBackground()
        run.openEntry("Costco")
        run.clearField(AccessibilityID.entryAmount)
        run.type("80.00", into: AccessibilityID.entryAmount)
        try await leslie.setLevelOfTheOther(.write, in: groupName)
        run.syncFromTheBackground()
        run.tap(AccessibilityID.entrySave)
        XCTAssertTrue(run.shows(EntryEditor.Words.notAllowed(.someoneElses(name: "Leslie"))),
                      "the sheet does not say why at Add. On screen: \(run.visibleTexts())")
        run.tap(AccessibilityID.entryDone)
        run.expectNoSheet()

        // Scenario EDIT-09
        // 3. At Manage, Robin deletes Leslie's Hilltop, and before he presses
        // Undo a sync brings his move down to View. Undo brings nothing back,
        // the bar goes, and the app says why.
        try await leslie.setLevelOfTheOther(.manage, in: groupName)
        try await leslie.addEntry("Hilltop", amount: Money(minorUnits: -1500), inBudget: budget, group: groupName)
        run.syncThroughHome(reopening: budget)
        try run.deleteEntryKeepingTheBar("Hilltop")
        // The delete reaches the server first: a move down before it would
        // refuse the delete itself, and leave nothing to undo.
        run.syncThroughHome(reopening: budget)
        try await leslie.setLevelOfTheOther(.read, in: groupName)
        run.syncThroughHome(reopening: budget)
        run.tap(AccessibilityID.undoButton)
        try run.expectAlert(saying: UndoOffer.Words.refused(.viewOnly))
        XCTAssertFalse(run.element(AccessibilityID.undoBar).exists, "the bar stayed")
        XCTAssertFalse(run.element(AccessibilityID.entryRow("Hilltop")).waitForExistence(timeout: 3), "Hilltop came back")

        // Scenario EDIT-09
        // 4. The same, moved down to Add instead: only Leslie, or a manager,
        // can change it.
        try await leslie.setLevelOfTheOther(.manage, in: groupName)
        try await leslie.addEntry("Hilltop Two", amount: Money(minorUnits: -1600), inBudget: budget, group: groupName)
        run.syncThroughHome(reopening: budget)
        try run.deleteEntryKeepingTheBar("Hilltop Two")
        run.syncThroughHome(reopening: budget)
        try await leslie.setLevelOfTheOther(.write, in: groupName)
        run.syncThroughHome(reopening: budget)
        run.tap(AccessibilityID.undoButton)
        try run.expectAlert(saying: UndoOffer.Words.refused(.someoneElses(name: "Leslie")))
        run.goBack()

        // Scenario BUDGET-13
        // 5. At View, Leave asks first, and leaves out the two sentences about
        // changes, since he has none to send. Cancel keeps the group.
        try await leslie.setLevelOfTheOther(.read, in: groupName)
        run.syncUntilTheLevel(allowsAdding: false, in: budget)
        try await leslie.syncAll()
        let transactions = AppModel(store: leslie.sync.store).transactionCount(inGroup: try leslie.group(named: groupName).id)
        let leave = PendingDelete.group(BudgetGroup(name: groupName), budgets: 1, transactions: transactions,
                                        reach: .thisMacOnly)
        run.longPress(AccessibilityID.sidebarGroup(groupName))
        run.tapMenuItem(MainScreen.Words.leave)
        XCTAssertTrue(run.text(leave.title).waitForExistence(timeout: 5), "no question. On screen: \(run.visibleTexts())")
        XCTAssertTrue(run.text(leave.message(sendsChanges: false)).waitForExistence(timeout: 5),
                      "at View the question still speaks of changes. On screen: \(run.visibleTexts())")
        run.cancelQuestion()

        // Scenario BUDGET-13
        // 6. At Add, the question says the whole of it, with Leave and Cancel.
        // Leave takes the group off Robin's phone, and Leslie keeps it.
        try await leslie.setLevelOfTheOther(.write, in: groupName)
        run.syncUntilTheLevel(allowsAdding: true, in: budget)
        run.longPress(AccessibilityID.sidebarGroup(groupName))
        run.tapMenuItem(MainScreen.Words.leave)
        XCTAssertTrue(run.text(leave.message(sendsChanges: true)).waitForExistence(timeout: 5),
                      "the question's words are wrong. On screen: \(run.visibleTexts())")
        try XCTUnwrap(run.questionButton(leave.confirmLabel), "no Leave").tap()
        XCTAssertTrue(run.wait(for: run.element(AccessibilityID.sidebarGroup(groupName)), until: "exists == false",
                               timeout: 10), "the group is still on Home")
        let alone = try await leslie.waitForMembers(1, in: groupName)
        XCTAssertTrue(alone, "the server still lists Robin in Leslie's group")
        XCTAssertNoThrow(try leslie.group(named: groupName), "Leslie lost the group")

        // 7. Tidy.
        run.signOut()
        await leslie.deleteGroup(named: groupName)
        await leslie.cleanUp()
    }

    // MARK: - Leslie's group, imports and a change that lost

    @MainActor
    func testAnImportCountsForTheOtherAndAChangeThatLostIsNoted() async throws {
        let accounts = try TestAccounts.fromEnvironment()
        let joes = "TRADER JOES #123", bakery = "CORNER BAKERY"
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("wellspent-shared-statements-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        Self.statementsPath = folder.path
        let dates = DateFormatter()
        dates.locale = Locale(identifier: "en_US_POSIX")
        dates.dateFormat = "MM/dd/yyyy"
        let day = dates.string(from: Date())
        let statement = folder.appendingPathComponent("statement.csv")
        try "Date,Description,Amount\n\(day),\"\(joes)\",-54.20\n\(day),\"\(bakery)\",-12.00\n"
            .write(to: statement, atomically: true, encoding: .utf8)
        let run = PhoneTestApp()
        Self.dataRootPath = run.dataRoot.path
        run.app.launchEnvironment[UITestStatement.variable] = statement.path
        let leslie = try SecondAccount(server: accounts.server)
        let stamp = PhoneTestApp.stamp()
        let groupName = SecondAccount.phoneRunPrefix + stamp
        let budget = "Costs \(stamp)"
        run.launch()
        try run.signIn(email: accounts.email, password: accounts.password, server: accounts.server)
        try await leslie.signIn(email: accounts.secondEmail, password: accounts.secondPassword)
        await leslie.deleteLeftoverRuns()
        let link = try await leslie.shareNewGroup(groupName, budget: budget, entry: "Costco",
                                                  amount: Money(minorUnits: 9900), myName: "Leslie", role: .manage)

        // Scenario IMPORT-10, IMPORT-08
        // 1. Leslie imports statement.csv into the budget, then deletes Corner
        // Bakery. Robin joins, and her Trader Joes shows in his list, added by
        // Leslie, from a statement.
        try await leslie.importStatement(statement, into: budget, group: groupName)
        try await leslie.deleteEntry("Corner Bakery", inGroup: groupName)
        run.join(link, as: "Robin")
        run.scrollTo(AccessibilityID.sidebarBudget(budget))
        run.openBudget(named: budget)
        XCTAssertTrue(run.row("Trader Joes", says: "Leslie", timeout: 20),
                      "Leslie's Trader Joes did not arrive. The row says: \(run.rowLabel("Trader Joes"))")
        XCTAssertTrue(run.row("Trader Joes", says: "Statement"), "the row does not say Statement: \(run.rowLabel("Trader Joes"))")
        let counted = run.transactionCount()

        // Scenario IMPORT-10, IMPORT-08
        // 2. Robin imports the same statement: every line says Already
        // imported, the one Leslie deleted too. Import ends with no error, and
        // Corner Bakery stays deleted.
        run.importStatement()
        XCTAssertEqual([run.status(of: joes), run.status(of: bakery)],
                       [ImportReviewScreen.Words.alreadyImported, ImportReviewScreen.Words.alreadyImported])
        run.tap(AccessibilityID.importConfirm)
        run.waitForTheReviewToClose()
        XCTAssertFalse(run.app.alerts.firstMatch.waitForExistence(timeout: 3), "the import ended in an error")
        XCTAssertFalse(run.waitForTransactionCount(counted + 1, timeout: 5), "the import added something. The page says: \(run.countLine())")
        XCTAssertTrue(run.waitForTransactionCount(counted, timeout: 1), "the count changed. The page says: \(run.countLine())")
        XCTAssertFalse(run.element(AccessibilityID.entryRow("Corner Bakery")).waitForExistence(timeout: 5), "Corner Bakery came back")

        // Scenario EDIT-14
        // 3. Robin has his Bread open, and Leslie's change to its amount
        // reaches the server first. His own change to the amount does not go
        // through: the row shows Leslie's version with the quiet line, the
        // sheet says so when opened, and the line goes then. Leslie sees no
        // note. (Changes to different fields both go in, as EDIT-12 says.)
        run.addEntry(merchant: "Bread", amount: "5.00")
        run.syncFromTheBackground()
        let lesliesBreadCame = try await leslie.syncUntilEntry("Bread", inGroup: groupName)
        XCTAssertTrue(lesliesBreadCame, "Leslie never got the phone's Bread")
        run.openEntry("Bread")
        run.clearField(AccessibilityID.entryAmount)
        run.type("6.00", into: AccessibilityID.entryAmount)
        try await leslie.changeEntry("Bread", inGroup: groupName, amount: "60.00")
        run.tap(AccessibilityID.entrySave)
        run.expectNoSheet()
        XCTAssertTrue(run.row("Bread", says: BudgetScreen.Words.notice, timeout: 30),
                      "no line saying the change didn't go through. The row says: \(run.rowLabel("Bread"))")
        XCTAssertTrue(run.row("Bread", says: "$60.00"), "the row does not show Leslie's version: \(run.rowLabel("Bread"))")
        run.openEntry("Bread")
        XCTAssertTrue(run.shows(EntryEditor.Words.notice), "the sheet does not say so. On screen: \(run.visibleTexts())")
        run.tap(AccessibilityID.entryCancel)
        run.expectNoSheet()
        XCTAssertFalse(run.row("Bread", says: BudgetScreen.Words.notice, timeout: 2), "the row's line stayed after opening")
        try await leslie.syncAll()
        let lesliesBread = try leslie.entry("Bread", inGroup: groupName)
        let lesliesEditor = try XCTUnwrap(EntryEditor(model: AppModel(store: leslie.sync.store), entry: lesliesBread.id),
                                          "Leslie's Bread does not open")
        XCTAssertNil(lesliesEditor.noticeLine, "Leslie sees a note")

        // Scenario EDIT-14
        // 4. The server refusing his change shows the same line: Robin, at
        // Manage, changes Leslie's Costco after he was moved down to Add, and
        // before his phone has heard of it. His Save goes to the server, which
        // refuses it.
        run.openEntry("Costco")
        run.clearField(AccessibilityID.entryAmount)
        run.type("80.00", into: AccessibilityID.entryAmount)
        try await leslie.setLevelOfTheOther(.write, in: groupName)
        run.tap(AccessibilityID.entrySave)
        run.expectNoSheet()
        XCTAssertTrue(run.row("Costco", says: BudgetScreen.Words.notice, timeout: 30),
                      "no line after the refused change. The row says: \(run.rowLabel("Costco"))")
        run.goBack()

        // 5. Tidy.
        run.signOut()
        await leslie.deleteGroup(named: groupName)
        await leslie.cleanUp()
    }
}

/// The steps these tests take, beside the ones every iPhone test shares.
extension PhoneTestApp {
    /// Sends the app to the background and brings it back, which syncs, as
    /// coming to the front does on a phone, even with a sheet open. Then
    /// waits until a sync has ended since it came back: the staging banner's
    /// value is when the last one ended, the only sign of it with a sheet open.
    func syncFromTheBackground() {
        XCUIDevice.shared.press(.home)
        Thread.sleep(forTimeInterval: 1)
        let back = Date().timeIntervalSince1970
        app.activate()
        XCTAssertTrue(element(AccessibilityID.stagingBanner).waitForExistence(timeout: 15), "the app did not come back")
        waitForASync(endingAfter: back)
    }

    /// Back to Home, a pull down, and a wait until the sync line says it has
    /// ended, then the budget again. For a step that needs a whole sync
    /// before it goes on, where the open budget shows no sign of one. The
    /// Undo bar after a delete comes back with the budget.
    func syncThroughHome(reopening budget: String) {
        goBack()
        XCTAssertTrue(element(AccessibilityID.sidebarAdd).waitForExistence(timeout: 10), "not back on Home")
        syncAndWait()
        scrollTo(AccessibilityID.sidebarBudget(budget))
        openBudget(named: budget)
    }

    /// Joins a group by tapping its link, then goes back to Home.
    func join(_ link: InviteLink, as name: String) {
        open(link: link.url)
        type(name, into: AccessibilityID.invitationName)
        tap(AccessibilityID.invitationJoin)
        XCTAssertTrue(element(AccessibilityID.groupSummary).waitForExistence(timeout: 20),
                      "no group page after Join. On screen: \(visibleTexts())")
        goBack()
        XCTAssertTrue(element(AccessibilityID.sidebarAdd).waitForExistence(timeout: 10), "not back on Home")
    }

    /// Shares the group through the Share sheet and the iPhone's share sheet,
    /// and reads the link back from Join a Group, where Copy put it.
    func shareAndCopyLink(_ group: String, as name: String) throws -> InviteLink {
        scrollTo(AccessibilityID.sidebarGroup(group))
        longPress(AccessibilityID.sidebarGroup(group))
        tapMenuItem(MainScreen.Words.share)
        type(name, into: AccessibilityID.shareName)
        tap(AccessibilityID.shareCreate)
        copyInShareSheet()
        XCTAssertTrue(wait(for: text(ShareScreen.Words.shareTitle(group)), until: "exists == false", timeout: 30),
                      "the Share sheet stayed after Copy")
        openAddMenu()
        tapMenuItem(MainScreen.Words.join)
        pasteCopied(into: AccessibilityID.joinLink)
        let pasted = (element(AccessibilityID.joinLink).value as? String) ?? ""
        tap(AccessibilityID.joinCancel)
        return try XCTUnwrap(InviteLink(parsing: pasted), "the copied text is not an invite link")
    }

    /// Deletes an entry from its sheet, answering the question Delete, and
    /// waits for the Undo bar.
    func deleteEntryKeepingTheBar(_ merchant: String) throws {
        openEntry(merchant)
        tap(AccessibilityID.entryDelete)
        answer("Delete")
        expectNoSheet()
        XCTAssertTrue(element(AccessibilityID.undoBar).waitForExistence(timeout: 10), "no Undo bar after the delete")
    }

    /// The app's alert, with these words, then OK.
    func expectAlert(saying words: String) throws {
        let alert = app.alerts.firstMatch
        XCTAssertTrue(alert.waitForExistence(timeout: 10), "no alert. On screen: \(visibleTexts())")
        XCTAssertTrue(alert.staticTexts[words].exists, "the alert does not say \(words). It says: \(alert.label) \(visibleTexts())")
        alert.buttons[MainScreen.Words.ok].tap()
    }
}
