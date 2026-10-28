import Foundation
import XCTest
import WellSpentAppCore
import WellSpentCrypto
import WellSpentModel

/// Tests the Extensions catalog, discovery menu, and native TabView on iPhone.
final class PhoneExtensionsTests: XCTestCase {
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

    /// The app with extensions and WarTable turned on. The catalog and its
    /// menu item are behind `FeatureFlags.areExtensionsEnabled`, and the
    /// WarTable card behind `isWarTableEnabled`, both off by default since
    /// 4bf63e5, so a fresh install shows none of it until the flags are
    /// set. The test sets them the way a staging scheme would, through the
    /// environment.
    @MainActor
    private func launched() -> PhoneTestApp {
        let run = PhoneTestApp()
        Self.dataRootPath = run.dataRoot.path
        run.app.launchEnvironment[FeatureFlags.extensionsVariable] = "1"
        run.app.launchEnvironment[FeatureFlags.warTableVariable] = "1"
        run.launch()
        return run
    }

    @MainActor
    func testExtensionsDiscoveryAndToggle() throws {
        let run = launched()

        // 1. Open the + action menu at the foot of Home
        run.openAddMenu()

        // A menu's items reach the test by their titles, as `tapMenuItem`
        // finds them. This one keeps its "…" on the phone, so it is looked
        // up by its full title, with the wait a slow runner needs.
        let title = "Add an extension…"
        let addExtension = run.app.buttons[title].firstMatch
        XCTAssertTrue(addExtension.waitForExistence(timeout: 15),
                      "no \(title) in the menu. On screen: \(run.visibleButtons())")
        addExtension.tap()

        // 2. Extensions Catalog opens
        XCTAssertTrue(run.text("Extensions").waitForExistence(timeout: 5))
        XCTAssertTrue(run.text("WarTable").exists)
        // The card is listed by name whatever its status; with the Runway
        // flag off it reads "Coming later". SEAM-1 renames the card to
        // "Properties", which the second name already allows for.
        XCTAssertTrue(run.text("Runway (Properties)").exists || run.text("Properties").exists)

        // 3. Turn on WarTable
        let turnOn = run.button("Turn on")
        XCTAssertTrue(turnOn.exists, "no Turn on button for WarTable")
        turnOn.tap()

        // WarTable staging placeholder opens
        XCTAssertTrue(run.text("WarTable").waitForExistence(timeout: 5))
        XCTAssertTrue(run.text("STAGING PREVIEW · IN DEVELOPMENT").exists)

        // 4. Tap Budgets tab in the TabView
        let budgetsTab = run.element("Budgets")
        if budgetsTab.exists {
            budgetsTab.tap()
        }

        // Open Household group page to inspect visual polish
        run.openGroupPage(named: "Household")
        XCTAssertTrue(run.element(AccessibilityID.groupSummary).waitForExistence(timeout: 5))
    }
}
