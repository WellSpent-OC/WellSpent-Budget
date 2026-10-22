import Foundation
import UIKit
import XCTest
import WellSpentAppCore
import WellSpentCrypto
import WellSpentModel
import WellSpentSync

/// Getting in, on a phone, with accounts the run makes: create an account,
/// the checks before anything is sent, an address that has one already,
/// confirming the email with the code staging sends, a wrong code and
/// another one, a password reset, signing out everywhere, being signed out
/// from another device, and an account whose email is not confirmed yet.
///
/// Each account has a fresh address at example.com, and its codes come from
/// staging's test mailbox (StagingMailbox.swift). Needs the mailbox token and
/// the server, and skips without them. Runs in light only, under the shared
/// sign-in lock, since staging limits sign-ups and sign-ins from one place.
final class PhoneAccountTests: XCTestCase {
    nonisolated(unsafe) private static var dataRootPath: String?

    static let password = "a-long-password-1"
    static let newPassword = "another-long-password-2"

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    /// No await in it, as in PhoneSignInSyncTests.
    override func tearDown() {
        let app = XCUIApplication()
        if app.state != .notRunning { app.terminate() }
        if let path = Self.dataRootPath { try? FileManager.default.removeItem(atPath: path) }
        Self.dataRootPath = nil
        UIPasteboard.general.items = []
        super.tearDown()
    }

    @MainActor
    func testMakingAnAccountConfirmingItAndResettingItsPassword() async throws {
        let mailbox = try StagingMailbox.fromEnvironment()
        let address = StagingMailbox.freshAddress("iphone", for: "robin")
        let run = PhoneTestApp()
        Self.dataRootPath = run.dataRoot.path
        run.launch()
        run.tap(AccessibilityID.sidebarSignIn)
        run.tap(AccessibilityID.accountCreateAccount)
        XCTAssertTrue(run.app.navigationBars[AccountFlow.Step.signUp.title].waitForExistence(timeout: 10), "no Create an account")
        run.paste(mailbox.server, into: AccessibilityID.accountServer)
        XCTAssertEqual(run.fieldText(AccessibilityID.accountServer), mailbox.server, "the server field did not take a paste")

        // Scenario ACCT-03
        // 1. An address that isn't one, a short password and a confirmation
        // that differs each say what is wrong, and nothing is sent.
        run.type("robin", into: AccessibilityID.accountEmail)
        run.type("short", into: AccessibilityID.accountPassword)
        run.type("something else", into: AccessibilityID.accountConfirmation)
        run.tap(AccessibilityID.accountSubmit)
        for problem in ["That does not look like an email address.", "A password needs at least 10 characters.",
                        "The two passwords are not the same."] {
            XCTAssertTrue(run.text(problem).waitForExistence(timeout: 5), "no \"\(problem)\". On screen: \(run.visibleTexts())")
        }
        XCTAssertTrue(run.app.navigationBars[AccountFlow.Step.signUp.title].exists, "the sheet moved on")

        // Scenario ACCT-02
        // 2. The sheet asks for Email, Password, Confirm password and Server,
        // with the privacy words, and Create account waits for all three.
        // Made with capitals in the address, it moves to Confirm your email,
        // naming the address in small letters, and the foot says the budgets
        // sync through the server.
        for field in [AccessibilityID.accountEmail, AccessibilityID.accountPassword, AccessibilityID.accountConfirmation,
                      AccessibilityID.accountServer] {
            XCTAssertTrue(run.element(field).exists, "no \(field)")
        }
        XCTAssertTrue(run.shows(AccountFlow.Words.privacy), "no privacy words. On screen: \(run.visibleTexts())")
        run.clearField(AccessibilityID.accountEmail)
        run.clearField(AccessibilityID.accountPassword)
        run.clearField(AccessibilityID.accountConfirmation)
        XCTAssertFalse(run.button(AccessibilityID.accountSubmit).isEnabled, "Create account lit with empty fields")
        let typed = "I" + address.dropFirst().replacingOccurrences(of: "@example.com", with: "@Example.com")
        run.paste(typed, into: AccessibilityID.accountEmail)
        run.paste(Self.password, into: AccessibilityID.accountPassword)
        XCTAssertFalse(run.button(AccessibilityID.accountSubmit).isEnabled, "Create account lit with no confirmation")
        run.paste(Self.password, into: AccessibilityID.accountConfirmation)
        XCTAssertTrue(run.button(AccessibilityID.accountSubmit).isEnabled, "Create account did not light once pasted")
        run.tap(AccessibilityID.accountSubmit)
        XCTAssertTrue(run.app.navigationBars[AccountFlow.Step.confirmEmail.title].waitForExistence(timeout: 30),
                      "the sheet did not move to Confirm your email. On screen: \(run.visibleTexts())")
        XCTAssertTrue(run.shows(AccountFlow.Words.enterCode(sentTo: address)), "the address is not named in small letters")
        let first = try await mailbox.code(for: address)

        // Scenario ACCT-06
        // 3. A wrong code says so and stays. Send another code says which code
        // works.
        run.type("AAAA-AAAA", into: AccessibilityID.accountCode)
        run.tap(AccessibilityID.accountSubmit)
        XCTAssertTrue(run.text("That code is wrong or has expired.").waitForExistence(timeout: 15),
                      "a wrong code is not refused. On screen: \(run.visibleTexts())")
        XCTAssertTrue(run.app.navigationBars[AccountFlow.Step.confirmEmail.title].exists, "the sheet moved on")
        run.tap(AccessibilityID.accountSendCode)
        XCTAssertTrue(run.text(ConfirmEmailScreen.codeOnItsWay).waitForExistence(timeout: 15),
                      "no words after Send another code. On screen: \(run.visibleTexts())")

        // Scenario ACCT-05
        // 4. Confirm waits for all 8 letters and numbers. The code typed in
        // small letters with no dash confirms the email: the sheet says so,
        // names the account, and offers Change password, Sign out, Sign out
        // everywhere and Done.
        let code = try await mailbox.code(for: address)
        run.clearField(AccessibilityID.accountCode)
        run.type("ABCD", into: AccessibilityID.accountCode)
        XCTAssertFalse(run.button(AccessibilityID.accountSubmit).isEnabled, "Confirm lit with half a code")
        run.clearField(AccessibilityID.accountCode)
        run.type(code.replacingOccurrences(of: "-", with: "").lowercased(), into: AccessibilityID.accountCode)
        run.tap(AccessibilityID.accountSubmit)
        XCTAssertTrue(run.app.navigationBars[AccountFlow.Step.account.title].waitForExistence(timeout: 30),
                      "the code did not confirm the email. On screen: \(run.visibleTexts()) (first code \(first == code ? "reused" : "replaced"))")
        XCTAssertTrue(run.shows(AccountFlow.Words.confirmed), "no Your email is confirmed")
        XCTAssertTrue(run.shows(AccountFlow.Words.signedInAs(address)), "the account is not named")
        for button in [AccessibilityID.accountChangePassword, AccessibilityID.accountSignOut,
                       AccessibilityID.accountSignOutEverywhere, AccessibilityID.accountClose] {
            XCTAssertTrue(run.element(button).exists, "no \(button)")
        }
        run.tap(AccessibilityID.accountClose)
        XCTAssertTrue(run.shows(SyncWording.footer(signedIn: true)), "the foot does not say the budgets sync")
        run.addGroup(named: "Mine")

        // Scenario ACCT-14
        // 5. The account's list of signed-in devices, which the server keeps,
        // names the phone the way the shared code does: "iPhone".
        let labels = try await SecondAccount.deviceLabels(server: mailbox.server, email: address, password: Self.password)
        XCTAssertTrue(labels.contains(DeviceName.current),
                      "the server does not list this phone as \(DeviceName.current): \(labels)")
        XCTAssertEqual(DeviceName.current, PhoneTestApp.device)

        // Scenario ACCT-12
        // 6. Sign out everywhere asks first. Cancel keeps him signed in. Sign
        // Out Everywhere closes the sheet and signs this phone out.
        run.syncAndWait()
        run.tap(AccessibilityID.toolbarAccount)
        run.tap(AccessibilityID.accountSignOutEverywhere)
        XCTAssertTrue(run.text(AccountFlow.Words.signOutEverywhereTitle).waitForExistence(timeout: 5), "no question")
        XCTAssertTrue(run.text(AccountFlow.Words.signOutEverywhereMessage).exists, "the question's words are wrong")
        run.cancelQuestion()
        XCTAssertTrue(run.element(AccessibilityID.accountSignOutEverywhere).exists, "Cancel signed him out")
        run.tap(AccessibilityID.accountSignOutEverywhere)
        try XCTUnwrap(run.questionButton(AccountFlow.Words.signOutEverywhereButton)).tap()
        XCTAssertTrue(run.text(SyncWording.footer(signedIn: false, device: PhoneTestApp.device)).waitForExistence(timeout: 20),
                      "still signed in. On screen: \(run.visibleTexts())")

        // Scenario ACCT-04
        // 7. Making an account with that address again stays on Create an
        // account and says it has one. Nothing signs in.
        run.tap(AccessibilityID.sidebarSignIn)
        run.tap(AccessibilityID.accountCreateAccount)
        run.paste(address, into: AccessibilityID.accountEmail)
        run.paste(Self.password, into: AccessibilityID.accountPassword)
        run.paste(Self.password, into: AccessibilityID.accountConfirmation)
        run.tap(AccessibilityID.accountSubmit)
        XCTAssertTrue(run.text("That email already has an account. Sign in, or reset its password.").waitForExistence(timeout: 20),
                      "no words for an address with an account. On screen: \(run.visibleTexts())")
        XCTAssertTrue(run.app.navigationBars[AccountFlow.Step.signUp.title].exists, "the sheet moved on")
        run.tap(AccessibilityID.accountBack)

        // Scenario ACCT-10, PASTE-09
        // 8. Forgot your password, with the address typed: Reset your password
        // has it filled in. Send code says a code is on its way, and asks for
        // the code and a new password twice, with Start over. The emailed
        // code and the new password sign him in and say every other device
        // was signed out.
        run.paste(address, into: AccessibilityID.accountEmail)
        run.tap(AccessibilityID.accountForgotPassword)
        XCTAssertTrue(run.app.navigationBars[AccountFlow.Step.forgotPassword.title].waitForExistence(timeout: 10), "no reset")
        XCTAssertEqual(run.fieldText(AccessibilityID.accountEmail), address, "the address is not filled in")
        run.tap(AccessibilityID.accountSubmit)
        XCTAssertTrue(run.text(AccountFlow.Words.resetCodeSent(to: address)).waitForExistence(timeout: 20),
                      "no words after Send code. On screen: \(run.visibleTexts())")
        for field in [AccessibilityID.accountCode, AccessibilityID.accountNewPassword, AccessibilityID.accountConfirmation,
                      AccessibilityID.accountStartOver] {
            XCTAssertTrue(run.element(field).exists, "no \(field)")
        }
        // The code pasted as the email shows it, with its dash, and the new
        // password pasted twice, light Set password.
        let resetCode = try await mailbox.code(for: address, after: code)
        run.paste(resetCode, into: AccessibilityID.accountCode)
        run.paste(Self.newPassword, into: AccessibilityID.accountNewPassword)
        run.paste(Self.newPassword, into: AccessibilityID.accountConfirmation)
        XCTAssertTrue(run.button(AccessibilityID.accountSubmit).isEnabled, "Set password did not light once pasted")
        run.tap(AccessibilityID.accountSubmit)
        XCTAssertTrue(run.text(PasswordResetScreen.finished).waitForExistence(timeout: 30),
                      "the reset did not finish. On screen: \(run.visibleTexts())")
        run.tap(AccessibilityID.accountClose)

        // Scenario ACCT-13
        // 9. Signed in on another device too, which signs out everywhere: at
        // the phone's next sync the sign-in sheet opens by itself, with the
        // address filled in and why. Signed in again, the account's group is
        // back.
        let otherDevice = try SecondAccount(server: mailbox.server, settingsSuite: "app.wellspent.uitest.robin")
        try await otherDevice.signIn(email: address, password: Self.newPassword)
        try await otherDevice.sync.signOutEverywhere()
        run.pullDown()
        let signedOut = "You were signed out on this device. Sign in again. Your budgets are still here."
        XCTAssertTrue(run.text(signedOut).waitForExistence(timeout: 30),
                      "the sign-in did not open by itself. On screen: \(run.visibleTexts())")
        XCTAssertEqual(run.fieldText(AccessibilityID.accountEmail), address, "the address is not filled in")
        run.paste(Self.newPassword, into: AccessibilityID.accountPassword)
        run.tap(AccessibilityID.accountSubmit)
        XCTAssertTrue(run.text(SyncWording.footer(signedIn: true)).waitForExistence(timeout: 30), "signing in again did not finish")
        XCTAssertTrue(run.scrollTo(AccessibilityID.sidebarGroup("Mine")).exists, "the account's group did not come back")

        // 10. Tidy.
        run.signOut()
        await otherDevice.cleanUp()
    }

    @MainActor
    func testAnAccountWhoseEmailIsNotConfirmedYet() async throws {
        let mailbox = try StagingMailbox.fromEnvironment()
        let address = StagingMailbox.freshAddress("iphone", for: "leslie")
        let run = PhoneTestApp()
        Self.dataRootPath = run.dataRoot.path
        run.launch()
        run.tap(AccessibilityID.sidebarSignIn)
        run.tap(AccessibilityID.accountCreateAccount)
        if (run.element(AccessibilityID.accountServer).value as? String) != mailbox.server {
            run.type(mailbox.server, into: AccessibilityID.accountServer)
        }
        run.paste(address, into: AccessibilityID.accountEmail)
        run.paste(Self.password, into: AccessibilityID.accountPassword)
        run.paste(Self.password, into: AccessibilityID.accountConfirmation)
        run.tap(AccessibilityID.accountSubmit)
        XCTAssertTrue(run.app.navigationBars[AccountFlow.Step.confirmEmail.title].waitForExistence(timeout: 30), "no Confirm your email")
        let signUpCode = try await mailbox.code(for: address)
        run.tap(AccessibilityID.accountClose)
        run.signOut()

        // Scenario ACCT-09
        // 1. A wrong password, and an address with no account, each stay on
        // Sign in and say the email or password is wrong. Nothing syncs: the
        // foot still says the budgets are kept on this iPhone.
        run.tap(AccessibilityID.sidebarSignIn)
        for (email, password) in [(address, "not-the-password-9"),
                                  (StagingMailbox.freshAddress("iphone", for: "nobody"), Self.password)] {
            run.paste(email, into: AccessibilityID.accountEmail)
            run.paste(password, into: AccessibilityID.accountPassword)
            run.tap(AccessibilityID.accountSubmit)
            XCTAssertTrue(run.text("That email or password is wrong.").waitForExistence(timeout: 20),
                          "no words for a wrong sign-in. On screen: \(run.visibleTexts())")
            XCTAssertTrue(run.app.navigationBars[AccountFlow.Step.signIn.title].exists, "the sheet moved on")
        }
        run.tap(AccessibilityID.accountClose)
        XCTAssertTrue(run.shows(SyncWording.footer(signedIn: false, device: PhoneTestApp.device)),
                      "a wrong sign-in changed the foot. On screen: \(run.visibleTexts())")

        // Scenario ACCT-07
        // 2. Signing in to an account not confirmed yet moves to Confirm your
        // email, says why, and offers Send a code. Not now closes the sheet,
        // signed in.
        run.tap(AccessibilityID.sidebarSignIn)
        run.paste(address, into: AccessibilityID.accountEmail)
        run.paste(Self.password, into: AccessibilityID.accountPassword)
        run.tap(AccessibilityID.accountSubmit)
        XCTAssertTrue(run.app.navigationBars[AccountFlow.Step.confirmEmail.title].waitForExistence(timeout: 30),
                      "the sheet did not ask to confirm. On screen: \(run.visibleTexts())")
        XCTAssertTrue(run.shows(ConfirmEmailScreen.reason), "no words saying why")
        XCTAssertTrue(run.app.buttons[AccountFlow.Words.sendFirstCode].exists, "no Send a code")
        run.tap(AccessibilityID.accountClose)
        XCTAssertTrue(run.shows(SyncWording.footer(signedIn: true)), "Not now signed him out")

        // Scenario ACCT-07
        // 3. Later, Account with a budget open says the same, with Confirm
        // your email, which leads back to the code.
        run.addGroup(named: "Mine")
        run.addBudget(named: "Groceries", amount: "500", inGroup: "Mine")
        run.goBack()
        run.tap(AccessibilityID.toolbarAccount)
        XCTAssertTrue(run.shows(ConfirmEmailScreen.reason), "Your account does not say why to confirm")
        run.tap(AccessibilityID.accountConfirmEmail)
        XCTAssertTrue(run.element(AccessibilityID.accountCode).waitForExistence(timeout: 10), "Confirm your email did not lead to the code")
        run.tap(AccessibilityID.accountClose)
        if run.element(AccessibilityID.accountClose).waitForExistence(timeout: 2) { run.tap(AccessibilityID.accountClose) }

        // Scenario ACCT-10
        // 4. A reset for an address never confirmed says the same words, and
        // no code is sent.
        run.syncAndWait()
        run.signOut()
        run.tap(AccessibilityID.sidebarSignIn)
        run.paste(address, into: AccessibilityID.accountEmail)
        run.tap(AccessibilityID.accountForgotPassword)
        run.tap(AccessibilityID.accountSubmit)
        XCTAssertTrue(run.text(AccountFlow.Words.resetCodeSent(to: address)).waitForExistence(timeout: 20),
                      "the words differ for an address never confirmed. On screen: \(run.visibleTexts())")
        do {
            let sent = try await mailbox.code(for: address, after: signUpCode, timeout: 12)
            XCTFail("a reset code went to an address never confirmed: \(sent.count) characters")
        } catch is UITestError {
            // No new code reached the mailbox, as it should.
        }
    }
}

/// The steps these tests and the other new-account tests take, beside the
/// ones every iPhone test shares.
extension PhoneTestApp {
    /// Makes an account from the sign-in sheet's Create an account, already
    /// open or opened from the foot of Home, and leaves the code for later
    /// with Not now. Signed in after, with the email not confirmed yet.
    func makeAccount(_ address: String, password: String, server: String, fromHome: Bool = true) {
        if fromHome { tap(AccessibilityID.sidebarSignIn) }
        tap(AccessibilityID.accountCreateAccount)
        XCTAssertTrue(app.navigationBars[AccountFlow.Step.signUp.title].waitForExistence(timeout: 10), "no Create an account")
        if (element(AccessibilityID.accountServer).value as? String) != server {
            paste(server, into: AccessibilityID.accountServer)
        }
        paste(address, into: AccessibilityID.accountEmail)
        paste(password, into: AccessibilityID.accountPassword)
        paste(password, into: AccessibilityID.accountConfirmation)
        tap(AccessibilityID.accountSubmit)
        XCTAssertTrue(app.navigationBars[AccountFlow.Step.confirmEmail.title].waitForExistence(timeout: 30),
                      "the account was not made. On screen: \(visibleTexts())")
        tap(AccessibilityID.accountClose)
        XCTAssertTrue(wait(for: app.navigationBars[AccountFlow.Step.confirmEmail.title], until: "exists == false",
                           timeout: 10), "Not now did not close the sheet")
    }
}
