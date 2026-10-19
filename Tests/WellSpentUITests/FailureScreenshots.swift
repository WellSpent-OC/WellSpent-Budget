import XCTest

/// Keeps a picture of the screen whenever a Mac UI test records a failure.
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

    func testCase(_ testCase: XCTestCase, didRecord issue: XCTIssue) {
        let picture = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        picture.name = "failure \(testCase.name)"
        picture.lifetime = .keepAlways
        testCase.add(picture)
    }
}
