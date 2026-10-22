// The UI test for the Mac app. It drives the real window through XCUITest,
// signed in to the staging server with two test accounts. It lives outside the
// Swift package: Package.swift does not declare this folder, so `swift test`
// never sees it. `make ui-test` builds it through Xcode/project.yml.
import AppKit
import Foundation
import XCTest
import WellSpentAppCore
import WellSpentCrypto
import WellSpentModel
import WellSpentSync

/// The app under test: launched with its data in a folder of its own, and
/// the ways the test reaches into its window.
@MainActor
final class TestApp {
    let app = XCUIApplication()
    /// Where this run's databases go. Removed at the end.
    let dataRoot: URL

    init() throws {
        FailureScreenshots.registerOnce()
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

    /// The UI test host's bundle ID, from Xcode/project.yml.
    static let hostBundleIdentifier = "app.wellspent.mac.uitest"

    /// Clicks a link the way a click in Mail or Messages does: macOS picks the
    /// app that claims the link's type and hands it the link. So this checks
    /// the link type is claimed, which `open(link:)` skips.
    ///
    /// The app must already be running, launched by the test with the run's
    /// folder, so the click reaches that copy. macOS starting a fresh copy
    /// itself would skip the run's folder. And only when macOS would pick the
    /// app under test: on a Mac where another app claims the same type, such
    /// as an installed WellSpent Staging, the link goes straight to the app
    /// under test instead. Returns whether macOS routed it.
    @discardableResult
    func click(link: String) throws -> Bool {
        let url = try XCTUnwrap(URL(string: link), "not a link: \(link)")
        XCTAssertEqual(app.state, .runningForeground, "the app must be running before a link is clicked")
        let handler = NSWorkspace.shared.urlForApplication(toOpen: url).flatMap { Bundle(url: $0)?.bundleIdentifier }
        guard handler == Self.hostBundleIdentifier else {
            try open(link: link)
            return false
        }
        XCTAssertTrue(NSWorkspace.shared.open(url), "macOS did not take the link")
        return true
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
        if Self.isSidebarLine(identifier) { revealInSidebar(target) }
        waitUntilHittable(target, identifier)
        target.click()
    }

    /// A group's or a budget's line in the sidebar's list.
    static func isSidebarLine(_ identifier: String) -> Bool {
        identifier.hasPrefix("sidebar.group.") || identifier.hasPrefix("sidebar.budget.")
    }

    /// Scrolls the sidebar until `target` sits clear of the bar at its foot,
    /// and holds still there. Add Budget and the sync line sit over the
    /// list's last lines, so a line under them exists and reads as hittable,
    /// yet a click on it lands on the bar. A long list of test groups puts a
    /// new one there.
    func revealInSidebar(_ target: XCUIElement) {
        let foot = element(AccessibilityID.sidebarAdd)
        let list = app.outlines.containing(NSPredicate(format: "identifier BEGINSWITH 'sidebar.'")).firstMatch
        guard target.exists, foot.exists, list.exists else { return }
        var delta: CGFloat = -60
        for _ in 0..<20 {
            waitUntilStill(target)
            let line = target.frame
            let clear = line.maxY <= foot.frame.minY - 2 && line.minY >= list.frame.minY
            if clear || line.isEmpty { return }
            // Below the foot, or above the list's top: scroll toward it.
            let wanted: CGFloat = line.maxY > foot.frame.minY - 2 ? delta : -delta
            let before = line.minY
            list.scroll(byDeltaX: 0, deltaY: wanted)
            let moved = target.frame.minY - before
            // It moved the wrong way, or not at all: the other sign is down.
            if (line.maxY > foot.frame.minY - 2 && moved >= 0) || (line.minY < list.frame.minY && moved <= 0) {
                delta = -delta
            }
        }
    }

    /// Waits, up to two seconds, for a line to stop moving. A scroll glides
    /// on after the call returns, and a click on a line still moving lands on
    /// the line beside it: another group, whose menu has the same items.
    private func waitUntilStill(_ target: XCUIElement) {
        var last = target.frame
        for _ in 0..<10 {
            Thread.sleep(forTimeInterval: 0.2)
            let now = target.frame
            if now == last { return }
            last = now
        }
    }

    /// Right-clicks a line until its menu offers `item`, then leaves the
    /// menu open for clickMenuItem. A menu that opens without it, or not at
    /// all, is closed and tried again, twice. If it never shows, the failure
    /// says where the line and the foot were, and how many elements carry
    /// the name, so a run in CI can be read without its screen.
    func openMenu(on target: XCUIElement, _ name: String, offering item: String) {
        let entry = menuItem(item)
        for _ in 0..<3 {
            if Self.isSidebarLine(name) { revealInSidebar(target) }
            rightClick(target, name)
            if entry.waitForExistence(timeout: 3) { return }
            app.typeKey(.escape, modifierFlags: [])
        }
        let carriers = app.descendants(matching: .any).matching(identifier: name).count
        XCTFail("no menu item \(item) after three right-clicks on \(name). Its frame: \(target.frame). "
                + "The sidebar's foot: \(element(AccessibilityID.sidebarAdd).frame). Elements with its name: "
                + "\(carriers). Menu items on screen: \(visibleMenuItems())")
    }

    /// Right-clicks once the target can be clicked. A sidebar line just added
    /// exists before it has its place on screen, and a right-click then lands
    /// at the screen's corner and opens the Apple menu instead (seen twice in
    /// CI on 2026-10-19).
    func rightClick(_ target: XCUIElement, _ name: String) {
        XCTAssertTrue(target.waitForExistence(timeout: 10), "nothing called \(name) to right-click")
        waitUntilHittable(target, name)
        target.rightClick()
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

    /// Pastes, then checks the field shows exactly what was pasted.
    func pasteAndCheck(_ pasted: String, into identifier: String,
                       file: StaticString = #filePath, line: UInt = #line) {
        paste(pasted, into: identifier)
        let field = element(identifier)
        XCTAssertTrue(wait(for: field, holds: pasted, timeout: 5),
                      "Command-V did not paste into \(identifier): it shows \(text(of: field))",
                      file: file, line: line)
    }

    /// Waits for a button to turn on, or off, and fails naming it when it
    /// does not.
    func expect(_ identifier: String, enabled: Bool, _ what: String,
                file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(wait(for: element(identifier), until: "isEnabled == \(enabled)", timeout: 5),
                      "\(what): it is \(enabled ? "off" : "on")", file: file, line: line)
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
        // The frames say whether a window, or the control, is off the screen.
        XCTAssertTrue(wait(for: target, until: "hittable == true", timeout: 10),
                      "\(identifier) is on screen but cannot be clicked. Its frame: \(target.frame). "
                      + "Windows: \(app.windows.allElementsBoundByIndex.map(\.frame)). On screen: \(visibleTexts())")
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
        // A failed check never prints the address: CI logs are public.
        paste(email, into: AccessibilityID.accountEmail)
        XCTAssertTrue((element(AccessibilityID.accountEmail).value as? String) == email,
                      "Command-V did not paste the address")
        paste(password, into: AccessibilityID.accountPassword)
        click(AccessibilityID.accountSubmit)

        let signedIn = app.staticTexts[SyncWording.footer(signedIn: true)]
        guard signedIn.waitForExistence(timeout: 60) else {
            if element(AccessibilityID.accountCode).exists {
                throw UITestError("the test account has not confirmed its address. Confirm it once, then run again.")
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
        openMenu(on: element(AccessibilityID.sidebarGroup(group)), AccessibilityID.sidebarGroup(group),
                 offering: MainScreen.Words.newBudget(in: group))
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
        openShareSheet(for: group)
        pasteAndCheck(myName, into: AccessibilityID.shareName)
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

    /// Share… from the group's menu, until the sheet that opens is titled
    /// with this group. A right-click that lands on the line beside it opens
    /// another group's menu, which offers Share… too, and the link then names
    /// that group (seen in CI on 2026-10-19). Such a sheet is cancelled and
    /// the menu tried again, twice.
    private func openShareSheet(for group: String) {
        let line = AccessibilityID.sidebarGroup(group)
        let form = element(AccessibilityID.shareName)
        let title = app.staticTexts[ShareScreen.Words.shareTitle(group)].firstMatch
        for _ in 0..<3 {
            openMenu(on: element(line), line, offering: MainScreen.Words.share)
            clickMenuItem(MainScreen.Words.share)
            XCTAssertTrue(form.waitForExistence(timeout: 10), "Share\u{2026} opened no sheet. On screen: \(visibleTexts())")
            if title.waitForExistence(timeout: 3) { return }
            click(AccessibilityID.shareCancel)
            wait(for: form, until: "exists == false", timeout: 10)
        }
        XCTFail("Share\u{2026} never opened the sheet for \(group). On screen: \(visibleTexts())")
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
        revealInSidebar(row)
        waitUntilHittable(row, name)
        row.click()
    }

    /// Delete… from a budget's menu in the sidebar, confirmed.
    func deleteBudget(named name: String) {
        let row = sidebarBudget(name)
        XCTAssertTrue(row.waitForExistence(timeout: 10), "no budget called \(name) in the sidebar")
        openMenu(on: row, AccessibilityID.sidebarBudget(name), offering: MainScreen.Words.delete)
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
        revealInSidebar(line)
        waitUntilHittable(line, identifier)
        line.coordinate(withNormalizedOffset: CGVector(dx: 1, dy: 0.5)).withOffset(CGVector(dx: -9, dy: 0)).click()
    }

    /// How many elements in the sidebar carry a budget's identifier, across
    /// every group. One row shows as more than one element, its name and its
    /// amount, so compare counts with each other, never with a row count.
    func sidebarBudgetCount(_ name: String) -> Int {
        app.descendants(matching: .any).matching(identifier: AccessibilityID.sidebarBudget(name)).count
    }

    /// Waits until the count `sidebarBudgetCount` gives for `name` passes `test`.
    @discardableResult
    func wait(forBudgetRows name: String, timeout: TimeInterval, until test: @escaping (Int) -> Bool) -> Bool {
        let rows = app.descendants(matching: .any).matching(identifier: AccessibilityID.sidebarBudget(name))
        let counted = NSPredicate { _, _ in test(rows.count) }
        let expectation = XCTNSPredicateExpectation(predicate: counted, object: nil)
        return XCTWaiter().wait(for: [expectation], timeout: timeout) == .completed
    }

    // MARK: - The money wheel

    /// Waits for a wheel, a budget's or a group's, to read `expected`, as a
    /// screen reader reads it: "Left $75 of $100". Each wheel is one element,
    /// labelled with what its middle says.
    func expect(wheel identifier: String, reads expected: String, _ what: String,
                file: StaticString = #filePath, line: UInt = #line) {
        let wheel = element(identifier)
        XCTAssertTrue(wheel.waitForExistence(timeout: 10), "\(what): no \(identifier). On screen: \(visibleTexts())",
                      file: file, line: line)
        XCTAssertTrue(wait(for: wheel, holds: expected, timeout: 10),
                      "\(what): the wheel reads \(text(of: wheel)), not \(expected)", file: file, line: line)
    }

    /// Waits for each of a wheel's figures to show, its label and its amount.
    func expect(figures: [MoneyWheel.Figure], _ what: String, file: StaticString = #filePath, line: UInt = #line) {
        for figure in figures {
            for words in [figure.label, figure.amount] {
                XCTAssertTrue(listText(words).waitForExistence(timeout: 10),
                              "\(what): no \(words). On screen: \(visibleTexts())", file: file, line: line)
            }
        }
    }

    /// Checks the pace words under a budget's figures are exactly `pace`'s,
    /// with Edit Budget… beside them when it offers it, or that there are
    /// none when it is nil.
    func expect(pace: BudgetPace?, _ what: String, file: StaticString = #filePath, line: UInt = #line) {
        let words = element(AccessibilityID.budgetPace)
        let edit = element(AccessibilityID.budgetPaceEdit)
        guard let pace else {
            XCTAssertFalse(words.waitForExistence(timeout: 3),
                           "\(what): pace words where there should be none: \(text(of: words))", file: file, line: line)
            return
        }
        XCTAssertTrue(words.waitForExistence(timeout: 10), "\(what): no pace words. On screen: \(visibleTexts())",
                      file: file, line: line)
        XCTAssertTrue(wait(for: words, holds: pace.text, timeout: 10),
                      "\(what): the pace words are \(text(of: words)), not \(pace.text)", file: file, line: line)
        if pace.offersEdit {
            XCTAssertTrue(edit.waitForExistence(timeout: 5), "\(what): no Edit Budget\u{2026} beside the pace words",
                          file: file, line: line)
        } else {
            XCTAssertFalse(edit.exists, "\(what): Edit Budget\u{2026} for someone who may not change it",
                           file: file, line: line)
        }
    }

    /// Waits for a budget's row in the sidebar to show `words`. The row is a
    /// button, which may read its texts into its own label rather than show
    /// each one, so either counts.
    func expect(row name: String, shows words: String, file: StaticString = #filePath, line: UInt = #line) {
        let row = sidebarBudget(name)
        let text = listText(words)
        let shown = NSPredicate { _, _ in text.exists || (row.exists && row.label.contains(words)) }
        let found = XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: shown, object: nil)], timeout: 10)
        XCTAssertEqual(found, .completed, "\(name)'s row does not show \(words). Its label: \(row.label). "
                       + "On screen: \(visibleTexts())", file: file, line: line)
    }

    /// People… in the group's menu, which opens the same page.
    func openGroupPageFromMenu(named name: String) {
        openMenu(on: element(AccessibilityID.sidebarGroup(name)), AccessibilityID.sidebarGroup(name),
                 offering: MembersScreen.Words.menuItem)
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
        guard header.waitForExistence(timeout: 5), wait(for: header, until: "hittable == true", timeout: 10) else {
            return
        }
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
    /// A sandboxed runner reaches only its own copy, so the app also starts
    /// afresh on a run's first launch (`AccountDirectory.testing(at:)`).
    nonisolated static func wipeSettings() {
        UserDefaults(suiteName: AccountDirectory.testDefaultsSuiteName)?
            .removePersistentDomain(forName: AccountDirectory.testDefaultsSuiteName)
    }
}
