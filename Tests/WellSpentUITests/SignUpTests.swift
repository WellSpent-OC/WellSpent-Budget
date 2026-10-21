import AppKit
import Foundation
import XCTest
import WellSpentAppCore
import WellSpentSync

/// Making an account in the real window, at an address no person can own:
/// what Create an account asks for and turns down, the code staging emails,
/// a wrong code and another code, the address confirmed later from Account,
/// an address that already has an account, and a forgotten password, for an
/// address not confirmed yet and for one confirmed.
///
/// One account a run, at a fresh address at example.com, with passwords made
/// in the run and never printed: they are pasted, so the log shows no
/// keystrokes of them. Staging cannot delete an account, so it stays there.
/// The account's group is deleted at the end, and the password reset signs
/// out every other session before this one signs out.
///
/// One run makes 1 account and sends 2 sign-ups (the second turned down, for
/// an address with an account), 1 sign-in, 2 requests for a reset code (one
/// for the address before it is confirmed, which gets none) and 1 password
/// reset, which signs in too. Staging emails 2 codes, a third if "Send
/// another code" comes a minute or more after the first, and a note that the
/// password changed.
///
/// Needs WELLSPENT_UI_TEST_MAILBOX_TOKEN, which reads the codes staging
/// emails (StagingMailbox.swift), and skips without it. It never uses the two
/// shared test accounts.
final class SignUpTests: XCTestCase {
    /// The run's app, for tearDown.
    nonisolated(unsafe) private static var run: TestApp?
    /// The account's group on staging, until the test deletes it.
    nonisolated(unsafe) private static var groupName: String?

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    /// Runs after the test, passed or halted, with no await in it. A test
    /// that halted part way can leave the account signed in, and its group
    /// on staging: as far as the window allows, the group is deleted and the
    /// account signed out. Then the app is closed, and nothing of the run
    /// stays on this Mac, the clipboard included.
    override func tearDown() {
        // A click that fails here must not stop the rest.
        continueAfterFailure = true
        MainActor.assumeIsolated {
            if let run = Self.run {
                run.tidyAfterAHalt(deleting: Self.groupName)
                run.cleanUp()
            }
        }
        Self.run = nil
        Self.groupName = nil
        NSPasteboard.general.clearContents()
        super.tearDown()
    }

    @MainActor
    func testCreateAnAccountConfirmItsEmailAndResetItsPassword() async throws {
        typealias Words = AccountFlow.Words
        let mailbox = try StagingMailbox.fromEnvironment()
        let run = try TestApp()
        Self.run = run
        let address = StagingMailbox.freshAddress("mac", for: "robin")
        // As a person might type it. The account is the address in small letters.
        let typed = address.replacingOccurrences(of: "robin@example.com", with: "Robin@Example.com")
        let password = UUID().uuidString + "Aa1!", newPassword = UUID().uuidString + "Aa1!"
        let groupName = "UI Signup \(Self.stamp())", kept = "On this computer"
        let typo = (email: "robin", password: "short", confirmation: "something else")
        let refused = try await Self.refusals(for: typo)

        // 1. A staging build on a fresh install, signed out.
        run.launch()

        // Scenario ACCT-02
        // 2. Sign in, then Create an account: the sheet asks for an email, a
        // password twice and the server, and says where the budgets go and
        // who can read them.
        run.click(AccessibilityID.sidebarSignIn)
        run.click(AccessibilityID.accountCreateAccount)
        run.expect(step: .signUp, "Create an account")
        for (field, name) in [(AccessibilityID.accountEmail, Words.email),
                              (AccessibilityID.accountPassword, Words.password),
                              (AccessibilityID.accountConfirmation, Words.confirmation),
                              (AccessibilityID.accountServer, Words.server)] {
            run.expect(field: field, named: name, "Create an account")
        }
        run.expect(words: Words.privacy, "Create an account")

        // Scenario ACCT-02
        // 3. Create account stays dimmed until the email and both passwords
        // hold something.
        run.expect(AccessibilityID.accountSubmit, named: Words.createAccountButton, "Create an account")
        run.expect(AccessibilityID.accountSubmit, enabled: false, "Create account, with nothing typed")
        run.type(typo.email, into: AccessibilityID.accountEmail)
        run.expect(AccessibilityID.accountSubmit, enabled: false, "Create account, with only the email")
        run.type(typo.password, into: AccessibilityID.accountPassword)
        run.expect(AccessibilityID.accountSubmit, enabled: false, "Create account, with the password once")
        run.type(typo.confirmation, into: AccessibilityID.accountConfirmation)
        run.expect(AccessibilityID.accountSubmit, enabled: true, "Create account, with all three")

        // Scenario ACCT-03
        // 4. With "robin", "short" and another password, Create account says
        // under each field what is wrong. Nothing is sent: the sheet stays,
        // and the foot of the list still says this computer only.
        run.click(AccessibilityID.accountSubmit)
        run.expect(problem: refused.email, under: AccessibilityID.accountEmail,
                   above: AccessibilityID.accountPassword)
        run.expect(problem: refused.password, under: AccessibilityID.accountPassword,
                   above: AccessibilityID.accountConfirmation)
        run.expect(problem: refused.confirmation, under: AccessibilityID.accountConfirmation,
                   above: AccessibilityID.accountServer)
        run.expect(step: .signUp, "after the problems")
        run.expectFooter(signedIn: false, "after the problems")

        // Scenario ACCT-02
        // 5. The address with capitals, and the same password twice: the
        // sheet moves on to Confirm your email, naming the address in small
        // letters, and the foot of the list says the server. Staging emails
        // a code, and keeps it for the test.
        run.useServer(mailbox.server)
        run.type(typed, into: AccessibilityID.accountEmail)
        run.paste(password, into: AccessibilityID.accountPassword)
        run.paste(password, into: AccessibilityID.accountConfirmation)
        run.click(AccessibilityID.accountSubmit)
        run.expect(step: .confirmEmail, "after Create account")
        run.expect(words: Words.enterCode(sentTo: address), "after Create account")
        run.expectFooter(signedIn: true, "after Create account")
        let firstCode = try await mailbox.code(for: address)

        // Scenario ACCT-05
        // 6. Confirm stays dimmed until the code has all 8 letters and
        // numbers. The code typed is a wrong one: the emailed code with its
        // last letter changed.
        let wrongCode = String(firstCode.dropLast()) + (firstCode.hasSuffix("A") ? "B" : "A")
        run.expect(AccessibilityID.accountSubmit, named: Words.confirm, "Confirm your email")
        run.expect(AccessibilityID.accountSubmit, enabled: false, "Confirm, with no code")
        run.type(String(wrongCode.dropLast()), into: AccessibilityID.accountCode)
        run.expect(AccessibilityID.accountSubmit, enabled: false, "Confirm, with 7 of the 8")
        run.type(wrongCode, into: AccessibilityID.accountCode)
        run.expect(AccessibilityID.accountSubmit, enabled: true, "Confirm, with all 8")

        // Scenario ACCT-06
        // 7. The wrong code is turned down, and the sheet stays on Confirm
        // your email. Send another code says when a new code comes.
        run.click(AccessibilityID.accountSubmit)
        run.expect(words: refused.wrongCode, "after a wrong code")
        run.expect(step: .confirmEmail, "after a wrong code")
        run.expect(AccessibilityID.accountSendCode, named: Words.sendAnotherCode, "after a wrong code")
        run.click(AccessibilityID.accountSendCode)
        run.expect(words: ConfirmEmailScreen.codeOnItsWay, "after Send another code")

        // 8. Not now closes the sheet, signed in, with the address still to
        // confirm. A group and a budget in the account give the toolbar its
        // Account button. Then Account, Sign out.
        run.expect(AccessibilityID.accountClose, named: Words.notNow, "Confirm your email")
        run.click(AccessibilityID.accountClose)
        run.expectSheetClosed("after Not now")
        run.expectFooter(signedIn: true, "after Not now")
        run.addGroup(named: groupName)
        Self.groupName = groupName
        run.addBudget(named: "Groceries", amount: "500", inGroup: groupName)
        run.signOut()
        run.expectFooter(signedIn: false, "after Sign out")

        // 9. Signed out, a group of this computer's own, with a budget.
        run.addGroup(named: kept)
        run.addBudget(named: "Fuel", amount: "100", inGroup: kept)

        // Scenario ACCT-10
        // 10. A forgotten password for the address not confirmed yet. The
        // address typed on Sign in is filled in on Reset your password. Send
        // code says what it says for any address, and no code comes. Start
        // over goes back to the address.
        run.click(AccessibilityID.sidebarSignIn)
        run.expect(step: .signIn, "Sign in")
        run.useServer(mailbox.server)
        run.type(address, into: AccessibilityID.accountEmail)
        run.click(AccessibilityID.accountForgotPassword)
        run.expect(step: .forgotPassword, "after Forgot your password?")
        run.expectEmail(address, "Reset your password")
        // The newest message to the address: the code to confirm it.
        let unconfirmedCode = try await mailbox.code(for: address)
        run.expect(AccessibilityID.accountSubmit, named: Words.sendResetCode, "Reset your password")
        run.click(AccessibilityID.accountSubmit)
        run.expect(words: Words.resetCodeSent(to: address), "after Send code, not confirmed")
        XCTAssertTrue(run.element(AccessibilityID.accountCode).waitForExistence(timeout: 10),
                      "no Code field after Send code. On screen: \(run.visibleTexts())")
        let stray = try? await mailbox.code(for: address, after: unconfirmedCode, timeout: 10)
        XCTAssertNil(stray, "a reset code went to an address never confirmed")
        run.click(AccessibilityID.accountStartOver)
        XCTAssertTrue(run.wait(for: run.element(AccessibilityID.accountCode), until: "exists == false", timeout: 10),
                      "Start over did not go back to the address. On screen: \(run.visibleTexts())")
        run.expectEmail(address, "after Start over")

        // Scenario ACCT-04
        // 11. Back on Sign in, Create an account with the same address is
        // turned down, and the sheet stays. Cancel: still signed out, and
        // this computer's group and budget are as they were.
        run.click(AccessibilityID.accountBack)
        run.click(AccessibilityID.accountCreateAccount)
        run.expect(step: .signUp, "Create an account, again")
        run.type(address, into: AccessibilityID.accountEmail)
        run.paste(password, into: AccessibilityID.accountPassword)
        run.paste(password, into: AccessibilityID.accountConfirmation)
        run.click(AccessibilityID.accountSubmit)
        run.expect(words: refused.taken, "an address with an account")
        run.expect(step: .signUp, "an address with an account")
        run.click(AccessibilityID.accountClose)
        run.expectSheetClosed("after Cancel")
        run.expectFooter(signedIn: false, "after an address with an account")
        XCTAssertTrue(run.element(AccessibilityID.sidebarGroup(kept)).waitForExistence(timeout: 10),
                      "this computer's group is gone. Sidebar: \(run.sidebarIdentifiers())")
        XCTAssertTrue(run.sidebarBudget("Fuel").exists, "this computer's budget is gone. Sidebar: \(run.sidebarIdentifiers())")

        // Scenario ACCT-07
        // 12. Signing in with the address not confirmed: the sheet moves to
        // Confirm your email, says why, and offers Send a code. Not now
        // closes it, and the account stays signed in.
        run.click(AccessibilityID.sidebarSignIn)
        run.expect(step: .signIn, "Sign in, not confirmed")
        run.useServer(mailbox.server)
        run.type(address, into: AccessibilityID.accountEmail)
        run.paste(password, into: AccessibilityID.accountPassword)
        run.click(AccessibilityID.accountSubmit)
        run.expect(step: .confirmEmail, "after signing in")
        run.expect(words: ConfirmEmailScreen.reason, "after signing in")
        run.expect(AccessibilityID.accountSendCode, named: Words.sendFirstCode, "after signing in")
        run.click(AccessibilityID.accountClose)
        run.expectSheetClosed("after Not now")
        run.expectFooter(signedIn: true, "after Not now")

        // Scenario ACCT-07
        // 13. With a budget open, Account says the same words, and Confirm
        // your email… leads back to the code.
        run.openBudget(named: "Groceries")
        run.openAccount()
        run.expect(step: .account, "Account, not confirmed")
        run.expect(words: ConfirmEmailScreen.reason, "Account, not confirmed")
        run.expect(AccessibilityID.accountConfirmEmail, named: Words.confirmEmail, "Account, not confirmed")
        run.click(AccessibilityID.accountConfirmEmail)
        run.expect(step: .confirmEmail, "after Confirm your email\u{2026}")
        XCTAssertTrue(run.element(AccessibilityID.accountCode).waitForExistence(timeout: 10),
                      "no Code field after Confirm your email\u{2026}. On screen: \(run.visibleTexts())")

        // Scenario ACCT-05
        // 14. The code from the email, in small letters and without its dash:
        // the sheet moves to Your account, says the email is confirmed and
        // who is signed in, and offers the account's buttons.
        let code = try await mailbox.code(for: address)
        run.type(code.lowercased().replacingOccurrences(of: "-", with: ""), into: AccessibilityID.accountCode)
        run.expect(AccessibilityID.accountSubmit, enabled: true, "Confirm, with the code")
        run.click(AccessibilityID.accountSubmit)
        run.expect(step: .account, "after Confirm")
        run.expect(words: Words.confirmed, "after Confirm")
        run.expect(words: Words.signedInAs(address), "after Confirm")
        for (button, name) in [(AccessibilityID.accountChangePassword, Words.changePassword),
                               (AccessibilityID.accountSignOut, Words.signOut),
                               (AccessibilityID.accountSignOutEverywhere, Words.signOutEverywhere),
                               (AccessibilityID.accountClose, Words.done)] {
            run.expect(button, named: name, "Your account, confirmed")
        }
        XCTAssertFalse(run.element(AccessibilityID.accountConfirmEmail).exists,
                       "Confirm your email\u{2026} after the email is confirmed")
        XCTAssertFalse(run.app.staticTexts[ConfirmEmailScreen.reason].exists,
                       "Your account still asks to confirm the email")
        run.click(AccessibilityID.accountClose)
        run.expectSheetClosed("after Done")

        // 15. Tidy, before the end: the group goes, for everyone.
        run.deleteGroup(named: groupName)
        Self.groupName = nil

        // Scenario ACCT-10
        // 16. Quit and opened again. The test build keeps its keys in memory
        // (AccountDirectory.testing), so this computer is signed out now.
        // Its sign-in sheet opens by itself, or Sign in opens it. Forgot your
        // password?, with the address typed, then Send code: a code is on
        // its way, and the sheet asks for it and a new password twice, with
        // Start over.
        run.app.terminate()
        run.launch()
        if !run.element(AccessibilityID.accountForgotPassword).waitForExistence(timeout: 10) {
            run.click(AccessibilityID.sidebarSignIn)
        }
        run.expect(step: .signIn, "after opening again")
        run.type(address, into: AccessibilityID.accountEmail)
        run.click(AccessibilityID.accountForgotPassword)
        run.expect(step: .forgotPassword, "after Forgot your password?, confirmed")
        run.expectEmail(address, "Reset your password, confirmed")
        run.useServer(mailbox.server)
        run.click(AccessibilityID.accountSubmit)
        run.expect(words: Words.resetCodeSent(to: address), "after Send code, confirmed")
        for (field, name) in [(AccessibilityID.accountCode, Words.code),
                              (AccessibilityID.accountNewPassword, Words.newPassword),
                              (AccessibilityID.accountConfirmation, Words.confirmation)] {
            run.expect(field: field, named: name, "after Send code, confirmed")
        }
        run.expect(AccessibilityID.accountStartOver, named: Words.startOver, "after Send code, confirmed")
        let resetCode = try await mailbox.code(for: address, after: code)

        // Scenario ACCT-10, ACCT-05
        // 17. The code and a new password twice, then Set password: Your
        // account says the password is changed and this computer is signed
        // in. The email stayed confirmed through the quit: nothing asks for
        // it again.
        run.type(resetCode, into: AccessibilityID.accountCode)
        run.paste(newPassword, into: AccessibilityID.accountNewPassword)
        run.paste(newPassword, into: AccessibilityID.accountConfirmation)
        run.expect(AccessibilityID.accountSubmit, named: Words.setPassword, "Reset your password")
        run.expect(AccessibilityID.accountSubmit, enabled: true, "Set password, with the code and both passwords")
        run.click(AccessibilityID.accountSubmit)
        run.expect(step: .account, "after Set password")
        run.expect(words: PasswordResetScreen.finished, "after Set password")
        run.expectFooter(signedIn: true, "after Set password")
        XCTAssertFalse(run.element(AccessibilityID.accountConfirmEmail).exists,
                       "Confirm your email\u{2026} after the quit, for an email confirmed before it")
        XCTAssertFalse(run.app.staticTexts[ConfirmEmailScreen.reason].exists,
                       "Your account asks again to confirm an email confirmed before the quit")

        // 18. Tidy: Sign out. The reset has already signed every other
        // session out.
        run.click(AccessibilityID.accountSignOut)
        run.expectSheetClosed("after Sign out")
        run.expectFooter(signedIn: false, "after Sign out")
    }

    /// Part of the group's name, so runs never share one.
    private static func stamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: Date())
    }
}

// MARK: - The words a refusal shows

private extension SignUpTests {
    /// What the sheet says when it turns something down. These words are
    /// written inside the shared screens rather than in a Words enum, so the
    /// test reads them by running those screens, with the shared stand-in
    /// for the server behind them, which refuses as staging does.
    struct Refusals {
        /// Under Email, Password and Confirm password.
        let email: String, password: String, confirmation: String
        /// For an address that already has an account.
        let taken: String
        /// For a code that is wrong.
        let wrongCode: String
    }

    /// `typo` is what the test types first: an email, a password and its
    /// confirmation, each wrong.
    @MainActor
    static func refusals(for typo: (email: String, password: String, confirmation: String)) async throws
        -> Refusals {
        let standIn = StandIn()
        func signUp(_ email: String, _ password: String, _ confirmation: String) async -> SignUpScreen {
            let screen = SignUpScreen(actions: standIn)
            screen.email = email
            screen.password = password
            screen.confirmation = confirmation
            _ = await screen.submit()
            return screen
        }
        let checked = await signUp(typo.email, typo.password, typo.confirmation)
        let password = UUID().uuidString + "Aa1!"
        _ = await signUp("robin@example.com", password, password)
        let again = await signUp("robin@example.com", password, password)
        let confirm = ConfirmEmailScreen(actions: standIn, codeAlreadySent: true)
        // No code has a 0 in it, so this one is wrong.
        confirm.code = "0000-0000"
        _ = await confirm.submit()
        return Refusals(email: try XCTUnwrap(checked.problems[.email], "no problem under Email"),
                        password: try XCTUnwrap(checked.problems[.password], "no problem under Password"),
                        confirmation: try XCTUnwrap(checked.problems[.confirmation],
                                                    "no problem under Confirm password"),
                        taken: try XCTUnwrap(again.failure, "an address with an account was not turned down"),
                        wrongCode: try XCTUnwrap(confirm.failure, "a wrong code was not turned down"))
    }

    /// The shared stand-in for the server, as the account screens see it.
    /// Signing up and confirming go to it. The test asks nothing else.
    @MainActor
    final class StandIn: AccountActions {
        private let client = InMemoryReadableServer().client()
        private(set) var account: String?
        var emailVerified: Bool { false }
        var signInPrompt: SyncCoordinator.SignInPrompt? { nil }

        func signUp(email: String, password: String) async throws {
            _ = try await client.signUp(email: email, password: password, deviceLabel: nil)
            account = email
        }

        func verifyEmail(code: String) async throws {
            try await client.verifyEmail(code: code)
        }

        func signIn(email: String, password: String) async throws { throw Self.notAsked }
        func resendVerification() async throws { throw Self.notAsked }
        func forgotPassword(email: String) async throws { throw Self.notAsked }
        func resetPassword(email: String, code: String, newPassword: String) async throws { throw Self.notAsked }
        func changePassword(current: String, new: String) async throws { throw Self.notAsked }
        func signOut() async {}
        func signOutEverywhere() async throws { throw Self.notAsked }

        private static var notAsked: UITestError { UITestError("the test asks the stand-in only to sign up and confirm") }
    }
}

// MARK: - The account sheet

private extension TestApp {
    /// Waits for the account sheet to show `step`: its title, and a control
    /// only that step has. The words of some titles are on a button too,
    /// such as Create an account, a link on Sign in, so a title alone could
    /// be the wrong step. Reset your password has no such button.
    func expect(step: AccountFlow.Step, _ what: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(app.staticTexts[step.title].firstMatch.waitForExistence(timeout: 30),
                      "\(what): the sheet is not on \(step.title). On screen: \(visibleTexts())",
                      file: file, line: line)
        let own: String? = switch step {
        case .signIn: AccessibilityID.accountForgotPassword
        case .signUp: AccessibilityID.accountConfirmation
        case .forgotPassword: nil
        case .confirmEmail: AccessibilityID.accountSendCode
        case .account: AccessibilityID.accountChangePassword
        case .changePassword: AccessibilityID.accountCurrentPassword
        }
        guard let own else { return }
        XCTAssertTrue(element(own).waitForExistence(timeout: 10),
                      "\(what): \(step.title) has no \(own). On screen: \(visibleTexts())", file: file, line: line)
    }

    /// Waits for a line with exactly these words, anywhere in the app. A
    /// line drawn with an icon, such as the sheet's failure, can reach the
    /// test as another kind of element, so any kind counts.
    func expect(words: String, _ what: String, file: StaticString = #filePath, line: UInt = #line) {
        let saying = NSPredicate(format: "label == %@ OR title == %@ OR value == %@", words, words, words)
        XCTAssertTrue(app.descendants(matching: .any).matching(saying).firstMatch.waitForExistence(timeout: 15),
                      "\(what): no line saying \(words) On screen: \(visibleTexts())", file: file, line: line)
    }

    /// Waits for a field, and for its name beside it: the words on the
    /// field's row, or else the field's own label or the words it shows
    /// when empty. A form's field shows its name on its row, and on the
    /// first run its own label was empty.
    func expect(field identifier: String, named words: String, _ what: String,
                file: StaticString = #filePath, line: UInt = #line) {
        let field = element(identifier)
        XCTAssertTrue(field.waitForExistence(timeout: 10), "\(what): no \(identifier). On screen: \(visibleTexts())",
                      file: file, line: line)
        if [field.label, field.title, field.placeholderValue ?? ""].contains(words) { return }
        let name = app.staticTexts[words].firstMatch
        XCTAssertTrue(name.waitForExistence(timeout: 5),
                      "\(what): no \(words) for \(identifier). On screen: \(visibleTexts())", file: file, line: line)
        let row = field.frame.insetBy(dx: 0, dy: -4), middle = name.frame.midY
        XCTAssertTrue(row.minY <= middle && middle <= row.maxY,
                      "\(what): \(words) is not on the row of \(identifier). It is at \(name.frame), "
                      + "the field at \(field.frame)", file: file, line: line)
    }

    /// Waits for a button to be named with these words: its label, or else
    /// its title.
    func expect(_ identifier: String, named words: String, _ what: String,
                file: StaticString = #filePath, line: UInt = #line) {
        let target = element(identifier)
        XCTAssertTrue(target.waitForExistence(timeout: 10), "\(what): no \(identifier). On screen: \(visibleTexts())",
                      file: file, line: line)
        let named = NSPredicate { candidate, _ in
            guard let element = candidate as? XCUIElement, element.exists else { return false }
            return [element.label, element.title, element.placeholderValue ?? ""].contains(words)
        }
        let found = XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: named, object: target)], timeout: 5)
        XCTAssertEqual(found, .completed, "\(what): \(identifier) is not named \(words). Its label is \(target.label), "
                       + "its title \(target.title), its placeholder \(target.placeholderValue ?? "none")",
                       file: file, line: line)
    }

    /// Waits for a problem's words, and checks they sit under their field
    /// and above the next field down.
    func expect(problem words: String, under field: String, above next: String,
                file: StaticString = #filePath, line: UInt = #line) {
        let problem = app.staticTexts[words].firstMatch
        XCTAssertTrue(problem.waitForExistence(timeout: 10), "no line saying \(words) On screen: \(visibleTexts())",
                      file: file, line: line)
        let over = element(field).frame, below = element(next).frame, shown = problem.frame
        XCTAssertTrue(shown.minY >= over.maxY - 2 && shown.maxY <= below.minY + 2,
                      "\(words) is not under \(field): it is at \(shown), \(field) at \(over), \(next) at \(below)",
                      file: file, line: line)
    }

    /// Waits for the Email field to hold this address.
    func expectEmail(_ address: String, _ what: String, file: StaticString = #filePath, line: UInt = #line) {
        let field = element(AccessibilityID.accountEmail)
        XCTAssertTrue(wait(for: field, holds: address, timeout: 10),
                      "\(what): the Email field holds \(text(of: field)), not \(address)", file: file, line: line)
    }

    /// Waits for the account sheet to close.
    func expectSheetClosed(_ what: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(wait(for: element(AccessibilityID.accountClose), until: "exists == false", timeout: 15),
                      "\(what): the sheet is still open. On screen: \(visibleTexts())", file: file, line: line)
    }

    /// Waits for the foot of the list to say whether this computer syncs.
    func expectFooter(signedIn: Bool, _ what: String, file: StaticString = #filePath, line: UInt = #line) {
        let words = SyncWording.footer(signedIn: signedIn)
        XCTAssertTrue(app.staticTexts[words].firstMatch.waitForExistence(timeout: 30),
                      "\(what): the foot of the list does not say \(words). On screen: \(visibleTexts())",
                      file: file, line: line)
    }

    /// The sheet's Server field set to `server`, when it says another.
    func useServer(_ server: String) {
        let field = element(AccessibilityID.accountServer)
        XCTAssertTrue(field.waitForExistence(timeout: 10), "no Server field. On screen: \(visibleTexts())")
        if (field.value as? String) != server {
            type(server, into: AccessibilityID.accountServer)
        }
    }

    /// Account, in the open budget's toolbar, once a sync no longer holds it.
    func openAccount() {
        let account = element(AccessibilityID.toolbarAccount)
        XCTAssertTrue(account.waitForExistence(timeout: 10), "no Account button: is a budget open?")
        XCTAssertTrue(wait(for: account, until: "isEnabled == true", timeout: 30), "Account stayed dimmed")
        account.click()
        XCTAssertTrue(element(AccessibilityID.accountClose).waitForExistence(timeout: 10),
                      "Account opened no sheet. On screen: \(visibleTexts())")
    }

    /// After a test that halted part way. Once the group is gone, the
    /// sheet's own Sign out ends the session, if it shows. Otherwise any
    /// sheet closes, and a signed-in account's group is deleted, then the
    /// account signed out through Account while a budget is left to open it
    /// from. Best effort: what the window no longer reaches stays.
    func tidyAfterAHalt(deleting group: String?) {
        guard app.state == .runningForeground else { return }
        let signOutHere = element(AccessibilityID.accountSignOut)
        if group == nil, signOutHere.exists {
            signOutHere.click()
            return
        }
        let close = element(AccessibilityID.accountClose)
        if close.exists, close.isEnabled {
            close.click()
            wait(for: close, until: "exists == false", timeout: 10)
        }
        guard app.staticTexts[SyncWording.footer(signedIn: true)].firstMatch.exists else { return }
        if let group { deleteGroup(named: group) }
        signOut()
    }
}
