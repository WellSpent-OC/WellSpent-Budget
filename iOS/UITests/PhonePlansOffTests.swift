import Foundation
import XCTest
import WellSpentAppCore
import WellSpentModel

/// Plans off, on a phone: the "off" side of the plans switch. The app has no
/// plan answer, as when the server runs with WELLSPENT_PLANS off. Here the
/// pinned answer file names a file that isn't there, so asking for the plan
/// fails (`Workspace.pinnedPlanVariable`). Signed in, the phone then shows no
/// plan card, no locked card, no pick and no Choose a plan.
///
/// Each of those gates on a shared value the package tests also check with
/// plans off: `plans.answer`, `lockedScreen`, `pickScreen()` and
/// `sync.planSheet`. Needs the four WELLSPENT_UI_TEST_ variables and skips
/// without them. Signs in, so it runs in light only.
final class PhonePlansOffTests: XCTestCase {
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

    @MainActor
    func testWithNoPlanAnswerNothingAboutPlansShows() throws {
        let accounts = try TestAccounts.fromEnvironment()
        let group = "Rentals \(PhoneTestApp.stamp())"
        let run = PhoneTestApp()
        Self.dataRootPath = run.dataRoot.path
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent("no-plan-\(UUID().uuidString).json")
        run.app.launchEnvironment[Workspace.pinnedPlanVariable] = missing.path
        run.app.launchEnvironment[Workspace.emptyStoreVariable] = "empty"
        run.launch()
        try run.signIn(email: accounts.email, password: accounts.password, server: accounts.server)
        run.addGroup(named: group)
        run.syncAndWait()

        // No Choose a plan and no pick, on their own.
        XCTAssertFalse(choosePlan(run).exists, "Choose a plan opened with no plan answer")
        XCTAssertFalse(run.element(AccessibilityID.pickSheet).exists, "the pick opened with no plan answer")

        // The group's page, with no locked card.
        run.openGroupPage(named: group)
        XCTAssertTrue(run.lacks(AccessibilityID.lockedCard), "a locked card with no plan answer")
        run.goBack()

        // The account sheet, signed in, with no plan card.
        run.tap(AccessibilityID.toolbarAccount)
        XCTAssertTrue(run.element(AccessibilityID.accountChangePassword).waitForExistence(timeout: 15),
                      "the account sheet didn't open signed in. On screen: \(run.visibleTexts())")
        XCTAssertTrue(run.lacks(AccessibilityID.planCard), "a plan card with no plan answer")
        XCTAssertFalse(choosePlan(run).exists, "Choose a plan opened with no plan answer")
        run.tap(AccessibilityID.accountClose)
    }

    private func choosePlan(_ run: PhoneTestApp) -> XCUIElement {
        run.app.navigationBars[PlanWording.choosePlan].firstMatch
    }
}
