import AppKit
import Foundation
import SystemConfiguration
import XCTest
import WellSpentAppCore
import WellSpentSync

/// Accounts, in the real window: where the budgets are kept signed out and
/// signed in, a wrong password, signing out, signing out everywhere, being
/// signed out from another device, and the name this Mac goes by in the
/// account's list of signed-in devices. Then the word STAGING outside the
/// window: on the app's Dock icon, and in the note over the orange bar.
///
/// The signed-in test makes an account of its own, at a fresh example.com
/// address, and confirms it with the code staging emails there. Signing out
/// everywhere ends every session an account has, so it is never done to the
/// shared test accounts, which other runs are signed in to.
///
/// Robin's desktop has no window. It is a connection to the same staging
/// server from inside this process, as the app on another computer would
/// be. It makes the account, so it is signed in to it from the start. The
/// app has no screen for the account's list of devices yet, so the desktop
/// reads that list from the server. It also signs out everywhere, which
/// signs this Mac out at its next sync.
///
/// One run makes one account, and signs in through the window four times,
/// once with a wrong password. It needs the mailbox token (see
/// StagingMailbox) and skips without it. The account and its group stay on
/// staging, under an address no other run uses. The Dock test needs no
/// account.
final class AccountGapTests: XCTestCase {
    /// The run's data folder, for tearDown.
    nonisolated(unsafe) private static var dataRootPath: String?

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    /// Runs after each test, passed or halted, with no await in it. The app
    /// is closed, and nothing of the run stays on this Mac: its data folder,
    /// the settings, and the clipboard, which signing in pastes the password
    /// through.
    override func tearDown() {
        let app = XCUIApplication()
        if app.state != .notRunning { app.terminate() }
        TestApp.wipeSettings()
        if let path = Self.dataRootPath { try? FileManager.default.removeItem(atPath: path) }
        Self.dataRootPath = nil
        NSPasteboard.general.clearContents()
        super.tearDown()
    }

    // MARK: - Signing in and out

    @MainActor
    func testSignInSignOutAndSignOutEverywhere() async throws {
        let mailbox = try StagingMailbox.fromEnvironment()
        let run = try TestApp()
        Self.dataRootPath = run.dataRoot.path
        let groupName = "Home", budgetName = "Rent"
        let localGroup = "Pocket money", localBudget = "Snacks"
        let wrongPassword = AccountWording.words(for: ReadableTransportError.badCredentials)
        let signedOutElsewhere = AccountWording.words(for: ReadableTransportError.sessionEnded(""))
        let syncsThroughServer = SyncWording.footer(signedIn: true)

        // 1. Robin's desktop makes an account at a fresh address, and
        // confirms it with the code staging emails there.
        let email = StagingMailbox.freshAddress("mac", for: "robin")
        let password = "Robin-\(UUID().uuidString)"
        let desktop = try await Self.desktop(at: mailbox.server)
        _ = try await desktop.signUp(email: email, password: password, deviceLabel: Self.desktopName)
        try await desktop.verifyEmail(code: try await mailbox.code(for: email, timeout: 30))

        // Scenario ACCT-01
        // 2. Signed out, the foot of the list says the budgets are kept on
        // this computer, with Sign in beside it.
        run.launch()
        run.expectSignedOut("On a fresh launch")

        // Scenario ACCT-01
        // 3. A budget made signed out, in a group of this Mac's own, opens
        // with no Sync in its toolbar. The groups listed now are what this
        // Mac keeps when nobody is signed in.
        run.addGroup(named: localGroup)
        run.addBudget(named: localBudget, amount: "100", inGroup: localGroup)
        run.expectSignedOut("With a budget made signed out", withBudgetOpen: true)
        let keptHere = run.sidebarGroups()
        XCTAssertTrue(keptHere.contains(AccessibilityID.sidebarGroup(localGroup)),
                      "the sidebar does not list the group just made. Listed: \(keptHere.sorted())")

        // Scenario ACCT-09
        // 4. A wrong password: the sheet stays on Sign in, and says the email
        // or the password is wrong. Cancel leaves the window as it was: the
        // budgets kept on this computer, no Sync, and no failure shown.
        run.click(AccessibilityID.sidebarSignIn)
        run.enterSignIn(email: email, password: "not-\(password)", server: mailbox.server)
        run.click(AccessibilityID.accountSubmit)
        XCTAssertTrue(run.shows(wrongPassword, timeout: 30),
                      "the sheet does not say \(wrongPassword) On screen: \(run.visibleTexts())")
        XCTAssertTrue(run.showsLine(AccountFlow.Step.signIn.title),
                      "the sheet moved on from \(AccountFlow.Step.signIn.title). On screen: \(run.visibleTexts())")
        run.click(AccessibilityID.accountClose)
        XCTAssertTrue(run.wait(for: run.element(AccessibilityID.accountClose), until: "exists == false", timeout: 30),
                      "Cancel did not close the sheet")
        run.expectSignedOut("After a wrong password", withBudgetOpen: true)
        XCTAssertEqual(run.sidebarGroups(), keptHere, "the list changed after a wrong password")
        XCTAssertFalse(run.shows(wrongPassword, timeout: 1), "the failure is still shown, outside the sheet")

        // Scenario ACCT-01
        // 5. Signed in, in the window, the foot says the budgets sync through
        // WellSpent's server.
        try run.signIn(email: email, password: password, server: mailbox.server)
        XCTAssertTrue(run.app.staticTexts[syncsThroughServer].exists,
                      "the foot does not say \(syncsThroughServer). On screen: \(run.visibleTexts())")

        // Scenario ACCT-14
        // 6. The account's list of signed-in devices, which the server keeps
        // and the desktop reads, names this Mac as the app's shared code
        // names it. That is its Computer Name in System Settings, which the
        // test asks macOS for itself, and not a network name ending in .local.
        let devices = try await desktop.sessions()
        let listed: [String] = devices.map { $0.deviceLabel ?? "(no name)" }
        let thisMac: [String] = listed.filter { $0 != Self.desktopName }
        let networkNames: [String] = listed.filter { $0.hasSuffix(".local") }
        let computerName: String = (SCDynamicStoreCopyComputerName(nil, nil) as String?) ?? ""
        XCTAssertFalse(computerName.isEmpty, "macOS gives this Mac no Computer Name, so there is no name to expect")
        XCTAssertTrue(devices.contains { $0.deviceLabel == DeviceName.current },
                      "no device in the account's list goes by \(DeviceName.current). Listed: \(listed)")
        XCTAssertEqual(thisMac, [computerName],
                       "the account's list does not name this Mac by its Computer Name. Listed: \(listed)")
        XCTAssertEqual(networkNames, [], "the account's list names a device by a network name. Listed: \(listed)")

        // 7. A group of the account's own, with a budget, sent to the server.
        // It is the account's budgets in the steps that follow.
        run.addGroup(named: groupName)
        run.addBudget(named: budgetName, amount: "900", inGroup: groupName)
        run.syncAndWait()

        // Scenario ACCT-12
        // 8. Account, then Sign out everywhere…, asks first, with Sign Out
        // Everywhere and Cancel. Cancel changes nothing: the sheet stays on
        // the account, and this Mac and the desktop stay signed in.
        run.openAccount()
        run.clickOnAccountSheet(AccessibilityID.accountSignOutEverywhere)
        run.expectSignOutEverywhereQuestion()
        try XCTUnwrap(run.dialogButton(AccountFlow.Words.cancel),
                      "no \(AccountFlow.Words.cancel) on the question").click()
        XCTAssertTrue(run.wait(for: run.app.staticTexts[AccountFlow.Words.signOutEverywhereTitle],
                               until: "exists == false", timeout: 30), "the question stayed after Cancel")
        XCTAssertTrue(run.element(AccessibilityID.accountSignOut).exists, "Cancel closed the account")
        run.clickOnAccountSheet(AccessibilityID.accountClose)
        XCTAssertTrue(run.app.staticTexts[syncsThroughServer].waitForExistence(timeout: 30),
                      "Cancel signed this Mac out. On screen: \(run.visibleTexts())")
        do {
            _ = try await desktop.sessions()
        } catch {
            XCTFail("Cancel signed the desktop out: \(error)")
        }

        // Scenario ACCT-11
        // 9. Account, then Sign out: the sheet closes, the foot says the
        // budgets are kept on this computer, and the list shows what this Mac
        // keeps when nobody is signed in, without the account's group.
        run.openAccount()
        run.clickOnAccountSheet(AccessibilityID.accountSignOut)
        XCTAssertTrue(run.wait(for: run.element(AccessibilityID.accountClose), until: "exists == false", timeout: 30),
                      "the sheet stayed open after Sign out. On screen: \(run.visibleTexts())")
        run.expectSignedOut("After Sign out")
        run.expectList(keptHere, without: groupName, "After Sign out")

        // Scenario ACCT-11
        // 10. Quit and opened again, it is still signed out, and no sign-in
        // opens by itself. Signed in again, the account's group is back.
        run.app.terminate()
        run.launch()
        run.expectSignedOut("After quitting and opening again")
        XCTAssertFalse(run.element(AccessibilityID.accountEmail).waitForExistence(timeout: 3),
                       "a sign-in opened by itself")
        run.expectList(keptHere, without: groupName, "After quitting and opening again")
        try run.signIn(email: email, password: password, server: mailbox.server)
        XCTAssertTrue(run.element(AccessibilityID.sidebarGroup(groupName)).waitForExistence(timeout: 30),
                      "the account's group did not come back. Sidebar: \(run.sidebarIdentifiers())")

        // Scenario ACCT-13
        // 11. The desktop signs out everywhere. At this Mac's next sync, the
        // sign-in sheet opens by itself, with the email filled in and the
        // reason, and behind it the list shows what this Mac keeps when
        // nobody is signed in.
        run.openBudget(named: budgetName)
        try await desktop.signOutEverywhere()
        let emailField = run.element(AccessibilityID.accountEmail)
        XCTAssertTrue(run.waitForSignInByItself(timeout: 60),
                      "no sign-in opened by itself. On screen: \(run.visibleTexts())")
        XCTAssertTrue(run.showsLine(AccountFlow.Step.signIn.title),
                      "the sheet that opened is not \(AccountFlow.Step.signIn.title). On screen: \(run.visibleTexts())")
        XCTAssertTrue(run.shows(signedOutElsewhere, timeout: 30),
                      "the sheet does not say \(signedOutElsewhere) On screen: \(run.visibleTexts())")
        XCTAssertTrue(run.text(of: emailField).lowercased() == email,
                      "the sign-in does not have the account's email filled in")
        run.expectList(keptHere, without: groupName, "Behind the sign-in")

        // Scenario ACCT-13
        // 12. Signed in again on that sheet, the account's group is back.
        try run.signInOnSheet(email: email, password: password, server: mailbox.server)
        XCTAssertTrue(run.element(AccessibilityID.sidebarGroup(groupName)).waitForExistence(timeout: 30),
                      "the account's group did not come back. Sidebar: \(run.sidebarIdentifiers())")

        // Scenario ACCT-12
        // 13. Sign out everywhere… again, and this time Sign Out Everywhere:
        // the sheet closes, and this Mac is signed out.
        run.openBudget(named: budgetName)
        run.openAccount()
        run.clickOnAccountSheet(AccessibilityID.accountSignOutEverywhere)
        run.expectSignOutEverywhereQuestion()
        try XCTUnwrap(run.dialogButton(AccountFlow.Words.signOutEverywhereButton),
                      "no \(AccountFlow.Words.signOutEverywhereButton) on the question").click()
        XCTAssertTrue(run.wait(for: run.element(AccessibilityID.accountClose), until: "exists == false", timeout: 30),
                      "the sheet stayed open after \(AccountFlow.Words.signOutEverywhereButton). "
                      + "On screen: \(run.visibleTexts())")
        run.expectSignedOut("After \(AccountFlow.Words.signOutEverywhereButton)")
    }

    // MARK: - STAGING outside the window

    /// XCUITest reads no badge on a Dock icon. The Dock draws the badge macOS
    /// keeps for each running app, so the test asks macOS for it, with
    /// lsappinfo, as the Dock does.
    ///
    /// The note over the bar is checked to come up, not for its words. They
    /// are not in the shared code, only in the bar's view. And XCUITest reads
    /// none in a note: they show on screen, but the note's label, title and
    /// value are empty.
    @MainActor
    func testTheDockAndTheBarSayStaging() throws {
        let run = try TestApp()
        Self.dataRootPath = run.dataRoot.path

        // 1. The staging build opens, with the orange bar across the top of
        // its window. What the bar says is what the Dock must say too.
        run.launch()
        let bar = run.element(AccessibilityID.stagingBanner)
        let word = run.words(in: bar).first ?? ""
        XCTAssertFalse(word.isEmpty, "the orange bar says nothing")

        // Scenario ACCT-16
        // 2. The app's icon in the Dock carries a badge with the bar's word.
        let host = TestApp.hostBundleIdentifier
        var said = ""
        let badged = NSPredicate { _, _ in
            said = Self.dockBadgeAnswer(for: host)
            return Self.badge(in: said) == word
        }
        let found = XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: badged, object: nil)], timeout: 30)
        XCTAssertEqual(found, .completed, "the Dock icon's badge is not \(word). macOS says: \(said)")

        // Scenario ACCT-16
        // 3. The pointer, moved onto the orange bar and held there, brings up
        // a note.
        run.app.staticTexts[SyncWording.footer(signedIn: false)].hover()
        bar.hover()
        XCTAssertTrue(run.app.helpTags.firstMatch.waitForExistence(timeout: 30),
                      "no note came up over the orange bar. On screen: \(run.visibleTexts())")
    }
}

// MARK: - Helpers

private extension AccountGapTests {
    /// What the desktop calls itself in the account's list of devices.
    static let desktopName = "Robin's desktop"

    /// Robin's desktop: a connection to the server, checked to be staging
    /// before any password goes to it, as the app checks.
    static func desktop(at address: String) async throws -> ReadableHTTPTransport {
        guard let url = URL(string: address) else { throw UITestError("\(address) is not a server address") }
        if let why = AppEnvironment.staging.refusal(ofServerAt: url) { throw UITestError(why) }
        let desktop = ReadableHTTPTransport(baseURL: url)
        if let why = AppEnvironment.staging.refusal(ofServerSaying: try await desktop.health().environment) {
            throw UITestError(why)
        }
        return desktop
    }

    /// What macOS says of the badge on a running app's Dock icon, such as
    /// `"StatusLabel"={ "label"="3" }`, or what went wrong asking.
    static func dockBadgeAnswer(for bundleIdentifier: String) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/lsappinfo")
        process.arguments = ["info", "-only", "StatusLabel", "-app", bundleIdentifier]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        do {
            try process.run()
        } catch {
            return "lsappinfo did not start: \(error)"
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The badge in that answer, or nil when the icon has none.
    static func badge(in answer: String) -> String? {
        guard let start = answer.range(of: "\"label\"=\"") else { return nil }
        let rest = answer[start.upperBound...]
        guard let end = rest.firstIndex(of: "\"") else { return nil }
        return String(rest[..<end])
    }
}

@MainActor
private extension TestApp {
    /// Signed out: the foot says the budgets are kept on this computer, with
    /// Sign in beside it, and, with a budget open, its toolbar has no Sync.
    func expectSignedOut(_ when: String, withBudgetOpen budgetOpen: Bool = false,
                         file: StaticString = #filePath, line: UInt = #line) {
        let keptHere = SyncWording.footer(signedIn: false)
        XCTAssertTrue(app.staticTexts[keptHere].waitForExistence(timeout: 30),
                      "\(when), the foot does not say \(keptHere). On screen: \(visibleTexts())", file: file, line: line)
        let signIn = element(AccessibilityID.sidebarSignIn)
        let title = SyncWording.accountTitle(signedIn: false)
        XCTAssertTrue(signIn.waitForExistence(timeout: 30), "\(when), no \(title) at the foot", file: file, line: line)
        XCTAssertTrue([signIn.label, signIn.title].contains(title),
                      "\(when), the button at the foot says \(signIn.label), not \(title)", file: file, line: line)
        guard budgetOpen else { return }
        XCTAssertTrue(element(AccessibilityID.toolbarAccount).waitForExistence(timeout: 30),
                      "\(when), no budget is open, so there is no toolbar to look at. On screen: \(visibleTexts())",
                      file: file, line: line)
        XCTAssertFalse(element(AccessibilityID.toolbarSync).exists, "\(when), Sync shows", file: file, line: line)
    }

    /// The groups the sidebar lists, by their lines' identifiers, read from
    /// one snapshot.
    func sidebarGroups() -> Set<String> {
        guard let root = try? app.snapshot() else { return [] }
        let prefix = AccessibilityID.sidebarGroup("")
        var found: Set<String> = []
        var waiting = [root]
        while let node = waiting.popLast() {
            if node.identifier.hasPrefix(prefix) { found.insert(node.identifier) }
            waiting.append(contentsOf: node.children)
        }
        return found
    }

    /// Waits for the sidebar to list exactly `kept`, and checks `group` is
    /// not among them.
    func expectList(_ kept: Set<String>, without group: String, _ when: String,
                    file: StaticString = #filePath, line: UInt = #line) {
        let same = NSPredicate { _, _ in self.sidebarGroups() == kept }
        let listed = XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: same, object: nil)], timeout: 30)
        XCTAssertEqual(listed, .completed, "\(when), the list is not what this Mac keeps when nobody is signed in. "
                       + "Listed: \(sidebarGroups().sorted()). Kept: \(kept.sorted())", file: file, line: line)
        XCTAssertFalse(element(AccessibilityID.sidebarGroup(group)).exists, "\(when), the account's group is listed",
                       file: file, line: line)
    }

    /// Fills in the sign-in sheet, already open, without pressing Sign in:
    /// the server if it differs, and the email and password pasted.
    func enterSignIn(email: String, password: String, server: String) {
        let serverField = element(AccessibilityID.accountServer)
        XCTAssertTrue(serverField.waitForExistence(timeout: 30), "the sign-in sheet did not open")
        if (serverField.value as? String) != server {
            type(server, into: AccessibilityID.accountServer)
        }
        paste(email, into: AccessibilityID.accountEmail)
        paste(password, into: AccessibilityID.accountPassword)
    }

    /// Account, in the toolbar, once it is not dimmed by a sync: the account
    /// sheet, on Your account.
    func openAccount(file: StaticString = #filePath, line: UInt = #line) {
        let account = element(AccessibilityID.toolbarAccount)
        XCTAssertTrue(account.waitForExistence(timeout: 30), "no Account in the toolbar. On screen: \(visibleTexts())",
                      file: file, line: line)
        XCTAssertTrue(wait(for: account, until: "isEnabled == true", timeout: 60), "Account stayed dimmed",
                      file: file, line: line)
        account.click()
        XCTAssertTrue(element(AccessibilityID.accountSignOut).waitForExistence(timeout: 30),
                      "Account did not open the account. On screen: \(visibleTexts())", file: file, line: line)
    }

    /// A click on the account sheet, once the control can take it.
    func clickOnAccountSheet(_ identifier: String, file: StaticString = #filePath, line: UInt = #line) {
        let target = element(identifier)
        XCTAssertTrue(target.waitForExistence(timeout: 30), "no \(identifier) on the sheet. On screen: \(visibleTexts())",
                      file: file, line: line)
        XCTAssertTrue(wait(for: target, until: "hittable == true", timeout: 30),
                      "\(identifier) cannot be clicked. On screen: \(visibleTexts())", file: file, line: line)
        target.click()
    }

    /// The question before signing out everywhere, in the shared words, with
    /// both its buttons.
    func expectSignOutEverywhereQuestion(file: StaticString = #filePath, line: UInt = #line) {
        let words = AccountFlow.Words.self
        XCTAssertTrue(shows(words.signOutEverywhereTitle, timeout: 30),
                      "no question \(words.signOutEverywhereTitle) On screen: \(visibleTexts())", file: file, line: line)
        XCTAssertTrue(shows(words.signOutEverywhereMessage, timeout: 30),
                      "the question does not say \(words.signOutEverywhereMessage) On screen: \(visibleTexts())",
                      file: file, line: line)
        for button in [words.signOutEverywhereButton, words.cancel] {
            XCTAssertNotNil(dialogButton(button), "no \(button) on the question", file: file, line: line)
        }
    }

    /// Sync, in the toolbar, then waits for it to finish.
    func syncAndWait(file: StaticString = #filePath, line: UInt = #line) {
        syncNow()
        let button = element(AccessibilityID.toolbarSync)
        wait(for: button, until: "isEnabled == false", timeout: 3)
        XCTAssertTrue(wait(for: button, until: "isEnabled == true", timeout: 60), "the sync did not finish",
                      file: file, line: line)
    }

    /// Waits for the sign-in sheet to open by itself, which it does at the
    /// next sync once the session has ended. Sync is pressed when it is there
    /// and ready, so that sync comes now rather than at the next timed one,
    /// and again if a while passes with no sheet. A sync already running
    /// finds the ended session as well, and takes Sync away with it.
    func waitForSignInByItself(timeout: TimeInterval) -> Bool {
        let emailField = element(AccessibilityID.accountEmail)
        let sync = element(AccessibilityID.toolbarSync)
        let giveUp = Date().addingTimeInterval(timeout)
        var pressed = Date.distantPast
        while Date() < giveUp {
            if emailField.waitForExistence(timeout: 3) { return true }
            if Date().timeIntervalSince(pressed) > 20, sync.exists, sync.isEnabled, sync.isHittable {
                sync.click()
                pressed = Date()
            }
        }
        return emailField.exists
    }

    /// Waits for these words anywhere in the app, as a line's text or an
    /// element's label.
    func shows(_ words: String, timeout: TimeInterval) -> Bool {
        app.descendants(matching: .any)
            .matching(NSPredicate(format: "label == %@ OR value == %@", words, words))
            .firstMatch.waitForExistence(timeout: timeout)
    }

    /// Whether a line of text says exactly these words, such as a sheet's
    /// title. Buttons with the same words do not count.
    func showsLine(_ words: String) -> Bool {
        app.staticTexts.matching(NSPredicate(format: "label == %@ OR value == %@", words, words)).firstMatch.exists
    }

    /// Every piece of text an element and what is inside it show, read from
    /// one snapshot.
    func words(in element: XCUIElement) -> [String] {
        guard let root = try? element.snapshot() else { return [] }
        var found: [String] = []
        var waiting = [root]
        while let node = waiting.popLast() {
            let texts: [String] = [node.label, node.title, (node.value as? String) ?? ""]
            found.append(contentsOf: texts.filter { !$0.isEmpty })
            waiting.append(contentsOf: node.children)
        }
        return found
    }
}
