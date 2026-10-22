import AppKit
import Foundation
import XCTest
import WellSpentAppCore
import WellSpentCrypto
import WellSpentModel
import WellSpentSync

/// Who may do what, in the real window: what Robin sees and may do at each
/// level in groups Leslie made, and in a group of his own. Leslie has no
/// window: she makes the groups and their links, adds, changes, deletes and
/// imports, and moves Robin up and down, as in EntryEditingTests.
///
/// Four tests, each signed in once on each side, so a failure in one
/// leaves the others to run:
/// - Leslie's group with a link at Manage: a change of Robin's that lost to
///   hers, an entry she deleted while he had it open, his menus and the
///   Share sheet at Manage, and a statement she imported. Then a group of
///   Robin's own: what the one who made it is offered, and deleting it for
///   everyone once Leslie is in it.
/// - Leslie's group with a link at View: what he sees, what he is not
///   offered, and an entry opened read-only. Then her group with a link
///   that shows only what comes after it.
/// - Leslie's group with a link at Add: the Share sheet at Add, an entry
///   open while she moves him down to View from Manage, an entry of his own
///   at View, an Undo she moves him down under, and leaving the group.
/// - Leslie's group with a link at Add: his menus at Add, and once she
///   moves him up to Manage.
///
/// The window syncs on its own two minutes after it opens, and two minutes
/// after each of those syncs ends. The first test keeps Leslie's change
/// clear of them until Robin has saved his, then waits for one with a sheet
/// open. The third waits for one with a sheet open.
///
/// Needs the four WELLSPENT_UI_TEST_ variables (see UITestSupport.swift) and
/// skips without them. Each test's groups are named with the time and
/// deleted at its end for everyone. Leslie's groups from an earlier run
/// that stopped part way, more than an hour old, are deleted first.
final class WhoMayGapTests: XCTestCase {
    /// The run's data folder, for tearDown.
    nonisolated(unsafe) private static var dataRootPath: String?
    /// Where the second person keeps their settings, for tearDown.
    nonisolated(unsafe) private static var secondSuite: String?
    /// The start of every group's name in this test. It sorts the groups
    /// first in the sidebar, above what other tests leave on the account.
    private static let prefix = "Access "

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    /// Runs after each test, passed or halted, with no await in it. The app
    /// is closed, and nothing of the run stays on this Mac, the clipboard
    /// and the second person's settings included: the Share sheet's name is
    /// pasted. The staging side is tidied at the end of each test itself.
    override func tearDown() {
        let app = XCUIApplication()
        if app.state != .notRunning { app.terminate() }
        TestApp.wipeSettings()
        if let path = Self.dataRootPath { try? FileManager.default.removeItem(atPath: path) }
        Self.dataRootPath = nil
        NSPasteboard.general.clearContents()
        if let suite = Self.secondSuite { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        Self.secondSuite = nil
        super.tearDown()
    }

    // MARK: - At Manage, and in a group of his own

    @MainActor
    func testAtManageAndInAGroupOfHisOwn() async throws {
        let accounts = try TestAccounts.fromEnvironment()
        let run = try TestApp()
        Self.dataRootPath = run.dataRoot.path
        let second = try SecondAccount(server: accounts.server)
        Self.secondSuite = second.suite
        let stamp = Self.stamp()
        let managed = "\(Self.prefix)Manage \(stamp)", bulk = "Bulk \(stamp)"
        let mine = "\(Self.prefix)Own \(stamp)", rent = "Rent \(stamp)"
        let hilltop = "Hilltop Grocery", bakery = "Corner Bakery", market = "Market"
        let share = MainScreen.Words.share, people = MembersScreen.Words.menuItem
        let rename = MainScreen.Words.rename, delete = MainScreen.Words.delete, leave = MainScreen.Words.leave
        let cancel = MainScreen.Words.cancel

        // 1. Leslie, with no window, signs in and deletes any groups an
        // earlier run left on her account. Then she makes a group with a
        // budget and Hilltop Grocery, $142.08, and a link that invites at
        // Manage.
        try await second.signIn(email: accounts.secondEmail, password: accounts.secondPassword)
        await second.deleteLeftovers(startingWith: Self.prefix)
        let manageLink = try await second.shareNewGroup(managed, budget: bulk, entry: hilltop,
                                                        amount: Money(minorUnits: 14208), myName: "Leslie",
                                                        role: .manage)

        // 2. The window, signed in as Robin, joins with the link and opens
        // the budget.
        run.launch()
        let opened = Date()
        try run.signIn(email: accounts.email, password: accounts.password, server: accounts.server)
        run.join(manageLink.url, as: "Robin")
        run.openBudget(named: bulk)
        XCTAssertTrue(run.entryRow(hilltop).waitForExistence(timeout: 60),
                      "Hilltop Grocery did not arrive. On screen: \(run.visibleTexts())")

        // Scenario EDIT-14
        // 3. Robin opens Hilltop Grocery and types a new amount. Meanwhile
        // Leslie's app takes in all his app sent, and she changes its note,
        // then its amount, and her app sends both. He saves before his app
        // has taken either in. Each change carries a count one past the
        // highest its app has seen in the group, and the higher count is the
        // newer change. Her app has seen all of his, so her second change is
        // newer than his. Once his app syncs, the row shows her version,
        // with a quiet line under the merchant saying his change didn't go
        // through. One of the window's timed syncs would take her change in
        // before he saves, so hers waits until none can come first.
        run.clickRow(hilltop)
        run.expectSheet(for: hilltop)
        run.type("150.00", into: AccessibilityID.entryAmount)
        print("WHOMAY step 3 at \(Int(Date().timeIntervalSince(opened))) s")
        try await Self.waitClearOfTheTimedSyncs(afterOpening: opened, for: 45)
        try await second.syncAll()
        try await second.changeEntry(hilltop, inGroup: managed, note: "two loaves")
        try await second.changeEntry(hilltop, inGroup: managed, amount: "124.08")
        run.click(AccessibilityID.entrySave)
        run.expectNoSheet()
        XCTAssertTrue(run.listText(BudgetScreen.Words.notice).waitForExistence(timeout: 60),
                      "no line saying his change didn't go through. On screen: \(run.visibleTexts())")
        run.expectEntry(hilltop, shows: ["two loaves", BudgetScreen.Words.notice, Money(minorUnits: 12408).display])
        XCTAssertFalse(run.listText("$150.00").exists, "his amount stayed. On screen: \(run.visibleTexts())")

        // Scenario EDIT-14
        // 4. Opened, the sheet says his last change didn't go through and
        // this is the version everyone sees. The row's line is gone.
        run.clickRow(hilltop)
        run.expectSheet(for: hilltop)
        XCTAssertTrue(run.wait(for: run.element(AccessibilityID.entryNoticeLine), holds: EntryEditor.Words.notice,
                               timeout: 5), "the sheet does not say his change didn't go through. On screen: "
                      + "\(run.visibleTexts())")
        XCTAssertTrue(run.wait(for: run.element(AccessibilityID.entryAmount), holds: "124.08", timeout: 5),
                      "the sheet does not hold her amount")
        run.click(AccessibilityID.entryCancel)
        run.expectNoSheet()
        XCTAssertTrue(run.wait(for: run.listText(BudgetScreen.Words.notice), until: "exists == false", timeout: 10),
                      "the row's line stayed after the sheet was opened")

        // Scenario EDIT-12
        // 5. Robin opens Hilltop Grocery again and types a new amount.
        // Leslie deletes it meanwhile, and the window's timed sync brings
        // that in while the sheet is open: the row behind the sheet goes.
        // Save then saves nothing. The sheet turns read-only and says Leslie
        // deleted it, with Done as its only button, and it stays deleted.
        run.clickRow(hilltop)
        run.expectSheet(for: hilltop)
        run.type("99.00", into: AccessibilityID.entryAmount)
        try await second.deleteEntry(hilltop, inGroup: managed)
        print("WHOMAY step 5 at \(Int(Date().timeIntervalSince(opened))) s")
        if run.element(AccessibilityID.entryRow(hilltop)).exists {
            print("WHOMAY the list reads behind the sheet")
            XCTAssertTrue(run.rowIsGone(hilltop, timeout: 300),
                          "no sync took the delete in while the sheet was open. On screen: \(run.visibleTexts())")
        } else {
            print("WHOMAY the list does not read behind the sheet")
            try await Self.waitPastTheNextTimedSync(afterOpening: opened)
        }
        run.click(AccessibilityID.entrySave)
        run.expectReadOnly(saying: EntryEditor.Words.deleted(by: .someone(name: "Leslie")))
        run.click(AccessibilityID.entryDone)
        run.expectNoSheet()
        XCTAssertTrue(run.rowIsGone(hilltop, timeout: 5), "Hilltop Grocery came back")

        // Scenario SHARE-12
        // 6. At Manage, the budget has Add and Import statement, and its
        // menu offers Edit… and Delete…. Edit… opens it.
        print("WHOMAY step 6 at \(Int(Date().timeIntervalSince(opened))) s")
        XCTAssertTrue(run.element(AccessibilityID.budgetAdd).exists, "no Add, at Manage")
        XCTAssertTrue(run.element(AccessibilityID.budgetImport).exists, "no Import statement, at Manage")
        run.expectBudgetMenu(bulk, offersChanges: true)

        // Scenario SHARE-12
        // 7. The group's menu offers New Budget in it and Rename…, and its
        // last item is Leave…, not Delete….
        run.expectGroupMenu(managed, offers: [share, people, MainScreen.Words.newBudget(in: managed), rename, leave],
                            last: leave)

        // Scenario SHARE-06
        // 8. Share… lets him invite at View or Add, with Add chosen, and
        // not at Manage.
        run.openShare(managed)
        run.expectRoles([.view, .add], chosen: .add)
        run.click(AccessibilityID.shareCancel)
        XCTAssertTrue(run.wait(for: run.element(AccessibilityID.shareName), until: "exists == false", timeout: 10),
                      "the Share sheet did not close")

        // Scenario IMPORT-10
        // 9. Leslie imports a statement into the budget. Once Robin's app
        // syncs, its lines are in his list, each added by Leslie, from a
        // statement.
        let joes = "TRADER JOES #123", bakeryLine = "CORNER BAKERY"
        let statement = try run.writeStatement([(joes, "-54.20"), (bakeryLine, "-12.00")])
        try await second.importStatement(statement, into: bulk, group: managed)
        run.syncNow()
        for merchant in ["Trader Joes", bakery] {
            XCTAssertTrue(run.entryRow(merchant).waitForExistence(timeout: 60),
                          "\(merchant) did not arrive. On screen: \(run.visibleTexts())")
            run.expectEntry(merchant, shows: ["Leslie", TransactionSource.statement.rawValue.capitalized])
        }

        // Scenario IMPORT-10
        // 10. Robin imports the same statement: every line says Already
        // imported. Cancel adds nothing.
        run.importStatement(at: statement)
        for line in [joes, bakeryLine] {
            XCTAssertTrue(run.wait(for: run.element(AccessibilityID.importLineStatus(line)),
                                   holds: ImportReviewScreen.Words.alreadyImported, timeout: 10),
                          "\(line) is not already imported. On screen: \(run.visibleTexts())")
        }
        run.click(AccessibilityID.importCancel)
        XCTAssertTrue(run.wait(for: run.element(AccessibilityID.importCancel), until: "exists == false", timeout: 10),
                      "the review did not close")

        // Scenario BUDGET-07, ENTRY-10
        // 11. Robin deletes any group of his own an earlier run left, then
        // makes one, with a budget and two transactions. As the one who
        // made it, his budget has Add and Import statement. The group's menu
        // offers Share…, People…, New Budget in it, Rename… and Delete…, and
        // the budget's Edit… and Delete….
        run.deleteLeftovers(startingWith: "\(Self.prefix)Own ")
        run.addGroup(named: mine)
        run.addBudget(named: rent, amount: "500", inGroup: mine)
        run.addEntry(merchant: hilltop, amount: "42.00")
        run.addEntry(merchant: market, amount: "9.50")
        XCTAssertTrue(run.element(AccessibilityID.budgetAdd).exists, "no Add, in his own group")
        XCTAssertTrue(run.element(AccessibilityID.budgetImport).exists, "no Import statement, in his own group")
        run.expectGroupMenu(mine, offers: [share, people, MainScreen.Words.newBudget(in: mine), rename, delete],
                            last: delete)
        run.expectBudgetMenu(rent, offersChanges: true)

        // 12. Robin shares his own group, and Leslie joins it. Once his app
        // syncs, the group's page lists her.
        run.openBudget(named: rent)
        let mineLink = try run.share(group: mine, myName: "Robin", role: .add)
        _ = try await second.join(mineLink, as: "Leslie")
        run.syncAndWait()
        run.openGroupPageFromMenu(named: mine)
        XCTAssertTrue(run.listText("Leslie").waitForExistence(timeout: 30),
                      "the group's page does not list Leslie. On screen: \(run.visibleTexts())")

        // Scenario BUDGET-12
        // 13. Delete… asks first, saying the group is deleted for everyone
        // in it, with its 1 budget and 2 transactions. Delete takes it away,
        // from Leslie too.
        let forEveryone = PendingDelete.group(BudgetGroup(name: mine), budgets: 1, transactions: 2, reach: .everyone)
        run.expectQuestion(from: mine, item: delete, title: forEveryone.title, message: forEveryone.message,
                           buttons: [forEveryone.confirmLabel, cancel])
        try XCTUnwrap(run.dialogButton(forEveryone.confirmLabel), "no Delete on the question").click()
        XCTAssertTrue(run.wait(for: run.element(AccessibilityID.sidebarGroup(mine)), until: "exists == false",
                               timeout: 10), "the group stayed in his list")
        let gone = try await second.waitUntilGone(mine)
        XCTAssertTrue(gone, "Leslie still has Robin's group")

        // 14. Tidy: Robin's session ends. Then Leslie deletes her group for
        // everyone, and her session ends.
        run.signOut()
        await second.deleteGroup(named: managed)
        await second.cleanUp()
    }

    // MARK: - At View, and only from now on

    @MainActor
    func testAtViewAndOnlyFromNowOn() async throws {
        let accounts = try TestAccounts.fromEnvironment()
        let run = try TestApp()
        Self.dataRootPath = run.dataRoot.path
        let second = try SecondAccount(server: accounts.server)
        Self.secondSuite = second.suite
        let stamp = Self.stamp()
        let viewed = "\(Self.prefix)View \(stamp)", groceries = "Groceries \(stamp)"
        let fromNow = "\(Self.prefix)New \(stamp)", treats = "Treats \(stamp)"
        let hilltop = "Hilltop Grocery", market = "Market", costco = "Costco"
        let share = MainScreen.Words.share, people = MembersScreen.Words.menuItem, leave = MainScreen.Words.leave
        let hilltopAmount = Money(minorUnits: 14208)

        // 1. Leslie, with no window, signs in and deletes any groups an
        // earlier run left on her account. Then she makes a group with
        // Hilltop Grocery, $142.08, gives it a note, and makes a link that
        // invites at View.
        try await second.signIn(email: accounts.secondEmail, password: accounts.secondPassword)
        await second.deleteLeftovers(startingWith: Self.prefix)
        let viewLink = try await second.shareNewGroup(viewed, budget: groceries, entry: hilltop, amount: hilltopAmount,
                                                      myName: "Leslie", role: .view)
        try await second.changeEntry(hilltop, inGroup: viewed, note: "weekly shop")

        // 2. The window, signed in as Robin, joins with the link and opens
        // the budget.
        run.launch()
        try run.signIn(email: accounts.email, password: accounts.password, server: accounts.server)
        run.join(viewLink.url, as: "Robin")
        run.openBudget(named: groceries)

        // Scenario SHARE-11, ENTRY-10, IMPORT-14
        // 3. At View he sees her entry, with Leslie under Added by, and
        // there is no Add and no Import statement.
        XCTAssertTrue(run.entryRow(hilltop).waitForExistence(timeout: 60),
                      "Hilltop Grocery did not arrive. On screen: \(run.visibleTexts())")
        run.expectEntry(hilltop, shows: ["Leslie"])
        XCTAssertFalse(run.element(AccessibilityID.budgetAdd).exists, "Add, at View")
        XCTAssertFalse(run.element(AccessibilityID.budgetImport).exists, "Import statement, at View")

        // Scenario EDIT-10
        // 4. A click opens Hilltop Grocery read-only: its merchant,
        // amount, date, note and budget as plain text, a line saying he can
        // view the group but not change it, and Done as the only button.
        run.clickRow(hilltop)
        run.expectReadOnly(saying: EntryAccess.Words.viewOnly,
                           details: [(EntryEditor.Words.merchant, hilltop), (EntryEditor.Words.amount, hilltopAmount.display),
                                     (EntryEditor.Words.date, EntryEditor.Words.fullDate(Date())),
                                     (EntryEditor.Words.note, "weekly shop"), (EntryEditor.Words.budget, groceries)])
        run.click(AccessibilityID.entryDone)
        run.expectNoSheet()

        // Scenario SHARE-11
        // 5. The group's menu offers only Share…, People… and Leave…, and
        // the budget's row offers no menu to change or delete it.
        run.expectBudgetMenu(groceries, offersChanges: false)
        run.expectGroupMenu(viewed, offers: [share, people, leave], last: leave)

        // 6. Leslie makes a group with Hilltop Grocery, $42.00, and a link
        // that shows only what is added from now on. Robin joins and opens
        // its budget.
        let newLink = try await second.shareNewGroup(fromNow, budget: treats, entry: hilltop,
                                                     amount: Money(minorUnits: 4200), myName: "Leslie", role: .add,
                                                     history: .fromNow)
        run.join(newLink.url, as: "Robin")
        run.openBudget(named: treats)

        // Scenario SHARE-13
        // 7. Hilltop Grocery is not in his list, and the budget's wheel
        // leaves it out: nothing is spent.
        run.expect(wheel: AccessibilityID.budgetWheel, reads: TodaysBudget(limit: 50_000, spent: 0).wheel.spokenSummary,
                   "the budget, with what came before the link left out")
        XCTAssertTrue(run.rowIsGone(hilltop, timeout: 3), "Hilltop Grocery shows. On screen: \(run.visibleTexts())")

        // Scenario SHARE-13
        // 8. Costco, which Leslie adds after he joined, reaches him at his
        // next sync, and the wheel counts it.
        try await second.addEntry(costco, amount: Money(minorUnits: 9900), inBudget: treats, group: fromNow)
        run.syncNow()
        XCTAssertTrue(run.entryRow(costco).waitForExistence(timeout: 60),
                      "Costco did not arrive. On screen: \(run.visibleTexts())")
        run.expect(wheel: AccessibilityID.budgetWheel,
                   reads: TodaysBudget(limit: 50_000, spent: 9_900).wheel.spokenSummary, "the budget, with Costco")

        // Scenario SHARE-13
        // 9. Leslie changes Hilltop Grocery, then adds Market. Once Market
        // reaches him, Hilltop Grocery is still not there, and the wheel
        // counts Costco and Market only.
        try await second.changeEntry(hilltop, inGroup: fromNow, amount: "43.00")
        try await second.addEntry(market, amount: Money(minorUnits: 950), inBudget: treats, group: fromNow)
        run.syncNow()
        XCTAssertTrue(run.entryRow(market).waitForExistence(timeout: 60),
                      "Market did not arrive. On screen: \(run.visibleTexts())")
        XCTAssertTrue(run.rowIsGone(hilltop, timeout: 3),
                      "Hilltop Grocery showed once Leslie changed it. On screen: \(run.visibleTexts())")
        let costcoAndMarket: Int = 9_900 + 950
        run.expect(wheel: AccessibilityID.budgetWheel,
                   reads: TodaysBudget(limit: 50_000, spent: costcoAndMarket).wheel.spokenSummary,
                   "the budget, with Costco and Market")

        // 10. Tidy: Robin's session ends. Then Leslie deletes her groups for
        // everyone, and her session ends.
        run.signOut()
        for name in [viewed, fromNow] { await second.deleteGroup(named: name) }
        await second.cleanUp()
    }

    // MARK: - At Add, then moved up and down

    @MainActor
    func testAtAddThenMovedUpAndDown() async throws {
        let accounts = try TestAccounts.fromEnvironment()
        let run = try TestApp()
        Self.dataRootPath = run.dataRoot.path
        let second = try SecondAccount(server: accounts.server)
        Self.secondSuite = second.suite
        let stamp = Self.stamp()
        let added = "\(Self.prefix)Add \(stamp)", eatingOut = "Eating out \(stamp)"
        let hilltop = "Hilltop Grocery", bakery = "Corner Bakery", market = "Market"
        let leave = MainScreen.Words.leave, cancel = MainScreen.Words.cancel
        let hilltopAmount = Money(minorUnits: 14208), bakeryAmount = Money(minorUnits: 1200)

        // 1. Leslie, with no window, signs in and deletes any groups an
        // earlier run left on her account. Then she makes a group with
        // Hilltop Grocery and Corner Bakery, and a link that invites at Add.
        try await second.signIn(email: accounts.secondEmail, password: accounts.secondPassword)
        await second.deleteLeftovers(startingWith: Self.prefix)
        let addLink = try await second.shareNewGroup(added, budget: eatingOut, entry: hilltop, amount: hilltopAmount,
                                                     myName: "Leslie", role: .add)
        try await second.addEntry(bakery, amount: bakeryAmount, inBudget: eatingOut, group: added)

        // 2. The window, signed in as Robin, joins with the link and opens
        // the budget. Its Undo bar stays ten minutes, not ten seconds, so
        // Leslie can move him down while it is up.
        run.app.launchEnvironment[Workspace.undoWindowVariable] = "600"
        run.launch()
        let opened = Date()
        try run.signIn(email: accounts.email, password: accounts.password, server: accounts.server)
        run.join(addLink.url, as: "Robin")
        run.openBudget(named: eatingOut)
        XCTAssertTrue(run.entryRow(bakery).waitForExistence(timeout: 60),
                      "Corner Bakery did not arrive. On screen: \(run.visibleTexts())")

        // Scenario SHARE-05
        // 3. Share… says only a manager or admin can invite people to the
        // group, offers no level to choose, and Create Link stays dimmed
        // with his name in.
        run.openShare(added)
        XCTAssertTrue(run.listText(ShareScreen.Words.cannotInvite).waitForExistence(timeout: 5),
                      "the sheet does not say who can invite. On screen: \(run.visibleTexts())")
        run.expectRoles([], chosen: nil)
        run.pasteAndCheck("Robin", into: AccessibilityID.shareName)
        run.expect(AccessibilityID.shareCreate, enabled: false, "Create Link, at Add")
        run.click(AccessibilityID.shareCancel)
        XCTAssertTrue(run.wait(for: run.element(AccessibilityID.shareName), until: "exists == false", timeout: 10),
                      "the Share sheet did not close")

        // Scenario BUDGET-13
        // 4. Leave… asks first, with Leave and Cancel, and says he leaves
        // the group with its 1 budget and 2 transactions, and what becomes
        // of changes not synced yet. Cancel keeps the group.
        let leaveAtAdd = PendingDelete.group(BudgetGroup(name: added), budgets: 1, transactions: 2,
                                             reach: .thisMacOnly)
        run.expectQuestion(from: added, item: leave, title: leaveAtAdd.title,
                           message: leaveAtAdd.message(sendsChanges: true),
                           buttons: [leaveAtAdd.confirmLabel, cancel])
        try XCTUnwrap(run.dialogButton(cancel), "no Cancel on the question").click()
        XCTAssertTrue(run.element(AccessibilityID.sidebarGroup(added)).waitForExistence(timeout: 5),
                      "Cancel did not keep the group")

        // 5. Robin adds Market. Leslie moves him up to Manage, and his app
        // syncs.
        run.openBudget(named: eatingOut)
        run.addEntry(merchant: market, amount: "9.50")
        try await second.setLevelOfTheOther(.manage, in: added)
        run.syncAndWait()

        // Scenario EDIT-13
        // 6. Robin opens Hilltop Grocery and types a new amount. Leslie
        // moves him down to View meanwhile, then gives Corner Bakery a
        // note. The window's timed sync brings both in while the sheet is
        // open: the note shows in the list behind it. Save then saves
        // nothing. The sheet turns read-only, with Done as its only button,
        // and shows Hilltop Grocery as it was when he opened it, $142.08,
        // not what he typed. It says nothing was changed, since he can view
        // the group but not change it.
        run.clickRow(hilltop)
        run.expectSheet(for: hilltop)
        run.type("150.00", into: AccessibilityID.entryAmount)
        try await second.setLevelOfTheOther(.read, in: added)
        try await second.changeEntry(bakery, inGroup: added, note: "day old")
        print("WHOMAY step 6 at \(Int(Date().timeIntervalSince(opened))) s")
        if run.element(AccessibilityID.entryRow(bakery)).exists {
            print("WHOMAY the list reads behind the sheet")
            XCTAssertTrue(run.listText("day old").waitForExistence(timeout: 300),
                          "no sync took the move down in while the sheet was open. On screen: \(run.visibleTexts())")
        } else {
            print("WHOMAY the list does not read behind the sheet")
            try await Self.waitPastTheNextTimedSync(afterOpening: opened)
        }
        run.click(AccessibilityID.entrySave)
        run.expectReadOnly(saying: EntryEditor.Words.notAllowed(.viewOnly),
                           details: [(EntryEditor.Words.merchant, hilltop),
                                     (EntryEditor.Words.amount, hilltopAmount.display)])
        run.click(AccessibilityID.entryDone)
        run.expectNoSheet()
        XCTAssertTrue(run.listText(hilltopAmount.display).waitForExistence(timeout: 5),
                      "Hilltop Grocery's row lost \(hilltopAmount.display). On screen: \(run.visibleTexts())")
        XCTAssertFalse(run.listText("$150.00").exists, "his amount was saved. On screen: \(run.visibleTexts())")

        // Scenario EDIT-10
        // 7. Market, which he added before the move down, opens read-only,
        // saying he can only view the group now, so he can't change what he
        // added. Done is the only button.
        run.clickRow(market)
        run.expectReadOnly(saying: EntryAccess.Words.viewOnlyOwn, details: [(EntryEditor.Words.merchant, market)])
        run.click(AccessibilityID.entryDone)
        run.expectNoSheet()

        // 8. Leslie moves him up to Manage again, and his app syncs. Robin
        // opens Corner Bakery, which she added, and deletes it, and the bar
        // offers Undo. His app sends the delete, and Leslie's app sees it
        // go. Then she moves him down to View, and his app syncs. The bar
        // stays.
        try await second.setLevelOfTheOther(.manage, in: added)
        run.syncAndWait()
        let bakeryQuestion = PendingDelete.entry(try second.entry(bakery, inGroup: added), budget: eatingOut,
                                                 group: added, shared: true)
        run.clickRow(bakery)
        run.expectSheet(for: bakery)
        run.click(AccessibilityID.entryDelete)
        XCTAssertTrue(run.text(saying: bakeryQuestion.title).waitForExistence(timeout: 5),
                      "no question before the delete. On screen: \(run.visibleTexts())")
        try XCTUnwrap(run.dialogButton(bakeryQuestion.confirmLabel), "no Delete on the question").click()
        run.expectNoSheet()
        XCTAssertTrue(run.rowIsGone(bakery), "Delete left the Corner Bakery row")
        let undoBar = run.text(saying: UndoOffer.Words.deleted(bakery, bakeryAmount.display))
        XCTAssertTrue(undoBar.waitForExistence(timeout: 5), "no Undo bar. On screen: \(run.visibleTexts())")
        run.syncAndWait()
        let deleted = try await second.waitUntilDeleted(bakery, inGroup: added)
        XCTAssertTrue(deleted, "Robin's delete never reached the server")
        try await second.setLevelOfTheOther(.read, in: added)
        run.syncAndWait()
        XCTAssertTrue(undoBar.exists, "the sync took the Undo bar away. On screen: \(run.visibleTexts())")

        // Scenario EDIT-09
        // 9. Undo brings nothing back. The bar goes, and the app says this
        // can't be undone now, since he can view the group but not change
        // it. OK closes that, and Corner Bakery stays deleted.
        run.click(AccessibilityID.undoButton)
        XCTAssertTrue(run.text(saying: UndoOffer.Words.refused(.viewOnly)).waitForExistence(timeout: 5),
                      "the app does not say why Undo did nothing. On screen: \(run.visibleTexts())")
        XCTAssertTrue(run.wait(for: run.element(AccessibilityID.undoBar), until: "exists == false", timeout: 5),
                      "the bar stayed after Undo")
        try XCTUnwrap(run.dialogButton(MainScreen.Words.ok), "no OK on the message").click()
        XCTAssertTrue(run.rowIsGone(bakery, timeout: 5), "Undo brought Corner Bakery back")

        // Scenario BUDGET-13
        // 10. At View, Leave… asks without the two sentences about changes
        // not synced yet. Leave takes the group from his list, and Leslie
        // keeps it, with Hilltop Grocery and Market.
        let leaveAtView = PendingDelete.group(BudgetGroup(name: added), budgets: 1, transactions: 2,
                                              reach: .thisMacOnly)
        run.expectQuestion(from: added, item: leave, title: leaveAtView.title,
                           message: leaveAtView.message(sendsChanges: false),
                           buttons: [leaveAtView.confirmLabel, cancel])
        try XCTUnwrap(run.dialogButton(leaveAtView.confirmLabel), "no Leave on the question").click()
        XCTAssertTrue(run.wait(for: run.element(AccessibilityID.sidebarGroup(added)), until: "exists == false",
                               timeout: 10), "the group stayed in his list")
        let alone = try await second.waitForMembers(1, in: added)
        XCTAssertTrue(alone, "Robin's leave never reached the server")
        for merchant in [hilltop, market] {
            XCTAssertNoThrow(try second.entry(merchant, inGroup: added), "Leslie lost \(merchant)")
        }

        // 11. Tidy: Robin's session ends. Then Leslie deletes her group for
        // everyone, and her session ends.
        run.signOut()
        await second.deleteGroup(named: added)
        await second.cleanUp()
    }

    // MARK: - Moved up from Add to Manage

    @MainActor
    func testMovedUpFromAddToManage() async throws {
        let accounts = try TestAccounts.fromEnvironment()
        let run = try TestApp()
        Self.dataRootPath = run.dataRoot.path
        let second = try SecondAccount(server: accounts.server)
        Self.secondSuite = second.suite
        let stamp = Self.stamp()
        let moved = "\(Self.prefix)Up \(stamp)", lunch = "Lunch \(stamp)"
        let hilltop = "Hilltop Grocery"
        let share = MainScreen.Words.share, people = MembersScreen.Words.menuItem
        let rename = MainScreen.Words.rename, leave = MainScreen.Words.leave

        // 1. Leslie, with no window, signs in and deletes any groups an
        // earlier run left on her account. Then she makes a group with
        // Hilltop Grocery, and a link that invites at Add.
        try await second.signIn(email: accounts.secondEmail, password: accounts.secondPassword)
        await second.deleteLeftovers(startingWith: Self.prefix)
        let addLink = try await second.shareNewGroup(moved, budget: lunch, entry: hilltop,
                                                     amount: Money(minorUnits: 14208), myName: "Leslie", role: .add)

        // 2. The window, signed in as Robin, joins with the link and opens
        // the budget.
        run.launch()
        try run.signIn(email: accounts.email, password: accounts.password, server: accounts.server)
        run.join(addLink.url, as: "Robin")
        run.openBudget(named: lunch)
        XCTAssertTrue(run.entryRow(hilltop).waitForExistence(timeout: 60),
                      "Hilltop Grocery did not arrive. On screen: \(run.visibleTexts())")

        // Scenario BUDGET-07
        // 3. At Add, the budget's row offers no Edit… and no Delete…, and
        // the group's menu offers only Share…, People… and Leave….
        run.expectBudgetMenu(lunch, offersChanges: false)
        run.expectGroupMenu(moved, offers: [share, people, leave], last: leave)

        // 4. Leslie moves him up to Manage, and his app syncs.
        try await second.setLevelOfTheOther(.manage, in: moved)
        run.openBudget(named: lunch)
        run.syncAndWait()

        // Scenario BUDGET-07
        // 5. At Manage, the group's menu offers New Budget in it and
        // Rename…, with Leave… still in place of Delete….
        run.expectGroupMenu(moved, offers: [share, people, MainScreen.Words.newBudget(in: moved), rename, leave],
                            last: leave)

        // Scenario BUDGET-07
        // 6. The budget's row offers Edit… and Delete….
        run.expectBudgetMenu(lunch, offersChanges: true)

        // 7. Tidy: Robin's session ends. Then Leslie deletes her group for
        // everyone, and her session ends.
        run.signOut()
        await second.deleteGroup(named: moved)
        await second.cleanUp()
    }

    // MARK: - The window's timed syncs

    /// When the window's timed sync number `tick` can start, in seconds
    /// after `opened`, and when it is surely done. The timer starts as the
    /// window opens, a few seconds before `opened`, and each tick comes two
    /// minutes after the last one's sync ends. So a tick can start up to ten
    /// seconds before its two minutes are up, and drifts later by up to five
    /// seconds for each tick before it. Its sync takes up to fifteen seconds.
    @MainActor
    private static func timedSync(_ tick: Int) -> (soonest: TimeInterval, done: TimeInterval) {
        let interval: TimeInterval = TimeInterval(AutoSync.defaultInterval.components.seconds)
        let due: TimeInterval = TimeInterval(tick) * interval
        let drift: TimeInterval = TimeInterval(tick) * 5
        return (soonest: due - 10, done: due + drift + 15)
    }

    /// Waits while one of the window's timed syncs could be running now, or
    /// start within the next `seconds`, until it is surely done.
    @MainActor
    private static func waitClearOfTheTimedSyncs(afterOpening opened: Date, for seconds: TimeInterval) async throws {
        var tick = 1
        while true {
            let now: TimeInterval = Date().timeIntervalSince(opened)
            let sync = timedSync(tick)
            if now >= sync.done {
                tick += 1
            } else if now + seconds <= sync.soonest {
                return
            } else {
                let wait: TimeInterval = sync.done - now
                print("WHOMAY waiting \(Int(wait)) s for timed sync \(tick) to pass")
                try await Task.sleep(for: .seconds(wait))
            }
        }
    }

    /// Waits until a timed sync of the window's that started after now is
    /// surely done.
    @MainActor
    private static func waitPastTheNextTimedSync(afterOpening opened: Date) async throws {
        let now: TimeInterval = Date().timeIntervalSince(opened)
        var tick = 1
        while timedSync(tick).soonest <= now { tick += 1 }
        let wait: TimeInterval = timedSync(tick).done - now
        print("WHOMAY waiting \(Int(wait)) s for timed sync \(tick)")
        try await Task.sleep(for: .seconds(wait))
    }

    // MARK: - Names

    /// Part of each name, so runs never share one.
    private static func stamp() -> String {
        stampFormatter().string(from: Date())
    }

    /// The time in a group's name, "20261021-161500", always in UTC, so this
    /// Mac and a CI runner in another time zone read each other's the same.
    nonisolated static func stampFormatter() -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter
    }
}

// MARK: - Steps in the window

@MainActor
private extension TestApp {
    /// Deletes groups of this person's own that an earlier run of this test
    /// left when it stopped part way: lines in the sidebar whose names start
    /// with `prefix` and end with a time more than an hour ago. Another run
    /// may be going at the same time, on this Mac or in CI, so a newer
    /// group stays. Best effort.
    func deleteLeftovers(startingWith prefix: String) {
        let formatter = WhoMayGapTests.stampFormatter()
        let anHourAgo = Date().addingTimeInterval(-3600)
        let start = AccessibilityID.sidebarGroup("")
        let lines = app.windows.firstMatch.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", AccessibilityID.sidebarGroup(prefix)))
        let names = Set(lines.allElementsBoundByIndex.map { String($0.identifier.dropFirst(start.count)) })
        for name in names {
            guard let made = formatter.date(from: String(name.suffix(15))), made < anHourAgo else { continue }
            deleteGroup(named: name)
        }
    }

    /// A text anywhere in the app with exactly these words, as its label or
    /// its value. A query by words in brackets refuses more than 128
    /// characters, and a question's words run longer.
    func text(saying words: String) -> XCUIElement {
        app.staticTexts.matching(NSPredicate(format: "label == %@ OR value == %@", words, words)).firstMatch
    }

    /// Every item a group's menu can hold.
    func groupMenuItems(_ group: String) -> [String] {
        [MainScreen.Words.share, MembersScreen.Words.menuItem, MainScreen.Words.newBudget(in: group),
         MainScreen.Words.rename, MainScreen.Words.delete, MainScreen.Words.leave]
    }

    /// Right-clicks a group's line and checks its menu offers `offered`,
    /// none of the other items a group's menu can hold, and `last` below the
    /// rest. A menu with no item naming its group is then checked to be this
    /// group's by People…, which opens the group's own page. Any other menu
    /// is closed with Escape.
    func expectGroupMenu(_ group: String, offers offered: [String], last: String,
                         file: StaticString = #filePath, line: UInt = #line) {
        let id = AccessibilityID.sidebarGroup(group)
        openMenu(on: element(id), id, offering: MainScreen.Words.share)
        for title in groupMenuItems(group) {
            let shown = menuItem(title).exists
            if offered.contains(title) {
                XCTAssertTrue(shown, "\(group)'s menu does not offer \(title). It offers \(visibleMenuItems())",
                              file: file, line: line)
            } else {
                XCTAssertFalse(shown, "\(group)'s menu offers \(title)", file: file, line: line)
            }
        }
        let lowest = menuItem(last).frame.minY
        for title in offered where title != last {
            XCTAssertLessThan(menuItem(title).frame.minY, lowest, "\(title) is below \(last) in \(group)'s menu",
                              file: file, line: line)
        }
        if offered.contains(MainScreen.Words.newBudget(in: group)) {
            app.typeKey(.escape, modifierFlags: [])
        } else {
            clickMenuItem(MembersScreen.Words.menuItem)
            XCTAssertTrue(element(AccessibilityID.groupSummary).waitForExistence(timeout: 10),
                          "People\u{2026} opened no page. On screen: \(visibleTexts())", file: file, line: line)
            XCTAssertTrue(listText(group).waitForExistence(timeout: 5),
                          "the menu was another group's: People\u{2026} did not open \(group)'s page. On screen: "
                          + "\(visibleTexts())", file: file, line: line)
        }
        XCTAssertTrue(wait(for: menuItem(MainScreen.Words.share), until: "exists == false", timeout: 5),
                      "\(group)'s menu did not close", file: file, line: line)
    }

    /// Right-clicks a budget's row in the sidebar. With `offersChanges`, its
    /// menu offers Edit… and Delete…, and Edit… opens this budget's sheet,
    /// which Cancel closes. Without, no menu opens.
    func expectBudgetMenu(_ budget: String, offersChanges: Bool,
                          file: StaticString = #filePath, line: UInt = #line) {
        let row = sidebarBudget(budget)
        let edit = menuItem(MainScreen.Words.edit), delete = menuItem(MainScreen.Words.delete)
        guard offersChanges else {
            revealInSidebar(row)
            rightClick(row, budget)
            XCTAssertFalse(edit.waitForExistence(timeout: 3), "\(budget) offers Edit\u{2026}", file: file, line: line)
            XCTAssertFalse(delete.exists, "\(budget) offers Delete\u{2026}", file: file, line: line)
            app.typeKey(.escape, modifierFlags: [])
            return
        }
        openMenu(on: row, AccessibilityID.sidebarBudget(budget), offering: MainScreen.Words.edit)
        XCTAssertTrue(delete.exists, "\(budget) offers Edit\u{2026} but not Delete\u{2026}", file: file, line: line)
        clickMenuItem(MainScreen.Words.edit)
        let name = element(AccessibilityID.budgetEditorName)
        XCTAssertTrue(wait(for: name, holds: budget, timeout: 10),
                      "Edit\u{2026} did not open \(budget). On screen: \(visibleTexts())", file: file, line: line)
        click(AccessibilityID.budgetEditorCancel)
        XCTAssertTrue(wait(for: name, until: "exists == false", timeout: 10), "the Edit Budget sheet stayed open",
                      file: file, line: line)
    }

    /// Share… from the group's menu, until the sheet that opens is this
    /// group's, as TestApp.share does: a right-click on the line beside it
    /// opens another group's menu.
    func openShare(_ group: String, file: StaticString = #filePath, line: UInt = #line) {
        let id = AccessibilityID.sidebarGroup(group)
        let form = element(AccessibilityID.shareName)
        let title = app.staticTexts[ShareScreen.Words.shareTitle(group)].firstMatch
        for _ in 0..<3 {
            openMenu(on: element(id), id, offering: MainScreen.Words.share)
            clickMenuItem(MainScreen.Words.share)
            XCTAssertTrue(form.waitForExistence(timeout: 10), "Share\u{2026} opened no sheet. On screen: "
                          + "\(visibleTexts())", file: file, line: line)
            if title.waitForExistence(timeout: 3) { return }
            click(AccessibilityID.shareCancel)
            wait(for: form, until: "exists == false", timeout: 10)
        }
        XCTFail("Share\u{2026} never opened the sheet for \(group). On screen: \(visibleTexts())", file: file, line: line)
    }

    /// One of They can's choices on the Share sheet, by its title, however
    /// the picker reads: as radio buttons, as buttons, or as anything else
    /// in the sheet by that name that is not plain text.
    func roleChoice(_ role: InviteRole) -> XCUIElement {
        let picker = element(AccessibilityID.shareRole)
        let named = NSPredicate(format: "(label == %@ OR title == %@) AND elementType != %d", role.title, role.title,
                                XCUIElement.ElementType.staticText.rawValue)
        let candidates = [picker.radioButtons[role.title], picker.buttons[role.title], app.radioButtons[role.title],
                          app.sheets.firstMatch.descendants(matching: .any).matching(named).firstMatch]
        return candidates.first { $0.exists } ?? candidates[0]
    }

    /// Checks They can offers exactly `roles`, with `chosen` picked. With
    /// none, the sheet offers no level to choose at all.
    func expectRoles(_ roles: [InviteRole], chosen: InviteRole?, file: StaticString = #filePath, line: UInt = #line) {
        let picker = element(AccessibilityID.shareRole)
        if roles.isEmpty {
            XCTAssertFalse(picker.exists, "the sheet offers a level to choose", file: file, line: line)
        } else {
            XCTAssertTrue(picker.waitForExistence(timeout: 5), "the sheet offers no level to choose", file: file,
                          line: line)
        }
        for role in InviteRole.allCases {
            let shown = roleChoice(role).exists
            if roles.contains(role) {
                XCTAssertTrue(shown, "They can does not offer \(role.title). The picker: \(picker.debugDescription)",
                              file: file, line: line)
            } else {
                XCTAssertFalse(shown, "They can offers \(role.title)", file: file, line: line)
            }
        }
        if let chosen {
            let choice = roleChoice(chosen)
            let picked = choice.isSelected || (choice.value as? Int) == 1 || (choice.value as? Bool) == true
            XCTAssertTrue(picked, "\(chosen.title) is not chosen. The picker: \(picker.debugDescription)",
                          file: file, line: line)
        }
    }

    /// Picks an item in a group's menu that asks first, and checks the
    /// question's title, its words and its buttons. The question is left up.
    func expectQuestion(from group: String, item: String, title: String, message: String, buttons: [String],
                        file: StaticString = #filePath, line: UInt = #line) {
        let id = AccessibilityID.sidebarGroup(group)
        openMenu(on: element(id), id, offering: item)
        clickMenuItem(item)
        XCTAssertTrue(text(saying: title).waitForExistence(timeout: 5),
                      "no question \(title) On screen: \(visibleTexts())", file: file, line: line)
        XCTAssertTrue(text(saying: message).exists, "the question does not say \(message) On screen: "
                      + "\(visibleTexts())", file: file, line: line)
        for button in buttons {
            XCTAssertNotNil(dialogButton(button), "no \(button) on the question", file: file, line: line)
        }
    }

    /// Sync, in the toolbar, then waits for it to finish: the button is off
    /// while a sync runs.
    func syncAndWait(file: StaticString = #filePath, line: UInt = #line) {
        syncNow()
        let button = element(AccessibilityID.toolbarSync)
        _ = wait(for: button, until: "isEnabled == false", timeout: 3)
        XCTAssertTrue(wait(for: button, until: "isEnabled == true", timeout: 60), "the sync never finished",
                      file: file, line: line)
    }

    /// Waits for an entry's row in the budget's list to show each of
    /// `words`, such as who added it and where it came from. A row is a band
    /// across the list: a word is in the row when it sits within the height
    /// of the row's merchant cell, which holds the merchant and the lines
    /// under it.
    func expectEntry(_ merchant: String, shows words: [String], file: StaticString = #filePath, line: UInt = #line) {
        let cell = element(AccessibilityID.entryRow(merchant))
        XCTAssertTrue(cell.waitForExistence(timeout: 10), "no row for \(merchant). On screen: \(visibleTexts())",
                      file: file, line: line)
        // A list's texts carry their words as a value, not a label.
        let texts = app.windows.firstMatch.staticTexts
        for word in words {
            let inTheRow = NSPredicate { _, _ in
                let band = cell.frame
                return texts.matching(NSPredicate(format: "label == %@ OR value == %@", word, word))
                    .allElementsBoundByIndex.contains {
                        $0.frame.midY >= band.minY - 1 && $0.frame.midY <= band.maxY + 1
                    }
            }
            let shown = XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: inTheRow, object: nil)],
                                         timeout: 10) == .completed
            XCTAssertTrue(shown, "\(merchant)'s row does not show \(word). The row: \(cell.debugDescription)",
                          file: file, line: line)
        }
    }

    /// Checks the opened entry's sheet is read-only: `reason` says why,
    /// each of `details` shows as plain text, and Done is its only button.
    func expectReadOnly(saying reason: String, details: [(label: String, value: String)] = [],
                        file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(element(AccessibilityID.entryDone).waitForExistence(timeout: 10),
                      "no read-only sheet. On screen: \(visibleTexts())", file: file, line: line)
        XCTAssertTrue(wait(for: element(AccessibilityID.entryReadOnlyLine), holds: reason, timeout: 5),
                      "the sheet does not say \(reason) On screen: \(visibleTexts())", file: file, line: line)
        for detail in details {
            XCTAssertTrue(wait(for: element(AccessibilityID.entryDetail(detail.label)), holds: detail.value, timeout: 5),
                          "\(detail.label) is not \(detail.value) in plain text. On screen: \(visibleTexts())",
                          file: file, line: line)
        }
        for control in [AccessibilityID.entryMerchant, AccessibilityID.entryAmount, AccessibilityID.entrySave,
                        AccessibilityID.entryCancel, AccessibilityID.entryDelete] {
            XCTAssertFalse(element(control).exists, "\(control) on a read-only sheet", file: file, line: line)
        }
    }
}

// MARK: - Steps the second person takes

@MainActor
private extension SecondAccount {
    /// Deletes this person's groups that an earlier run of this test left
    /// when it stopped part way: names that start with `prefix` and end with
    /// a time more than an hour ago. Another run may be going at the same
    /// time, on this Mac or in CI, so a newer group stays. Best effort.
    func deleteLeftovers(startingWith prefix: String) async {
        let formatter = WhoMayGapTests.stampFormatter()
        let anHourAgo = Date().addingTimeInterval(-3600)
        for group in AppModel(store: sync.store).groups where group.name.hasPrefix(prefix) {
            guard let made = formatter.date(from: String(group.name.suffix(15))), made < anHourAgo else { continue }
            await deleteGroup(named: group.name)
        }
    }

    /// Waits until this person's app, syncing, no longer has the entry, such
    /// as after the other person deleted it. True when it goes in time.
    func waitUntilDeleted(_ merchant: String, inGroup group: String, timeout: TimeInterval = 30) async throws -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            try await syncAll()
            if (try? entry(merchant, inGroup: group)) == nil { return true }
            try await Task.sleep(for: .seconds(1))
        } while Date() < deadline
        return false
    }

    /// Waits until this person no longer has the group, such as after its
    /// owner deleted it for everyone. True when it goes in time.
    func waitUntilGone(_ group: String, timeout: TimeInterval = 30) async throws -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            try await syncAll()
            if (try? self.group(named: group)) == nil { return true }
            try await Task.sleep(for: .seconds(1))
        } while Date() < deadline
        return false
    }
}
