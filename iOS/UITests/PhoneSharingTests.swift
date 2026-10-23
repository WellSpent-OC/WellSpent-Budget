import Foundation
import UIKit
import XCTest
import WellSpentAppCore
import WellSpentCrypto
import WellSpentModel
import WellSpentSync

/// Sending and responding to email invitations on a phone, plus legacy
/// received links and management of joined people. The second account uses
/// the production sync API against the same test server, without a window.
///
/// Needs the four WELLSPENT_UI_TEST_ variables (see UITestAccounts.swift)
/// and skips without them. Both accounts must exist on staging with their
/// addresses confirmed. Every run makes groups of its own, named with the
/// time. At the end it waits until the phone's changes are on the server,
/// deletes the groups and signs every session out. Other runs may share the
/// accounts at the same time, so it never assumes the groups it sees are its
/// own.
final class PhoneSharingTests: XCTestCase {
    nonisolated(unsafe) private static var dataRootPath: String?

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    /// No await in it, as in PhoneSignInSyncTests. A halted run can leave a
    /// group named "UI Phone <time>" on staging, which a later run clears.
    override func tearDown() {
        let app = XCUIApplication()
        if app.state != .notRunning { app.terminate() }
        if let path = Self.dataRootPath { try? FileManager.default.removeItem(atPath: path) }
        Self.dataRootPath = nil
        // A halted run must not leave a password or a link on the pasteboard.
        UIPasteboard.general.items = []
        super.tearDown()
    }

    @MainActor
    func testEmailInvitationAndManagePeople() async throws {
        let accounts = try TestAccounts.fromEnvironment()
        let run = PhoneTestApp()
        Self.dataRootPath = run.dataRoot.path
        let leslie = try SecondAccount(server: accounts.server)
        let stamp = PhoneTestApp.stamp()
        let groupName = SecondAccount.phoneRunPrefix + stamp
        let lesliesGroup = groupName + " Leslie"
        run.launch()
        try run.signIn(email: accounts.email, password: accounts.password, server: accounts.server)
        XCTAssertTrue(run.element(AccessibilityID.toolbarAccount).waitForExistence(timeout: 10), "no Account")
        run.addGroup(named: groupName)
        run.scrollTo(AccessibilityID.sidebarGroup(groupName))

        // Scenario SHARE-01, EMAIL-01
        // 1. The addressed form keeps Add and full history as its defaults.
        run.longPress(AccessibilityID.sidebarGroup(groupName))
        run.tapMenuItem(MainScreen.Words.share)
        XCTAssertTrue(run.text("Invite someone to “\(groupName)”").waitForExistence(timeout: 10),
                      "no email invitation sheet")
        for id in [AccessibilityID.shareEmail, AccessibilityID.shareInviteeName, AccessibilityID.shareName] {
            XCTAssertTrue(run.element(id).exists, "a required invitation field is missing")
        }
        let roles = run.element(AccessibilityID.shareRole)
        for role in InviteRole.allCases {
            XCTAssertTrue(roles.buttons[role.title].exists, "They can offers no \(role.title)")
        }
        XCTAssertTrue(roles.buttons[InviteRole.add.title].isSelected, "Add is not chosen")
        XCTAssertTrue(run.text(InviteRole.add.explanation).exists)
        XCTAssertTrue(run.text(EmailInviteScreen.Words.note).exists)
        let history = run.element(AccessibilityID.shareHistory)
        XCTAssertTrue(history.label.contains(EmailInviteScreen.Words.historyAll)
                      || (history.value as? String ?? "").contains(EmailInviteScreen.Words.historyAll),
                      "Everything so far is not selected")
        XCTAssertFalse(run.button(AccessibilityID.shareCreate).isEnabled, "an empty form can send")
        run.type("Robin", into: AccessibilityID.shareName)
        run.type("Leslie", into: AccessibilityID.shareInviteeName)
        run.type("not-an-address", into: AccessibilityID.shareEmail)
        XCTAssertFalse(run.button(AccessibilityID.shareCreate).isEnabled, "an invalid email can send")
        run.paste(accounts.secondEmail, into: AccessibilityID.shareEmail)
        run.tap(AccessibilityID.shareCreate)
        XCTAssertTrue(run.element(AccessibilityID.shareDone).waitForExistence(timeout: 30),
                      "sending did not finish")
        XCTAssertFalse(run.element(AccessibilityID.shareCopyLink).exists, "Copy Link is still offered")
        run.tap(AccessibilityID.shareDone)

        // 2. The sender sees Pending; the invitation does not count as a member.
        run.openGroupPage(named: groupName)
        XCTAssertTrue(run.text(EmailInvitationWords.pending).waitForExistence(timeout: 15))
        XCTAssertFalse(run.element(AccessibilityID.groupPerson("Leslie")).exists)
        let pendingSummary = MembersScreen.Words.line([MembersScreen.Words.notShared, MembersScreen.Words.madeByYou])
        XCTAssertTrue(run.wait(for: run.element(AccessibilityID.groupSummary),
                               until: "label == '\(pendingSummary)'", timeout: 15))

        // Scenario EMAIL-05
        run.app.buttons[EmailInvitationWords.cancelInvite].firstMatch.tap()
        run.cancelQuestion()
        XCTAssertTrue(run.text(EmailInvitationWords.pending).exists)
        run.app.buttons[EmailInvitationWords.cancelInvite].firstMatch.tap()
        try XCTUnwrap(run.questionButton(EmailInvitationWords.cancelInvite)).tap()
        XCTAssertTrue(run.wait(for: run.text(EmailInvitationWords.pending), until: "exists == false", timeout: 20))
        run.tap(AccessibilityID.groupInvite)
        XCTAssertTrue(run.element(AccessibilityID.shareEmail).waitForExistence(timeout: 10))
        XCTAssertTrue(run.element(AccessibilityID.shareName).value as? String == "Robin",
                      "Your name was not remembered")
        run.type("Leslie", into: AccessibilityID.shareInviteeName)
        run.paste(accounts.secondEmail, into: AccessibilityID.shareEmail)
        run.tap(AccessibilityID.shareCreate)
        XCTAssertTrue(run.element(AccessibilityID.shareDone).waitForExistence(timeout: 30))
        run.tap(AccessibilityID.shareDone)
        XCTAssertTrue(run.text(EmailInvitationWords.pending).waitForExistence(timeout: 15))
        run.goBack()
        try await leslie.signIn(email: accounts.secondEmail, password: accounts.secondPassword)
        await leslie.deleteLeftoverRuns()
        let addressed = try XCTUnwrap(leslie.sync.incomingInvitations.first { $0.groupName == groupName },
                                       "the recipient has no addressed invitation")
        _ = try await leslie.sync.acceptInvitation(addressed)
        try await leslie.syncAll()

        // Scenario SHARE-07, PASTE-03, EMAIL-08
        // 5. A link Leslie sent, pasted into Join a Group with a name, joins
        // her group: the sheet closes and the group is on Home.
        let lesliesLink = try await leslie.shareNewGroup(lesliesGroup, budget: "Costs \(stamp)", entry: "Costco",
                                                         amount: Money(minorUnits: 9900), myName: "Leslie", role: .add)
        run.openAddMenu()
        run.tapMenuItem(MainScreen.Words.join)
        run.paste(lesliesLink.url, into: AccessibilityID.joinLink)
        let pasted = (run.element(AccessibilityID.joinLink).value as? String) ?? ""
        XCTAssertTrue(InviteLink(parsing: pasted) == lesliesLink, "Paste changed the legacy invitation")
        XCTAssertEqual(lesliesLink.scheme, InviteLink.stagingScheme)
        XCTAssertTrue(run.text("Leslie invited you to \u{201C}\(lesliesGroup)\u{201D}.").waitForExistence(timeout: 10),
                      "the pasted link does not say who invited whom. On screen: \(run.visibleTexts())")
        run.type("Robin", into: AccessibilityID.joinName)
        run.tap(AccessibilityID.joinJoin)
        XCTAssertTrue(run.wait(for: run.element(AccessibilityID.joinLink), until: "exists == false", timeout: 20),
                      "Join a Group stayed. On screen: \(run.visibleTexts())")
        XCTAssertTrue(run.scrollTo(AccessibilityID.sidebarGroup(lesliesGroup)).exists,
                      "her group is not on Home. On screen: \(run.visibleTexts())")

        // Scenario PAGE-01, PAGE-06, PAGE-08, PAGE-09
        // 6. A tap on the group's name opens its page. It says it is shared
        // by two, made by Robin, and lists him first as the owner, then
        // Leslie at Add. Invite Someone shows, and Leave Group does not.
        run.openGroupPage(named: groupName)
        let summary = run.element(AccessibilityID.groupSummary)
        let shared = MembersScreen.Words.line([MembersScreen.Words.shared, MembersScreen.Words.peopleCount(2),
                                               MembersScreen.Words.madeByYou])
        XCTAssertTrue(run.wait(for: summary, until: "label == '\(shared)'", timeout: 20),
                      "the page does not say it is shared by two: \(summary.label)")
        let robinRow = run.element(AccessibilityID.groupPerson("Robin"))
        let leslieRow = run.element(AccessibilityID.groupPerson("Leslie"))
        XCTAssertTrue(robinRow.label.contains(MembersScreen.Words.you("Robin")), "no Robin (you): \(robinRow.label)")
        XCTAssertTrue(robinRow.label.contains(MembersScreen.Words.levelTitle(.superadmin)), "Robin is not the owner")
        XCTAssertTrue(leslieRow.label.contains(MembersScreen.Words.levelTitle(.write)), "Leslie is not at Add")
        XCTAssertLessThan(robinRow.frame.minY, leslieRow.frame.minY, "the owner does not come first")
        XCTAssertTrue(run.element(AccessibilityID.groupInvite).exists, "no Invite Someone")
        XCTAssertFalse(run.element(AccessibilityID.groupLeave).exists, "the owner is offered Leave Group")

        // Scenario PAGE-10
        // 7. A tap on Leslie opens her page: the four levels, a tick on Add.
        // A tap on View moves the tick, and her row says what View does.
        run.tap(AccessibilityID.groupPerson("Leslie"))
        for level in MembershipRules.grantable.sorted() {
            XCTAssertTrue(levelRow(level, in: run).waitForExistence(timeout: 10),
                          "no \(MembersScreen.Words.levelTitle(level)). On screen: \(run.visibleTexts())")
        }
        XCTAssertTrue(levelRow(.write, in: run).isSelected, "Add has no tick")
        levelRow(.read, in: run).tap()
        XCTAssertTrue(run.wait(for: levelRow(.read, in: run), until: "selected == true", timeout: 20),
                      "the tick did not move to View. On screen: \(run.visibleTexts()) \(run.visibleButtons())")
        run.goBack()
        XCTAssertTrue(run.wait(for: leslieRow, until: "label CONTAINS '\(InviteRole.view.explanation)'", timeout: 10),
                      "her row does not say what View does: \(leslieRow.label)")

        // Scenario SHARE-16
        // 8. Remove on her page asks from the bottom of the screen. Once
        // removed, her page closes, and the group's page says so, and that
        // it is no longer shared.
        run.tap(AccessibilityID.groupPerson("Leslie"))
        run.tap(AccessibilityID.groupRemove("Leslie"))
        XCTAssertTrue(run.text(MembersScreen.Words.removeTitle("Leslie")).waitForExistence(timeout: 5),
                      "no question. On screen: \(run.visibleTexts())")
        try XCTUnwrap(run.questionButton(MembersScreen.Words.removeButton)).tap()
        XCTAssertTrue(run.element(AccessibilityID.groupRemoved).waitForExistence(timeout: 20),
                      "no line saying she was removed. On screen: \(run.visibleTexts())")
        XCTAssertEqual(run.element(AccessibilityID.groupRemoved).label, MembersScreen.Words.removed("Leslie"))
        let alone = MembersScreen.Words.line([MembersScreen.Words.notShared, MembersScreen.Words.madeByYou])
        XCTAssertTrue(run.wait(for: summary, until: "label == '\(alone)'", timeout: 10),
                      "the page still says it is shared: \(summary.label)")

        // Scenario BUDGET-11
        // 9. Delete under the page's ⋯ asks first, then the group and its
        // page go, back to Home.
        run.tap(AccessibilityID.groupMenu)
        run.tapMenuItem(MainScreen.Words.delete)
        try XCTUnwrap(run.questionButton("Delete"), "no Delete on the question").tap()
        XCTAssertTrue(run.element(AccessibilityID.sidebarAdd).waitForExistence(timeout: 10), "not back on Home")
        XCTAssertTrue(run.wait(for: run.element(AccessibilityID.sidebarGroup(groupName)), until: "exists == false",
                               timeout: 10), "the group is still on Home")

        // 10. Tidy: the delete reaches the server before signing out, which
        // sends nothing. Leslie's group goes for everyone, and every session
        // ends.
        run.syncAndWait()
        run.signOut()
        await leslie.deleteGroup(named: lesliesGroup)
        await leslie.cleanUp()
    }

    @MainActor
    func testEmailInboxRejectAndAcceptAFreshInvitation() async throws {
        let accounts = try TestAccounts.fromEnvironment()
        let run = PhoneTestApp()
        Self.dataRootPath = run.dataRoot.path
        let sender = try SecondAccount(server: accounts.server)
        try await sender.signIn(email: accounts.secondEmail, password: accounts.secondPassword)
        let stamp = PhoneTestApp.stamp()
        let groupName = SecondAccount.phoneRunPrefix + stamp + " Inbox"
        let budgets = ["Food " + stamp, "Travel " + stamp]
        let group = try await EmailInvitationFixture.makeGroup(sender: sender, named: groupName, budgets: budgets)
        let first = try await EmailInvitationFixture.send(sender: sender, group: group,
                                                           groupName: groupName, to: accounts.email)
        run.launch()
        try run.signIn(email: accounts.email, password: accounts.password, server: accounts.server)

        // Scenario EMAIL-02
        XCTAssertTrue(run.element(AccessibilityID.incomingInvitation(first.id)).waitForExistence(timeout: 20))
        XCTAssertTrue(run.text(EmailInvitationWords.invited).exists)
        XCTAssertTrue(run.text(EmailInvitationWords.from("Leslie")).exists)
        XCTAssertTrue(run.text(InviteRole.add.title + " · " + JoinScreen.Words.sees(.all)).exists)
        XCTAssertFalse(run.element(AccessibilityID.sidebarGroup(groupName)).exists)
        for budget in budgets { XCTAssertFalse(run.element(AccessibilityID.sidebarBudget(budget)).exists) }

        // Scenario EMAIL-04
        run.tap(AccessibilityID.rejectInvitation(first.id))
        run.cancelQuestion()
        XCTAssertTrue(run.element(AccessibilityID.acceptInvitation(first.id)).exists)
        run.tap(AccessibilityID.rejectInvitation(first.id))
        try XCTUnwrap(run.questionButton(EmailInvitationWords.reject)).tap()
        XCTAssertTrue(run.wait(for: run.element(AccessibilityID.incomingInvitation(first.id)),
                               until: "exists == false", timeout: 20))
        let rejected = try await sender.sync.invites(in: group)
        XCTAssertEqual(rejected.first { $0.id == first.id }?.status, "rejected")
        run.syncAndWait()
        XCTAssertFalse(run.element(AccessibilityID.incomingInvitation(first.id)).exists)

        let fresh = try await EmailInvitationFixture.send(sender: sender, group: group,
                                                           groupName: groupName, to: accounts.email)
        XCTAssertNotEqual(fresh.id, first.id)
        run.syncAndWait()
        XCTAssertTrue(run.element(AccessibilityID.acceptInvitation(fresh.id)).waitForExistence(timeout: 20))

        // Scenario EMAIL-03
        run.tap(AccessibilityID.acceptInvitation(fresh.id))
        XCTAssertTrue(run.element(AccessibilityID.groupSummary).waitForExistence(timeout: 20))
        XCTAssertFalse(run.element(AccessibilityID.invitationName).exists, "Accept asked for a name")
        XCTAssertTrue(run.element(AccessibilityID.groupPerson("Robin")).waitForExistence(timeout: 15),
                      "the accepted member did not receive their invited name")
        run.goBack()
        XCTAssertFalse(run.element(AccessibilityID.incomingInvitation(fresh.id)).exists)
        for budget in budgets { XCTAssertTrue(run.scrollTo(AccessibilityID.sidebarBudget(budget)).exists) }
        run.openBudget(named: budgets[0])
        XCTAssertTrue(run.element(AccessibilityID.entryRow("Existing purchase")).waitForExistence(timeout: 15))
        run.goBack()
        run.signOut()
        await sender.deleteGroup(named: groupName)
        await sender.cleanUp()
    }

    @MainActor
    func testATappedInviteLinkJoinsAndLeaving() async throws {
        let accounts = try TestAccounts.fromEnvironment()
        let run = PhoneTestApp()
        Self.dataRootPath = run.dataRoot.path
        let leslie = try SecondAccount(server: accounts.server)
        let stamp = PhoneTestApp.stamp()
        let groupName = SecondAccount.phoneRunPrefix + stamp
        let budgetName = "Costs \(stamp)"
        run.launch()
        try run.signIn(email: accounts.email, password: accounts.password, server: accounts.server)
        XCTAssertTrue(run.element(AccessibilityID.toolbarAccount).waitForExistence(timeout: 10), "no Account")
        try await leslie.signIn(email: accounts.secondEmail, password: accounts.secondPassword)
        await leslie.deleteLeftoverRuns()
        let link = try await leslie.shareNewGroup(groupName, budget: budgetName, entry: "Costco",
                                                  amount: Money(minorUnits: 9900), myName: "Leslie", role: .view,
                                                  history: .fromNow)

        // Scenario CLICK-01, CLICK-03
        // 1. A tap on Leslie's link opens its invitation page: who invited
        // Robin to what, then what the server says it offers, here View and
        // only what is added from now on. Join stays dimmed until there is a
        // name, and there is no Decline.
        run.open(link: link.url)
        XCTAssertTrue(run.text("Leslie invited you to \u{201C}\(groupName)\u{201D}.").waitForExistence(timeout: 15),
                      "no invitation page. On screen: \(run.visibleTexts())")
        XCTAssertTrue(run.text(JoinScreen.Words.joinsAt(InviteRole.view.title)).waitForExistence(timeout: 15),
                      "no level from the server. On screen: \(run.visibleTexts())")
        XCTAssertTrue(run.text(InviteRole.view.explanation).exists, "no line about what View lets them do")
        XCTAssertTrue(run.text(JoinScreen.Words.sees(.fromNow)).exists, "no line about what they would see")
        XCTAssertFalse(run.app.buttons["Decline"].exists, "the page offers Decline")
        let join = run.button(AccessibilityID.invitationJoin)
        XCTAssertTrue(join.waitForExistence(timeout: 10),
                      "no Join. On screen: \(run.visibleTexts()) \(run.visibleButtons())")
        XCTAssertFalse(join.isEnabled, "Join is not dimmed")

        // Scenario CLICK-04
        // 2. Join takes the group in and opens its page in place of the
        // invitation.
        run.type("Robin", into: AccessibilityID.invitationName)
        run.tap(AccessibilityID.invitationJoin)
        let summary = run.element(AccessibilityID.groupSummary)
        let shared = MembersScreen.Words.line([MembersScreen.Words.shared, MembersScreen.Words.peopleCount(2),
                                               MembersScreen.Words.madeBy("Leslie")])
        XCTAssertTrue(summary.waitForExistence(timeout: 20), "no group page. On screen: \(run.visibleTexts())")
        XCTAssertTrue(run.wait(for: summary, until: "label == '\(shared)'", timeout: 20),
                      "the page does not say Leslie shared it with two: \(summary.label)")

        // Scenario PAGE-12
        // 3. At View, the page shows levels only: no one to tap, no Invite
        // Someone, and Leave Group at the end.
        let robinRow = run.element(AccessibilityID.groupPerson("Robin"))
        XCTAssertTrue(robinRow.label.contains(MembersScreen.Words.levelTitle(.read)), "Robin is not at View")
        XCTAssertNotEqual(robinRow.elementType, .button, "Robin's own row opens a page")
        XCTAssertNotEqual(run.element(AccessibilityID.groupPerson("Leslie")).elementType, .button,
                          "Leslie's row opens a page")
        XCTAssertFalse(run.element(AccessibilityID.groupInvite).exists, "View is offered Invite Someone")
        XCTAssertTrue(run.element(AccessibilityID.groupLeave).exists, "no Leave Group")

        // Scenario PAGE-14, SHARE-15
        // 4. Leslie makes Robin an admin, so the group's menu offers him
        // Delete. Leave Group still asks first, and leaves: the group and its
        // page go from the phone, and Leslie keeps it, with what is in it.
        let model = AppModel(store: leslie.sync.store)
        let group = try XCTUnwrap(model.groups.first { $0.name == groupName }, "Leslie has no group").id
        await leslie.sync.refresh(group)
        let robin = try XCTUnwrap(leslie.sync.members(of: group).keys.first { $0 != leslie.sync.userID },
                                  "Leslie does not see Robin in her group")
        try await leslie.sync.setLevel(.admin, of: robin, in: group)
        run.pullDown()
        XCTAssertTrue(run.wait(for: robinRow, until: "label CONTAINS '\(MembersScreen.Words.levelTitle(.admin))'",
                               timeout: 20), "Robin is not an admin on the phone: \(robinRow.label)")
        run.tap(AccessibilityID.groupMenu)
        XCTAssertTrue(run.menuItem(MainScreen.Words.delete).waitForExistence(timeout: 5),
                      "the group's menu does not offer Delete. On screen: \(run.visibleButtons())")
        run.dismissMenu()
        run.tap(AccessibilityID.groupLeave)
        XCTAssertTrue(run.text(MembersScreen.Words.leaveTitle(groupName)).waitForExistence(timeout: 5),
                      "no question. On screen: \(run.visibleTexts())")
        try XCTUnwrap(run.questionButton(MembersScreen.Words.leaveButton)).tap()
        XCTAssertTrue(run.element(AccessibilityID.sidebarAdd).waitForExistence(timeout: 10), "not back on Home")
        XCTAssertTrue(run.wait(for: run.element(AccessibilityID.sidebarGroup(groupName)), until: "exists == false",
                               timeout: 10), "the group is still on Home")
        var others = leslie.sync.members(of: group).count
        let deadline = Date().addingTimeInterval(30)
        while others > 1, Date() < deadline {
            try await Task.sleep(for: .seconds(1))
            await leslie.sync.refresh(group)
            others = leslie.sync.members(of: group).count
        }
        XCTAssertEqual(others, 1, "the server still lists Robin in Leslie's group")
        let kept = try await leslie.waitFor(group: groupName, budget: budgetName, merchant: "Costco", timeout: 15)
        XCTAssertTrue(kept, "Leslie lost her group, its budget or Costco")

        // 5. Tidy: the leave is on the server, as Leslie's list shows. Her
        // group goes for everyone, and every session ends.
        run.signOut()
        await leslie.deleteGroup(named: groupName)
        await leslie.cleanUp()
    }

    /// A level on a person's page, by its name at the start of the row.
    @MainActor
    private func levelRow(_ level: AccessLevel, in run: PhoneTestApp) -> XCUIElement {
        let title = MembersScreen.Words.levelTitle(level)
        return run.app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", title)).firstMatch
    }
}
