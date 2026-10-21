import Foundation
import UIKit
import XCTest
import WellSpentAppCore
import WellSpentCrypto
import WellSpentModel
import WellSpentSync

/// Sharing on a phone, signed in: Robin shares a group through the iPhone's
/// share sheet and manages who is in it, and Robin taps a link Leslie sent
/// and joins her group, then leaves it. Leslie has no window: she is a
/// coordinator inside this process, against the same staging server.
///
/// Needs the four WELLSPENT_UI_TEST_ variables (see UITestAccounts.swift)
/// and skips without them. Both accounts must exist on staging with their
/// addresses confirmed. Every run makes groups of its own, named with the
/// time, and deletes them at the end. Other runs may share the accounts at
/// the same time, so it never assumes the groups it sees are its own.
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
    func testShareThroughTheShareSheetAndManagePeople() async throws {
        let accounts = try TestAccounts.fromEnvironment()
        let run = PhoneTestApp()
        Self.dataRootPath = run.dataRoot.path
        let leslie = try SecondAccount(server: accounts.server)
        let groupName = SecondAccount.phoneRunPrefix + PhoneTestApp.stamp()
        run.launch()
        try run.signIn(email: accounts.email, password: accounts.password, server: accounts.server)
        XCTAssertTrue(run.element(AccessibilityID.toolbarAccount).waitForExistence(timeout: 10), "no Account")
        run.addGroup(named: groupName)
        run.scrollTo(AccessibilityID.sidebarGroup(groupName))

        // Scenario SHARE-01
        // 1. Share in the group's menu asks for a name, what they can do,
        // with Add chosen, and what they see. Create Link stays dimmed until
        // there is a name.
        run.longPress(AccessibilityID.sidebarGroup(groupName))
        run.tapMenuItem(MainScreen.Words.share)
        XCTAssertTrue(run.text(ShareScreen.Words.shareTitle(groupName)).waitForExistence(timeout: 10),
                      "no Share sheet. On screen: \(run.visibleTexts())")
        let roles = run.element(AccessibilityID.shareRole)
        for role in InviteRole.allCases {
            XCTAssertTrue(roles.buttons[role.title].exists, "They can offers no \(role.title)")
        }
        XCTAssertTrue(roles.buttons[InviteRole.add.title].isSelected, "Add is not chosen")
        XCTAssertTrue(run.text(InviteRole.add.explanation).exists, "no line about what Add lets them do")
        XCTAssertTrue(run.text(ShareScreen.Words.linkNote).exists)
        XCTAssertFalse(run.button(AccessibilityID.shareCreate).isEnabled, "Create Link is not dimmed")

        // Scenario SHARE-02, SHARE-03
        // 2. Create Link makes the link and opens the iPhone's share sheet
        // with it. Copy puts it on the pasteboard, and the Share sheet
        // closes with the share sheet.
        run.type("Robin", into: AccessibilityID.shareName)
        run.tap(AccessibilityID.shareCreate)
        run.copyInShareSheet()
        XCTAssertTrue(run.wait(for: run.text(ShareScreen.Words.shareTitle(groupName)), until: "exists == false",
                               timeout: 10), "the Share sheet stayed after Copy")

        // Scenario SHARE-07
        // 3. Pasted into Join a Group, the link says who invited whom to
        // what. Leslie joins with it.
        run.openAddMenu()
        run.tapMenuItem(MainScreen.Words.join)
        run.pasteCopied(into: AccessibilityID.joinLink)
        let pasted = (run.element(AccessibilityID.joinLink).value as? String) ?? ""
        let link = try XCTUnwrap(InviteLink(parsing: pasted), "the copied text is not an invite link")
        XCTAssertEqual(link.scheme, InviteLink.stagingScheme)
        XCTAssertTrue(run.text("Robin invited you to \u{201C}\(groupName)\u{201D}.").waitForExistence(timeout: 10),
                      "the pasted link does not say who invited whom. On screen: \(run.visibleTexts())")
        run.tap(AccessibilityID.joinCancel)
        try await leslie.signIn(email: accounts.secondEmail, password: accounts.secondPassword)
        await leslie.deleteLeftoverRuns()
        _ = try await leslie.join(link, as: "Leslie")

        // Scenario PAGE-01, PAGE-06, PAGE-08, PAGE-09
        // 4. A tap on the group's name opens its page. It says it is shared
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
        // 5. A tap on Leslie opens her page: the four levels, a tick on Add.
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
        // 6. Remove on her page asks from the bottom of the screen. Once
        // removed, the page says so, and that it is no longer shared.
        run.tap(AccessibilityID.groupPerson("Leslie"))
        run.tap(AccessibilityID.groupRemove("Leslie"))
        XCTAssertTrue(run.text(MembersScreen.Words.removeTitle("Leslie")).waitForExistence(timeout: 5),
                      "no question. On screen: \(run.visibleTexts())")
        try XCTUnwrap(run.questionButton(MembersScreen.Words.removeButton)).tap()
        XCTAssertTrue(run.element(AccessibilityID.groupRemoved).waitForExistence(timeout: 15),
                      "no line saying she was removed. On screen: \(run.visibleTexts())")
        XCTAssertEqual(run.element(AccessibilityID.groupRemoved).label, MembersScreen.Words.removed("Leslie"))
        let alone = MembersScreen.Words.line([MembersScreen.Words.notShared, MembersScreen.Words.madeByYou])
        XCTAssertTrue(run.wait(for: summary, until: "label == '\(alone)'", timeout: 10),
                      "the page still says it is shared: \(summary.label)")

        // Scenario PAGE-16
        // 7. Delete under the page's ⋯ asks first, then the group and its
        // page go, back to Home.
        run.tap(AccessibilityID.groupMenu)
        run.tapMenuItem(MainScreen.Words.delete)
        try XCTUnwrap(run.questionButton("Delete"), "no Delete on the question").tap()
        XCTAssertTrue(run.element(AccessibilityID.sidebarAdd).waitForExistence(timeout: 10), "not back on Home")
        XCTAssertTrue(run.wait(for: run.element(AccessibilityID.sidebarGroup(groupName)), until: "exists == false",
                               timeout: 10), "the group is still on Home")

        await leslie.cleanUp()
    }

    @MainActor
    func testATappedInviteLinkJoinsAndLeaving() async throws {
        let accounts = try TestAccounts.fromEnvironment()
        let run = PhoneTestApp()
        Self.dataRootPath = run.dataRoot.path
        let leslie = try SecondAccount(server: accounts.server)
        let stamp = PhoneTestApp.stamp()
        let groupName = SecondAccount.phoneRunPrefix + stamp
        run.launch()
        try run.signIn(email: accounts.email, password: accounts.password, server: accounts.server)
        XCTAssertTrue(run.element(AccessibilityID.toolbarAccount).waitForExistence(timeout: 10), "no Account")
        try await leslie.signIn(email: accounts.secondEmail, password: accounts.secondPassword)
        await leslie.deleteLeftoverRuns()
        let link = try await leslie.shareNewGroup(groupName, budget: "Costs \(stamp)", entry: "Costco",
                                                  amount: Money(minorUnits: 9900), myName: "Leslie", role: .add)

        // Scenario CLICK-01, CLICK-03
        // 1. A tap on Leslie's link opens its invitation page: who invited
        // Robin to what, then what the server says it offers. Join stays
        // dimmed until there is a name, and there is no Decline.
        run.open(link: link.url)
        XCTAssertTrue(run.text("Leslie invited you to \u{201C}\(groupName)\u{201D}.").waitForExistence(timeout: 15),
                      "no invitation page. On screen: \(run.visibleTexts())")
        XCTAssertTrue(run.text(JoinScreen.Words.joinsAt(InviteRole.add.title)).waitForExistence(timeout: 15),
                      "no level from the server. On screen: \(run.visibleTexts())")
        XCTAssertTrue(run.text(InviteRole.add.explanation).exists)
        XCTAssertTrue(run.text(JoinScreen.Words.sees(.all)).exists)
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
        // 3. At Add, the page shows levels only: no one to tap, no Invite
        // Someone, and Leave Group at the end.
        let robinRow = run.element(AccessibilityID.groupPerson("Robin"))
        XCTAssertTrue(robinRow.label.contains(MembersScreen.Words.levelTitle(.write)), "Robin is not at Add")
        XCTAssertNotEqual(robinRow.elementType, .button, "Robin's own row opens a page")
        XCTAssertNotEqual(run.element(AccessibilityID.groupPerson("Leslie")).elementType, .button,
                          "Leslie's row opens a page")
        XCTAssertFalse(run.element(AccessibilityID.groupInvite).exists, "Add is offered Invite Someone")
        XCTAssertTrue(run.element(AccessibilityID.groupLeave).exists, "no Leave Group")

        // Scenario PAGE-14, SHARE-15
        // 4. Leave Group asks first, then the group and its page go from the
        // phone. Leslie keeps it.
        run.tap(AccessibilityID.groupLeave)
        XCTAssertTrue(run.text(MembersScreen.Words.leaveTitle(groupName)).waitForExistence(timeout: 5),
                      "no question. On screen: \(run.visibleTexts())")
        try XCTUnwrap(run.questionButton(MembersScreen.Words.leaveButton)).tap()
        XCTAssertTrue(run.element(AccessibilityID.sidebarAdd).waitForExistence(timeout: 10), "not back on Home")
        XCTAssertTrue(run.wait(for: run.element(AccessibilityID.sidebarGroup(groupName)), until: "exists == false",
                               timeout: 10), "the group is still on Home")
        try await leslie.syncAll()
        XCTAssertNotNil(AppModel(store: leslie.sync.store).groups.first { $0.name == groupName },
                        "Leslie lost the group")

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
