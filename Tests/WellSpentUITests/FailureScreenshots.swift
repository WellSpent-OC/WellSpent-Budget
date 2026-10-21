import XCTest

/// Keeps a picture of the screen whenever a Mac UI test records a failure,
/// unless a test account's address is on screen (ScreenPrivacy).
/// In CI the run's screen is gone afterwards, and XCUITest kept no picture of
/// its own there, so a failed step could only be guessed at (2026-10-19). The
/// picture is kept with the result, and the workflow's upload step takes it.
///
/// One observer for every test, registered by the first `TestApp`: it is
/// given each failure, rather than every test class inheriting a base. XCTest
/// calls its observers on the main thread, which the conformance checks.
@MainActor
final class FailureScreenshots: NSObject, @preconcurrency XCTestObservation {
    nonisolated(unsafe) private static var registered = false

    /// Registers the observer, once per run. Tests start on the main thread.
    nonisolated static func registerOnce() {
        guard !registered else { return }
        registered = true
        MainActor.assumeIsolated {
            XCTestObservationCenter.shared.addTestObserver(FailureScreenshots())
        }
    }

    /// The apps a Mac UI test drives: the test host, and the release twin.
    private static let appsUnderTest = [TestApp.hostBundleIdentifier, "app.wellspent.mac.twin"]

    func testCase(_ testCase: XCTestCase, didRecord issue: XCTIssue) {
        // No picture while a test account's address is on screen, such as on
        // the sign-in sheet: CI's pictures are public, the addresses never.
        let apps = Self.appsUnderTest.map { XCUIApplication(bundleIdentifier: $0) }
        if ScreenPrivacy.showsAnAddress(in: apps) {
            let note = XCTAttachment(string: "No picture: the screen showed a test account's address.")
            note.name = "failure \(testCase.name), no picture"
            note.lifetime = .keepAlways
            testCase.add(note)
            return
        }
        let picture = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        picture.name = "failure \(testCase.name)"
        picture.lifetime = .keepAlways
        testCase.add(picture)
    }
}
