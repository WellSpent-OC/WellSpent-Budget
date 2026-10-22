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
        PhoneFailureScreenshots.registerOnce()
        dataRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("wellspent-phone-ui-test-\(UUID().uuidString)", isDirectory: true)
        // Not made here, though it needn't be: the app's first launch into it
        // starts its settings afresh and marks the folder (AccountDirectory).
        // The test cannot reach the app's settings on a phone to wipe them.
        app.launchEnvironment[AccountDirectory.dataRootVariable] = dataRoot.path
    }

    // MARK: - Launching and finding things

    /// Launches, and refuses to go on against anything but a staging build.
    /// `pinnedDay` puts the money wheel on that day of this month, whatever
    /// day the test runs (`Workspace.pinnedDayVariable`).
    func launch(startingOn start: StartingScreen? = nil, pinnedDay: Int? = nil) {
        if let start { app.launchEnvironment[StartingScreen.variable] = start.rawValue }
        if let pinnedDay { app.launchEnvironment[Workspace.pinnedDayVariable] = String(pinnedDay) }
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
        // A query by words takes at most 128 characters. Longer ones, such as
        // a question's message, are matched by label.
        guard words.count > 128 else { return app.staticTexts[words].firstMatch }
        return app.staticTexts.matching(NSPredicate(format: "label == %@", words)).firstMatch
    }

    /// Whether these words show on screen within the time given. A slow
    /// runner draws a change late, so a check right after an action waits
    /// for it. Capitals are ignored: the phone's keyboard may start a note
    /// with one.
    func shows(_ words: String, timeout: TimeInterval = 10) -> Bool {
        app.staticTexts.matching(NSPredicate(format: "label ==[c] %@", words)).firstMatch
            .waitForExistence(timeout: timeout)
    }

    /// Whether an entry's row holds these words within the time given. A row
    /// is one element, read as its words in order, so its words are in its
    /// label and not on screen as words of their own. Capitals are ignored,
    /// as in `shows`.
    func row(_ merchant: String, says words: String, timeout: TimeInterval = 10) -> Bool {
        app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier == %@ AND label CONTAINS[c] %@",
                                  AccessibilityID.entryRow(merchant), words))
            .firstMatch.waitForExistence(timeout: timeout)
    }

    /// What an entry's row says, for a failure message.
    func rowLabel(_ merchant: String) -> String {
        let row = element(AccessibilityID.entryRow(merchant))
        return row.exists ? row.label : "no row for \(merchant)"
    }

    func tap(_ identifier: String, timeout: TimeInterval = 10) {
        let target = find(identifier, timeout: timeout)
        XCTAssertTrue(target.exists, "nothing called \(identifier) to tap. On screen: \(visibleTexts())")
        waitUntilHittable(target, identifier)
        target.tap()
    }

    /// Holds a finger on a row of a list, which opens its menu.
    func longPress(_ identifier: String) {
        let target = find(identifier, timeout: 10)
        XCTAssertTrue(target.exists, "nothing called \(identifier) to press. On screen: \(visibleTexts())")
        bringToMiddle(target)
        waitUntilHittable(target, identifier)
        // A press on a row the list is still moving is taken as a tap, which
        // opens the row instead of its menu.
        waitUntilStill(target, identifier)
        target.press(forDuration: 1.2)
    }

    /// Waits for an element. If it has not shown, a Save Password sheet in
    /// front is answered, and then the list is scrolled to it: a test account
    /// keeps the groups earlier runs made, so a row just made can sit below
    /// the bottom of Home, where the list has not drawn it.
    private func find(_ identifier: String, timeout: TimeInterval) -> XCUIElement {
        let target = element(identifier)
        if target.waitForExistence(timeout: timeout) { return target }
        if answerSavePasswordIfAsked(), target.waitForExistence(timeout: timeout) { return target }
        scrollTo(identifier)
        return target
    }

    /// An item in the menu on screen, by its title as the shared words write
    /// it. The iPhone drops a desktop "…" (`PhoneWording.button`), so this
    /// does too. A context menu's items reach the test as buttons, a menu
    /// button's as buttons or menu items.
    func menuItem(_ desktopTitle: String) -> XCUIElement {
        let title = PhoneWording.button(desktopTitle)
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
        tap(AccessibilityID.budgetMenu)
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
        if target.exists { bringToMiddle(target) }
        return target
    }

    /// Drags the list until a row of it is mid screen, if it is near the top
    /// or the bottom. Low on the screen, a row sits against Home's foot bar,
    /// where a long press opens nothing. High up, it sits under the title
    /// bar, which takes a tap meant for it.
    func bringToMiddle(_ row: XCUIElement) {
        let list = app.collectionViews.firstMatch
        // A row not drawn yet has no frame to read, which looks like the top.
        guard list.exists, row.exists else { return }
        let screen = app.frame
        let frame = row.frame
        // A high row comes down only just clear of the bar, to 30 percent:
        // a list near its top would go past it into a pull, which syncs.
        let goal: CGFloat
        if frame.maxY > screen.height * 0.6 {
            goal = 0.45
        } else if frame.minY < screen.height * 0.2 {
            goal = 0.3
        } else {
            return
        }
        let distance = frame.midY - screen.height * goal
        // Up from low on the list, or down from high on it, so the drag stays
        // on the screen.
        let start = list.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: distance > 0 ? 0.7 : 0.3))
        start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: 0, dy: -distance)))
    }

    /// Pulls the list down from near its top, which syncs.
    func pullDown() {
        let list = app.collectionViews.firstMatch
        XCTAssertTrue(list.waitForExistence(timeout: 10), "no list to pull down")
        // A pull only syncs from the top of the list. Scrolled down, as after
        // a step that scrolled to a row, the drag only scrolls back up.
        for _ in 0..<3 { list.swipeDown() }
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
        UIPasteboard.general.string = text
        pasteCopied(into: identifier)
    }

    /// Pastes whatever was copied, such as a link copied in the share sheet,
    /// into an empty field with Paste from the field's own menu. The
    /// pasteboard is emptied after.
    func pasteCopied(into identifier: String) {
        let field = element(identifier)
        XCTAssertTrue(field.waitForExistence(timeout: 10), "no field called \(identifier)")
        waitUntilHittable(field, identifier)
        // On a slow runner a Paste can land nowhere, leaving the field empty.
        // So the field is checked, and pasted into once more if it is empty.
        pasteOnce(into: field)
        if !isFilled(field) { pasteOnce(into: field) }
        XCTAssertTrue(isFilled(field), "the paste into \(identifier) did not land. On screen: \(visibleTexts())")
        UIPasteboard.general.items = []
    }

    /// Empties the field, then Paste from its own menu.
    private func pasteOnce(into field: XCUIElement) {
        field.tap()
        clear(field)
        field.tap()
        let paste = app.menuItems["Paste"].firstMatch
        if !paste.waitForExistence(timeout: 3) {
            field.press(forDuration: 1.2)
        }
        XCTAssertTrue(paste.waitForExistence(timeout: 5), "the field's menu shows no Paste. On screen: \(visibleButtons())")
        paste.tap()
    }

    /// Whether the field holds something other than its prompt, within a
    /// few seconds. A password field holds dots, which counts.
    private func isFilled(_ field: XCUIElement) -> Bool {
        let deadline = Date().addingTimeInterval(3)
        repeat {
            let value = (field.value as? String) ?? ""
            if !value.isEmpty, value != field.placeholderValue { return true }
            Thread.sleep(forTimeInterval: 0.25)
        } while Date() < deadline
        return false
    }

    /// Pulls Home down and waits for the sync it starts to end, so every
    /// change made so far is on the server, and every change on the server
    /// is here.
    func syncAndWait() {
        let pulled = Date().timeIntervalSince1970
        pullDown()
        waitForASync(endingAfter: pulled)
        XCTAssertTrue(text(SyncWording.footer(signedIn: true, device: Self.device)).waitForExistence(timeout: 10),
                      "the sync did not end well. On screen: \(visibleTexts())")
    }

    /// Waits up to 30 seconds for a sync that ends after `time`, in seconds
    /// since 1970. The staging banner's value is when the last one ended:
    /// the one sign of a sync that every screen has, a sheet's included.
    func waitForASync(endingAfter time: TimeInterval) {
        let banner = element(AccessibilityID.stagingBanner)
        let deadline = Date().addingTimeInterval(30)
        while Date() < deadline {
            if let ended = Double((banner.value as? String) ?? ""), ended >= time { return }
            Thread.sleep(forTimeInterval: 1)
        }
        XCTFail("no sync ended in the 30 seconds after asking for one. "
                + "The banner says the last one ended at \(banner.value ?? "no time")")
    }

    /// A sync, then the budget opened to see whether it offers Add: the sign
    /// that a move to a level has come in, since at View it does not. Back on
    /// Home after.
    func syncUntilTheLevel(allowsAdding: Bool, in budget: String) {
        syncAndWait()
        scrollTo(AccessibilityID.sidebarBudget(budget))
        openBudget(named: budget)
        let add = element(AccessibilityID.budgetAdd)
        if allowsAdding {
            XCTAssertTrue(add.waitForExistence(timeout: 30), "no Add in \(budget): the move up has not come in")
        } else {
            XCTAssertTrue(wait(for: add, until: "exists == false", timeout: 30),
                          "\(budget) still offers Add: the move down to View has not come in")
        }
        goBack()
        XCTAssertTrue(element(AccessibilityID.sidebarAdd).waitForExistence(timeout: 10), "not back on Home")
    }

    /// Closes a menu that is open, with a tap beside it, as a person does.
    func dismissMenu() {
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.08, dy: 0.6)).tap()
        _ = app.collectionViews.firstMatch.waitForExistence(timeout: 2)
    }

    /// Closes the iPhone's own share sheet without sending anything: its
    /// close button, or a swipe down on it where iOS draws none.
    func closeShareSheetWithoutSending() {
        let copy = app.buttons["Copy"].firstMatch
        let copyCell = app.cells["Copy"].firstMatch
        let deadline = Date().addingTimeInterval(30)
        while !copy.exists, !copyCell.exists, Date() < deadline { _ = copy.waitForExistence(timeout: 0.5) }
        XCTAssertTrue(copy.exists || copyCell.exists, "the share sheet never opened. On screen: \(visibleTexts())")
        let close = app.buttons.matching(NSPredicate(format: "label ==[c] 'close' OR identifier ==[c] 'close'"))
            .firstMatch
        if close.exists, close.isHittable {
            close.tap()
        } else {
            // Down from inside the share sheet, never from mid screen: the share
            // sheet can start below the middle, and a drag there closes the
            // app's own Share sheet behind it instead (seen on CI). From its
            // link at the top, or else a little above Copy.
            let link = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "wellspent")).firstMatch
            let row = copy.exists ? copy : copyCell
            let start = link.exists ? link.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
                                    : row.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: -2.5))
            start.press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.98)),
                        withVelocity: .fast, thenHoldForDuration: 0)
        }
        let gone = wait(for: copy, until: "exists == false", timeout: 10)
            && wait(for: copyCell, until: "exists == false", timeout: 5)
        XCTAssertTrue(gone, "the share sheet stayed. Its buttons: "
                      + app.buttons.allElementsBoundByIndex.prefix(30).map(\.label).joined(separator: ", "))
    }

    /// Copy, in the iPhone's own share sheet, once it has slid up. The
    /// share sheet draws Copy as a button or a cell, by iOS version.
    func copyInShareSheet() {
        let deadline = Date().addingTimeInterval(20)
        while Date() < deadline {
            for candidate in [app.buttons["Copy"], app.cells["Copy"]] where candidate.firstMatch.exists {
                let copy = candidate.firstMatch
                if copy.isHittable {
                    // The share sheet is still sliding up when Copy can first
                    // be tapped, and a tap then misses it.
                    waitUntilStill(copy, "Copy")
                    copy.tap()
                    return
                }
            }
            _ = app.buttons["Copy"].waitForExistence(timeout: 0.5)
        }
        XCTFail("the share sheet shows no Copy. On screen: \(visibleButtons())")
    }

    /// A tap on a link, as in Messages: the system hands it to the copy of
    /// the app already running. Not XCUIApplication.open(_:), which may start
    /// a fresh copy: a test run keeps its keys in memory only, so that copy
    /// would have no session. iOS may ask first whether to open the app.
    func open(link: String) {
        guard let url = URL(string: link) else {
            XCTFail("\(link) is not a link")
            return
        }
        XCUIDevice.shared.system.open(url)
        let ask = XCUIApplication(bundleIdentifier: "com.apple.springboard").buttons["Open"]
        if ask.waitForExistence(timeout: 3) { ask.tap() }
    }

    /// A tap on a group's name on Home, which opens its page. Home is
    /// scrolled to the top first, since a list only scrolls down to it.
    func openGroupPage(named name: String) {
        for _ in 0..<3 where !element(AccessibilityID.sidebarGroup(name)).exists { app.swipeDown() }
        let header = scrollTo(AccessibilityID.sidebarGroup(name))
        XCTAssertTrue(header.exists, "no group called \(name) on Home. On screen: \(visibleTexts())")
        waitUntilStill(header, name)
        tap(AccessibilityID.sidebarGroup(name))
        // One tap, then a long wait: on CI a look at the screen can take 9
        // seconds. If the page never comes, the buttons say whether the tap
        // was taken as a long press, which opens the group's menu instead.
        XCTAssertTrue(element(AccessibilityID.groupSummary).waitForExistence(timeout: 30),
                      "a tap on \(name) opened no page. On screen: \(visibleTexts()) \(visibleButtons())")
    }

    /// A control inside a sheet exists before the sheet has finished sliding
    /// in, and a tap then misses. So every tap waits for it to be hittable.
    /// The wait is long because CI's runners are slow: one look at the screen
    /// there took 9 seconds while a sheet slid in after a menu.
    func waitUntilHittable(_ target: XCUIElement, _ identifier: String) {
        var hittable = wait(for: target, until: "hittable == true", timeout: 30)
        if !hittable, answerSavePasswordIfAsked() {
            hittable = wait(for: target, until: "hittable == true", timeout: 30)
        }
        XCTAssertTrue(hittable, "\(identifier) is on screen but cannot be tapped. On screen: \(visibleTexts())")
    }

    /// After a form with a password goes away, iOS may offer to save the
    /// password, in a sheet over the app. A person answers it, and so does a
    /// test: Not Now. This answers only a sheet already showing, and says
    /// whether there was one.
    @discardableResult
    func answerSavePasswordIfAsked() -> Bool {
        guard app.staticTexts["Save Password?"].exists else { return false }
        let notNow = app.buttons["Not Now"].firstMatch
        XCTAssertTrue(notNow.waitForExistence(timeout: 10),
                      "the Save Password sheet has no Not Now. On screen: \(visibleButtons())")
        notNow.tap()
        XCTAssertTrue(wait(for: notNow, until: "exists == false", timeout: 15), "the Save Password sheet stayed")
        return true
    }

    /// A row a list is still sliding into place is hittable before it is
    /// still, and a swipe or tap on it then lands in the wrong place. So this
    /// waits for two looks in a row to find it in the same place.
    func waitUntilStill(_ target: XCUIElement, _ identifier: String) {
        let deadline = Date().addingTimeInterval(30)
        var last = target.frame
        while Date() < deadline {
            Thread.sleep(forTimeInterval: 0.5)
            let now = target.frame
            if now == last { return }
            last = now
        }
        XCTFail("\(identifier) kept moving for 30 seconds")
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
        let giveaways = ScreenPrivacy.giveaways
        var found: [String] = []
        func walk(_ node: XCUIElementSnapshot) {
            if node.elementType == type, !node.label.isEmpty { found.append(masked(node.label, giveaways)) }
            node.children.forEach(walk)
        }
        walk(root)
        return found
    }

    /// A label with a test account's address, or the part before its @, out
    /// of sight: failure messages go to CI's log, which is public.
    private func masked(_ label: String, _ giveaways: [String]) -> String {
        giveaways.reduce(label) { text, giveaway in
            text.replacingOccurrences(of: giveaway, with: "[a test address]", options: .caseInsensitive)
        }
    }

    // MARK: - The steps the tests take

    /// Opens a budget from Home.
    func openBudget(named name: String) {
        bringToMiddle(scrollTo(AccessibilityID.sidebarBudget(name)))
        tap(AccessibilityID.sidebarBudget(name))
        XCTAssertTrue(app.navigationBars[name].waitForExistence(timeout: 10),
                      "\(name) did not open. On screen: \(visibleTexts())")
    }

    /// New Group from the + at the foot of Home, named.
    func addGroup(named name: String) {
        openAddMenu()
        tapMenuItem(MainScreen.Words.newGroup)
        type(name, into: AccessibilityID.groupEditorName)
        tap(AccessibilityID.groupEditorSave)
        // A signed-in account may hold other groups, so the new one can be
        // below the bottom of the screen.
        XCTAssertTrue(scrollTo(AccessibilityID.sidebarGroup(name), timeout: 15).exists,
                      "\(name) is not on Home. On screen: \(visibleTexts())")
    }

    /// New Budget in <group> from the group's menu. Saving opens the new budget.
    func addBudget(named name: String, amount: String, inGroup group: String) {
        scrollTo(AccessibilityID.sidebarGroup(group))
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
        // Not XCTAssertEqual, which would print the address into the CI log.
        XCTAssertTrue(element(AccessibilityID.accountEmail).value as? String == email, "Paste did not paste the email")
        paste(password, into: AccessibilityID.accountPassword)
        tap(AccessibilityID.accountSubmit)

        guard text(SyncWording.footer(signedIn: true)).waitForExistence(timeout: 60) else {
            if element(AccessibilityID.accountCode).exists {
                throw UITestError("the first test account has not confirmed its address. Confirm it once, then run again.")
            }
            throw UITestError("signing in did not finish. On screen: \(visibleTexts())")
        }
    }

    /// Sign out, from Account at the foot of Home. A step of its own, so it
    /// fails the test when it cannot. Changes not sent yet are not sent: wait
    /// for the sync first (`syncAndWait()`).
    func signOut() {
        guard app.state == .runningForeground else { return }
        let account = button(AccessibilityID.toolbarAccount)
        guard account.waitForExistence(timeout: 5), wait(for: account, until: "isEnabled == true", timeout: 30) else {
            XCTFail("Account never lit, so no sign out. On screen: \(visibleTexts())")
            return
        }
        account.tap()
        let signOut = element(AccessibilityID.accountSignOut)
        // A tap while the screen is still sliding back can be lost: once more.
        if !signOut.waitForExistence(timeout: 5), account.isHittable { account.tap() }
        guard signOut.waitForExistence(timeout: 10) else {
            XCTFail("the account sheet shows no Sign out. On screen: \(visibleTexts()) \(visibleButtons())")
            return
        }
        waitUntilHittable(signOut, AccessibilityID.accountSignOut)
        signOut.tap()
        wait(for: text(SyncWording.footer(signedIn: false, device: Self.device)), until: "exists == true",
             timeout: 15)
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
        runStampFormatter().string(from: Date())
    }
}

extension SecondAccount {
    /// What every iPhone run's group names start with: "UI Phone " and the
    /// run's time, like the Mac's "UI <word> <time>", so staging's cleanup
    /// knows them.
    static let phoneRunPrefix = "UI Phone "

    /// Deletes groups of this person's own that an earlier, halted iPhone run
    /// left on staging. Other runs may be going at the same time, on the Mac
    /// or in another pull request's CI, so only groups more than an hour old
    /// go, and only the iPhone's. Best effort.
    func deleteLeftoverRuns() async {
        let formatter = runStampFormatter()
        let anHourAgo = Date().addingTimeInterval(-3600)
        let model = AppModel(store: sync.store)
        for group in model.groups where group.name.hasPrefix(Self.phoneRunPrefix) {
            // The time, and anything after it, such as " mine".
            let stamp = String(group.name.dropFirst(Self.phoneRunPrefix.count).prefix(15))
            guard let made = formatter.date(from: stamp), made < anHourAgo else { continue }
            model.deleteGroup(group.id, reach: sync.deleteReach(of: group.id))
        }
        await sync.syncAll()
    }
}

/// The time in a run's group name, "20261018-161500", always in UTC, so a
/// Mac and a CI runner in different time zones read each other's the same.
func runStampFormatter() -> DateFormatter {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(identifier: "UTC")
    formatter.dateFormat = "yyyyMMdd-HHmmss"
    return formatter
}

extension SecondAccount {
    /// Syncs until a group of this name holds a budget of that name with an
    /// entry for this merchant, or the time runs out. The phone sends a change
    /// a moment after it is made, so a first sync can come too soon.
    func waitFor(group: String, budget: String, merchant: String, timeout: TimeInterval = 60) async throws -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            try await syncAll()
            let model = AppModel(store: sync.store)
            if let found = model.groups.first(where: { $0.name == group }),
               let summary = model.summaries[found.id]?.first(where: { $0.budget.name == budget }),
               try model.store.transactions(in: summary.budget.id).contains(where: { $0.merchant == merchant }) {
                return true
            }
            try await Task.sleep(for: .seconds(3))
        } while Date() < deadline
        return false
    }
}
