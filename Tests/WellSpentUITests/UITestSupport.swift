// The UI test for the Mac app. It drives the real window through XCUITest,
// signed in to the staging server with two test accounts. It lives outside the
// Swift package: Package.swift does not declare this folder, so `swift test`
// never sees it. `make ui-test` builds it through Xcode/project.yml.
import AppKit
import Foundation
import XCTest
import WellSpentAppCore
import WellSpentKeyStore
import WellSpentModel
import WellSpentStore
import WellSpentSync

/// The two staging accounts a run uses, read from the environment. `make
/// ui-test` passes them to xcodebuild as TEST_RUNNER_ variables, which reach
/// this process with the prefix removed, so they are never on a command line.
struct TestAccounts {
    static let serverVariable = "WELLSPENT_UI_TEST_SERVER"
    static let emailVariable = "WELLSPENT_UI_TEST_EMAIL"
    static let passwordVariable = "WELLSPENT_UI_TEST_PASSWORD"
    static let secondEmailVariable = "WELLSPENT_UI_TEST_EMAIL_2"
    static let secondPasswordVariable = "WELLSPENT_UI_TEST_PASSWORD_2"

    let server: String
    let email: String
    let password: String
    let secondEmail: String
    let secondPassword: String

    /// Skips the test when any of the four is missing, so a checkout without
    /// accounts, such as a pull request from a fork, passes with nothing run.
    static func fromEnvironment(_ environment: [String: String] = ProcessInfo.processInfo.environment)
        throws -> TestAccounts {
        func required(_ name: String) throws -> String {
            guard let value = environment[name], !value.isEmpty else {
                throw XCTSkip("\(name) is not set. The four WELLSPENT_UI_TEST_ variables name the two "
                              + "staging accounts this test signs in with; see the Makefile's ui-test target.")
            }
            return value
        }
        let server = environment[serverVariable].flatMap { $0.isEmpty ? nil : $0 }
        return TestAccounts(server: server ?? AppEnvironment.staging.defaultServerAddress,
                            email: try required(emailVariable),
                            password: try required(passwordVariable),
                            secondEmail: try required(secondEmailVariable),
                            secondPassword: try required(secondPasswordVariable))
    }
}

/// Something the test could not do, in words.
struct UITestError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

/// The app under test: launched with its data in a folder of its own, and
/// the ways the test reaches into its window.
@MainActor
final class TestApp {
    let app = XCUIApplication()
    /// Where this run's databases go. Removed at the end.
    let dataRoot: URL

    init() throws {
        dataRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("wellspent-ui-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dataRoot, withIntermediateDirectories: true)
        Self.wipeSettings()
        // Read by AccountDirectory.standard in the app: databases under this
        // folder, keys in memory, settings in the test suite. Nothing reaches
        // Application Support or the keychain, so no password prompt can stop
        // the run.
        app.launchEnvironment[AccountDirectory.dataRootVariable] = dataRoot.path
    }

    // MARK: - Launching and finding things

    /// Launches, and refuses to go on against anything but a staging build.
    func launch() {
        app.launch()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 30), "the window never appeared")
        XCTAssertTrue(element(AccessibilityID.stagingBanner).waitForExistence(timeout: 10),
                      "no staging banner: this is not a staging build, so nothing more is done")
    }

    /// Any element with this identifier, whatever its type. SwiftUI's element
    /// types are not certain until seen, so nothing here asks for one.
    func element(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    /// A menu item by its title, in a context menu or a menu button's menu.
    func menuItem(_ title: String) -> XCUIElement {
        app.menuItems[title].firstMatch
    }

    /// Waits for a menu item to show, then clicks it.
    func clickMenuItem(_ title: String) {
        let item = menuItem(title)
        XCTAssertTrue(item.waitForExistence(timeout: 5),
                      "no menu item \(title). Menu items on screen: \(visibleMenuItems())")
        item.click()
    }

    func click(_ identifier: String, timeout: TimeInterval = 10) {
        let target = element(identifier)
        XCTAssertTrue(target.waitForExistence(timeout: timeout), "nothing called \(identifier) to click")
        waitUntilHittable(target, identifier)
        target.click()
    }

    /// Clicks into a field and types, replacing whatever was there.
    func type(_ text: String, into identifier: String) {
        let field = element(identifier)
        XCTAssertTrue(field.waitForExistence(timeout: 10), "no field called \(identifier)")
        waitUntilHittable(field, identifier)
        field.click()
        field.typeKey("a", modifierFlags: .command)
        field.typeText(text)
    }

    /// A control inside a sheet exists before the sheet has finished sliding
    /// in, and a click then fails as "not hittable" (seen on the first real
    /// runs). So every click waits for the control to be hittable first.
    func waitUntilHittable(_ target: XCUIElement, _ identifier: String) {
        XCTAssertTrue(wait(for: target, until: "hittable == true", timeout: 10),
                      "\(identifier) is on screen but cannot be clicked. On screen: \(visibleTexts())")
    }

    /// Waits for a condition on an element, such as "isEnabled == true" or
    /// "exists == false".
    @discardableResult
    func wait(for element: XCUIElement, until condition: String, timeout: TimeInterval) -> Bool {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: condition), object: element)
        return XCTWaiter().wait(for: [expectation], timeout: timeout) == .completed
    }

    /// Every static text on screen, for a failure message. Read from one
    /// snapshot: asking each element in turn failed on the first real run,
    /// when the sheet changed between the query and the read.
    func visibleTexts() -> [String] {
        guard let root = try? app.snapshot() else { return [] }
        var texts: [String] = []
        func walk(_ node: XCUIElementSnapshot) {
            if node.elementType == .staticText, !node.label.isEmpty { texts.append(node.label) }
            node.children.forEach(walk)
        }
        walk(root)
        return texts
    }

    func visibleMenuItems() -> [String] {
        app.menuItems.allElementsBoundByIndex.map(\.title).filter { !$0.isEmpty }
    }

    // MARK: - The steps the test takes

    /// Signs in through the sheet, and waits until the window says budgets
    /// sync through the server. An address not confirmed yet, or a refusal,
    /// fails with what the sheet says.
    func signIn(email: String, password: String, server: String) throws {
        click(AccessibilityID.sidebarSignIn)
        let serverField = element(AccessibilityID.accountServer)
        XCTAssertTrue(serverField.waitForExistence(timeout: 10), "the sign-in sheet did not open")
        if (serverField.value as? String) != server {
            type(server, into: AccessibilityID.accountServer)
        }
        type(email, into: AccessibilityID.accountEmail)
        type(password, into: AccessibilityID.accountPassword)
        click(AccessibilityID.accountSubmit)

        let signedIn = app.staticTexts[SyncWording.footer(signedIn: true)]
        guard signedIn.waitForExistence(timeout: 60) else {
            if element(AccessibilityID.accountCode).exists {
                throw UITestError("\(email) has not confirmed its address. Confirm it once, then run again.")
            }
            throw UITestError("signing in did not finish. On screen: \(visibleTexts())")
        }
    }

    /// Opens the menu on the Add Budget control. The common action is the
    /// button itself and the menu hangs off its right edge, so a click in
    /// the middle may open New Budget instead; that is closed and the edge
    /// tried next.
    func openAddMenu() {
        let control = element(AccessibilityID.sidebarAdd)
        XCTAssertTrue(control.waitForExistence(timeout: 10), "no Add Budget control")
        let item = menuItem(MainScreen.Words.newGroup)
        control.click()
        if item.waitForExistence(timeout: 2) { return }
        let cancel = element(AccessibilityID.budgetEditorCancel)
        if cancel.exists { cancel.click() }
        control.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).click()
        XCTAssertTrue(item.waitForExistence(timeout: 5),
                      "the Add menu did not open. Menu items on screen: \(visibleMenuItems())")
    }

    /// New Group… from the Add menu, named.
    func addGroup(named name: String) {
        openAddMenu()
        clickMenuItem(MainScreen.Words.newGroup)
        type(name, into: AccessibilityID.groupEditorName)
        click(AccessibilityID.groupEditorSave)
        XCTAssertTrue(element(AccessibilityID.sidebarGroup(name)).waitForExistence(timeout: 10),
                      "the new group is not in the sidebar")
    }

    /// New Budget in <group>… from the group's menu. Saving selects the new
    /// budget (AppModel.addBudget), so its toolbar appears on its own. The
    /// sidebar row is clicked only if it does not: a row's identifier may not
    /// surface in the accessibility tree, and a leftover group from an
    /// aborted run could own a row with the same name.
    func addBudget(named name: String, amount: String, inGroup group: String) {
        element(AccessibilityID.sidebarGroup(group)).rightClick()
        clickMenuItem(MainScreen.Words.newBudget(in: group))
        type(name, into: AccessibilityID.budgetEditorName)
        type(amount, into: AccessibilityID.budgetEditorAmount)
        click(AccessibilityID.budgetEditorSave)
        if !element(AccessibilityID.budgetAdd).waitForExistence(timeout: 10) {
            click(AccessibilityID.sidebarBudget(name))
        }
        XCTAssertTrue(element(AccessibilityID.budgetAdd).waitForExistence(timeout: 10),
                      "\(name) did not open after Save")
    }

    /// Add, in the budget's toolbar.
    func addEntry(merchant: String, amount: String) {
        click(AccessibilityID.budgetAdd)
        type(merchant, into: AccessibilityID.entryMerchant)
        type(amount, into: AccessibilityID.entryAmount)
        click(AccessibilityID.entryAdd)
        XCTAssertTrue(app.staticTexts[merchant].waitForExistence(timeout: 10), "\(merchant) is not in the table")
    }

    /// Share… from the group's menu: a name, the role, Create Link, and the
    /// link read off the sheet. The link is read from the screen, not the
    /// clipboard: reading the clipboard from another process brings up a
    /// system prompt on recent macOS, which would stop the run.
    func share(group: String, myName: String, role: InviteRole) throws -> InviteLink {
        element(AccessibilityID.sidebarGroup(group)).rightClick()
        clickMenuItem(MainScreen.Words.share)
        type(myName, into: AccessibilityID.shareName)
        choose(role: role)
        click(AccessibilityID.shareCreate)
        XCTAssertTrue(element(AccessibilityID.shareCopyLink).waitForExistence(timeout: 30),
                      "no link was made. On screen: \(visibleTexts())")
        let shown = element(AccessibilityID.shareLink)
        let text = (shown.value as? String) ?? shown.label
        guard let link = InviteLink(parsing: text) else {
            throw UITestError("the sheet shows no invite link: \(text)")
        }
        click(AccessibilityID.shareDone)
        return link
    }

    /// The role segment, when the picker shows one by that name. The owner's
    /// default is Add already, so a picker drawn another way is left alone.
    private func choose(role: InviteRole) {
        let picker = element(AccessibilityID.shareRole)
        for candidate in [picker.radioButtons[role.title], picker.buttons[role.title],
                          app.radioButtons[role.title]] where candidate.exists {
            candidate.click()
            return
        }
    }

    /// Sync, in the toolbar, once it is ready.
    func syncNow() {
        let button = element(AccessibilityID.toolbarSync)
        XCTAssertTrue(button.waitForExistence(timeout: 10), "no Sync button: is a budget open?")
        XCTAssertTrue(wait(for: button, until: "isEnabled == true", timeout: 30), "Sync stayed busy")
        button.click()
    }

    // MARK: - Cleaning up

    /// Delete… from the group's menu, confirmed. The founder's delete removes
    /// the group for everyone on the server, once the sync that follows an
    /// edit has run. Best effort: nothing here fails the test.
    func deleteGroup(named name: String) {
        guard app.state == .runningForeground else { return }
        let header = element(AccessibilityID.sidebarGroup(name))
        guard header.waitForExistence(timeout: 5) else { return }
        header.rightClick()
        let item = menuItem(MainScreen.Words.delete)
        guard item.waitForExistence(timeout: 5) else { return }
        item.click()
        let label = PendingDelete.group(BudgetGroup(name: name), budgets: 0, reach: .everyone).confirmLabel
        guard let confirm = dialogButton(label) else { return }
        confirm.click()
        wait(for: header, until: "exists == false", timeout: 10)
        // The sync after an edit waits for edits to stop, then talks to the
        // server. Give it that long before the app is closed. (A waiter on an
        // expectation nobody fulfils is XCTest's way to pause.)
        _ = XCTWaiter().wait(for: [XCTestExpectation(description: "the sync after the delete")], timeout: 8)
    }

    /// The button on the confirmation, wherever macOS put it.
    private func dialogButton(_ label: String) -> XCUIElement? {
        for candidate in [app.sheets.firstMatch.buttons[label], app.dialogs.firstMatch.buttons[label],
                          app.buttons[label]] where candidate.waitForExistence(timeout: 3) {
            return candidate
        }
        return nil
    }

    /// Sign out, through the account button. That button lives in a budget's
    /// toolbar, so a budget is opened first if any is left. Best effort.
    func signOut() {
        guard app.state == .runningForeground else { return }
        if !element(AccessibilityID.toolbarAccount).exists {
            let anyBudget = app.descendants(matching: .any)
                .matching(NSPredicate(format: "identifier BEGINSWITH 'sidebar.budget.'")).firstMatch
            guard anyBudget.exists else { return }
            anyBudget.click()
        }
        let account = element(AccessibilityID.toolbarAccount)
        guard account.waitForExistence(timeout: 5), wait(for: account, until: "isEnabled == true", timeout: 30) else {
            return
        }
        account.click()
        let signOut = element(AccessibilityID.accountSignOut)
        guard signOut.waitForExistence(timeout: 5) else { return }
        signOut.click()
        wait(for: app.staticTexts[SyncWording.footer(signedIn: false)], until: "exists == true", timeout: 15)
    }

    /// Closes the app and leaves nothing of the run on this Mac.
    func cleanUp() {
        if app.state != .notRunning { app.terminate() }
        Self.wipeSettings()
        try? FileManager.default.removeItem(at: dataRoot)
    }

    /// The settings the host reads, wiped so a run starts signed out with no
    /// server address remembered, and wiped again after so nothing is left.
    nonisolated static func wipeSettings() {
        UserDefaults(suiteName: AccountDirectory.testDefaultsSuiteName)?
            .removePersistentDomain(forName: AccountDirectory.testDefaultsSuiteName)
    }
}

/// The second person, with no window: a coordinator of their own against the
/// same staging server, the way the two-person tests in WellSpentAppCoreTests
/// do it, but over real HTTP. Databases and keys in memory, settings in a
/// suite of its own.
@MainActor
final class SecondAccount {
    static let settingsSuite = "app.wellspent.uitest.second"
    let sync: SyncCoordinator

    init(server: String) throws {
        guard let defaults = UserDefaults(suiteName: Self.settingsSuite) else {
            throw UITestError("could not open the \(Self.settingsSuite) defaults")
        }
        defaults.removePersistentDomain(forName: Self.settingsSuite)
        let accounts = AccountDirectory(root: nil, defaults: defaults) { _ in InMemoryKeyStore() }
        sync = try SyncCoordinator(accounts: accounts, defaults: defaults, serverAddress: server,
                                   environment: .staging)
    }

    /// Signs in and takes in everything the account has.
    func signIn(email: String, password: String) async throws {
        try await sync.signIn(email: email, password: password)
        await sync.syncAll()
        try checkSynced()
    }

    /// Joins with the link and takes the group in. The model is made after,
    /// because signing in switched the store underneath.
    func join(_ link: InviteLink, as name: String) async throws -> AppModel {
        try await sync.join(link, myName: name)
        await sync.syncAll()
        try checkSynced()
        return AppModel(store: sync.store)
    }

    /// Sends what was saved, and fails with the server's words if it did not go.
    func syncAll() async throws {
        await sync.syncAll()
        try checkSynced()
    }

    private func checkSynced() throws {
        if case .failed(let why) = sync.state { throw UITestError("the second account's sync failed: \(why)") }
    }

    /// Ends the session on the server. Best effort.
    func cleanUp() async {
        if sync.account != nil { await sync.signOut() }
        UserDefaults(suiteName: Self.settingsSuite)?.removePersistentDomain(forName: Self.settingsSuite)
    }
}
