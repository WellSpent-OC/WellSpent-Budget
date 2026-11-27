import Foundation
import XCTest
import WellSpentAppCore

/// Whether Houses is a tab on the phone. With Properties off, nothing of it
/// shows, and that needs no private package. Turning it on does, because the
/// test extension has no catalog card, so that test is built only with one.
final class PhonePropertiesTabTests: XCTestCase {
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
    private func launched(extensionsOn: Bool) -> PhoneTestApp {
        let run = PhoneTestApp()
        Self.dataRootPath = run.dataRoot.path
        if extensionsOn {
            run.app.launchEnvironment[FeatureFlags.extensionsVariable] = "1"
            run.app.launchEnvironment[FeatureFlags.propertiesVariable] = "1"
        }
        run.launch()
        return run
    }

    // Scenario PROP-02
    @MainActor
    func testWithPropertiesOffNothingOfItShows() throws {
        let run = launched(extensionsOn: false)
        XCTAssertTrue(run.has(AccessibilityID.sidebarAdd), "Home did not open")
        XCTAssertFalse(run.app.tabBars.buttons["Houses"].exists, "Houses shows with extensions off")

        // Extensions on, with Properties still off in the catalog.
        run.app.terminate()
        try? FileManager.default.removeItem(at: run.dataRoot)
        let again = launched(extensionsOn: true)
        XCTAssertTrue(again.has(AccessibilityID.sidebarAdd), "Home did not open")
        XCTAssertFalse(again.app.tabBars.buttons["Houses"].exists, "Houses shows before it is turned on")
    }

    #if canImport(WellSpentPropertiesViews)
    // Scenario PROP-01
    @MainActor
    func testTurningOnPropertiesAddsTheTab() throws {
        let run = launched(extensionsOn: true)
        run.openAddMenu()
        let addExtension = run.app.buttons["Add an extension…"].firstMatch
        XCTAssertTrue(addExtension.waitForExistence(timeout: 15), "no Add an extension…. On screen: \(run.visibleButtons())")
        addExtension.tap()
        let turnOn = run.app.buttons["Turn on"].firstMatch
        XCTAssertTrue(turnOn.waitForExistence(timeout: 10), "no Turn on for Properties. On screen: \(run.visibleButtons())")
        turnOn.tap()
        XCTAssertTrue(run.app.tabBars.buttons["Houses"].waitForExistence(timeout: 10), "no Houses tab")
        XCTAssertTrue(run.app.tabBars.buttons["Budgets"].exists, "no Budgets tab beside it")
    }

    // Scenario PROP-63
    @MainActor
    func testItStaysOnAfterTheAppIsClosed() throws {
        // Given Robin turned Properties on
        let run = launched(extensionsOn: true)
        run.openAddMenu()
        let addExtension = run.app.buttons["Add an extension…"].firstMatch
        XCTAssertTrue(addExtension.waitForExistence(timeout: 15), "no Add an extension…. On screen: \(run.visibleButtons())")
        addExtension.tap()
        let turnOn = run.app.buttons["Turn on"].firstMatch
        XCTAssertTrue(turnOn.waitForExistence(timeout: 10), "no Turn on for Properties. On screen: \(run.visibleButtons())")
        turnOn.tap()
        XCTAssertTrue(run.app.tabBars.buttons["Houses"].waitForExistence(timeout: 10), "no Houses tab")

        // When he closes WellSpent and opens it again
        run.app.terminate()
        XCTAssertTrue(run.app.wait(for: .notRunning, timeout: 10), "the app did not close")
        run.launch()

        // Then Properties is still on, and Houses is a tab
        XCTAssertTrue(run.app.tabBars.buttons["Houses"].waitForExistence(timeout: 15),
                      "no Houses tab after opening again. On screen: \(run.visibleButtons())")
        XCTAssertTrue(run.app.tabBars.buttons["Budgets"].exists, "no Budgets tab beside it")
        run.openAddMenu()
        let again = run.app.buttons["Add an extension…"].firstMatch
        XCTAssertTrue(again.waitForExistence(timeout: 15), "no Add an extension…. On screen: \(run.visibleButtons())")
        again.tap()
        XCTAssertTrue(run.app.buttons["Turn off"].firstMatch.waitForExistence(timeout: 10),
                      "Properties is not on in the catalog. On screen: \(run.visibleButtons())")
        XCTAssertFalse(run.app.buttons["Turn on"].exists, "the catalog offers Turn on again")
    }
    #endif
}
