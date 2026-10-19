import Testing
import Foundation
@testable import WellSpentAppCore
import WellSpentKeyStore
import WellSpentStore
import WellSpentSync

/// A device's coordinator on a shared in-memory server.
@MainActor
private func device(on server: InMemoryReadableServer) throws -> SyncCoordinator {
    let transport = StubReadableTransport(server: server)
    return SyncCoordinator(store: Store(database: try WellSpentDatabase.inMemory()), keyStore: InMemoryKeyStore(),
                           defaults: isolatedDefaults(), makeTransport: { _ in transport })
}

/// The account sheet's steps, below any layout: where each starts, where
/// each goes, and what it says.
@Suite("Account flow")
@MainActor
struct AccountFlowTests {
    /// Signed out without asking, the sheet opens at signing in with the
    /// address filled in and the reason said.
    @Test func aPromptOpensAtSignInWithItsReason() throws {
        let sync = try device(on: InMemoryReadableServer())
        let flow = AccountFlow(actions: sync, email: "robin@example.com", reason: "You were signed out.")

        #expect(flow.step == .signIn)
        #expect(flow.signIn.email == "robin@example.com")
        #expect(flow.reset.email == "robin@example.com")
        #expect(flow.notice == "You were signed out.")
        #expect(flow.submitLabel == "Sign in")
        #expect(flow.back == nil)

        flow.go(to: .signUp)
        #expect(flow.step == .signUp)
        #expect(flow.notice == nil, "a notice belongs to the step it was said on")
        #expect(flow.back == .signIn)
    }

    /// Creating an account goes on to the code, which the server sent at
    /// sign-up, then to the account with the address confirmed.
    @Test func signingUpGoesOnToTheCodeThenTheAccount() async throws {
        let server = InMemoryReadableServer()
        let sync = try device(on: server)
        var synced = 0
        let flow = AccountFlow(actions: sync, afterSigningIn: { synced += 1 })
        flow.go(to: .signUp)
        flow.signUp.email = "robin@example.com"
        flow.signUp.password = "a-long-password"
        flow.signUp.confirmation = "a-long-password"

        await flow.submit()
        await flow.syncing?.value

        #expect(synced == 1)
        #expect(flow.step == .confirmEmail)
        #expect(flow.confirmText == "Enter the code sent to robin@example.com.")
        #expect(flow.sendCodeLabel == "Send another code")
        #expect(flow.back == .account)

        flow.confirm.code = try #require(server.lastCode(for: "robin@example.com", purpose: .verify))
        await flow.submit()
        #expect(flow.step == .account)
        #expect(flow.notice == "Your email is confirmed.")
        #expect(!flow.needsConfirming)
        #expect(!flow.isFinished)
    }

    /// An account from before readable sync signs in unconfirmed and was
    /// never sent a code, so the next step says why and offers one.
    @Test func signingInUnconfirmedAsksForACodeFirst() async throws {
        let server = InMemoryReadableServer()
        server.seedAccount(email: "robin@example.com", password: "a-long-password")
        let sync = try device(on: server)
        let flow = AccountFlow(actions: sync)
        flow.signIn.email = "robin@example.com"
        flow.signIn.password = "a-long-password"

        await flow.submit()

        #expect(flow.step == .confirmEmail)
        #expect(flow.confirmText == ConfirmEmailScreen.reason)
        #expect(flow.sendCodeLabel == "Send a code")
        #expect(!flow.canSubmit, "no code yet")
        await flow.sendCode()
        #expect(flow.confirm.note == ConfirmEmailScreen.codeOnItsWay)
        #expect(flow.confirmText == "Enter the code sent to robin@example.com.")

        #expect(flow.closeLabel == "Not now")
        flow.close()
        #expect(flow.isFinished)
    }

    /// A confirmed account signs in and the sheet closes.
    @Test func signingInConfirmedCloses() async throws {
        let server = InMemoryReadableServer()
        server.seedAccount(email: "robin@example.com", password: "a-long-password", verified: true)
        let sync = try device(on: server)
        var synced = 0
        let flow = AccountFlow(actions: sync, afterSigningIn: { synced += 1 })
        flow.signIn.email = "robin@example.com"
        flow.signIn.password = "a-long-password"

        await flow.submit()
        await flow.syncing?.value

        #expect(flow.isFinished)
        #expect(synced == 1)
    }

    /// A forgotten password takes the address already typed, ends signed in,
    /// and says every other device was signed out.
    @Test func aForgottenPasswordEndsOnTheAccount() async throws {
        let server = InMemoryReadableServer()
        server.seedAccount(email: "robin@example.com", password: "the-old-password", verified: true)
        let sync = try device(on: server)
        var synced = 0
        let flow = AccountFlow(actions: sync, afterSigningIn: { synced += 1 })
        flow.signIn.email = "robin@example.com"

        flow.go(to: .forgotPassword)
        #expect(flow.reset.email == "robin@example.com")
        #expect(flow.submitLabel == "Send code")
        #expect(flow.canSubmit)
        await flow.submit()
        #expect(flow.reset.step == .enterCode)
        #expect(flow.submitLabel == "Set password")
        flow.reset.code = try #require(server.lastCode(for: "robin@example.com", purpose: .reset))
        flow.reset.password = "the-new-password"
        flow.reset.confirmation = "the-new-password"
        #expect(flow.canSubmit)
        await flow.submit()
        await flow.syncing?.value

        #expect(flow.step == .account)
        #expect(flow.notice == PasswordResetScreen.finished)
        #expect(synced == 1)
        #expect(sync.account == "robin@example.com")
    }

    /// Signed in, the sheet opens at the account. Changing the password
    /// comes back to it and says so.
    @Test func signedInItOpensAtTheAccount() async throws {
        let server = InMemoryReadableServer()
        server.seedAccount(email: "robin@example.com", password: "the-old-password")
        let sync = try device(on: server)
        try await sync.signIn(email: "robin@example.com", password: "the-old-password")
        let flow = AccountFlow(actions: sync, reason: "ignored while signed in")

        #expect(flow.step == .account)
        #expect(flow.notice == nil)
        #expect(flow.signedInAs == "Signed in as robin@example.com.")
        #expect(flow.needsConfirming)
        #expect(flow.submitLabel == nil)

        flow.go(to: .changePassword)
        #expect(flow.back == .account)
        flow.change.current = "the-old-password"
        flow.change.password = "the-new-password"
        flow.change.confirmation = "the-new-password"
        await flow.submit()
        #expect(flow.step == .account)
        #expect(flow.notice == ChangePasswordScreen.finished)
    }

    @Test func signingOutCloses() async throws {
        let server = InMemoryReadableServer()
        server.seedAccount(email: "robin@example.com", password: "a-long-password")
        let sync = try device(on: server)
        try await sync.signIn(email: "robin@example.com", password: "a-long-password")
        let flow = AccountFlow(actions: sync)

        await flow.signOut()

        #expect(flow.isFinished)
        #expect(sync.account == nil)
    }

    /// Signing out everywhere that fails keeps the sheet open, signed in,
    /// with the reason.
    @Test func signingOutEverywhereThatFailsSaysWhy() async throws {
        let actions = OfflineActions()
        let flow = AccountFlow(actions: actions)

        flow.askToSignOutEverywhere()
        flow.signOutEverywhere()
        await flow.signingOutEverywhere?.value

        #expect(!flow.isFinished)
        #expect(flow.currentFailure == "This computer is not connected to the internet.")
        #expect(actions.account != nil)
    }

    @Test func signingOutEverywhereCloses() async throws {
        let server = InMemoryReadableServer()
        server.seedAccount(email: "robin@example.com", password: "a-long-password")
        let sync = try device(on: server)
        try await sync.signIn(email: "robin@example.com", password: "a-long-password")
        let flow = AccountFlow(actions: sync)
        flow.askToSignOutEverywhere()
        #expect(flow.isAskingToSignOutEverywhere)
        flow.keepDevicesSignedIn()
        #expect(!flow.isAskingToSignOutEverywhere)

        flow.askToSignOutEverywhere()
        flow.signOutEverywhere()
        #expect(flow.isWorking, "started at once")
        await flow.signingOutEverywhere?.value

        #expect(flow.isFinished)
        #expect(sync.account == nil)
    }

    /// A dialog may clear its question before or after its button's action
    /// runs. Either way, Sign Out Everywhere goes through.
    @Test(arguments: [true, false])
    func signingOutEverywhereSurvivesTheDialogClosing(closesFirst: Bool) async throws {
        let server = InMemoryReadableServer()
        server.seedAccount(email: "robin@example.com", password: "a-long-password")
        let sync = try device(on: server)
        try await sync.signIn(email: "robin@example.com", password: "a-long-password")
        let flow = AccountFlow(actions: sync)
        flow.askToSignOutEverywhere()

        if closesFirst {
            flow.keepDevicesSignedIn()
            flow.signOutEverywhere()
        } else {
            flow.signOutEverywhere()
            flow.keepDevicesSignedIn()
        }
        await flow.signingOutEverywhere?.value

        #expect(flow.isFinished)
        #expect(sync.account == nil)
    }

    /// A failure from one step is not left on the next. Signing out
    /// everywhere refused because the session ended, then signing in again,
    /// shows the account without the old warning.
    @Test func aFailureIsNotCarriedToTheNextStep() async throws {
        let server = InMemoryReadableServer()
        server.seedAccount(email: "robin@example.com", password: "a-long-password", verified: true)
        let transport = StubReadableTransport(server: server)
        let sync = SyncCoordinator(store: Store(database: try WellSpentDatabase.inMemory()),
                                   keyStore: InMemoryKeyStore(), defaults: isolatedDefaults(),
                                   makeTransport: { _ in transport })
        try await sync.signIn(email: "robin@example.com", password: "a-long-password")
        let flow = AccountFlow(actions: sync)
        let other = try device(on: server)
        try await other.signIn(email: "robin@example.com", password: "a-long-password")
        try await other.signOutEverywhere()

        flow.askToSignOutEverywhere()
        flow.signOutEverywhere()
        await flow.signingOutEverywhere?.value
        #expect(flow.step == .signIn, "the session had ended")

        flow.signIn.email = "robin@example.com"
        flow.signIn.password = "a-long-password"
        await flow.submit()
        await flow.syncing?.value
        flow.go(to: .account)
        #expect(flow.currentFailure == nil)
    }

    /// A wrong password stays on signing in, says why, and syncs nothing.
    @Test func aWrongPasswordStaysOnSignIn() async throws {
        let server = InMemoryReadableServer()
        server.seedAccount(email: "robin@example.com", password: "a-long-password")
        let sync = try device(on: server)
        var synced = 0
        let flow = AccountFlow(actions: sync, afterSigningIn: { synced += 1 })
        flow.signIn.email = "robin@example.com"
        flow.signIn.password = "not the password"

        await flow.submit()

        #expect(flow.step == .signIn)
        #expect(flow.currentFailure == "That email or password is wrong.")
        #expect(flow.syncing == nil)
        #expect(synced == 0)
        #expect(!flow.isFinished)
    }

    /// Signed in, the step moves on before the sync that follows ends, so
    /// the sheet never sits idle with a sign-in that could be sent twice.
    @Test func theStepMovesOnBeforeTheSyncEnds() async throws {
        let server = InMemoryReadableServer()
        server.seedAccount(email: "robin@example.com", password: "a-long-password")
        let sync = try device(on: server)
        let gate = Gate()
        let flow = AccountFlow(actions: sync, afterSigningIn: { await gate.wait() })
        flow.signIn.email = "robin@example.com"
        flow.signIn.password = "a-long-password"

        await flow.submit()

        #expect(flow.step == .confirmEmail, "while the sync still runs")
        #expect(!flow.isWorking)
        gate.open()
        await flow.syncing?.value
    }

    /// While a request is out, nothing else moves the sheet.
    @Test func nothingMovesWhileARequestIsOut() async throws {
        let actions = HeldSignIn()
        let flow = AccountFlow(actions: actions)
        flow.signIn.email = "robin@example.com"
        flow.signIn.password = "a-long-password"

        let signingIn = Task { await flow.submit() }
        await actions.started()
        #expect(flow.isWorking)
        flow.go(to: .signUp)
        flow.close()
        #expect(flow.step == .signIn)
        #expect(!flow.isFinished)
        actions.release()
        await signingIn.value
    }

    /// Each step's close button, and Done closing the account.
    @Test func eachStepHasItsCloseButton() async throws {
        let server = InMemoryReadableServer()
        server.seedAccount(email: "robin@example.com", password: "a-long-password")
        let sync = try device(on: server)
        let signedOut = AccountFlow(actions: sync)
        #expect(signedOut.closeLabel == "Cancel")
        signedOut.go(to: .forgotPassword)
        #expect(signedOut.closeLabel == "Cancel")

        try await sync.signIn(email: "robin@example.com", password: "a-long-password")
        let flow = AccountFlow(actions: sync)
        #expect(flow.closeLabel == "Done")
        flow.go(to: .confirmEmail)
        #expect(flow.closeLabel == "Not now")
        flow.go(to: .account)
        flow.close()
        #expect(flow.isFinished)
    }

    /// A session that ends while the sheet shows the account falls back to
    /// signing in, rather than "Signed in as ." with buttons that do nothing.
    @Test func aSessionEndingWithTheSheetOpenFallsBackToSignIn() async throws {
        let server = InMemoryReadableServer()
        server.seedAccount(email: "robin@example.com", password: "a-long-password")
        let sync = try device(on: server)
        try await sync.signIn(email: "robin@example.com", password: "a-long-password")
        let flow = AccountFlow(actions: sync)
        flow.go(to: .changePassword)
        flow.change.current = "a-long-password"
        flow.change.password = "the-new-password"
        flow.change.confirmation = "the-new-password"
        await flow.submit()
        #expect(flow.notice == ChangePasswordScreen.finished)

        sync.endSession(reason: SyncCoordinator.sessionEndedReason)

        #expect(flow.step == .signIn)
        #expect(flow.submitLabel == "Sign in")
        #expect(flow.notice == SyncCoordinator.sessionEndedReason, "the reason, not what was said before")
    }

    /// A reset waiting for its code keeps the address the code went to,
    /// whatever is typed on the sign-in step meanwhile. A finished reset
    /// starts over.
    @Test func aResetKeepsTheAddressItsCodeWentTo() async throws {
        let server = InMemoryReadableServer()
        server.seedAccount(email: "robin@example.com", password: "the-old-password", verified: true)
        let sync = try device(on: server)
        let flow = AccountFlow(actions: sync)
        flow.signIn.email = "robin@example.com"
        flow.go(to: .forgotPassword)
        await flow.submit()
        #expect(flow.reset.step == .enterCode)

        flow.go(to: .signIn)
        flow.signIn.email = "someone@example.com"
        flow.go(to: .forgotPassword)
        #expect(flow.reset.email == "robin@example.com")
        #expect(flow.reset.step == .enterCode)
        #expect(flow.resetCodeText.hasPrefix("If robin@example.com has an account"), "the step names its address")

        flow.reset.code = try #require(server.lastCode(for: "robin@example.com", purpose: .reset))
        flow.reset.password = "the-new-password"
        flow.reset.confirmation = "the-new-password"
        await flow.submit()
        await flow.syncing?.value
        sync.endSession(reason: SyncCoordinator.sessionEndedReason)
        flow.go(to: .forgotPassword)
        #expect(flow.reset.step == .enterEmail, "a finished reset starts over")
        #expect(flow.canSubmit)
    }

    /// An address typed on the sign-in step goes to the reset, over one a
    /// sign-in prompt filled in.
    @Test func aTypedAddressGoesToTheReset() throws {
        let sync = try device(on: InMemoryReadableServer())
        let flow = AccountFlow(actions: sync, email: "old@example.com", reason: "Signed out.")
        flow.signIn.email = "new@example.com"

        flow.go(to: .forgotPassword)

        #expect(flow.reset.email == "new@example.com")
    }

    /// What the sidebar says, pinned here too, since the Linux build cannot
    /// run the SwiftUI tests.
    @Test func theSidebarsWords() {
        #expect(SyncWording.footer(signedIn: true) == "Syncs through WellSpent's server")
        #expect(SyncWording.footer(signedIn: false) == "Kept on this computer only")
        #expect(SyncWording.waitingGroups(1) == "A group is waiting for the person who made it to update WellSpent.")
        #expect(SyncWording.waitingGroups(3).hasPrefix("3 groups are waiting"))
    }

    /// Each app names its own device. The iPhone app hands in "iPhone" at
    /// launch. An app that hands in nothing, like this test run or the Linux
    /// app, says "computer".
    @Test func theWordsNameTheDeviceTheAppRunsOn() {
        #expect(SyncWording.device == "computer", "nothing in a test run sets it")

        #expect(SyncWording.footer(signedIn: false, device: "iPhone") == "Kept on this iPhone only")
        #expect(SyncWording.footer(signedIn: true, device: "iPhone") == "Syncs through WellSpent's server")
        #expect(SyncWording.importNote(device: "iPhone") == "Read on this iPhone. Nothing is sent until you add it.")
        #expect(AccountWording.words(for: URLError(.notConnectedToInternet), device: "iPhone")
                == "This iPhone is not connected to the internet.")
        #expect(SyncWording.footer(signedIn: false, device: "Mac") == "Kept on this Mac only")
    }

    /// The words on every step: plain, with no "Mac", no dashes standing in
    /// for punctuation, and no semicolons.
    @Test func theWordsArePlain() {
        let steps: [AccountFlow.Step] = [.signIn, .signUp, .forgotPassword, .confirmEmail, .account, .changePassword]
        let words = steps.map(\.title) + [
            AccountFlow.Words.email, AccountFlow.Words.password, AccountFlow.Words.confirmation,
            AccountFlow.Words.currentPassword, AccountFlow.Words.newPassword, AccountFlow.Words.code,
            AccountFlow.Words.server, AccountFlow.Words.createAccount, AccountFlow.Words.forgotPassword,
            AccountFlow.Words.back, AccountFlow.Words.startOver, AccountFlow.Words.notNow, AccountFlow.Words.done,
            AccountFlow.Words.confirmEmail, AccountFlow.Words.changePassword, AccountFlow.Words.signOut,
            AccountFlow.Words.signOutEverywhere, AccountFlow.Words.confirmed,
            AccountFlow.Words.signOutEverywhereTitle, AccountFlow.Words.signOutEverywhereMessage,
            AccountFlow.Words.signOutEverywhereButton, AccountFlow.Words.privacy,
            AccountFlow.Words.signInButton, AccountFlow.Words.createAccountButton, AccountFlow.Words.sendResetCode,
            AccountFlow.Words.setPassword, AccountFlow.Words.confirm, AccountFlow.Words.changePasswordButton,
            AccountFlow.Words.sendFirstCode, AccountFlow.Words.sendAnotherCode, AccountFlow.Words.cancel,
            AccountFlow.Words.signedInAs("robin@example.com"), AccountFlow.Words.enterCode(sentTo: "robin@example.com"),
            AccountFlow.Words.enterCode(sentTo: nil), SyncWording.leaveGroupMessage,
            AccountFlow.Words.resetCodeSent(to: "robin@example.com"),
            SyncWording.waitingGroups(1), SyncWording.waitingGroups(2),
            SyncWording.footer(signedIn: true), SyncWording.footer(signedIn: false), SyncWording.signedOutHelp,
            SyncWording.accountTitle(signedIn: true), SyncWording.accountTitle(signedIn: false),
            SyncWording.accountHelp(account: nil), SyncWording.accountHelp(account: "robin@example.com"),
            SyncWording.waitingForFounder, SyncWording.inviteNote, SyncWording.importNote,
        ]
        for text in words {
            #expect(!text.contains("Mac"), "\(text)")
            #expect(!text.contains("\u{2014}") && !text.contains("--"), "\(text)")
            #expect(!text.contains(";"), "\(text)")
        }
        #expect(AccountFlow.Words.privacy == """
            Your budgets sync through WellSpent's server. Connections and backups are encrypted. \
            The server can read your budgets, which is how it checks who may change what and how \
            it resets a forgotten password.
            """, "the wording approved on 2026-10-08, word for word")
    }
}

/// Signed in, with no way to reach the server.
@MainActor
private final class OfflineActions: AccountActions {
    var account: String? = "robin@example.com"
    var emailVerified = true
    var signInPrompt: SyncCoordinator.SignInPrompt? { nil }
    func signIn(email: String, password: String) async throws {}
    func signUp(email: String, password: String) async throws {}
    func verifyEmail(code: String) async throws {}
    func resendVerification() async throws {}
    func forgotPassword(email: String) async throws {}
    func resetPassword(email: String, code: String, newPassword: String) async throws {}
    func changePassword(current: String, new: String) async throws {}
    func signOut() async {}
    func signOutEverywhere() async throws { throw URLError(.notConnectedToInternet) }
}

/// Holds a closure until opened.
@MainActor
private final class Gate {
    private var waiting: CheckedContinuation<Void, Never>?
    private var isOpen = false

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { waiting = $0 }
    }

    func open() {
        isOpen = true
        waiting?.resume()
        waiting = nil
    }
}

/// Holds a sign-in open until released.
@MainActor
private final class HeldSignIn: AccountActions {
    var account: String?
    var emailVerified = true
    var signInPrompt: SyncCoordinator.SignInPrompt? { nil }
    private var held: CheckedContinuation<Void, Never>?
    private var begun: CheckedContinuation<Void, Never>?
    private var hasBegun = false

    func started() async {
        guard !hasBegun else { return }
        await withCheckedContinuation { begun = $0 }
    }

    func release() {
        held?.resume()
        held = nil
    }

    func signIn(email: String, password: String) async throws {
        hasBegun = true
        begun?.resume()
        begun = nil
        await withCheckedContinuation { held = $0 }
        account = email
    }

    func signUp(email: String, password: String) async throws {}
    func verifyEmail(code: String) async throws {}
    func resendVerification() async throws {}
    func forgotPassword(email: String) async throws {}
    func resetPassword(email: String, code: String, newPassword: String) async throws {}
    func changePassword(current: String, new: String) async throws {}
    func signOut() async {}
    func signOutEverywhere() async throws {}
}
