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

    @MainActor
    private func launched() -> PhoneTestApp {
        let run = PhoneTestApp()
        Self.dataRootPath = run.dataRoot.path
        run.launch()
        return run
    }

    @MainActor
    func testExtensionsDiscoveryAndToggle() throws {
        let run = launched()

        // 1. Open the + action menu at the foot of Home
        run.openAddMenu()

        let addExtensionButton = run.element(AccessibilityID.sidebarAddExtension)
        XCTAssertTrue(addExtensionButton.waitForExistence(timeout: 5), "no Add an extension… button")
        addExtensionButton.tap()

        // 2. Extensions Catalog opens
        XCTAssertTrue(run.text("Extensions").waitForExistence(timeout: 5))
        XCTAssertTrue(run.text("WarTable").exists)
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
