import XCTest
import WellSpentAppCore

/// The release twin's check, which runs before every upload. Apple will not
/// run the App Store build itself on a Mac, so `make release-twin` builds the
/// same release signed for development under its own app ID, and names it in
/// WELLSPENT_TWIN_APP. Launched from that path, the twin keeps its databases in
/// its own sandbox container and its keys in the keychain, as the shipping app
/// does on a tester's Mac. Anywhere else, with no twin named, this is skipped.
final class ReleaseTwinTests: XCTestCase {
    @MainActor
    func testTheTwinSignsInAndIsStillSignedInAfterAQuit() throws {
        let path = ProcessInfo.processInfo.environment["WELLSPENT_TWIN_APP"] ?? ""
        try XCTSkipIf(path.isEmpty, "no twin named: make release-twin runs this")
        let accounts = try TestAccounts.fromEnvironment()
        let run = try TestApp(twin: URL(fileURLWithPath: path))
        defer { run.cleanUp() }
        let groupName = "UI Test \(Self.stamp()) twin"
        let signedIn = run.app.staticTexts[SyncWording.footer(signedIn: true)]

        // 1. The twin opens. A run that stopped half way may have left it
        // signed in, so it signs out first.
        run.launch()
        if signedIn.waitForExistence(timeout: 5) { run.signOut() }

        // 2. Signed in to staging, with a group and a budget of this run's own.
        try run.signIn(email: accounts.email, password: accounts.password, server: accounts.server)
        run.addGroup(named: groupName)
        run.addBudget(named: "Groceries", amount: "500", inGroup: groupName)

        // 3. Quit with Command-Q, as a person does, and opened again.
        run.app.typeKey("q", modifierFlags: .command)
        XCTAssertTrue(run.app.wait(for: .notRunning, timeout: 30), "the twin did not quit")
        run.launch()

        // 4. Still signed in, from the keychain, and the group is back, from
        // its own container.
        XCTAssertTrue(signedIn.waitForExistence(timeout: 30), "signed out by a quit: the keychain kept nothing")
        XCTAssertTrue(run.element(AccessibilityID.sidebarGroup(groupName)).waitForExistence(timeout: 30),
                      "the group did not come back after a quit. On screen: \(run.visibleTexts())")

        // 5. Tidy: the group goes for everyone, and the session ends.
        run.deleteGroup(named: groupName)
        run.signOut()
    }

    /// Part of the group's name, so runs never share one. The "UI Test" start
    /// is what CI's clean-up of old test groups looks for.
    private static func stamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: Date())
    }
}
