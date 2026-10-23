import Foundation
import UIKit
import XCTest
import WellSpentAppCore

/// Paste from a field's own menu puts copied words into it, the way a person
/// pastes a code or an address on a phone. The Mac's first TestFlight build
/// could not paste at all (2026-10-17). Needs no account and no server: it
/// only opens the sign-in sheet. The signed-in test also signs in by pasting.
final class PhonePasteTests: XCTestCase {
    nonisolated(unsafe) private static var dataRootPath: String?

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    override func tearDown() {
        let app = XCUIApplication()
        if app.state != .notRunning { app.terminate() }
        if let path = Self.dataRootPath { try? FileManager.default.removeItem(atPath: path) }
        Self.dataRootPath = nil
        UIPasteboard.general.items = []
        super.tearDown()
    }

    @MainActor
    func testPasteFromTheFieldsMenu() throws {
        let run = PhoneTestApp()
        Self.dataRootPath = run.dataRoot.path
        run.launch()
        run.tap(AccessibilityID.sidebarSignIn)

        // Scenario PASTE-01
        // 1. Paste in the Email field's menu puts the copied address in it.
        run.paste("pasted@example.com", into: AccessibilityID.accountEmail)
        XCTAssertEqual(run.element(AccessibilityID.accountEmail).value as? String, "pasted@example.com",
                       "Paste did not paste into the email field")
    }

    @MainActor
    func testSelectAllCopyCutAndPasteInATransactionsFields() throws {
        let run = PhoneTestApp()
        Self.dataRootPath = run.dataRoot.path
        run.launch(startingOn: .budget)
        run.tap(AccessibilityID.budgetAdd)
        let fields = [(AccessibilityID.entryMerchant, "Hilltop", "Probe"), (AccessibilityID.entryAmount, "42.50", "12"),
                      (AccessibilityID.entryNote, "milk", "bread")]

        // Scenario PASTE-04
        // 1. Select All, then typing, replaces the whole of Merchant, Amount
        // and Note.
        for (field, first, typed) in fields {
            run.type(first, into: field)
            run.selectAll(in: field)
            run.element(field).typeText(typed)
            XCTAssertEqual(run.fieldText(field), typed, "something of \(first) is left in \(field)")
        }

        // Scenario PASTE-05
        // 2. Select All and Copy, typing X over it, then Select All and Paste,
        // brings the copied words back, in each field.
        for (field, _, typed) in fields {
            run.selectAll(in: field)
            run.chooseInEditMenu("Copy")
            run.selectAll(in: field)
            run.element(field).typeText("X")
            XCTAssertEqual(run.fieldText(field), "X", "X did not replace the words in \(field)")
            run.selectAll(in: field)
            run.chooseInEditMenu("Paste")
            XCTAssertEqual(run.fieldText(field), typed, "Paste did not bring \(typed) back into \(field)")
        }

        // Scenario PASTE-06
        // 3. Select All and Cut empties Note, and Paste puts the words back.
        run.type("weekly shop", into: AccessibilityID.entryNote)
        run.selectAll(in: AccessibilityID.entryNote)
        run.chooseInEditMenu("Cut")
        XCTAssertEqual(run.fieldText(AccessibilityID.entryNote), "", "Cut left words in Note")
        run.element(AccessibilityID.entryNote).tap()
        run.chooseInEditMenu("Paste")
        XCTAssertEqual(run.fieldText(AccessibilityID.entryNote), "weekly shop", "Paste did not put the cut words back")
        run.tap(AccessibilityID.entryCancel)
    }

    @MainActor
    func testTheFieldsForAGroupABudgetAndJoiningTakeAPaste() throws {
        let run = PhoneTestApp()
        Self.dataRootPath = run.dataRoot.path
        run.launch()

        // Scenario PASTE-10
        // 1. Signed out, with the samples: a new group's name, a new budget's
        // name and amount, and Join a Group's link and name each hold what
        // was pasted.
        run.openAddMenu()
        run.tapMenuItem(MainScreen.Words.newGroup)
        run.paste("Pasted Group", into: AccessibilityID.groupEditorName)
        XCTAssertEqual(run.fieldText(AccessibilityID.groupEditorName), "Pasted Group")
        run.tap(AccessibilityID.groupEditorCancel)

        run.openAddMenu()
        run.tapMenuItem(MainScreen.Words.addBudget)
        run.paste("Pasted Budget", into: AccessibilityID.budgetEditorName)
        run.paste("$1,250.00", into: AccessibilityID.budgetEditorAmount)
        XCTAssertEqual(run.fieldText(AccessibilityID.budgetEditorName), "Pasted Budget")
        XCTAssertEqual(run.fieldText(AccessibilityID.budgetEditorAmount), "$1,250.00")
        run.tap(AccessibilityID.budgetEditorCancel)

        run.openAddMenu()
        run.tapMenuItem(MainScreen.Words.join)
        let link = "wellspent-staging://join#s=abc&g=Household&f=Leslie"
        run.paste(link, into: AccessibilityID.joinLink)
        run.paste("Robin", into: AccessibilityID.joinName)
        XCTAssertEqual(run.fieldText(AccessibilityID.joinLink), link)
        XCTAssertEqual(run.fieldText(AccessibilityID.joinName), "Robin")
        run.tap(AccessibilityID.joinCancel)
    }
}

/// The steps these tests take, beside the ones every iPhone test shares.
extension PhoneTestApp {
    /// Select All, from the field's own edit menu, with the field focused.
    func selectAll(in identifier: String) {
        let field = element(identifier)
        XCTAssertTrue(field.waitForExistence(timeout: 10), "no field called \(identifier)")
        waitUntilHittable(field, identifier)
        field.tap()
        field.tap()
        chooseInEditMenu("Select All", holdingOn: field)
    }

    /// An item in the edit menu on screen. When it is not there yet, a press
    /// on the field opens the menu.
    func chooseInEditMenu(_ title: String, holdingOn field: XCUIElement? = nil) {
        var item = app.menuItems[title].firstMatch
        if !item.waitForExistence(timeout: 3), let field {
            field.press(forDuration: 1.0)
            item = app.menuItems[title].firstMatch
        }
        XCTAssertTrue(item.waitForExistence(timeout: 5), "the edit menu shows no \(title). On screen: \(visibleButtons())")
        item.tap()
    }
}
