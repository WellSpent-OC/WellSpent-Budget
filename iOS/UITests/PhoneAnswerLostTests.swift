import Foundation
import XCTest
import WellSpentAppCore
import WellSpentModel
import WellSpentSync

/// An Accept whose answer was lost still joins (EMAIL-12, ops#368), on the
/// phone. The test build's failure switch (`Workspace.faultFileVariable`) lets
/// the server take the Accept and then drops its answer, so the phone shows it
/// couldn't reach the server while Leslie is already in the group. The Mac's
/// `AnswerLostTests` does the same with two invitations.
///
/// Needs the WELLSPENT_UI_TEST_ variables (see UITestAccounts.swift) and
/// skips without them. The second account sends the invitations from groups
/// of its own, named with the time, and deletes them at the end.
final class PhoneAnswerLostTests: XCTestCase {
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

    /// What the phone says when the server's answer is lost: the failure
    /// switch's error, the same words the Mac's test reads.
    @MainActor
    private static var offline: String {
        AccountWording.words(for: AppFaults.unreachable, device: PhoneTestApp.device)
    }

    /// Two invitations whose Accept answers are lost. The first is accepted
    /// again, the second is brought in by a sync. Both end in the group, with
    /// no error about the invitation being accepted already.
    @MainActor
    func testALostAcceptAnswerStillJoins() async throws {
        let accounts = try TestAccounts.fromEnvironment()
        let run = PhoneTestApp()
        Self.dataRootPath = run.dataRoot.path
        let sender = try SecondAccount(server: accounts.server)
        try await sender.signIn(email: accounts.secondEmail, password: accounts.secondPassword)
        let stamp = PhoneTestApp.stamp()
        let againGroupName = SecondAccount.phoneRunPrefix + stamp + " Again"
        let syncGroupName = SecondAccount.phoneRunPrefix + stamp + " Sync"
        let againBudget = "Food " + stamp
        let syncBudget = "Travel " + stamp
        let againGroup = try await EmailInvitationFixture.makeGroup(sender: sender, named: againGroupName,
                                                                    budgets: [againBudget])
        let syncGroup = try await EmailInvitationFixture.makeGroup(sender: sender, named: syncGroupName,
                                                                   budgets: [syncBudget])
        let again = try await EmailInvitationFixture.send(sender: sender, group: againGroup,
                                                           groupName: againGroupName, to: accounts.email)
        let bySync = try await EmailInvitationFixture.send(sender: sender, group: syncGroup,
                                                            groupName: syncGroupName, to: accounts.email)

        try run.setFaults([.invitationAcceptAnswerLost])
        run.launch()
        try run.signIn(email: accounts.email, password: accounts.password, server: accounts.server)
        run.syncAndWait()
        let againRow = run.element(AccessibilityID.incomingInvitation(again.id))
        let syncRow = run.element(AccessibilityID.incomingInvitation(bySync.id))
        XCTAssertTrue(run.scrollTo(AccessibilityID.acceptInvitation(again.id)).exists,
                      "the invitation did not arrive. On screen: \(run.visibleTexts())")

        // Scenario EMAIL-12
        // Given Leslie pressed Accept, the server accepted it, and the answer
        // never reached the app.
        run.tap(AccessibilityID.acceptInvitation(again.id))
        XCTAssertTrue(againRow.staticTexts[Self.offline].waitForExistence(timeout: 20),
                      "the lost answer said nothing. On screen: \(run.visibleTexts())")
        let taken = try await sender.sync.invites(in: againGroup)
        XCTAssertNotEqual(taken.first { $0.id == again.id }?.status, "pending", "the server never took the Accept")

        // Scenario EMAIL-12
        // When she presses Accept again, then she is in the group, as in
        // EMAIL-03, with no error about it being accepted already.
        try run.setFaults([])
        run.tap(AccessibilityID.acceptInvitation(again.id))
        XCTAssertTrue(run.element(AccessibilityID.groupSummary).waitForExistence(timeout: 20),
                      "Accept again did not open the group. On screen: \(run.visibleTexts())")
        XCTAssertFalse(Self.saysAcceptedAlready(run), "an error says it was accepted already")
        run.goBack()
        XCTAssertTrue(run.wait(for: againRow, until: "exists == false", timeout: 15), "the invitation stayed")
        XCTAssertTrue(run.scrollTo(AccessibilityID.sidebarGroup(againGroupName), timeout: 20).exists,
                      "the group is not on Home. On screen: \(run.visibleTexts())")
        XCTAssertTrue(run.scrollTo(AccessibilityID.sidebarBudget(againBudget), timeout: 20).exists,
                      "the group's budget is not on Home. On screen: \(run.visibleTexts())")
        XCTAssertFalse(Self.saysAcceptedAlready(run), "an error says it was accepted already")

        // Scenario EMAIL-12
        // The same lost answer, and then the app syncs: she is in the group,
        // and the invitation and its error go.
        try run.setFaults([.invitationAcceptAnswerLost])
        XCTAssertTrue(run.scrollTo(AccessibilityID.acceptInvitation(bySync.id)).exists,
                      "the second invitation is not on Home. On screen: \(run.visibleTexts())")
        run.tap(AccessibilityID.acceptInvitation(bySync.id))
        XCTAssertTrue(syncRow.staticTexts[Self.offline].waitForExistence(timeout: 20),
                      "the second lost answer said nothing. On screen: \(run.visibleTexts())")
        try run.setFaults([])
        run.syncAndWait()
        XCTAssertTrue(run.wait(for: syncRow, until: "exists == false", timeout: 30),
                      "a sync left the invitation. On screen: \(run.visibleTexts())")
        XCTAssertTrue(run.scrollTo(AccessibilityID.sidebarGroup(syncGroupName), timeout: 20).exists,
                      "a sync did not bring the group in. On screen: \(run.visibleTexts())")
        XCTAssertTrue(run.scrollTo(AccessibilityID.sidebarBudget(syncBudget), timeout: 20).exists,
                      "the group's budget is not on Home. On screen: \(run.visibleTexts())")
        XCTAssertFalse(run.app.staticTexts[Self.offline].exists, "the error stayed after a sync")
        XCTAssertFalse(Self.saysAcceptedAlready(run), "an error says it was accepted already")

        run.signOut()
        await sender.deleteGroup(named: againGroupName)
        await sender.deleteGroup(named: syncGroupName)
        // The deletes' own sync is sent once and not looked at. This one is
        // sent again if the network drops, and fails with the server's words.
        try await sender.syncAll()
        await sender.cleanUp()
    }

    /// Whether any text on screen says the invitation was accepted already.
    @MainActor
    private static func saysAcceptedAlready(_ run: PhoneTestApp) -> Bool {
        run.visibleTexts().contains { $0.localizedCaseInsensitiveContains("already been accepted") }
    }
}
