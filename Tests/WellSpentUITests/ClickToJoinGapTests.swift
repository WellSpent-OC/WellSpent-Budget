import AppKit
import Foundation
import XCTest
import WellSpentAppCore
import WellSpentCrypto
import WellSpentModel
import WellSpentSync

/// Clicked invite links in the real window, for what InviteLinkTests leaves
/// out: a link's own level and history, another link over the page, a link
/// to a group this person is in already, a used link, picking a budget or a
/// group on the left, and a link made for the other app.
///
/// Two runs:
/// - Signed in, with links the server made. The second account, with no
///   window, makes a group and a link that invites at View with only what is
///   added from now on. The window makes a group and a link of its own. Both
///   groups are named with the time and deleted at the end.
/// - Signed out, with a group of its own, and links made here that no server
///   has heard of. The server is asked only what such an invite offers, and
///   its answer, that it does not know the invite, is not what those steps
///   check. The group is named with the time and deleted at the end. It is
///   made here because the sample groups show only on a Mac's first launch:
///   the test runner is sandboxed, so its wipe of the app's settings never
///   reaches the app, which remembers it made them once.
///
/// The first run needs the four WELLSPENT_UI_TEST_ variables (see
/// UITestSupport.swift) and skips without them. Both accounts must have
/// confirmed their addresses, since joining needs it. There are only two
/// accounts, so the person who clicks the used link is the one who used it,
/// and then left the group.
final class ClickToJoinGapTests: XCTestCase {
    /// The run's data folder, for tearDown.
    nonisolated(unsafe) private static var dataRootPath: String?

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    /// Runs after each test, passed or halted, with no await in it. The app
    /// is closed, and nothing of the run stays on this Mac, the clipboard
    /// included: both runs paste.
    override func tearDown() {
        let app = XCUIApplication()
        if app.state != .notRunning { app.terminate() }
        TestApp.wipeSettings()
        if let path = Self.dataRootPath { try? FileManager.default.removeItem(atPath: path) }
        Self.dataRootPath = nil
        NSPasteboard.general.clearContents()
        super.tearDown()
    }

    // MARK: - Links the server made

    @MainActor
    func testALinksOwnTermsAnotherLinkYourOwnGroupAndAUsedLink() async throws {
        let accounts = try TestAccounts.fromEnvironment()
        let run = try TestApp()
        Self.dataRootPath = run.dataRoot.path
        let second = try SecondAccount(server: accounts.server)
        let stamp = Self.stamp()
        let robinsGroup = "UI Robin \(stamp)", lesliesGroup = "UI Leslie \(stamp)"
        let robinsPage = Self.invited(by: "Robin", to: robinsGroup)
        let lesliesPage = Self.invited(by: "Leslie", to: lesliesGroup)

        // 1. Signed in, Robin makes a group of his own, and a link to it that
        // invites at Add.
        run.launch()
        try run.signIn(email: accounts.email, password: accounts.password, server: accounts.server)
        run.addGroup(named: robinsGroup)
        let robinsLink = try run.share(group: robinsGroup, myName: "Robin", role: .add)

        // 2. The second account, with no window, makes a group with a budget
        // and an entry, and a link that invites at View, with only what is
        // added from now on, as Leslie.
        try await second.signIn(email: accounts.secondEmail, password: accounts.secondPassword)
        let lesliesLink = try await second.shareNewGroup(lesliesGroup, budget: "Bulk", entry: "Costco",
                                                         amount: Money(minorUnits: 2863), myName: "Leslie",
                                                         role: .view, history: .fromNow)

        // Scenario CLICK-10
        // 3. Robin clicks his own link, types his name and presses Join. The
        // page says he is in that group already.
        try run.click(link: robinsLink.url)
        XCTAssertTrue(run.listText(robinsPage).waitForExistence(timeout: 15),
                      "no invitation page for his own link. On screen: \(run.visibleTexts())")
        let atAdd = JoinScreen.Words.joinsAt(MembersScreen.Words.levelTitle(InviteRole.add.level))
        XCTAssertTrue(run.listText(atAdd).waitForExistence(timeout: 30),
                      "the page does not say \(atAdd) On screen: \(run.visibleTexts())")
        run.type("Robin", into: AccessibilityID.invitationName)
        run.click(AccessibilityID.invitationJoin)
        XCTAssertTrue(run.listText(Self.alreadyInTheGroup).waitForExistence(timeout: 30),
                      "the page does not say \(Self.alreadyInTheGroup) On screen: \(run.visibleTexts())")

        // Scenario CLICK-10
        // 4. The link is not used up: it still takes Leslie in.
        let lesliesModel = try await second.join(robinsLink, as: "Leslie")
        XCTAssertTrue(lesliesModel.groups.contains { $0.name == robinsGroup },
                      "his link did not take Leslie in: \(lesliesModel.groups.map(\.name))")

        // Scenario CLICK-03, CLICK-11
        // 5. Leslie's link, clicked while his own link's page is up, replaces
        // it. The page gives that invite's own level, what it lets him do,
        // and how much he would see: View, and only what is added from now on.
        try run.click(link: lesliesLink.url)
        XCTAssertTrue(run.listText(lesliesPage).waitForExistence(timeout: 15),
                      "no invitation page for Leslie's link. On screen: \(run.visibleTexts())")
        XCTAssertTrue(run.wait(for: run.listText(robinsPage), until: "exists == false", timeout: 10),
                      "the last link's page stayed. On screen: \(run.visibleTexts())")
        for line in Self.terms(InviteRole.view.level, .fromNow) {
            XCTAssertTrue(run.listText(line).waitForExistence(timeout: 30),
                          "the page does not say \(line) On screen: \(run.visibleTexts())")
        }
        XCTAssertFalse(run.listText(Self.alreadyInTheGroup).exists, "the last page's answer stayed")

        // 6. He joins with it, and the group's page opens. Leave Group…
        // takes the group off this Mac, and once Leslie's list shows nobody
        // else in it, the server has the leave.
        run.type("Robin", into: AccessibilityID.invitationName)
        run.click(AccessibilityID.invitationJoin)
        XCTAssertTrue(run.element(AccessibilityID.groupSummary).waitForExistence(timeout: 60),
                      "joining did not open the group's page. On screen: \(run.visibleTexts())")
        run.click(AccessibilityID.groupLeave)
        try XCTUnwrap(run.dialogButton(MembersScreen.Words.leaveButton),
                      "no \(MembersScreen.Words.leaveButton) on the question. On screen: \(run.visibleTexts())").click()
        XCTAssertTrue(run.wait(for: run.element(AccessibilityID.sidebarGroup(lesliesGroup)), until: "exists == false",
                               timeout: 10), "the group is still in the sidebar after leaving it")
        let left = try await second.waitForMembers(1, in: lesliesGroup)
        XCTAssertTrue(left, "the server still lists Robin in Leslie's group")

        // Scenario CLICK-09
        // 7. The used link, clicked again, still says who invited him to
        // what. It has no level or history lines, and says the invite was
        // not found.
        try run.click(link: lesliesLink.url)
        XCTAssertTrue(run.listText(lesliesPage).waitForExistence(timeout: 15),
                      "no invitation page for the used link. On screen: \(run.visibleTexts())")
        XCTAssertTrue(run.listText(Self.inviteNotFound).waitForExistence(timeout: 30),
                      "the page does not say \(Self.inviteNotFound) On screen: \(run.visibleTexts())")
        for line in Self.everyTermsLine {
            XCTAssertFalse(run.listText(line).exists, "a used link's page says \(line)")
        }

        // Scenario CLICK-09
        // 8. He types his name and presses Join anyway. The page says the
        // invite has already been accepted, and the group is not added.
        run.type("Robin", into: AccessibilityID.invitationName)
        run.click(AccessibilityID.invitationJoin)
        XCTAssertTrue(run.listText(Self.alreadyAccepted).waitForExistence(timeout: 30),
                      "the page does not say \(Self.alreadyAccepted) On screen: \(run.visibleTexts())")
        XCTAssertFalse(run.element(AccessibilityID.sidebarGroup(lesliesGroup)).waitForExistence(timeout: 5),
                       "the used link added the group")

        // 9. Tidy: Robin's group goes for everyone, and once it is gone from
        // Leslie's list, the delete is on the server. Leslie's group goes
        // too, and both sessions end.
        run.revealInSidebar(run.element(AccessibilityID.sidebarGroup(robinsGroup)))
        run.deleteGroup(named: robinsGroup)
        _ = await second.waitUntilGone(robinsGroup)
        await second.deleteGroup(named: lesliesGroup)
        run.signOut()
        await second.cleanUp()
    }

    // MARK: - Links no server knows

    @MainActor
    func testTheOtherAppsLinkAndPickingABudgetOrAGroup() throws {
        let run = try TestApp()
        Self.dataRootPath = run.dataRoot.path
        let stamp = Self.stamp()
        let groupName = "UI Pick \(stamp)"
        let fuel = "Fuel \(stamp)", treats = "Treats \(stamp)"
        let live = Self.link(to: "Household", from: "Robin", for: .live)
        let roadTrip = Self.link(to: "Road trip", from: "Robin", for: .staging)
        let otherApp = JoinScreen.Words.otherApp(AppEnvironment.live.appName)
        let roadTripPage = Self.invited(by: "Robin", to: "Road trip")
        // Nothing is spent, so every wheel reads the same whatever the day,
        // and the two budgets' amounts tell their wheels and the group's apart.
        let fuelToday = TodaysBudget(fuel, limit: 10_000, spent: 0)
        let treatsToday = TodaysBudget(treats, limit: 25_000, spent: 0)
        let month = try XCTUnwrap(TodaysBudget.group(groupName, [fuelToday, treatsToday]))

        // Scenario CLICK-13
        // 1. A link of the live app's type, the kind WellSpent makes, opened
        // by hand in this staging build, starts it on a page that says which
        // app the link is for. There is no Your name and no Join.
        try run.open(link: live.url)
        XCTAssertTrue(run.listText(otherApp).waitForExistence(timeout: 15),
                      "the page does not say \(otherApp) On screen: \(run.visibleTexts())")
        XCTAssertFalse(run.element(AccessibilityID.invitationName).exists, "Your name, for the other app's link")
        XCTAssertFalse(run.element(AccessibilityID.invitationJoin).exists, "Join, for the other app's link")

        // Scenario CLICK-13
        // 2. Pasted into Join a Group…, the same link gets the same words.
        run.openAddMenu()
        run.clickMenuItem(MainScreen.Words.join)
        run.paste(live.url, into: AccessibilityID.joinLink)
        XCTAssertTrue(run.app.sheets.firstMatch.staticTexts[otherApp].waitForExistence(timeout: 10),
                      "Join a Group does not say \(otherApp) On screen: \(run.visibleTexts())")
        run.click(AccessibilityID.joinCancel)
        XCTAssertTrue(run.wait(for: run.element(AccessibilityID.joinLink), until: "exists == false", timeout: 10),
                      "Join a Group stayed open")

        // 3. A group with two budgets: $100.00 for Fuel, then $250.00 for
        // Treats. The group's page takes the other app's page down, and
        // saving a budget opens it, so Treats is open.
        run.addGroup(named: groupName)
        run.openGroupPage(named: groupName)
        run.addBudget(named: fuel, amount: "100", inGroup: groupName)
        run.addBudget(named: treats, amount: "250", inGroup: groupName)

        // 4. A link of this build's type, clicked, puts up its invitation
        // page in place of Treats.
        try run.click(link: roadTrip.url)
        XCTAssertTrue(run.listText(roadTripPage).waitForExistence(timeout: 15),
                      "no invitation page. On screen: \(run.visibleTexts())")

        // Scenario CLICK-12
        // 5. Picking Fuel on the left shows it in place of the page.
        run.openBudget(named: fuel)
        run.expect(wheel: AccessibilityID.budgetWheel, reads: fuelToday.wheel.spokenSummary,
                   "Fuel, picked over the invitation")
        XCTAssertTrue(run.wait(for: run.listText(roadTripPage), until: "exists == false", timeout: 10),
                      "the invitation stayed over the budget. On screen: \(run.visibleTexts())")

        // Scenario CLICK-12
        // 6. The invitation does not come back by itself. Clicking the link
        // again brings it back.
        XCTAssertFalse(run.listText(roadTripPage).waitForExistence(timeout: 3), "the invitation came back by itself")
        try run.click(link: roadTrip.url)
        XCTAssertTrue(run.listText(roadTripPage).waitForExistence(timeout: 15),
                      "clicking the link again did not bring the invitation back. On screen: \(run.visibleTexts())")

        // Scenario CLICK-12
        // 7. A click on the group's name opens its page in place of the
        // invitation, which stays down.
        run.openGroupPage(named: groupName)
        run.expect(wheel: AccessibilityID.groupWheel, reads: month.wheel.spokenSummary,
                   "the group's page, opened over the invitation")
        XCTAssertTrue(run.wait(for: run.listText(roadTripPage), until: "exists == false", timeout: 10),
                      "the invitation stayed over the group's page. On screen: \(run.visibleTexts())")
        XCTAssertFalse(run.listText(roadTripPage).waitForExistence(timeout: 3), "the invitation came back by itself")

        // 8. Tidy: the group goes, with its budgets.
        run.deleteGroup(named: groupName)
    }
}

// MARK: - Helpers

@MainActor
private extension ClickToJoinGapTests {
    /// What the page says when the server refuses. The server's reasons and
    /// the coordinator's answer to a missing invite make these words, and no
    /// Words enum holds them, so they are written here as the scenarios
    /// quote them.
    static let alreadyInTheGroup = "You are already in that group."
    static let inviteNotFound = "That invite was not found. It may have been cancelled."
    static let alreadyAccepted = "That invite has already been accepted."

    /// The line at the top of a link's invitation page, as JoinScreen words
    /// it: Robin invited you to “Household”.
    static func invited(by inviter: String, to group: String) -> String {
        "\(inviter) invited you to \u{201C}\(group)\u{201D}."
    }

    /// The lines the page adds once the server says what an invite offers:
    /// the level, what it lets someone do, and how much they would see.
    static func terms(_ level: AccessLevel, _ history: HistoryAccess) -> [String] {
        [JoinScreen.Words.joinsAt(MembersScreen.Words.levelTitle(level)), MembersScreen.Words.levelExplanation(level),
         JoinScreen.Words.sees(history)]
    }

    /// Every such line, for each level a link can invite at, and both
    /// histories.
    static var everyTermsLine: [String] {
        InviteRole.allCases.flatMap { terms($0.level, .all) } + [JoinScreen.Words.sees(.fromNow)]
    }

    /// A whole invite link of `environment`'s type, made here with a secret
    /// of its own, so no server has heard of its invite.
    static func link(to group: String, from inviter: String, for environment: AppEnvironment) -> InviteLink {
        let secret = Data((0..<32).map { _ in UInt8.random(in: 0...255) })
        return InviteLink(secret: secret, groupName: group, inviterName: inviter, scheme: environment.inviteScheme)
    }

    /// Part of each group's name, so runs never share one.
    static func stamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: Date())
    }
}

private extension SecondAccount {
    /// Syncs until no group of this name is left here, or the time runs out.
    /// A group its founder deleted for everyone goes from the others' lists
    /// at their next sync, once the delete is on the server. Whether it went.
    func waitUntilGone(_ groupName: String, timeout: TimeInterval = 60) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            await sync.syncAll()
            if (try? group(named: groupName)) == nil { return true }
            try? await Task.sleep(for: .seconds(2))
        } while Date() < deadline
        return false
    }
}
