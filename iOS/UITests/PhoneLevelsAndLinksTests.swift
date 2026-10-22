import Foundation
import UIKit
import XCTest
import WellSpentAppCore
import WellSpentCrypto
import WellSpentModel
import WellSpentSync

/// Who may do what, and joining by a link, on a phone: what each level
/// offers, a link that only shows what comes after it, a link tapped while
/// WellSpent is closed or signed out, another link or a budget taking the
/// invitation's place, a link to a group already joined, and someone joining
/// or being removed while the group's page is open. Leslie has no window
/// (SecondAccountSteps.swift).
///
/// Needs the four WELLSPENT_UI_TEST_ variables (see UITestAccounts.swift)
/// and skips without them. Runs in light only, under the shared sign-in lock.
final class PhoneLevelsAndLinksTests: XCTestCase {
    nonisolated(unsafe) private static var dataRootPath: String?

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    /// No await in it, as in PhoneSignInSyncTests.
    override func tearDown() {
        let app = XCUIApplication()
        if app.state != .notRunning { app.terminate() }
        if let path = Self.dataRootPath { try? FileManager.default.removeItem(atPath: path) }
        Self.dataRootPath = nil
        UIPasteboard.general.items = []
        super.tearDown()
    }

    // MARK: - What each level offers

    @MainActor
    func testWhatEachLevelOffersAndALinkFromNowOn() async throws {
        let accounts = try TestAccounts.fromEnvironment()
        let run = PhoneTestApp()
        Self.dataRootPath = run.dataRoot.path
        let leslie = try SecondAccount(server: accounts.server)
        let stamp = PhoneTestApp.stamp()
        let groupName = SecondAccount.phoneRunPrefix + stamp
        let budget = "Costs \(stamp)"
        run.launch()
        try run.signIn(email: accounts.email, password: accounts.password, server: accounts.server)
        try await leslie.signIn(email: accounts.secondEmail, password: accounts.secondPassword)
        await leslie.deleteLeftoverRuns()
        let link = try await leslie.shareNewGroup(groupName, budget: budget, entry: "Costco",
                                                  amount: Money(minorUnits: 9900), myName: "Leslie", role: .view)
        run.join(link, as: "Robin")

        // Scenario SHARE-11, ENTRY-10, IMPORT-14
        // 1. Joined at View: Robin sees Leslie's entries with her name, there
        // is no Add and no Import statement, the group's menu offers only
        // Share, People and Leave, and nothing offers to edit or delete the
        // budget.
        run.expectGroupMenu(groupName, offers: [MainScreen.Words.share, MembersScreen.Words.menuItem, MainScreen.Words.leave],
                            not: [MainScreen.Words.newBudget(in: groupName), MainScreen.Words.rename, MainScreen.Words.delete])
        run.expectBudgetMenuIsEmpty(budget)
        run.scrollTo(AccessibilityID.sidebarBudget(budget))
        run.openBudget(named: budget)
        XCTAssertTrue(run.row("Costco", says: "Leslie", timeout: 15), "Costco without Leslie's name: \(run.rowLabel("Costco"))")
        XCTAssertFalse(run.element(AccessibilityID.budgetAdd).exists, "View is offered Add")
        XCTAssertFalse(run.element(AccessibilityID.budgetMenu).exists, "View is offered the budget's menu, with Import statement")

        // Scenario EDIT-10
        // 2. At View, Leslie's Costco opens read-only: its details as plain
        // text, the line saying why, and Done alone.
        run.openEntry("Costco")
        XCTAssertEqual(run.element(AccessibilityID.entryDetail(EntryEditor.Words.merchant)).value as? String, "Costco")
        XCTAssertEqual(run.element(AccessibilityID.entryDetail(EntryEditor.Words.amount)).value as? String, "$99.00")
        XCTAssertTrue(run.shows(EntryAccess.Words.viewOnly), "no line saying why. On screen: \(run.visibleTexts())")
        XCTAssertTrue(run.button(AccessibilityID.entryDone).exists, "no Done")
        for other in [AccessibilityID.entrySave, AccessibilityID.entryDelete, AccessibilityID.entryCancel, AccessibilityID.entryMerchant] {
            XCTAssertFalse(run.element(other).exists, "\(other) at View")
        }
        run.tap(AccessibilityID.entryDone)
        run.expectNoSheet()
        run.goBack()

        // Scenario SHARE-05, BUDGET-07
        // 3. Moved up to Add: the menu still offers only Share, People and
        // Leave, the budget no Edit or Delete, and Share says only a manager
        // or admin can invite, with no level to choose and Create Link dimmed.
        try await leslie.setLevelOfTheOther(.write, in: groupName)
        run.syncUntilTheLevel(allowsAdding: true, in: budget)
        run.expectGroupMenu(groupName, offers: [MainScreen.Words.share, MembersScreen.Words.menuItem, MainScreen.Words.leave],
                            not: [MainScreen.Words.newBudget(in: groupName), MainScreen.Words.rename, MainScreen.Words.delete])
        run.expectBudgetMenuIsEmpty(budget)
        run.longPress(AccessibilityID.sidebarGroup(groupName))
        run.tapMenuItem(MainScreen.Words.share)
        XCTAssertTrue(run.text(ShareScreen.Words.cannotInvite).waitForExistence(timeout: 10),
                      "Share does not say who may invite. On screen: \(run.visibleTexts())")
        XCTAssertFalse(run.element(AccessibilityID.shareRole).exists, "Share offers a level at Add")
        run.type("Robin", into: AccessibilityID.shareName)
        XCTAssertFalse(run.button(AccessibilityID.shareCreate).isEnabled, "Create Link lit at Add")
        run.tap(AccessibilityID.shareCancel)

        // Scenario EDIT-10
        // 4. Something Robin added at Add, after a move down to View, opens
        // read-only too, saying he can only view the group now.
        run.scrollTo(AccessibilityID.sidebarBudget(budget))
        run.openBudget(named: budget)
        run.addEntry(merchant: "Bread", amount: "5.00")
        run.syncFromTheBackground()
        try await leslie.setLevelOfTheOther(.read, in: groupName)
        run.goBack()
        run.syncUntilTheLevel(allowsAdding: false, in: budget)
        run.openBudget(named: budget)
        run.openEntry("Bread")
        XCTAssertTrue(run.shows(EntryAccess.Words.viewOnlyOwn), "no line for his own at View. On screen: \(run.visibleTexts())")
        run.tap(AccessibilityID.entryDone)
        run.expectNoSheet()
        run.goBack()

        // Scenario SHARE-06, SHARE-12, BUDGET-07
        // 5. Moved up to Manage: Share offers View and Add only, with Add
        // chosen. The menu offers New Budget and Rename, and still ends with
        // Leave, not Delete. The budget offers Edit and Delete, and has Add
        // and Import statement.
        try await leslie.setLevelOfTheOther(.manage, in: groupName)
        run.syncAndWait()
        run.longPress(AccessibilityID.sidebarGroup(groupName))
        run.tapMenuItem(MainScreen.Words.share)
        let roles = run.element(AccessibilityID.shareRole)
        XCTAssertTrue(roles.waitForExistence(timeout: 10), "no levels to choose at Manage")
        XCTAssertTrue(roles.buttons[InviteRole.view.title].exists && roles.buttons[InviteRole.add.title].exists,
                      "Share does not offer View and Add")
        XCTAssertFalse(roles.buttons[InviteRole.manage.title].exists, "a manager is offered Manage")
        XCTAssertTrue(roles.buttons[InviteRole.add.title].isSelected, "Add is not chosen")
        run.tap(AccessibilityID.shareCancel)
        run.expectGroupMenu(groupName, offers: [MainScreen.Words.newBudget(in: groupName), MainScreen.Words.rename,
                                                MainScreen.Words.leave],
                            not: [MainScreen.Words.delete])
        run.expectBudgetMenu(budget, offers: [MainScreen.Words.edit, MainScreen.Words.delete])
        run.openBudget(named: budget)
        XCTAssertTrue(run.element(AccessibilityID.budgetAdd).exists, "no Add at Manage")
        run.openBudgetMenu()
        XCTAssertTrue(run.menuItem(BudgetScreen.Words.importStatement).waitForExistence(timeout: 5), "no Import statement at Manage")
        run.dismissMenu()
        run.goBack()

        // Scenario SHARE-13
        // 6. A link with Only from now on: Leslie's earlier Hilltop Grocery is
        // hidden, and the total leaves it out. Costco, added after Robin
        // joined, reaches him, and Hilltop stays hidden after she changes it.
        let laterGroup = groupName + " Later"
        let laterBudget = "Later \(stamp)"
        let fromNow = try await leslie.shareNewGroup(laterGroup, budget: laterBudget, entry: "Hilltop Grocery",
                                                     amount: Money(minorUnits: 14_208), myName: "Leslie", role: .add,
                                                     history: .fromNow)
        run.join(fromNow, as: "Robin")
        run.scrollTo(AccessibilityID.sidebarBudget(laterBudget))
        run.openBudget(named: laterBudget)
        XCTAssertFalse(run.element(AccessibilityID.entryRow("Hilltop Grocery")).waitForExistence(timeout: 5),
                       "an entry from before the link shows")
        XCTAssertTrue(run.figure(MoneyWheel.Words.spent, is: "$0.00"), "the total counts what came before")
        try await leslie.addEntry("Costco", amount: Money(minorUnits: -9900), inBudget: laterBudget, group: laterGroup)
        try await leslie.changeEntry("Hilltop Grocery", inGroup: laterGroup, note: "changed later")
        run.goBack()
        run.syncAndWait()
        run.openBudget(named: laterBudget)
        XCTAssertTrue(run.element(AccessibilityID.entryRow("Costco")).waitForExistence(timeout: 20), "Costco did not reach Robin")
        XCTAssertFalse(run.element(AccessibilityID.entryRow("Hilltop Grocery")).waitForExistence(timeout: 5),
                       "Hilltop showed after it changed")
        // With Costco in, the total proves the sync came: it counts Costco and
        // still leaves Hilltop out.
        XCTAssertTrue(run.figure(MoneyWheel.Words.spent, is: "$99.00"), "the total is not Costco's alone")
        run.goBack()

        // 7. Tidy.
        run.signOut()
        await leslie.deleteGroup(named: groupName)
        await leslie.deleteGroup(named: laterGroup)
        await leslie.cleanUp()
    }

    // MARK: - A link tapped while closed or signed out

    @MainActor
    func testALinkTappedWhileClosedAndSignedOut() async throws {
        let accounts = try TestAccounts.fromEnvironment()
        let leslie = try SecondAccount(server: accounts.server)
        let stamp = PhoneTestApp.stamp()
        let first = SecondAccount.phoneRunPrefix + stamp
        let second = first + " Two"
        try await leslie.signIn(email: accounts.secondEmail, password: accounts.secondPassword)
        await leslie.deleteLeftoverRuns()
        let firstLink = try await leslie.shareNewGroup(first, budget: "Costs \(stamp)", entry: "Costco",
                                                       amount: Money(minorUnits: 9900), myName: "Leslie", role: .add)
        let secondLink = try await leslie.shareNewGroup(second, budget: "Later \(stamp)", entry: "Costco",
                                                        amount: Money(minorUnits: 9900), myName: "Leslie", role: .add)
        let run = PhoneTestApp()
        Self.dataRootPath = run.dataRoot.path
        // Opened once and quit, as on any phone that has it: a phone hands a
        // link only to an app it has seen start.
        run.launch()
        run.app.terminate()

        // Scenario CLICK-02
        // 1. With WellSpent not running, a tap on the link starts it on the
        // invitation page.
        XCTAssertEqual(run.app.state, .notRunning)
        run.open(link: firstLink.url)
        let invited = run.text("Leslie invited you to \u{201C}\(first)\u{201D}.")
        XCTAssertTrue(invited.waitForExistence(timeout: 30), "WellSpent did not start on the invitation. On screen: \(run.visibleTexts())")
        // A copy the system starts gets none of the test's settings, so it
        // runs in the phone's own data. The rest runs in the test's folder:
        // quit, start it as the test does, and tap the link again.
        run.app.terminate()
        run.launch()
        run.open(link: firstLink.url)
        XCTAssertTrue(invited.waitForExistence(timeout: 30), "the link did not open the invitation again. On screen: \(run.visibleTexts())")

        // Scenario CLICK-12
        // 2. Picking a budget takes the page down. So does opening a group's
        // page. The invitation comes back only from the link.
        run.goBack()
        run.openBudget(named: "Groceries")
        run.goBack()
        XCTAssertFalse(invited.exists, "the invitation came back after a budget")
        run.openGroupPage(named: "Household")
        XCTAssertTrue(run.element(AccessibilityID.groupSummary).waitForExistence(timeout: 10), "no group page")
        run.goBack()
        XCTAssertFalse(invited.exists, "the invitation came back after a group's page")
        run.open(link: firstLink.url)
        XCTAssertTrue(invited.waitForExistence(timeout: 15), "the link did not bring the invitation back")

        // Scenario CLICK-11
        // 3. Another link replaces the page.
        run.open(link: secondLink.url)
        XCTAssertTrue(run.text("Leslie invited you to \u{201C}\(second)\u{201D}.").waitForExistence(timeout: 15),
                      "the second link did not replace the page. On screen: \(run.visibleTexts())")
        XCTAssertFalse(invited.exists, "the first invitation is still up")

        // Scenario CLICK-05
        // 4. Signed out, the page still says who invited, the level and what
        // he'd see, with Sign in in place of Join. Signed in from there, the
        // page is still up, with Join in place of the notice.
        XCTAssertTrue(run.text(JoinScreen.Words.joinsAt(InviteRole.add.title)).waitForExistence(timeout: 15), "no level")
        XCTAssertTrue(run.text(JoinScreen.Words.sees(.all)).exists, "no history line")
        XCTAssertTrue(run.text(JoinScreen.Words.signInToJoin).exists, "no sign-in notice")
        XCTAssertFalse(run.element(AccessibilityID.invitationJoin).exists, "Join while signed out")
        run.tap(AccessibilityID.invitationSignIn)
        try run.signInOnTheOpenSheet(email: accounts.email, password: accounts.password, server: accounts.server)
        XCTAssertTrue(run.text("Leslie invited you to \u{201C}\(second)\u{201D}.").waitForExistence(timeout: 20),
                      "the invitation went after signing in. On screen: \(run.visibleTexts())")
        XCTAssertTrue(run.button(AccessibilityID.invitationJoin).waitForExistence(timeout: 10), "no Join after signing in")
        XCTAssertFalse(run.text(JoinScreen.Words.signInToJoin).exists, "the notice stayed")

        // 5. Tidy.
        run.goBack()
        run.signOut()
        await leslie.deleteGroup(named: first)
        await leslie.deleteGroup(named: second)
        await leslie.cleanUp()
    }

    // MARK: - Robin's own link, and someone joining and leaving his page

    @MainActor
    func testAnOwnLinkAndSomeoneJoiningOrRemovedWhileThePageIsOpen() async throws {
        let accounts = try TestAccounts.fromEnvironment()
        let run = PhoneTestApp()
        Self.dataRootPath = run.dataRoot.path
        let leslie = try SecondAccount(server: accounts.server)
        let stamp = PhoneTestApp.stamp()
        let groupName = SecondAccount.phoneRunPrefix + stamp
        let budget = "Groceries \(stamp)"
        run.launch()
        try run.signIn(email: accounts.email, password: accounts.password, server: accounts.server)
        run.addGroup(named: groupName)
        run.addBudget(named: budget, amount: "500", inGroup: groupName)
        run.goBack()

        // Scenario BUDGET-07
        // 1. The group's maker is offered everything: Share, People, New
        // Budget, Rename and Delete, and Edit and Delete for its budget.
        run.expectGroupMenu(groupName, offers: [MainScreen.Words.share, MembersScreen.Words.menuItem,
                                                MainScreen.Words.newBudget(in: groupName), MainScreen.Words.rename,
                                                MainScreen.Words.delete],
                            not: [MainScreen.Words.leave])
        run.expectBudgetMenu(budget, offers: [MainScreen.Words.edit, MainScreen.Words.delete])

        // Scenario CLICK-10
        // 2. Robin taps his own group's link and presses Join: the page says
        // he is in that group already, and the link is not used up.
        let link = try run.shareAndCopyLink(groupName, as: "Robin")
        run.open(link: link.url)
        XCTAssertTrue(run.text("Robin invited you to \u{201C}\(groupName)\u{201D}.").waitForExistence(timeout: 15), "no invitation")
        run.type("Robin", into: AccessibilityID.invitationName)
        run.tap(AccessibilityID.invitationJoin)
        XCTAssertTrue(run.shows("You are already in that group."),
                      "the page does not say he is in the group already. On screen: \(run.visibleTexts())")
        run.goBack()

        // Scenario PAGE-15
        // 3. With the page open, saying it is not shared, Leslie joins with
        // the same link, so it still works. At the next sync her row shows,
        // and the line says it is shared by two. Opened again, it shows her
        // at once.
        run.openGroupPage(named: groupName)
        let summary = run.element(AccessibilityID.groupSummary)
        let alone = MembersScreen.Words.line([MembersScreen.Words.notShared, MembersScreen.Words.madeByYou])
        XCTAssertTrue(run.wait(for: summary, until: "label == '\(alone)'", timeout: 15), "not 'Not shared': \(summary.label)")
        try await leslie.signIn(email: accounts.secondEmail, password: accounts.secondPassword)
        await leslie.deleteLeftoverRuns()
        _ = try await leslie.join(link, as: "Leslie")
        run.syncFromTheBackground()
        let shared = MembersScreen.Words.line([MembersScreen.Words.shared, MembersScreen.Words.peopleCount(2),
                                               MembersScreen.Words.madeByYou])
        XCTAssertTrue(run.wait(for: summary, until: "label == '\(shared)'", timeout: 30),
                      "the page did not hear of Leslie: \(summary.label)")
        XCTAssertTrue(run.element(AccessibilityID.groupPerson("Leslie")).exists, "no row for Leslie")
        run.goBack()
        run.openGroupPage(named: groupName)
        XCTAssertTrue(run.element(AccessibilityID.groupPerson("Leslie")).waitForExistence(timeout: 5),
                      "a page opened after she joined does not show her")

        // Scenario PAGE-17
        // 4. Leslie, at Add, adds Costco, and Robin removes her. At the next
        // sync Costco is still there, still added by Leslie, and Robin, the
        // owner, may still change it.
        try await leslie.addEntry("Costco", amount: Money(minorUnits: -9900), inBudget: budget, group: groupName)
        run.tap(AccessibilityID.groupPerson("Leslie"))
        run.tap(AccessibilityID.groupRemove("Leslie"))
        try XCTUnwrap(run.questionButton(MembersScreen.Words.removeButton)).tap()
        XCTAssertTrue(run.element(AccessibilityID.groupRemoved).waitForExistence(timeout: 20), "Leslie was not removed")
        run.goBack()
        run.syncFromTheBackground()
        run.pullDown()
        run.scrollTo(AccessibilityID.sidebarBudget(budget))
        run.openBudget(named: budget)
        XCTAssertTrue(run.row("Costco", says: "Leslie", timeout: 20),
                      "Costco went, or lost Leslie's name. The row says: \(run.rowLabel("Costco"))")
        run.openEntry("Costco")
        XCTAssertTrue(run.button(AccessibilityID.entrySave).exists, "the owner may not change Costco")
        run.tap(AccessibilityID.entryCancel)
        run.expectNoSheet()
        run.goBack()

        // 5. Tidy.
        run.longPress(AccessibilityID.sidebarGroup(groupName))
        run.tapMenuItem(MainScreen.Words.delete)
        try XCTUnwrap(run.questionButton("Delete")).tap()
        run.syncAndWait()
        run.signOut()
        await leslie.cleanUp()
    }
}

/// The steps these tests take, beside the ones every iPhone test shares.
extension PhoneTestApp {
    /// Holds a group on Home and checks its menu offers these items and not
    /// those, then closes the menu.
    func expectGroupMenu(_ group: String, offers: [String], not absent: [String]) {
        scrollTo(AccessibilityID.sidebarGroup(group))
        longPress(AccessibilityID.sidebarGroup(group))
        for item in offers {
            XCTAssertTrue(menuItem(item).waitForExistence(timeout: 5), "\(group)'s menu offers no \(item). On screen: \(visibleButtons())")
        }
        for item in absent {
            XCTAssertFalse(menuItem(item).exists, "\(group)'s menu offers \(item)")
        }
        dismissMenu()
    }

    /// Holds a budget on Home and checks its menu offers these items.
    func expectBudgetMenu(_ budget: String, offers: [String]) {
        scrollTo(AccessibilityID.sidebarBudget(budget))
        longPress(AccessibilityID.sidebarBudget(budget))
        for item in offers {
            XCTAssertTrue(menuItem(item).waitForExistence(timeout: 5), "\(budget)'s menu offers no \(item). On screen: \(visibleButtons())")
        }
        dismissMenu()
    }

    /// Holds a budget on Home and checks it offers no Edit and no Delete.
    /// With no menu to show, letting go opens the budget, as a tap does, so
    /// it goes back to Home after.
    func expectBudgetMenuIsEmpty(_ budget: String) {
        scrollTo(AccessibilityID.sidebarBudget(budget))
        longPress(AccessibilityID.sidebarBudget(budget))
        for item in [MainScreen.Words.edit, MainScreen.Words.delete] {
            XCTAssertFalse(menuItem(item).waitForExistence(timeout: 2), "\(budget) offers \(item)")
        }
        if app.navigationBars[budget].waitForExistence(timeout: 2) {
            goBack()
            XCTAssertTrue(element(AccessibilityID.sidebarAdd).waitForExistence(timeout: 10), "not back on Home")
        } else {
            dismissMenu()
        }
    }

    /// Signs in on the account sheet already open, pasting the email and the
    /// password, and waits for it to close.
    func signInOnTheOpenSheet(email: String, password: String, server: String) throws {
        let serverField = element(AccessibilityID.accountServer)
        XCTAssertTrue(serverField.waitForExistence(timeout: 10), "the sign-in sheet did not open")
        if (serverField.value as? String) != server { type(server, into: AccessibilityID.accountServer) }
        paste(email, into: AccessibilityID.accountEmail)
        paste(password, into: AccessibilityID.accountPassword)
        tap(AccessibilityID.accountSubmit)
        XCTAssertTrue(wait(for: serverField, until: "exists == false", timeout: 60),
                      "signing in did not finish. On screen: \(visibleTexts())")
    }
}
