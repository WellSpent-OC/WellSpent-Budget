import XCTest

/// Keeps a picture of the simulator's screen whenever an iPhone UI test
/// records a failure, unless a test account's address is on screen
/// (ScreenPrivacy). As on the Mac (FailureScreenshots): in CI the run's
/// screen is gone afterwards, so without a picture a failed step could only
/// be guessed at. The picture is kept with the result, and the workflow's
/// upload step takes it.
///
/// One observer for every test, registered by the first `PhoneTestApp`.
/// XCTest calls its observers on the main thread, which the conformance checks.
@MainActor
final class PhoneFailureScreenshots: NSObject, @preconcurrency XCTestObservation {
    nonisolated(unsafe) private static var registered = false

    /// Registers the observer, once per run. Tests start on the main thread.
    nonisolated static func registerOnce() {
        guard !registered else { return }
        registered = true
        MainActor.assumeIsolated {
            XCTestObservationCenter.shared.addTestObserver(PhoneFailureScreenshots())
        }
    }

    /// The app under test, and the home screen's own process, which draws
    /// system alerts over it. Both are always installed on a simulator, so
    /// neither stops the run for want of an app.
    private static var appsOnScreen: [XCUIApplication] {
        [XCUIApplication(), XCUIApplication(bundleIdentifier: "com.apple.springboard")]
    }

    func testCase(_ testCase: XCTestCase, didRecord issue: XCTIssue) {
        // No picture while a test account's address is on screen, such as on
        // the sign-in sheet: CI's pictures are public, the addresses never.
        if ScreenPrivacy.showsAnAddress(in: Self.appsOnScreen) {
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
