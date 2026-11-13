import AppKit
import Foundation
import XCTest
import WellSpentAppCore

/// Diagnosis for #199, not for merging: is the lost Account click the first
/// one after the app's first return to the front, on a window that isn't key?
final class AccountClickDiagTests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = true }

    private static let freePlan = #"{"tier":"free","period":"none","state":"free","source":"none","paidUntil":null,"renews":false,"nextTier":null,"limits":{"properties":1,"groups":1,"invitedPerGroup":1},"used":{"properties":0,"groups":0},"extensionsOpen":[],"canSyncPriceLabs":false,"refreshMinutes":60,"appleAccountToken":null}"#

    @MainActor
    private func launch() throws -> TestApp {
        let run = try TestApp()
        let file = run.dataRoot.appendingPathComponent("plan.json")
        try Data(Self.freePlan.utf8).write(to: file)
        run.app.launchEnvironment[Workspace.pinnedPlanVariable] = file.path
        run.launch()
        return run
    }

    /// To the back and forward, as LockTests does.
    @MainActor
    private func returnToFront(_ run: TestApp) {
        XCUIApplication(bundleIdentifier: "com.apple.finder").activate()
        _ = run.app.wait(for: .runningBackground, timeout: 5)
        run.app.activate()
        XCTAssertTrue(run.app.wait(for: .runningForeground, timeout: 10))
        Thread.sleep(forTimeInterval: 2)
    }

    @MainActor
    private func accountOpens(_ run: TestApp, _ label: String) -> Bool {
        let start = Date()
        run.click(AccessibilityID.toolbarAccount)
        let opened = run.element(AccessibilityID.accountClose).waitForExistence(timeout: 10)
        print("DIAG \(label): opened=\(opened) after \(Date().timeIntervalSince(start))s sheets=\(run.app.sheets.count) frontmost=\(NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "none")")
        return opened
    }

    /// D: four fresh launches; each returns to the front once, then Account.
    @MainActor
    func testDFirstReturnThenAccount() throws {
        var results: [Bool] = []
        for index in 1...4 {
            let run = try launch()
            returnToFront(run)
            results.append(accountOpens(run, "D\(index)"))
            run.app.terminate()
            try? FileManager.default.removeItem(at: run.dataRoot)
        }
        print("DIAG D results: \(results)")
        XCTAssertEqual(results, [true, true, true, true])
    }

    /// E: the same, with a click on the staging banner before Account.
    @MainActor
    func testEFirstReturnClickBannerThenAccount() throws {
        var results: [Bool] = []
        for index in 1...4 {
            let run = try launch()
            returnToFront(run)
            run.element(AccessibilityID.stagingBanner).click()
            results.append(accountOpens(run, "E\(index)"))
            run.app.terminate()
            try? FileManager.default.removeItem(at: run.dataRoot)
        }
        print("DIAG E results: \(results)")
        XCTAssertEqual(results, [true, true, true, true])
    }
}
