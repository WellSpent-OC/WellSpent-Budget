import AppKit
import Foundation
import XCTest
import WellSpentAppCore

/// Command-V pastes into the app's text fields, the way a person pastes the
/// code from a sign-up email or an address copied from somewhere else. The
/// first TestFlight build had no Edit menu, and Command-V did nothing in any
/// field (2026-10-17). Needs no account and no server: it only opens the
/// sign-in sheet. The main flow test also signs in by pasting.
final class PasteTests: XCTestCase {
    /// The run's data folder, for tearDown.
    nonisolated(unsafe) private static var dataRootPath: String?

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    /// Closes the app and leaves nothing of the run on this Mac, the clipboard
    /// included.
    override func tearDown() {
        let app = XCUIApplication()
        if app.state != .notRunning { app.terminate() }
        TestApp.wipeSettings()
        if let path = Self.dataRootPath { try? FileManager.default.removeItem(atPath: path) }
        Self.dataRootPath = nil
        NSPasteboard.general.clearContents()
        super.tearDown()
    }

    @MainActor
    func testCommandVPastesIntoATextField() throws {
        let run = try TestApp()
        Self.dataRootPath = run.dataRoot.path
        run.launch()
        run.click(AccessibilityID.sidebarSignIn)

        // Scenario PASTE-01
        run.paste("pasted@example.com", into: AccessibilityID.accountEmail)
        XCTAssertEqual(run.element(AccessibilityID.accountEmail).value as? String, "pasted@example.com",
                       "Command-V did not paste into the email field")
    }
}
