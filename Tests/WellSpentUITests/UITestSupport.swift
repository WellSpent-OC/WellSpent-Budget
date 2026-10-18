// The UI test for the Mac app. It drives the real window through XCUITest,
// signed in to the staging server with two test accounts. It lives outside the
// Swift package: Package.swift does not declare this folder, so `swift test`
// never sees it. `make ui-test` builds it through Xcode/project.yml.
import AppKit
import Foundation
import XCTest
import WellSpentAppCore
import WellSpentCrypto
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

    /// Opens a link with the app under test, the way a click on it does, and
    /// refuses to go on against anything but a staging build. It uses
    /// XCUIApplication.open(_:), which macOS has from 13.3. The SDK's header
    /// says it launches the app with the link and returns once the app is
    /// ready, as launch() does. It does not say whether a copy already
    /// running stays, so a test counts on nothing that copy did.
    ///
    /// The app must keep its data in the run's folder, as after launch(). So
    /// once it is open, the folder must not be empty.
    func open(link: String) throws {
        let url = try XCTUnwrap(URL(string: link), "not a link: \(link)")
        app.open(url)
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 30), "the window never appeared")
        XCTAssertTrue(element(AccessibilityID.stagingBanner).waitForExistence(timeout: 10),
                      "no staging banner: this is not a staging build, so nothing more is done")
        let kept = (try? FileManager.default.contentsOfDirectory(atPath: dataRoot.path)) ?? []
        XCTAssertFalse(kept.isEmpty, "the app keeps nothing in the run's folder, so it may be using this Mac's "
                       + "own. Nothing more is done.")
    }

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

    /// Clicks into a field and pastes, replacing whatever was there: the text
    /// goes on the clipboard, then Command-V. Writing the clipboard from the
    /// test needs no permission (only reading it would), and it is emptied
    /// again straight after.
    func paste(_ text: String, into identifier: String) {
        let field = element(identifier)
        XCTAssertTrue(field.waitForExistence(timeout: 10), "no field called \(identifier)")
        waitUntilHittable(field, identifier)
        field.click()
        field.typeKey("a", modifierFlags: .command)
        let clipboard = NSPasteboard.general
        clipboard.clearContents()
        clipboard.setString(text, forType: .string)
        field.typeKey("v", modifierFlags: .command)
        clipboard.clearContents()
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
        try signInOnSheet(email: email, password: password, server: server)
    }

    /// The same, from the sign-in sheet once something else has opened it,
    /// such as Sign in… on the invitation page.
    func signInOnSheet(email: String, password: String, server: String) throws {
        let serverField = element(AccessibilityID.accountServer)
        XCTAssertTrue(serverField.waitForExistence(timeout: 10), "the sign-in sheet did not open")
        if (serverField.value as? String) != server {
            type(server, into: AccessibilityID.accountServer)
        }
        // Pasted, not typed, the way people sign in with an address and a
        // password copied from somewhere else. A sign-in that goes through
        // proves the password field pasted too.
        paste(email, into: AccessibilityID.accountEmail)
        XCTAssertEqual(element(AccessibilityID.accountEmail).value as? String, email,
                       "Command-V did not paste the address")
        paste(password, into: AccessibilityID.accountPassword)
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
                      "the new group is not in the sidebar. The sidebar's names: \(sidebarIdentifiers())")
    }

    /// Every identifier in the window that starts "sidebar.", with its type,
    /// for a failure message: what the tests can find there.
    func sidebarIdentifiers() -> [String] {
        app.windows.firstMatch.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'sidebar.'"))
            .allElementsBoundByIndex.map { "\($0.identifier) (type \($0.elementType.rawValue))" }
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

    // MARK: - Budgets and their entries

    /// A budget's row in the sidebar: by identifier, or by its name in the
    /// sidebar's list when the identifier does not surface.
    func sidebarBudget(_ name: String) -> XCUIElement {
        let identified = element(AccessibilityID.sidebarBudget(name))
        if identified.waitForExistence(timeout: 5) { return identified }
        return app.outlines.staticTexts[name].firstMatch
    }

    /// Opens a budget from the sidebar.
    func openBudget(named name: String) {
        let row = sidebarBudget(name)
        XCTAssertTrue(row.waitForExistence(timeout: 10), "no budget called \(name) in the sidebar")
        waitUntilHittable(row, name)
        row.click()
    }

    /// Delete… from a budget's menu in the sidebar, confirmed.
    func deleteBudget(named name: String) {
        let row = sidebarBudget(name)
        XCTAssertTrue(row.waitForExistence(timeout: 10), "no budget called \(name) in the sidebar")
        row.rightClick()
        clickMenuItem(MainScreen.Words.delete)
        let label = PendingDelete.budget(Budget(groupID: GroupID(), name: name, limit: .zero()),
                                         transactions: 0).confirmLabel
        guard let confirm = dialogButton(label) else {
            XCTFail("no \(label) button on the question. On screen: \(visibleTexts())")
            return
        }
        confirm.click()
        XCTAssertTrue(wait(for: row, until: "exists == false", timeout: 10), "\(name) is still in the sidebar")
    }

    /// An entry's row in the budget's list: the cell with its merchant, by
    /// identifier, or by the merchant's words in the table when the
    /// identifier does not surface.
    func entryRow(_ merchant: String) -> XCUIElement {
        let identified = element(AccessibilityID.entryRow(merchant))
        if identified.waitForExistence(timeout: 10) { return identified }
        return listText(merchant)
    }

    /// A text shown in the window, such as a merchant or an amount in the
    /// budget's list. Searched across the whole window: the Mac's table can
    /// reach the test as a table or as an outline, and a query for only one
    /// of them finds nothing in the other.
    func listText(_ text: String) -> XCUIElement {
        app.windows.firstMatch.staticTexts[text].firstMatch
    }

    /// Clicks an entry's row once, which opens it.
    func clickRow(_ merchant: String) {
        let row = entryRow(merchant)
        XCTAssertTrue(row.waitForExistence(timeout: 10), "no row for \(merchant). On screen: \(visibleTexts())")
        waitUntilHittable(row, merchant)
        row.click()
    }

    /// Whether the list shows no row for this merchant, waiting for it to go.
    func rowIsGone(_ merchant: String, timeout: TimeInterval = 10) -> Bool {
        wait(for: element(AccessibilityID.entryRow(merchant)), until: "exists == false", timeout: timeout)
            && wait(for: listText(merchant), until: "exists == false", timeout: timeout)
    }

    /// Waits for an entry's sheet, and checks it is the one asked for.
    func expectSheet(for merchant: String, file: StaticString = #filePath, line: UInt = #line) {
        let field = element(AccessibilityID.entryMerchant)
        XCTAssertTrue(field.waitForExistence(timeout: 10), "no sheet opened. On screen: \(visibleTexts())",
                      file: file, line: line)
        XCTAssertTrue(wait(for: field, holds: merchant, timeout: 5), "the sheet is not \(merchant)'s: \(text(of: field))",
                      file: file, line: line)
    }

    /// Waits for the entry's sheet to close.
    func expectNoSheet(file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(wait(for: element(AccessibilityID.entryCancel), until: "exists == false", timeout: 10),
                      "the sheet is still open", file: file, line: line)
        XCTAssertTrue(wait(for: element(AccessibilityID.entryDone), until: "exists == false", timeout: 10),
                      "the sheet is still open", file: file, line: line)
    }

    /// Picks an item in a pop-up list, such as the sheet's Budget list.
    func choose(_ title: String, in identifier: String) {
        let found = element(identifier)
        XCTAssertTrue(found.waitForExistence(timeout: 10), "no list called \(identifier)")
        let list = [app.popUpButtons[identifier].firstMatch, found.popUpButtons.firstMatch]
            .first { $0.exists } ?? found
        waitUntilHittable(list, identifier)
        list.click()
        clickMenuItem(title)
        XCTAssertTrue(wait(for: list, holds: title, timeout: 5), "\(identifier) did not take \(title)")
    }

    /// What an element shows: a field's text, or a label's words.
    func text(of element: XCUIElement) -> String {
        if let value = element.value as? String, !value.isEmpty { return value }
        return element.label
    }

    /// Waits until an element shows exactly this text. An empty field reads
    /// as "", whether its value is empty or missing.
    @discardableResult
    func wait(for element: XCUIElement, holds expected: String, timeout: TimeInterval) -> Bool {
        let shows = NSPredicate { candidate, _ in
            guard let element = candidate as? XCUIElement, element.exists else { return false }
            return (element.value as? String ?? "") == expected || (expected.isEmpty == false && element.label == expected)
        }
        let expectation = XCTNSPredicateExpectation(predicate: shows, object: element)
        return XCTWaiter().wait(for: [expectation], timeout: timeout) == .completed
    }

    /// Whether this element has the keyboard. XCUITest answers it on the Mac
    /// by this name only.
    func hasKeyboardFocus(_ element: XCUIElement) -> Bool {
        (element.value(forKey: "hasKeyboardFocus") as? Bool) == true
    }

    /// The keyboard in one text field, the way people use it, then Tab:
    /// typing, Command-A, Command-C, Command-V and Command-Z each do their
    /// job. The field is left holding what it held, so nothing has changed.
    /// Without `clicking`, the field must have the keyboard already, from a
    /// Tab in the field before: typing into it proves that Tab worked.
    func keyboardPass(_ identifier: String, holding original: String, clicking: Bool = true,
                      file: StaticString = #filePath, line: UInt = #line) {
        let field = element(identifier)
        XCTAssertTrue(field.waitForExistence(timeout: 10), "no field called \(identifier)", file: file, line: line)
        if clicking {
            waitUntilHittable(field, identifier)
            field.click()
        }
        func expect(_ shown: String, _ what: String) {
            XCTAssertTrue(wait(for: field, holds: shown, timeout: 5),
                          "\(what) in \(identifier): it shows \(text(of: field)), not \(shown)", file: file, line: line)
        }
        app.typeKey("a", modifierFlags: .command)
        app.typeText("Probe")
        expect("Probe", "typing over everything Command-A selected")
        app.typeKey("a", modifierFlags: .command)
        app.typeKey("c", modifierFlags: .command)
        app.typeText("X")
        expect("X", "typing over a copied selection")
        app.typeKey("a", modifierFlags: .command)
        app.typeKey("v", modifierFlags: .command)
        expect("Probe", "Command-C, then Command-V")
        app.typeKey("z", modifierFlags: .command)
        expect("X", "Command-Z, taking the paste back")
        app.typeKey("a", modifierFlags: .command)
        if original.isEmpty {
            app.typeKey(.delete, modifierFlags: [])
        } else {
            app.typeText(original)
        }
        expect(original, "putting it back")
        XCTAssertTrue(hasKeyboardFocus(field), "\(identifier) did not have the keyboard before Tab", file: file, line: line)
        app.typeKey(.tab, modifierFlags: [])
        XCTAssertFalse(hasKeyboardFocus(field), "Tab did not move on from \(identifier)", file: file, line: line)
    }

    /// A statement in the run's folder, with today's date on every line, so
    /// the lines land in this period. Removed with the folder.
    func writeStatement(_ lines: [(bank: String, amount: String)]) throws -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "MM/dd/yyyy"
        let today = formatter.string(from: Date())
        let rows = ["Date,Description,Amount"] + lines.map { "\(today),\"\($0.bank)\",\($0.amount)" }
        let url = dataRoot.appendingPathComponent("statement.csv")
        try rows.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    /// Import statement, in the budget's toolbar, with the file chosen in the
    /// open panel by its path: Command-Shift-G opens the panel's Go to field,
    /// which takes a file's whole path and selects the file, then Open. The
    /// review opens once the file is read.
    func importStatement(at url: URL) {
        click(AccessibilityID.budgetImport)
        // Only the panel's button: on a Mac with a Touch Bar, the bar shows an
        // Open button too, and a click on that one fails.
        let open = app.windows.buttons["Open"].firstMatch
        XCTAssertTrue(open.waitForExistence(timeout: 10), "the open panel did not show. On screen: \(visibleTexts())")
        app.typeKey("g", modifierFlags: [.command, .shift])
        // The Go to field slides in. Keys typed before it has the keyboard go
        // to the panel's list of files instead, so wait for the field itself.
        let goTo = app.descendants(matching: .any).matching(NSPredicate(
            format: "hasKeyboardFocus == true AND (elementType == %d OR elementType == %d)",
            XCUIElement.ElementType.textField.rawValue, XCUIElement.ElementType.comboBox.rawValue)).firstMatch
        XCTAssertTrue(goTo.waitForExistence(timeout: 10),
                      "the open panel's Go to field never took the keyboard. On screen: \(visibleTexts())")
        app.typeText(url.path)
        app.typeKey(.return, modifierFlags: [])
        let review = element(AccessibilityID.importConfirm)
        if !review.waitForExistence(timeout: 3), open.exists {
            XCTAssertTrue(wait(for: open, until: "isEnabled == true", timeout: 10),
                          "the panel did not pick \(url.lastPathComponent). On screen: \(visibleTexts())")
            open.click()
        }
        XCTAssertTrue(review.waitForExistence(timeout: 15), "the import review did not open. On screen: \(visibleTexts())")
    }

    // MARK: - A group's page

    /// A click on a group's name in the sidebar, which opens the group's
    /// page. Waits for the line under the page's name.
    func openGroupPage(named name: String) {
        click(AccessibilityID.sidebarGroup(name))
        XCTAssertTrue(element(AccessibilityID.groupSummary).waitForExistence(timeout: 10),
                      "\(name)'s page did not open. On screen: \(visibleTexts())")
    }

    /// The arrow at the end of a group's line in the sidebar, which hides or
    /// shows its budgets. The list makes the whole line one element, so the
    /// click goes to its right end, where the arrow is.
    func clickGroupArrow(_ name: String) {
        let identifier = AccessibilityID.sidebarGroup(name)
        let line = element(identifier)
        XCTAssertTrue(line.waitForExistence(timeout: 10), "no group called \(name) in the sidebar")
        waitUntilHittable(line, identifier)
        line.coordinate(withNormalizedOffset: CGVector(dx: 1, dy: 0.5)).withOffset(CGVector(dx: -9, dy: 0)).click()
    }

    /// How many budget rows in the sidebar have this name, across every group.
    func sidebarBudgetCount(_ name: String) -> Int {
        app.descendants(matching: .any).matching(identifier: AccessibilityID.sidebarBudget(name)).count
    }

    /// Waits until the sidebar has exactly this many budget rows named `name`.
    @discardableResult
    func wait(forBudgetRows name: String, count expected: Int, timeout: TimeInterval) -> Bool {
        let rows = app.descendants(matching: .any).matching(identifier: AccessibilityID.sidebarBudget(name))
        let counted = NSPredicate { _, _ in rows.count == expected }
        let expectation = XCTNSPredicateExpectation(predicate: counted, object: nil)
        return XCTWaiter().wait(for: [expectation], timeout: timeout) == .completed
    }

    /// People… in the group's menu, which opens the same page.
    func openGroupPageFromMenu(named name: String) {
        element(AccessibilityID.sidebarGroup(name)).rightClick()
        clickMenuItem(MembersScreen.Words.menuItem)
        XCTAssertTrue(element(AccessibilityID.groupSummary).waitForExistence(timeout: 10),
                      "People\u{2026} did not open \(name)'s page. On screen: \(visibleTexts())")
    }

    /// Remove… on a person's row on a group's page. It asks first, in the
    /// shared words, and the answer is Remove.
    func removeFromGroup(_ person: String) {
        click(AccessibilityID.groupRemove(person))
        XCTAssertTrue(app.staticTexts[MembersScreen.Words.removeTitle(person)].waitForExistence(timeout: 5),
                      "no question before the removal. On screen: \(visibleTexts())")
        guard let remove = dialogButton(MembersScreen.Words.removeButton) else {
            XCTFail("no \(MembersScreen.Words.removeButton) on the question. On screen: \(visibleTexts())")
            return
        }
        remove.click()
    }

    /// Join a Group…, from the Add menu: the link pasted, a name, and Join.
    /// Joining takes the group in at once.
    func join(_ link: String, as name: String) {
        openAddMenu()
        clickMenuItem(MainScreen.Words.join)
        paste(link, into: AccessibilityID.joinLink)
        type(name, into: AccessibilityID.joinName)
        click(AccessibilityID.joinJoin)
        XCTAssertTrue(wait(for: element(AccessibilityID.joinJoin), until: "exists == false", timeout: 60),
                      "joining did not finish. On screen: \(visibleTexts())")
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
    func dialogButton(_ label: String) -> XCUIElement? {
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

    /// A group of the second person's own, with one budget and one entry in
    /// it, shared with a link that invites at `role` and names them as
    /// `myName`. Everything is sent before the link comes back.
    func shareNewGroup(_ name: String, budget: String, entry merchant: String, amount: Money,
                       myName: String, role: InviteRole) async throws -> InviteLink {
        let model = AppModel(store: sync.store)
        guard let group = model.addGroup(named: name),
              let budgetID = model.addBudget(named: budget, limit: Money(minorUnits: 50_000), in: group) else {
            throw UITestError("the second account could not make its group: \(model.errorMessage ?? "")")
        }
        model.selectedBudget = budgetID
        model.addTransaction(merchant: merchant, amount: amount, date: Date(), note: "")
        if let problem = model.errorMessage { throw UITestError("the second account could not add \(merchant): \(problem)") }
        let link = try await sync.share(group: group, groupName: name, level: role.level, historyAccess: .all,
                                        myName: myName)
        try await syncAll()
        return link
    }

    /// Deletes a group of the second person's own, for everyone. Best effort.
    func deleteGroup(named name: String) async {
        let model = AppModel(store: sync.store)
        guard let group = model.groups.first(where: { $0.name == name }) else { return }
        model.deleteGroup(group.id, reach: sync.deleteReach(of: group.id))
        await sync.syncAll()
    }

    /// Ends the session on the server. Best effort.
    func cleanUp() async {
        if sync.account != nil { await sync.signOut() }
        UserDefaults(suiteName: Self.settingsSuite)?.removePersistentDomain(forName: Self.settingsSuite)
    }
}
