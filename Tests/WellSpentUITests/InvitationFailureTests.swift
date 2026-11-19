import Foundation
import XCTest
import WellSpentAppCore
import WellSpentModel
import WellSpentSync

/// An Accept or Reject that can't reach the server says so, and can be tried
/// again. The test build's failure switch (`Workspace.faultFileVariable`)
/// makes each one fail as an unreachable server would, before it gets there.
///
/// Needs the four WELLSPENT_UI_TEST_ variables (see UITestAccounts.swift)
/// and skips without them. The second account sends the invitations from
/// groups of its own, named with the time, and deletes them at the end.
final class InvitationFailureTests: XCTestCase {
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

    /// What the Mac app says when it can't reach the server.
    private static let unreachable = AccountWording.words(for: AppFaults.unreachable)

    @MainActor
    func testAFailedAcceptOrRejectSaysSoAndCanBeTriedAgain() async throws {
        let accounts = try TestAccounts.fromEnvironment()
        let run = try TestApp()
        Self.dataRootPath = run.dataRoot.path
        let sender = try SecondAccount(server: accounts.server)
        try await sender.signIn(email: accounts.secondEmail, password: accounts.secondPassword)
        let stamp = Self.stamp()
        let acceptGroupName = "UI Leslie " + stamp + " Accept"
        let rejectGroupName = "UI Leslie " + stamp + " Reject"
        let budget = "Food " + stamp
        let acceptGroup = try await EmailInvitationFixture.makeGroup(sender: sender, named: acceptGroupName,
                                                                     budgets: [budget])
        let rejectGroup = try await EmailInvitationFixture.makeGroup(sender: sender, named: rejectGroupName,
                                                                     budgets: ["Travel " + stamp])
        let toAccept = try await EmailInvitationFixture.send(sender: sender, group: acceptGroup,
                                                              groupName: acceptGroupName, to: accounts.email)
        let toReject = try await EmailInvitationFixture.send(sender: sender, group: rejectGroup,
                                                              groupName: rejectGroupName, to: accounts.email)

        try run.setFaults([.invitationAccept, .invitationReject])
        run.launch()
        try run.signIn(email: accounts.email, password: accounts.password, server: accounts.server)
        let acceptRow = run.element(AccessibilityID.incomingInvitation(toAccept.id))
        let rejectRow = run.element(AccessibilityID.incomingInvitation(toReject.id))
        XCTAssertTrue(acceptRow.waitForExistence(timeout: 30),
                      "the invitation did not arrive. On screen: \(run.visibleTexts())")
        XCTAssertTrue(rejectRow.waitForExistence(timeout: 30))

        // Scenario EMAIL-10
        // Accept fails: the row says why, keeps Accept and Reject, and the
        // group is not in the sidebar. The server never heard it.
        run.click(AccessibilityID.acceptInvitation(toAccept.id))
        XCTAssertTrue(acceptRow.staticTexts[Self.unreachable].waitForExistence(timeout: 20),
                      "a failed Accept said nothing. On screen: \(run.visibleTexts())")
        XCTAssertTrue(run.element(AccessibilityID.acceptInvitation(toAccept.id)).exists, "no Accept to try again")
        XCTAssertTrue(run.element(AccessibilityID.rejectInvitation(toAccept.id)).exists)
        XCTAssertFalse(run.element(AccessibilityID.sidebarGroup(acceptGroupName)).exists,
                       "a failed Accept put the group in the sidebar")
        XCTAssertFalse(run.element(AccessibilityID.sidebarBudget(budget)).exists)
        XCTAssertFalse(rejectRow.staticTexts[Self.unreachable].exists, "the other invitation took the failure")
        let afterAccept = try await sender.sync.invites(in: acceptGroup)
        XCTAssertEqual(afterAccept.first { $0.id == toAccept.id }?.status, "pending")

        // Scenario EMAIL-10
        // Reject fails the same way: the row stays and says why.
        run.click(AccessibilityID.rejectInvitation(toReject.id))
        try XCTUnwrap(run.dialogButton(EmailInvitationWords.reject)).click()
        XCTAssertTrue(rejectRow.staticTexts[Self.unreachable].waitForExistence(timeout: 20),
                      "a failed Reject said nothing. On screen: \(run.visibleTexts())")
        XCTAssertTrue(run.element(AccessibilityID.rejectInvitation(toReject.id)).exists, "no Reject to try again")
        XCTAssertTrue(run.element(AccessibilityID.acceptInvitation(toReject.id)).exists)
        let afterReject = try await sender.sync.invites(in: rejectGroup)
        XCTAssertEqual(afterReject.first { $0.id == toReject.id }?.status, "pending")

        // Scenario EMAIL-10
        // With the server in reach again, trying again works, with no relaunch.
        try run.setFaults([])
        run.click(AccessibilityID.rejectInvitation(toReject.id))
        try XCTUnwrap(run.dialogButton(EmailInvitationWords.reject)).click()
        XCTAssertTrue(run.wait(for: rejectRow, until: "exists == false", timeout: 20),
                      "Reject did not work the second time. On screen: \(run.visibleTexts())")
        let rejected = try await sender.sync.invites(in: rejectGroup)
        XCTAssertEqual(rejected.first { $0.id == toReject.id }?.status, "rejected")

        run.click(AccessibilityID.acceptInvitation(toAccept.id))
        XCTAssertTrue(run.element(AccessibilityID.groupSummary).waitForExistence(timeout: 20),
                      "Accept did not work the second time. On screen: \(run.visibleTexts())")
        XCTAssertFalse(acceptRow.exists)
        XCTAssertTrue(run.element(AccessibilityID.sidebarGroup(acceptGroupName)).waitForExistence(timeout: 20),
                      "the group is not in the sidebar. On screen: \(run.visibleTexts())")
        XCTAssertTrue(run.element(AccessibilityID.sidebarBudget(budget)).waitForExistence(timeout: 20))
        let accepted = try await sender.sync.invites(in: acceptGroup)
        XCTAssertNotEqual(accepted.first { $0.id == toAccept.id }?.status, "pending",
                          "the server never heard the Accept")

        run.signOut()
        await sender.deleteGroup(named: acceptGroupName)
        await sender.deleteGroup(named: rejectGroupName)
        // The deletes' own sync is sent once and not looked at. This one is
        // sent again if the network drops, and fails with the server's words.
        try await sender.syncAll()
        await sender.cleanUp()
    }

    private static func stamp() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: Date())
    }
}
