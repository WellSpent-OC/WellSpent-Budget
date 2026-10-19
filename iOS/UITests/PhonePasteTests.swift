import Foundation
import UIKit
import XCTest
import WellSpentAppCore

/// Paste from a field's own menu puts copied words into it, the way a person
/// pastes a code or an address on a phone. The Mac's first TestFlight build
/// could not paste at all (2026-10-17). Needs no account and no server: it
/// only opens the sign-in sheet. The signed-in test also signs in by pasting.
final class PhonePasteTests: XCTestCase {
    nonisolated(unsafe) private static var dataRootPath: String?

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    override func tearDown() {
        let app = XCUIApplication()
        if app.state != .notRunning { app.terminate() }
        if let path = Self.dataRootPath { try? FileManager.default.removeItem(atPath: path) }
        Self.dataRootPath = nil
        UIPasteboard.general.items = []
        super.tearDown()
    }

    @MainActor
    func testPasteFromTheFieldsMenu() throws {
        let run = PhoneTestApp()
        Self.dataRootPath = run.dataRoot.path
        run.launch()
        run.tap(AccessibilityID.sidebarSignIn)

        // Scenario PASTE-01
        // 1. Paste in the Email field's menu puts the copied address in it.
        run.paste("pasted@example.com", into: AccessibilityID.accountEmail)
        XCTAssertEqual(run.element(AccessibilityID.accountEmail).value as? String, "pasted@example.com",
                       "Paste did not paste into the email field")
    }
}
