// The iPhone app's UI tests. They drive the real app in the iOS Simulator
// through XCUITest, the way a person uses a phone: taps, long presses, the
// field's own Paste, and pulling the list down. iOS/project.yml builds them,
// and `make iphone-ui-test` runs them on a simulator made for the run.
import Foundation
import UIKit
import XCTest
import WellSpentAppCore
import WellSpentCrypto
import WellSpentModel

/// The app under test: launched with its data in a folder of its own, and
/// the ways the test reaches into it.
@MainActor
final class PhoneTestApp {
    let app = XCUIApplication()
    /// Where this run's databases go. Removed at the end.
    let dataRoot: URL

    init() {
        dataRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("wellspent-phone-ui-test-\(UUID().uuidString)", isDirectory: true)
        // Not made here: a folder that does not exist yet tells the app this
        // is a new run, so its settings start afresh (AccountDirectory). The
        // test cannot reach the app's settings on a phone to wipe them.
        app.launchEnvironment[AccountDirectory.dataRootVariable] = dataRoot.path
    }

    // MARK: - Launching and finding things

    /// Launches, and refuses to go on against anything but a staging build.
    func launch(startingOn start: StartingScreen? = nil) {
        if let start { app.launchEnvironment[StartingScreen.variable] = start.rawValue }
        app.launch()
        XCTAssertTrue(element(AccessibilityID.stagingBanner).waitForExistence(timeout: 30),
                      "no staging banner: this is not a staging build, so nothing more is done")
    }

    /// Any element with this identifier, whatever its type. SwiftUI's element
    /// types are not certain until seen, so nothing here asks for one.
    func element(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    /// A button by its identifier. Whether it is lit is read from the button
    /// itself: a view around it can carry the same identifier and always
    /// reads as enabled.
    func button(_ identifier: String) -> XCUIElement {
        app.buttons.matching(identifier: identifier).firstMatch
    }

    /// Words on screen, wherever they are.
    func text(_ words: String) -> XCUIElement {
        app.staticTexts[words].firstMatch
    }

    func tap(_ identifier: String, timeout: TimeInterval = 10) {
        let target = element(identifier)
        XCTAssertTrue(target.waitForExistence(timeout: timeout),
                      "nothing called \(identifier) to tap. On screen: \(visibleTexts())")
        waitUntilHittable(target, identifier)
        target.tap()
    }

    /// Holds a finger on it, which opens its menu.
    func longPress(_ identifier: String) {
        let target = element(identifier)
        XCTAssertTrue(target.waitForExistence(timeout: 10), "nothing called \(identifier) to press")
        waitUntilHittable(target, identifier)
        target.press(forDuration: 1.2)
    }

    /// An item in the menu on screen, by its title. A context menu's items
    /// reach the test as buttons, a menu button's as buttons or menu items.
    func menuItem(_ title: String) -> XCUIElement {
        for candidate in [app.collectionViews.buttons[title], app.menuItems[title], app.buttons[title]]
        where candidate.exists {
            return candidate.firstMatch
        }
        return app.buttons[title].firstMatch
    }

    /// Waits for a menu item to show, then taps it.
    func tapMenuItem(_ title: String) {
        let deadline = Date().addingTimeInterval(5)
        var item = menuItem(title)
        while !item.exists, Date() < deadline {
            _ = item.waitForExistence(timeout: 0.5)
            item = menuItem(title)
        }
        XCTAssertTrue(item.exists, "no menu item \(title). On screen: \(visibleButtons())")
        item.tap()
    }

    /// The + at the foot of Home, which holds Add Budget, New Group and Join.
    func openAddMenu() {
        tap(AccessibilityID.sidebarAdd)
    }

    /// The ⋯ at the top right of a budget.
    func openBudgetMenu() {
        let more = app.navigationBars.buttons.element(boundBy: app.navigationBars.buttons.count - 1)
        XCTAssertTrue(more.waitForExistence(timeout: 10), "no ⋯ on the budget")
        more.tap()
    }

    /// Back, at the top left of a pushed screen.
    func goBack() {
        let back = app.navigationBars.buttons.element(boundBy: 0)
        XCTAssertTrue(back.waitForExistence(timeout: 10), "no Back")
        back.tap()
    }

    /// Scrolls the list until an element shows. A list draws only the rows
    /// on screen, so one further down does not exist until it is scrolled to.
    @discardableResult
    func scrollTo(_ identifier: String, timeout: TimeInterval = 30) -> XCUIElement {
        let target = element(identifier)
        let list = app.collectionViews.firstMatch
        let deadline = Date().addingTimeInterval(timeout)
        while !target.exists, Date() < deadline {
            if list.exists { list.swipeUp() } else { app.swipeUp() }
        }
        return target
    }

    /// Pulls the list down from near its top, which syncs.
    func pullDown() {
        let list = app.collectionViews.firstMatch
        XCTAssertTrue(list.waitForExistence(timeout: 10), "no list to pull down")
        let start = list.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.15))
        start.press(forDuration: 0.1, thenDragTo: start.withOffset(CGVector(dx: 0, dy: 400)))
    }

    /// Taps into a field and types, replacing whatever was there.
    func type(_ text: String, into identifier: String) {
        let field = element(identifier)
        XCTAssertTrue(field.waitForExistence(timeout: 10), "no field called \(identifier)")
        waitUntilHittable(field, identifier)
        field.tap()
        clear(field)
        field.typeText(text)
    }

    /// Takes out whatever a field holds, one Delete key at a time, as a person
    /// would with the keyboard.
    func clear(_ field: XCUIElement) {
        let current = (field.value as? String) ?? ""
        let placeholder = field.placeholderValue ?? ""
        guard !current.isEmpty, current != placeholder else { return }
        // To the end first: a tap may land the cursor anywhere in the text.
        field.coordinate(withNormalizedOffset: CGVector(dx: 0.97, dy: 0.5)).tap()
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: current.count))
    }

    /// Puts words on the phone's pasteboard, then pastes them into an empty
    /// field with Paste from the field's own menu, the way a person pastes on
    /// a phone. The pasteboard is emptied again after.
    func paste(_ text: String, into identifier: String) {
        let field = element(identifier)
        XCTAssertTrue(field.waitForExistence(timeout: 10), "no field called \(identifier)")
        waitUntilHittable(field, identifier)
        field.tap()
        clear(field)
        UIPasteboard.general.string = text
        field.tap()
        let paste = app.menuItems["Paste"].firstMatch
        if !paste.waitForExistence(timeout: 3) {
            field.press(forDuration: 1.2)
        }
        XCTAssertTrue(paste.waitForExistence(timeout: 5), "the field's menu shows no Paste. On screen: \(visibleButtons())")
        paste.tap()
        UIPasteboard.general.items = []
    }

    /// A control inside a sheet exists before the sheet has finished sliding
    /// in, and a tap then misses. So every tap waits for it to be hittable.
    func waitUntilHittable(_ target: XCUIElement, _ identifier: String) {
        XCTAssertTrue(wait(for: target, until: "hittable == true", timeout: 10),
                      "\(identifier) is on screen but cannot be tapped. On screen: \(visibleTexts())")
    }

    /// Waits for a condition on an element, such as "isEnabled == true" or
    /// "exists == false".
    @discardableResult
    func wait(for element: XCUIElement, until condition: String, timeout: TimeInterval) -> Bool {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: condition), object: element)
        return XCTWaiter().wait(for: [expectation], timeout: timeout) == .completed
    }

    /// The button on a question from the bottom of the screen, wherever iOS
    /// draws it: one query finds it in a sheet, an alert or a popover.
    func questionButton(_ label: String) -> XCUIElement? {
        let button = app.buttons[label].firstMatch
        return button.waitForExistence(timeout: 5) ? button : nil
    }

    /// Every static text on screen, for a failure message, from one snapshot.
    func visibleTexts() -> [String] {
        labels(of: .staticText)
    }

    func visibleButtons() -> [String] {
        labels(of: .button) + labels(of: .menuItem)
    }

    private func labels(of type: XCUIElement.ElementType) -> [String] {
        guard let root = try? app.snapshot() else { return [] }
        var found: [String] = []
        func walk(_ node: XCUIElementSnapshot) {
            if node.elementType == type, !node.label.isEmpty { found.append(node.label) }
            node.children.forEach(walk)
        }
        walk(root)
        return found
    }

    // MARK: - The steps the tests take

    /// Opens a budget from Home.
    func openBudget(named name: String) {
        tap(AccessibilityID.sidebarBudget(name))
        XCTAssertTrue(app.navigationBars[name].waitForExistence(timeout: 10), "\(name) did not open")
    }

    /// New Group from the + at the foot of Home, named.
    func addGroup(named name: String) {
        openAddMenu()
        tapMenuItem(MainScreen.Words.newGroup)
        type(name, into: AccessibilityID.groupEditorName)
        tap(AccessibilityID.groupEditorSave)
        XCTAssertTrue(element(AccessibilityID.sidebarGroup(name)).waitForExistence(timeout: 10),
                      "\(name) is not on Home")
    }

    /// New Budget in <group> from the group's menu. Saving opens the new budget.
    func addBudget(named name: String, amount: String, inGroup group: String) {
        longPress(AccessibilityID.sidebarGroup(group))
        tapMenuItem(MainScreen.Words.newBudget(in: group))
        type(name, into: AccessibilityID.budgetEditorName)
        type(amount, into: AccessibilityID.budgetEditorAmount)
        tap(AccessibilityID.budgetEditorSave)
        XCTAssertTrue(app.navigationBars[name].waitForExistence(timeout: 10), "\(name) did not open after Save")
    }

    /// Add, at the foot of the open budget.
    func addEntry(merchant: String, amount: String, note: String = "") {
        tap(AccessibilityID.budgetAdd)
        type(merchant, into: AccessibilityID.entryMerchant)
        type(amount, into: AccessibilityID.entryAmount)
        if !note.isEmpty { type(note, into: AccessibilityID.entryNote) }
        tap(AccessibilityID.entryAdd)
        XCTAssertTrue(element(AccessibilityID.entryRow(merchant)).waitForExistence(timeout: 10),
                      "\(merchant) is not in the list. On screen: \(visibleTexts())")
    }

    /// Signs in from the foot of Home, pasting the email and the password, and
    /// waits until the foot says budgets sync through the server.
    func signIn(email: String, password: String, server: String) throws {
        tap(AccessibilityID.sidebarSignIn)
        let serverField = element(AccessibilityID.accountServer)
        XCTAssertTrue(serverField.waitForExistence(timeout: 10), "the sign-in sheet did not open")
        if (serverField.value as? String) != server {
            type(server, into: AccessibilityID.accountServer)
        }
        paste(email, into: AccessibilityID.accountEmail)
        XCTAssertEqual(element(AccessibilityID.accountEmail).value as? String, email, "Paste did not paste the email")
        paste(password, into: AccessibilityID.accountPassword)
        tap(AccessibilityID.accountSubmit)

        guard text(SyncWording.footer(signedIn: true)).waitForExistence(timeout: 60) else {
            if element(AccessibilityID.accountCode).exists {
                throw UITestError("\(email) has not confirmed its address. Confirm it once, then run again.")
            }
            throw UITestError("signing in did not finish. On screen: \(visibleTexts())")
        }
    }

    /// Sign out, from Account at the foot of Home. Best effort.
    func signOut() {
        guard app.state == .runningForeground else { return }
        let account = element(AccessibilityID.toolbarAccount)
        guard account.waitForExistence(timeout: 5), wait(for: account, until: "isEnabled == true", timeout: 30) else {
            return
        }
        account.tap()
        let signOut = element(AccessibilityID.accountSignOut)
        guard signOut.waitForExistence(timeout: 5) else { return }
        signOut.tap()
        wait(for: text(SyncWording.footer(signedIn: false, device: Self.device)), until: "exists == true",
             timeout: 15)
    }

    /// Delete from a group's menu, confirmed. Best effort, for tidying up.
    func deleteGroup(named name: String) {
        guard app.state == .runningForeground else { return }
        let header = element(AccessibilityID.sidebarGroup(name))
        guard header.waitForExistence(timeout: 5) else { return }
        header.press(forDuration: 1.2)
        let item = menuItem(MainScreen.Words.delete)
        guard item.waitForExistence(timeout: 5) else { return }
        item.tap()
        let label = PendingDelete.group(BudgetGroup(name: name), budgets: 0, reach: .everyone).confirmLabel
        questionButton(label)?.tap()
        wait(for: header, until: "exists == false", timeout: 10)
        // The sync after an edit waits for edits to stop, then talks to the
        // server. Give it that long before the app is closed.
        _ = XCTWaiter().wait(for: [XCTestExpectation(description: "the sync after the delete")], timeout: 8)
    }

    /// What the app calls this device in its words.
    static let device = "iPhone"

    /// Closes the app and removes the run's folder.
    func cleanUp() {
        if app.state != .notRunning { app.terminate() }
        try? FileManager.default.removeItem(at: dataRoot)
    }

    /// Part of a group's name, so runs on the shared staging server never share one.
    static func stamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: Date())
    }
}

extension SecondAccount {
    /// Deletes groups of this person's own that an earlier, halted run left
    /// on staging: those named "UI Test " and a time. Only ever the test
    /// accounts' groups. Best effort.
    func deleteLeftoverRuns() async {
        let model = AppModel(store: sync.store)
        for group in model.groups where group.name.hasPrefix("UI Test ") {
            model.deleteGroup(group.id, reach: sync.deleteReach(of: group.id))
        }
        await sync.syncAll()
    }
}
