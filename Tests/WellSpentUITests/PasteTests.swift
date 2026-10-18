import AppKit
import Foundation
import XCTest
import WellSpentAppCore
import WellSpentSync

/// Command-V pastes into the app's text fields, the way a person pastes the
/// code from an email, an address or a password copied from somewhere else,
/// or an invite link from a message. The first TestFlight build had no Edit
/// menu, and Command-V did nothing in any field (2026-10-17). So every text
/// field is pasted into, here or in the flow that uses it:
/// - Here: every field of the account sheet a person reaches signed out, the
///   emailed code included. Then a new budget's name and amount, a new
///   group's name, and Join a Group's link and name.
/// - EntryEditingTests: the entry sheet's fields get the whole keyboard,
///   copy and undo included.
/// - InviteLinkTests and the share helper: the invitation page's and the
///   Share sheet's name fields.
/// - Every signed-in test: signing in pastes the address and the password.
///
/// Password fields never show what they hold. For them, the sheet's main
/// button tells whether the paste went in: it turns on only once every field
/// it needs holds something. Changing a password, signed in, uses the same
/// kind of field as resetting one.
///
/// No account is needed. The one call to the server asks for a password
/// reset for an address with no account. The staging server answers that as
/// it answers any address, and sends nothing.
final class PasteTests: XCTestCase {
    /// The run's data folder, for tearDown.
    nonisolated(unsafe) private static var dataRootPath: String?

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    /// Closes the app and leaves nothing of the run on this Mac, the clipboard
    /// included.
    override func tearDown() {
        let app = XCUIApplication()
        if app.state != .notRunning { app.terminate() }
        TestApp.wipeSettings()
        if let path = Self.dataRootPath { try? FileManager.default.removeItem(atPath: path) }
        Self.dataRootPath = nil
        NSPasteboard.general.clearContents()
        super.tearDown()
    }

    /// Signing in, making an account, and a forgotten password, as far as the
    /// emailed code and the new password.
    @MainActor
    func testCommandVPastesIntoEveryFieldOfTheAccountSheet() throws {
        let run = try start()
        run.click(AccessibilityID.sidebarSignIn)

        // Scenario PASTE-01, PASTE-09
        // 1. Signing in: the address, the server's address and the password.
        run.pasteAndCheck("pasted@example.com", into: AccessibilityID.accountEmail)
        let server = run.text(of: run.element(AccessibilityID.accountServer))
        run.pasteAndCheck(server + "/", into: AccessibilityID.accountServer)
        run.pasteAndCheck(server, into: AccessibilityID.accountServer)
        run.expect(AccessibilityID.accountSubmit, enabled: false, "Sign in, before the password")
        run.paste("a-long-password", into: AccessibilityID.accountPassword)
        run.expect(AccessibilityID.accountSubmit, enabled: true, "Sign in, once the password is pasted")

        // Scenario PASTE-09
        // 2. Making an account: the address, and the password twice.
        run.click(AccessibilityID.accountCreateAccount)
        run.pasteAndCheck("new-person@example.com", into: AccessibilityID.accountEmail)
        run.paste("a-long-password", into: AccessibilityID.accountPassword)
        run.expect(AccessibilityID.accountSubmit, enabled: false, "Create account, with the password once")
        run.paste("a-long-password", into: AccessibilityID.accountConfirmation)
        run.expect(AccessibilityID.accountSubmit, enabled: true, "Create account, once both are pasted")
        run.click(AccessibilityID.accountBack)

        // Scenario PASTE-09
        // 3. A forgotten password, for an address with no account. The code
        // goes in as the email shows it, with its dash.
        run.click(AccessibilityID.accountForgotPassword)
        run.pasteAndCheck("nobody-\(UUID().uuidString.prefix(8).lowercased())@example.com",
                          into: AccessibilityID.accountEmail)
        run.click(AccessibilityID.accountSubmit)
        guard run.element(AccessibilityID.accountCode).waitForExistence(timeout: 30) else {
            // The server allows a few reset requests an hour from one
            // address. When that is used up, the step cannot be reached.
            let limited = run.app.staticTexts.containing(NSPredicate(format: "label BEGINSWITH 'Too many attempts'"))
            if limited.firstMatch.exists {
                throw XCTSkip("the staging server's limit on reset requests from this address was reached, "
                              + "so the code field could not be reached this time")
            }
            XCTFail("no code field after asking for one. On screen: \(run.visibleTexts())")
            return
        }
        run.pasteAndCheck("K7QF-2M9X", into: AccessibilityID.accountCode)
        run.paste("a-new-long-password", into: AccessibilityID.accountNewPassword)
        run.expect(AccessibilityID.accountSubmit, enabled: false, "Set password, with the new password once")
        run.paste("a-new-long-password", into: AccessibilityID.accountConfirmation)
        run.expect(AccessibilityID.accountSubmit, enabled: true,
                   "Set password, once the code and both passwords are pasted")
        run.click(AccessibilityID.accountClose)
    }

    /// The fields for making things and for joining, signed out with the
    /// sample groups: a new budget's name and amount, a new group's name, and
    /// Join a Group's invite link and name. Nothing is saved.
    @MainActor
    func testCommandVPastesIntoTheFieldsForMakingAndJoining() throws {
        let run = try start()

        // Scenario PASTE-10
        // 1. A new budget's name and amount, the amount as a bank shows it.
        // A click on the middle of Add Budget is the button itself, not its
        // menu. If the menu opens instead, it is closed and the left part
        // clicked.
        let add = run.element(AccessibilityID.sidebarAdd)
        XCTAssertTrue(add.waitForExistence(timeout: 10), "no Add Budget control")
        run.waitUntilHittable(add, AccessibilityID.sidebarAdd)
        add.click()
        if !run.element(AccessibilityID.budgetEditorName).waitForExistence(timeout: 3) {
            run.app.typeKey(.escape, modifierFlags: [])
            add.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.5)).click()
        }
        XCTAssertTrue(run.element(AccessibilityID.budgetEditorName).waitForExistence(timeout: 5),
                      "New Budget did not open. On screen: \(run.visibleTexts())")
        run.pasteAndCheck("Pasted Budget", into: AccessibilityID.budgetEditorName)
        run.pasteAndCheck("$1,250.00", into: AccessibilityID.budgetEditorAmount)
        run.click(AccessibilityID.budgetEditorCancel)

        // Scenario PASTE-10
        // 2. A new group's name.
        run.openAddMenu()
        run.clickMenuItem(MainScreen.Words.newGroup)
        run.pasteAndCheck("Pasted Group", into: AccessibilityID.groupEditorName)
        run.click(AccessibilityID.groupEditorCancel)

        // Scenario PASTE-03, PASTE-10
        // 3. Join a Group: the pasted link says who sent it and to which
        // group, and the name takes a paste too. The link is made here, of
        // this build's type. Joining is not tried.
        let secret = Data((0..<32).map { _ in UInt8.random(in: 0...255) })
        let link = InviteLink(secret: secret, groupName: "Household", inviterName: "Leslie",
                              scheme: AppEnvironment.staging.inviteScheme)
        run.openAddMenu()
        run.clickMenuItem(MainScreen.Words.join)
        run.pasteAndCheck(link.url, into: AccessibilityID.joinLink)
        let invited = "Leslie invited you to \u{201C}Household\u{201D}."
        XCTAssertTrue(run.app.staticTexts[invited].waitForExistence(timeout: 10),
                      "the sheet does not say who sent the link. On screen: \(run.visibleTexts())")
        run.pasteAndCheck("Robin", into: AccessibilityID.joinName)
        run.click(AccessibilityID.joinCancel)
    }

    /// Launches the app with a data folder of its own, for tearDown to remove.
    @MainActor
    private func start() throws -> TestApp {
        let run = try TestApp()
        Self.dataRootPath = run.dataRoot.path
        run.launch()
        return run
    }
}
