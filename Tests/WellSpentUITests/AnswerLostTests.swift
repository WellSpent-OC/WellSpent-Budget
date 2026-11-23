import Foundation
import XCTest
import WellSpentAppCore
import WellSpentModel
import WellSpentSync

/// An Accept whose answer was lost still joins (EMAIL-12, ops#368). The test
/// build's failure switch (`Workspace.faultFileVariable`) lets the server take
/// the Accept and then drops its answer, so the app shows the unreachable
/// error while Leslie is already in the group.
///
/// Needs the four WELLSPENT_UI_TEST_ variables (see UITestAccounts.swift)
/// and skips without them. The second account sends the invitations from
/// groups of its own, named with the time, and deletes them at the end.
final class AnswerLostTests: XCTestCase {
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

    /// Two invitations whose Accept answers are lost. The first is accepted
    /// again, the second is brought in by Sync. Both end in the group, with
    /// no error about the invitation being accepted already.
    @MainActor
    func testALostAcceptAnswerStillJoins() async throws {
        let accounts = try TestAccounts.fromEnvironment()
        let run = try TestApp()
        Self.dataRootPath = run.dataRoot.path
        let sender = try SecondAccount(server: accounts.server)
        try await sender.signIn(email: accounts.secondEmail, password: accounts.secondPassword)
        let stamp = Self.stamp()
        let againGroupName = "UI Leslie " + stamp + " Again"
        let syncGroupName = "UI Leslie " + stamp + " Sync"
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
        let againRow = run.element(AccessibilityID.incomingInvitation(again.id))
        let syncRow = run.element(AccessibilityID.incomingInvitation(bySync.id))
        XCTAssertTrue(againRow.waitForExistence(timeout: 30),
                      "the invitation did not arrive. On screen: \(run.visibleTexts())")
        XCTAssertTrue(syncRow.waitForExistence(timeout: 30))

        // Scenario EMAIL-12
        // Given Leslie pressed Accept, the server accepted it, and the answer
        // never reached the app.
        run.click(AccessibilityID.acceptInvitation(again.id))
        XCTAssertTrue(againRow.staticTexts[Self.unreachable].waitForExistence(timeout: 20),
                      "the lost answer said nothing. On screen: \(run.visibleTexts())")
        let taken = try await sender.sync.invites(in: againGroup)
        XCTAssertNotEqual(taken.first { $0.id == again.id }?.status, "pending", "the server never took the Accept")

        // Scenario EMAIL-12
        // When she presses Accept again, then she is in the group, as in
        // EMAIL-03, with no error about it being accepted already.
        try run.setFaults([])
        run.click(AccessibilityID.acceptInvitation(again.id))
        XCTAssertTrue(run.element(AccessibilityID.groupSummary).waitForExistence(timeout: 20),
                      "Accept again did not open the group. On screen: \(run.visibleTexts())")
        XCTAssertFalse(againRow.exists, "the invitation stayed")
        XCTAssertTrue(run.element(AccessibilityID.sidebarGroup(againGroupName)).waitForExistence(timeout: 20),
                      "the group is not in the sidebar. On screen: \(run.visibleTexts())")
        XCTAssertTrue(run.sidebarBudget(againBudget).waitForExistence(timeout: 20))
        XCTAssertFalse(Self.saysAcceptedAlready(run), "an error says it was accepted already")

        // Scenario EMAIL-12
        // The same lost answer, and then the app syncs: she is in the group,
        // and the invitation and its error go.
        try run.setFaults([.invitationAcceptAnswerLost])
        run.click(AccessibilityID.acceptInvitation(bySync.id))
        XCTAssertTrue(syncRow.staticTexts[Self.unreachable].waitForExistence(timeout: 20),
                      "the second lost answer said nothing. On screen: \(run.visibleTexts())")
        try run.setFaults([])
        run.syncNow()
        XCTAssertTrue(run.wait(for: syncRow, until: "exists == false", timeout: 30),
                      "Sync left the invitation. On screen: \(run.visibleTexts())")
        XCTAssertTrue(run.element(AccessibilityID.sidebarGroup(syncGroupName)).waitForExistence(timeout: 20),
                      "Sync did not bring the group in. On screen: \(run.visibleTexts())")
        XCTAssertTrue(run.sidebarBudget(syncBudget).waitForExistence(timeout: 20))
        XCTAssertFalse(run.app.staticTexts[Self.unreachable].exists, "the error stayed after Sync")
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
    private static func saysAcceptedAlready(_ run: TestApp) -> Bool {
        run.visibleTexts().contains { $0.localizedCaseInsensitiveContains("already been accepted") }
    }

    private static func stamp() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: Date())
    }
}
