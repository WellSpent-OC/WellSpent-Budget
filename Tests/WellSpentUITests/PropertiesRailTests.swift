import Foundation
import XCTest
import WellSpentAppCore

/// With Properties off, nothing of it shows. No private package is needed.
final class PropertiesOffTests: XCTestCase {
    nonisolated(unsafe) private static var dataRootPath: String?

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    override func tearDown() {
        let app = XCUIApplication()
        if app.state != .notRunning { app.terminate() }
        TestApp.wipeSettings()
        if let path = Self.dataRootPath { try? FileManager.default.removeItem(atPath: path) }
        Self.dataRootPath = nil
        super.tearDown()
    }

    @MainActor
    func testNothingOfItShows() throws {
        let run = try TestApp()
        Self.dataRootPath = run.dataRoot.path
        run.app.launchEnvironment[FeatureFlags.extensionsVariable] = "1"
        run.launch()
        XCTAssertTrue(run.app.buttons["Extensions"].firstMatch.waitForExistence(timeout: 15), "no Extensions on the rail")

        // Scenario PROP-02
        // No Houses on the rail, and the entry sheet has no House row.
        XCTAssertFalse(run.app.buttons["Houses"].firstMatch.exists, "Houses is on the rail with Properties off")
        run.addGroup(named: "Home")
        run.addBudget(named: "Utilities", amount: "600", inGroup: "Home")
        run.click(AccessibilityID.budgetAdd)
        XCTAssertTrue(run.element(AccessibilityID.entryMerchant).waitForExistence(timeout: 10), "no entry sheet")
        XCTAssertFalse(run.element(AccessibilityID.entryLink).exists, "the entry sheet has a House row with Properties off")
    }
}

// The Properties card and the Houses tab come with the private package, so this
// exists only when it is linked. A run without it has nothing to skip.
#if canImport(WellSpentPropertiesViews)
final class PropertiesRailTests: XCTestCase {
    nonisolated(unsafe) private static var dataRootPath: String?

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    override func tearDown() {
        let app = XCUIApplication()
        if app.state != .notRunning { app.terminate() }
        TestApp.wipeSettings()
        if let path = Self.dataRootPath { try? FileManager.default.removeItem(atPath: path) }
        Self.dataRootPath = nil
        super.tearDown()
    }

    @MainActor
    func testItJoinsTheRailWhenTurnedOn() throws {
        let run = try TestApp()
        Self.dataRootPath = run.dataRoot.path
        run.app.launchEnvironment[FeatureFlags.extensionsVariable] = "1"
        run.app.launchEnvironment[FeatureFlags.propertiesVariable] = "1"
        run.launch()
        let extensions = run.app.buttons["Extensions"].firstMatch
        XCTAssertTrue(extensions.waitForExistence(timeout: 15), "no Extensions on the rail")
        XCTAssertFalse(run.app.buttons["Houses"].firstMatch.exists, "Houses is on the rail before it is turned on")

        // Scenario PROP-01
        // The catalog offers it, and turning it on puts Houses on the rail.
        extensions.click()
        let turnOn = run.app.buttons["Turn on"].firstMatch
        XCTAssertTrue(turnOn.waitForExistence(timeout: 10), "no Turn on. On screen: \(run.visibleTexts())")
        turnOn.click()
        XCTAssertTrue(run.app.buttons["Houses"].firstMatch.waitForExistence(timeout: 10),
                      "Houses did not join the rail. On screen: \(run.visibleTexts())")

        // Turning it off takes Houses off again.
        extensions.click()
        let turnOff = run.app.buttons["Turn off"].firstMatch
        XCTAssertTrue(turnOff.waitForExistence(timeout: 10), "no Turn off. On screen: \(run.visibleTexts())")
        turnOff.click()
        XCTAssertTrue(run.wait(for: run.app.buttons["Houses"].firstMatch, until: "exists == false", timeout: 10),
                      "Houses stayed on the rail after turning it off")
    }
}
#endif
