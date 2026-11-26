import XCTest

/// For a run-only branch, never merged (ops#412). On its first try the test
/// fails, and then the test runner stops, before xcodebuild can start the
/// retry: xcodebuild restarts the runner and the retry is lost, as in two
/// nightlies. A mark file on the Mac lets any later try pass. The fix
/// should give the lost retry its own run, and that run should pass.
final class PhoneLostRetryProofTests: XCTestCase {
    private static let mark = "/tmp/wellspent-lost-retry-proof"
    private var stopsTheRunner = false

    func testFailsAndThenTheRunnerStops() {
        if FileManager.default.fileExists(atPath: Self.mark) { return }
        XCTAssertTrue(FileManager.default.createFile(atPath: Self.mark, contents: Data()), "no mark file")
        stopsTheRunner = true
        XCTFail("the first try fails")
    }

    override func tearDown() {
        super.tearDown()
        if stopsTheRunner { exit(0) }
    }
}
