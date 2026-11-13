import AppKit
import Foundation
import XCTest
import WellSpentAppCore

/// Diagnosis for #199, not for merging. Signed in with two synced groups, as
/// LockTests is. The app logs what it does to a file (`DiagLog`), and each
/// click prints the log around it, so a lost click shows whether Account was
/// never set to open, or was opened and then closed.
final class AccountClickDiagTests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = true }

    private static let ended: String = {
        ISO8601DateFormatter().string(from: Date().addingTimeInterval(-2 * 86_400))
    }()

    private static func plan(ended: Bool) -> String {
        var fields = [
            #""tier":"free""#, #""period":"none""#, #""state":"free""#, #""source":"none""#,
            #""paidUntil":null"#, #""renews":false"#, #""nextTier":null"#,
            #""limits":{"properties":1,"groups":1,"invitedPerGroup":1}"#,
            #""used":{"properties":0,"groups":0}"#,
            #""extensionsOpen":[]"#, #""canSyncPriceLabs":false"#, #""refreshMinutes":60"#,
            #""appleAccountToken":"\#(UUID())""#
        ]
        if ended { fields.append(#""lastPlan":{"tier":"growth","endedOn":"\#(Self.ended)","reason":"ended"}"#) }
        return "{" + fields.joined(separator: ",") + "}"
    }

    private static func write(_ json: String, to file: URL) throws {
        let temporary = file.deletingLastPathComponent().appendingPathComponent("plan-\(UUID()).json")
        try Data(json.utf8).write(to: temporary)
        if FileManager.default.fileExists(atPath: file.path) {
            _ = try FileManager.default.replaceItemAt(file, withItemAt: temporary)
        } else {
            try FileManager.default.moveItem(at: temporary, to: file)
        }
    }

    private struct Launched {
        let run: TestApp
        let planFile: URL
        let logFile: URL
    }

    /// Signed in, with Home and Beach: made on the first launch, synced down
    /// on the others.
    @MainActor
    private func launch(first: Bool) throws -> Launched {
        let accounts = try TestAccounts.fromEnvironment()
        let run = try TestApp()
        let planFile = run.dataRoot.appendingPathComponent("plan.json")
        let logFile = run.dataRoot.appendingPathComponent("diag.log")
        try Self.write(Self.plan(ended: false), to: planFile)
        run.app.launchEnvironment[Workspace.pinnedPlanVariable] = planFile.path
        run.app.launchEnvironment[DiagLog.variable] = logFile.path
        run.launch()
        try run.signIn(email: accounts.email, password: accounts.password, server: accounts.server)
        if first {
            run.addGroup(named: "Home")
            run.addGroup(named: "Beach")
            run.syncNow()
        } else {
            for name in ["Home", "Beach"] {
                XCTAssertTrue(run.element(AccessibilityID.sidebarGroup(name)).waitForExistence(timeout: 60),
                              "\(name) didn't sync down")
            }
        }
        // Settle, so the log around the click is only the return to the front.
        let account = run.element(AccessibilityID.toolbarAccount)
        _ = run.wait(for: account, until: "enabled == true", timeout: 60)
        Thread.sleep(forTimeInterval: 2)
        return Launched(run: run, planFile: planFile, logFile: logFile)
    }

    /// To the back and forward, with LockTests' waits.
    @MainActor
    private func returnToFront(_ run: TestApp) -> Date {
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
        _ = run.wait(for: run.element(AccessibilityID.toolbarAccount), until: "enabled == true", timeout: 60)
        return forward
    }

    @MainActor
    private func accountOpens(_ launched: Launched, _ label: String, forward: Date) -> Bool {
        let run = launched.run
        let account = run.element(AccessibilityID.toolbarAccount)
        let before = account.isEnabled
        let click = Date()
        account.click()
        let clicked = Date()
        let after = account.exists ? account.isEnabled : false
        let opened = run.element(AccessibilityID.accountClose).waitForExistence(timeout: 10)
        Thread.sleep(forTimeInterval: 1)
        print(String(format: "DIAG %@: opened=%@ activate=%.3f click=%.3f..%.3f enabledBefore=%@ enabledAfter=%@ sheets=%d",
                     label, "\(opened)", forward.timeIntervalSince1970, click.timeIntervalSince1970,
                     clicked.timeIntervalSince1970, "\(before)", "\(after)", run.app.sheets.count))
        let log = (try? String(contentsOf: launched.logFile, encoding: .utf8)) ?? "(no log)"
        for line in log.split(separator: "\n") {
            guard let stamp = Double(line.prefix { $0 != " " }), stamp >= forward.timeIntervalSince1970 - 1 else { continue }
            print(String(format: "DIAG %@ log %+.3f %@", label, stamp - click.timeIntervalSince1970,
                         String(line.drop { $0 != " " }.dropFirst())))
        }
        return opened
    }

    @MainActor
    private func cleanUpGroups() {
        addTeardownBlock { @MainActor in
            guard let accounts = try? TestAccounts.fromEnvironment(),
                  let elsewhere = try? SecondAccount(server: accounts.server) else { return }
            try? await elsewhere.signIn(email: accounts.email, password: accounts.password)
            await elsewhere.sync.syncAll()
            await elsewhere.deleteGroup(named: "Home")
            await elsewhere.deleteGroup(named: "Beach")
            await elsewhere.cleanUp()
        }
    }

    @MainActor
    private func runCase(_ name: String, endPlan: Bool) throws {
        cleanUpGroups()
        var results: [Bool] = []
        for index in 1...4 {
            let launched = try launch(first: index == 1)
            if endPlan { try Self.write(Self.plan(ended: true), to: launched.planFile) }
            let forward = returnToFront(launched.run)
            let opened = accountOpens(launched, "\(name)\(index)", forward: forward)
            results.append(opened)
            if opened { launched.run.click(AccessibilityID.accountClose) }
            launched.run.app.terminate()
            try? FileManager.default.removeItem(at: launched.run.dataRoot)
        }
        print("DIAG \(name) results: \(results)")
        XCTAssertEqual(results, [true, true, true, true])
    }

    /// B: groups, plan unchanged, back to the front, Account.
    @MainActor
    func testBGroupsPlanUnchanged() throws { try runCase("B", endPlan: false) }

    /// D: groups, the plan switched to one that ended, back to the front, Account.
    @MainActor
    func testDGroupsPlanEnded() throws { try runCase("D", endPlan: true) }
}
