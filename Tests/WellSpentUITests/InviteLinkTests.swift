import Foundation
import XCTest
import WellSpentAppCore
import WellSpentModel
import WellSpentSync

/// A click on an invite link, in the real window: the link opens the app on
/// its invitation page, and Join takes the group in.
///
/// The link goes to the app with XCUIApplication.open(_:), so it reaches
/// the app under test whatever else on this Mac takes staging's links.
/// The second person, with no window, makes the group and the link, as in
/// EntryEditingTests.
///
/// Needs the four WELLSPENT_UI_TEST_ variables (see UITestSupport.swift) and
/// skips without them.
final class InviteLinkTests: XCTestCase {
    /// The run's data folder, for tearDown.
    nonisolated(unsafe) private static var dataRootPath: String?

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    /// Runs after the test, passed or halted, with no await in it. The app
    /// is closed, and nothing of the run stays on this Mac.
    override func tearDown() {
        let app = XCUIApplication()
        if app.state != .notRunning { app.terminate() }
        TestApp.wipeSettings()
        if let path = Self.dataRootPath { try? FileManager.default.removeItem(atPath: path) }
        Self.dataRootPath = nil
        super.tearDown()
    }

    @MainActor
    func testAClickedInviteLinkOpensItsInvitationAndJoinTakesTheGroupIn() async throws {
        let accounts = try TestAccounts.fromEnvironment()
        let run = try TestApp()
        Self.dataRootPath = run.dataRoot.path
        let second = try SecondAccount(server: accounts.server)
        let groupName = "UI Link \(Self.stamp())"
        let add = InviteRole.add.level

        // 1. The second account, with no window, makes a group with a budget
        // and an entry, and a link that invites at Add, as Leslie.
        try await second.signIn(email: accounts.secondEmail, password: accounts.secondPassword)
        let link = try await second.shareNewGroup(groupName, budget: "Bulk", entry: "Costco",
                                                  amount: Money(minorUnits: 2863), myName: "Leslie", role: .add)

        // 2. A link cut short, the way a message app can cut one, starts the
        // app on a page that says part of it is missing. There is no Join.
        try run.open(link: String(link.url.prefix("\(link.scheme)://join#s=".count + 20)))
        XCTAssertTrue(run.listText(JoinScreen.Words.notWhole).waitForExistence(timeout: 15),
                      "no line saying part of the link is missing. On screen: \(run.visibleTexts())")
        XCTAssertFalse(run.element(AccessibilityID.invitationJoin).exists, "Join, for a link with part missing")

        // 3. The whole link: who invited this person and to what, the level
        // and what it lets them do, and how much they would see. Signed out,
        // the notice and Sign in… stand in place of Join.
        try run.open(link: link.url)
        let invited = "Leslie invited you to \u{201C}\(groupName)\u{201D}."
        XCTAssertTrue(run.listText(invited).waitForExistence(timeout: 15),
                      "the page does not say who invited them. On screen: \(run.visibleTexts())")
        for line in [JoinScreen.Words.joinsAt(MembersScreen.Words.levelTitle(add)),
                     MembersScreen.Words.levelExplanation(add), JoinScreen.Words.sees(.all)] {
            XCTAssertTrue(run.listText(line).waitForExistence(timeout: 30),
                          "the page does not say \(line) On screen: \(run.visibleTexts())")
        }
        XCTAssertTrue(run.listText(JoinScreen.Words.signInToJoin).exists,
                      "no notice to sign in first. On screen: \(run.visibleTexts())")
        XCTAssertFalse(run.element(AccessibilityID.invitationJoin).exists, "Join, while signed out")

        // 4. Sign in… opens the sign-in sheet. Signed in, the page stays, and
        // Join takes the notice's place.
        run.click(AccessibilityID.invitationSignIn)
        try run.signInOnSheet(email: accounts.email, password: accounts.password, server: accounts.server)
        XCTAssertTrue(run.element(AccessibilityID.invitationJoin).waitForExistence(timeout: 30),
                      "no Join once signed in. On screen: \(run.visibleTexts())")
        XCTAssertTrue(run.listText(invited).exists, "the page did not stay through signing in")

        // 5. A name, pasted, then Join: the group is in the sidebar, and its
        // page opens with both people in it.
        run.pasteAndCheck("Robin", into: AccessibilityID.invitationName)
        run.click(AccessibilityID.invitationJoin)
        let summary = MembersScreen.Words.line([MembersScreen.Words.shared, MembersScreen.Words.peopleCount(2),
                                                MembersScreen.Words.madeBy("Leslie")])
        XCTAssertTrue(run.wait(for: run.element(AccessibilityID.groupSummary), holds: summary, timeout: 60),
                      "the group's page did not open with \(summary). On screen: \(run.visibleTexts())")
        XCTAssertTrue(run.element(AccessibilityID.sidebarGroup(groupName)).exists, "the group is not in the sidebar")

        // 6. Tidy: the second account deletes its group, and both sessions end.
        await second.deleteGroup(named: groupName)
        run.signOut()
        await second.cleanUp()
    }

    /// Part of the group's name, so runs never share one.
    private static func stamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: Date())
    }
}
