import AppKit
import Foundation
import XCTest
import WellSpentAppCore

/// Diagnosis for #199, not for merging. Signed in, as LockTests is: is the
/// lost Account click the first one after the app's first return to the
/// front? And was the button disabled when the click landed? Coming to the
/// front starts a sync when signed in, and Account is disabled while one runs.
final class AccountClickDiagTests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = true }

    private static let freePlan = #"{"tier":"free","period":"none","state":"free","source":"none","paidUntil":null,"renews":false,"nextTier":null,"limits":{"properties":1,"groups":1,"invitedPerGroup":1},"used":{"properties":0,"groups":0},"extensionsOpen":[],"canSyncPriceLabs":false,"refreshMinutes":60,"appleAccountToken":null}"#

    @MainActor
    private func launchSignedIn() throws -> TestApp {
        let accounts = try TestAccounts.fromEnvironment()
        let run = try TestApp()
        let file = run.dataRoot.appendingPathComponent("plan.json")
        try Data(Self.freePlan.utf8).write(to: file)
        run.app.launchEnvironment[Workspace.pinnedPlanVariable] = file.path
        run.launch()
        try run.signIn(email: accounts.email, password: accounts.password, server: accounts.server)
        return run
    }

    /// To the back and forward, then the same waits LockTests makes: the
    /// window can take a click, and Account is enabled.
    @MainActor
    private func returnToFront(_ run: TestApp, _ label: String) {
        XCUIApplication(bundleIdentifier: "com.apple.finder").activate()
        _ = run.app.wait(for: .runningBackground, timeout: 5)
        let forward = Date()
        run.app.activate()
        XCTAssertTrue(run.app.wait(for: .runningForeground, timeout: 10))
        let window = run.app.windows.firstMatch
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline, !(NSWorkspace.shared.frontmostApplication?.bundleIdentifier
                                   == TestApp.hostBundleIdentifier && window.isHittable) {
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        let account = run.element(AccessibilityID.toolbarAccount)
        let enabled = run.wait(for: account, until: "enabled == true", timeout: 60)
        print("DIAG \(label): ready \(String(format: "%.2f", Date().timeIntervalSince(forward)))s after activate, enabledWait=\(enabled)")
    }

    /// Clicks Account and logs whether it was enabled just before the click
    /// and just after.
    @MainActor
    private func accountOpens(_ run: TestApp, _ label: String) -> Bool {
        let account = run.element(AccessibilityID.toolbarAccount)
        let before = account.isEnabled
        let start = Date()
        account.click()
        let after = account.exists ? account.isEnabled : nil
        let opened = run.element(AccessibilityID.accountClose).waitForExistence(timeout: 10)
        var laterEnabled: [String] = []
        if !opened {
            for _ in 0..<6 {
                laterEnabled.append(account.isEnabled ? "y" : "n")
                Thread.sleep(forTimeInterval: 0.5)
            }
        }
        print("DIAG \(label): opened=\(opened) after \(String(format: "%.2f", Date().timeIntervalSince(start)))s enabledBefore=\(before) enabledAfter=\(after.map(String.init(describing:)) ?? "gone") laterEnabled=\(laterEnabled.joined()) sheets=\(run.app.sheets.count)")
        return opened
    }

    @MainActor
    private func close(_ run: TestApp, opened: Bool) {
        if opened { run.click(AccessibilityID.accountClose) }
        run.app.terminate()
        try? FileManager.default.removeItem(at: run.dataRoot)
    }

    /// D: four fresh signed-in launches; each returns to the front once, then Account.
    @MainActor
    func testDFirstReturnThenAccount() throws {
        var results: [Bool] = []
        for index in 1...4 {
            let run = try launchSignedIn()
            returnToFront(run, "D\(index)")
            let opened = accountOpens(run, "D\(index)")
            results.append(opened)
            close(run, opened: opened)
        }
        print("DIAG D results: \(results)")
        XCTAssertEqual(results, [true, true, true, true])
    }

    /// E: the same, with a click on the staging banner before Account, so
    /// the window is key when Account is clicked.
    @MainActor
    func testEFirstReturnClickBannerThenAccount() throws {
        var results: [Bool] = []
        for index in 1...4 {
            let run = try launchSignedIn()
            returnToFront(run, "E\(index)")
            run.element(AccessibilityID.stagingBanner).click()
            let opened = accountOpens(run, "E\(index)")
            results.append(opened)
            close(run, opened: opened)
        }
        print("DIAG E results: \(results)")
        XCTAssertEqual(results, [true, true, true, true])
    }
}
