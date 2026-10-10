import Testing
import Foundation
@testable import WellSpentAppCore
import WellSpentCrypto
import WellSpentKeyStore
import WellSpentModel
import WellSpentStore
import WellSpentSync

/// A device's coordinator on a shared in-memory server.
@MainActor
private func device(on server: InMemoryReadableServer) throws -> (SyncCoordinator, StubReadableTransport) {
    let transport = StubReadableTransport(server: server)
    let sync = SyncCoordinator(store: Store(database: try WellSpentDatabase.inMemory()), keyStore: InMemoryKeyStore(),
                               defaults: isolatedDefaults(), makeTransport: { _ in transport })
    return (sync, transport)
}

@Suite("Account rules")
struct AccountRulesTests {
    @Test func addressesAreKeptInTheServersForm() {
        #expect(AccountRules.normalisedEmail("  Robin@Example.COM ") == "robin@example.com")
        #expect(AccountRules.normalisedEmail("Re\u{0301}my@example.com") == "r\u{00E9}my@example.com")
        #expect(AccountRules.normalisedEmail(String(repeating: "a", count: 248) + "@b.com") != nil,
                "254 characters is the most an address may have")
        #expect(AccountRules.normalisedEmail("rob\u{0007}in@example.com") == nil, "no control characters")
        for bad in ["robin", "robin@", "@example.com", "a@b", "a@.com", "a@b.", "a@b..com", "first last@example.com",
                    "a@b@c.com", String(repeating: "a", count: 250) + "@b.com"] {
            #expect(AccountRules.normalisedEmail(bad) == nil, "\(bad)")
        }
    }

    @Test func passwordsAreTenToOneHundredTwentyEightCharacters() {
        #expect(AccountRules.passwordProblem("short") != nil)
        #expect(AccountRules.passwordProblem("123456789") != nil, "nine is one short")
        #expect(AccountRules.passwordProblem("ten chars!") == nil)
        #expect(AccountRules.passwordProblem(String(repeating: "x", count: 128)) == nil)
        #expect(AccountRules.passwordProblem(String(repeating: "x", count: 129)) != nil)
    }

    @Test func codesAreTypedLooselyAndShownAsTheEmailShowsThem() {
        #expect(AccountRules.normalisedCode(" abcd-efgh ") == "ABCDEFGH")
        #expect(AccountRules.displayedCode("abcdefgh") == "ABCD-EFGH")
        #expect(AccountRules.isWholeCode("abcd efgh"))
        #expect(!AccountRules.isWholeCode("abcd-efg"))
    }

    @Test func theServersReasonsReadAsSentences() {
        #expect(AccountWording.words(for: ReadableTransportError.http(status: 400, reason: "that code is wrong or has expired"))
                == "That code is wrong or has expired.")
        #expect(AccountWording.words(for: ReadableTransportError.http(status: 429,
                                                                      reason: "Too many attempts. Try again in a few minutes."))
                == "Too many attempts. Try again in a few minutes.")
        #expect(AccountWording.words(for: ReadableTransportError.http(status: 409, reason: "that email already has an account"))
                .contains("reset its password"))
        #expect(AccountWording.words(for: ReadableTransportError.badCredentials) == "That email or password is wrong.")
        #expect(AccountWording.words(for: ReadableTransportError.http(
            status: 403, reason: "the founder cannot leave or be removed; delete the group instead"))
                == "The founder cannot leave or be removed. Delete the group instead.")
    }

    /// Nothing raw reaches the screen: no server status, no page, no system text.
    @Test func rawTextNeverReachesAPerson() {
        let notAnswering = AccountWording.notAnswering
        #expect(AccountWording.words(for: ReadableTransportError.http(status: 530, reason: "")) == notAnswering)
        #expect(AccountWording.words(for: ReadableTransportError.http(status: 502, reason: "<html>")) == notAnswering)
        #expect(AccountWording.words(for: ReadableTransportError.http(status: 403, reason: "")).contains("could not use"))
        #expect(AccountWording.words(for: ReadableTransportError.malformed("Me: keyNotFound")).contains("could not use"))
        #expect(AccountWording.words(for: URLError(.notConnectedToInternet))
                == "This computer is not connected to the internet.")
        #expect(AccountWording.words(for: URLError(.timedOut)).contains("Could not reach the server"))
        #expect(AccountWording.words(for: URLError(.secureConnectionFailed))
                == "Could not reach the server. Check your connection and try again.")
        struct Odd: Error {}
        #expect(AccountWording.words(for: Odd()) == "Something went wrong. Try again.")
        for message in [SyncCoordinator.sessionEndedReason, SyncCoordinator.updatedReason, notAnswering,
                        ConfirmEmailScreen.codeOnItsWay] {
            #expect(!message.contains(";"), "\(message)")
        }
    }
}

@Suite("Account screens", .serialized)
@MainActor
struct AccountScreensTests {
    /// Sign up checks what it can before sending, then confirms the address
    /// with the emailed code, typed loosely.
    @Test func signingUpAndConfirmingTheAddress() async throws {
        let server = InMemoryReadableServer()
        let (sync, _) = try device(on: server)
        let signUp = SignUpScreen(actions: sync)
        signUp.email = "not an address"
        signUp.password = "short"
        signUp.confirmation = "different"
        #expect(await !signUp.submit())
        #expect(Set(signUp.problems.keys) == [.email, .password, .confirmation])

        signUp.email = "Robin@Example.com"
        signUp.password = "a-long-password"
        signUp.confirmation = "a-long-password"
        #expect(await signUp.submit())
        #expect(sync.account == "robin@example.com")
        #expect(!sync.emailVerified)

        let confirm = ConfirmEmailScreen(actions: sync, codeAlreadySent: true)
        #expect(confirm.address == "robin@example.com")
        confirm.code = "zzzz-zzzz"
        #expect(await !confirm.submit())
        #expect(confirm.failure == "That code is wrong or has expired.")
        let code = try #require(server.lastCode(for: "robin@example.com", purpose: .verify))
        confirm.code = AccountRules.displayedCode(code).lowercased()
        #expect(await confirm.submit())
        #expect(sync.emailVerified)
    }

    @Test func aWrongPasswordIsSaidPlainly() async throws {
        let server = InMemoryReadableServer()
        server.seedAccount(email: "robin@example.com", password: "a-long-password")
        let (sync, _) = try device(on: server)
        let signIn = SignInScreen(actions: sync, email: "robin@example.com")
        signIn.password = "not the password"
        #expect(await !signIn.submit())
        #expect(signIn.failure == "That email or password is wrong.")
        signIn.password = "a-long-password"
        #expect(await signIn.submit())
        #expect(signIn.password.isEmpty, "the password does not stay in memory")
    }

    /// A forgotten password, start to finish: a code by email, a new
    /// password, signed in here, and every other device signed out.
    @Test func resettingAForgottenPassword() async throws {
        let server = InMemoryReadableServer()
        server.seedAccount(email: "robin@example.com", password: "the-old-password", verified: true)
        let (laptop, _) = try device(on: server)
        try await laptop.signIn(email: "robin@example.com", password: "the-old-password")
        let (desktop, _) = try device(on: server)

        let reset = PasswordResetScreen(actions: desktop, email: "robin@example.com")
        await reset.submit()
        #expect(reset.step == .enterCode)
        reset.code = try #require(server.lastCode(for: "robin@example.com", purpose: .reset))
        reset.password = "a-new-password"
        reset.confirmation = "a-new-password!"
        await reset.submit()
        #expect(reset.problems[.confirmation] != nil)
        reset.confirmation = "a-new-password"
        await reset.submit()
        #expect(reset.step == .done)
        #expect(desktop.account == "robin@example.com")

        await laptop.syncAll()
        #expect(laptop.account == nil, "the old session ended")
        #expect(laptop.signInPrompt?.reason == SyncCoordinator.sessionEndedReason)
    }

    /// An address that was never confirmed gets no reset code, and the
    /// screen cannot say whether the address has an account.
    @Test func anUnconfirmedAddressGetsNoResetCode() async throws {
        let server = InMemoryReadableServer()
        server.seedAccount(email: "robin@example.com", password: "the-old-password")
        let (sync, _) = try device(on: server)
        let reset = PasswordResetScreen(actions: sync, email: "robin@example.com")
        await reset.submit()
        #expect(reset.step == .enterCode, "the same answer either way")
        #expect(server.lastCode(for: "robin@example.com", purpose: .reset) == nil)
    }

    /// An account from before the switch was never sent a code: the screen
    /// asks for one first, and says only the newest works.
    @Test func confirmingAnAddressThatWasNeverSentACode() async throws {
        let server = InMemoryReadableServer()
        server.seedAccount(email: "robin@example.com", password: "a-long-password")
        let (sync, _) = try device(on: server)
        try await sync.signIn(email: "robin@example.com", password: "a-long-password")
        let confirm = ConfirmEmailScreen(actions: sync)
        #expect(!confirm.codeSent)
        await confirm.sendCode()
        #expect(confirm.codeSent && confirm.note == ConfirmEmailScreen.codeOnItsWay)
        confirm.code = try #require(server.lastCode(for: "robin@example.com", purpose: .verify))
        #expect(await confirm.submit())
        #expect(sync.emailVerified)
    }

    /// A session ended elsewhere, met while confirming, signs this device out.
    @Test func anEndedSessionWhileConfirmingSignsOut() async throws {
        let server = InMemoryReadableServer()
        let (sync, _) = try device(on: server)
        try await sync.signUp(email: "robin@example.com", password: "a-long-password")
        server.endSessions(of: try #require(sync.userID))
        let confirm = ConfirmEmailScreen(actions: sync, codeAlreadySent: true)
        confirm.code = "ABCD-EFGH"
        #expect(await !confirm.submit())
        #expect(sync.signInPrompt?.reason == SyncCoordinator.sessionEndedReason)
        #expect(confirm.failure == SyncCoordinator.sessionEndedReason)
    }

    /// While a confirmation is out, the screen asks for nothing else.
    @Test func aBusyConfirmScreenSendsNoCode() async throws {
        let gate = GatedActions()
        let confirm = ConfirmEmailScreen(actions: gate, codeAlreadySent: true)
        confirm.code = "ABCD-EFGH"
        let pending = Task { await confirm.submit() }
        while !gate.verifying { await Task.yield() }
        #expect(confirm.isWorking && !confirm.canSendCode)
        await confirm.sendCode()
        #expect(gate.resends == 0)
        gate.release()
        #expect(await pending.value)
        #expect(!confirm.isWorking)
    }

    @Test func aTakenAddressSaysWhatToDo() async throws {
        let server = InMemoryReadableServer()
        server.seedAccount(email: "robin@example.com", password: "a-long-password")
        let (sync, _) = try device(on: server)
        let signUp = SignUpScreen(actions: sync)
        signUp.email = "robin@example.com"
        signUp.password = "a-long-password"
        signUp.confirmation = "a-long-password"
        #expect(await !signUp.submit())
        #expect(signUp.failure == "That email already has an account. Sign in, or reset its password.")
    }

    @Test func startingAResetOverGoesBackToTheAddress() async throws {
        let server = InMemoryReadableServer()
        let (sync, _) = try device(on: server)
        let reset = PasswordResetScreen(actions: sync, email: "robin@example.com")
        await reset.submit()
        #expect(reset.step == .enterCode)
        reset.code = "ABCD"
        reset.startOver()
        #expect(reset.step == .enterEmail && reset.code.isEmpty)
    }

    /// Changing the password keeps this device and signs out the others. A
    /// wrong current password leaves everything as it was.
    @Test func changingThePassword() async throws {
        let server = InMemoryReadableServer()
        server.seedAccount(email: "robin@example.com", password: "the-old-password")
        let (laptop, _) = try device(on: server)
        try await laptop.signIn(email: "robin@example.com", password: "the-old-password")
        let (desktop, _) = try device(on: server)
        try await desktop.signIn(email: "robin@example.com", password: "the-old-password")

        let change = ChangePasswordScreen(actions: laptop)
        change.current = "not it at all"
        change.password = "a-new-password"
        change.confirmation = "a-new-password"
        #expect(await !change.submit())
        #expect(change.failure == "Your current password is wrong.")
        #expect(laptop.account != nil)

        change.current = "the-old-password"
        change.password = "the-old-password"
        change.confirmation = "the-old-password"
        #expect(await !change.submit())
        #expect(change.problems[.password] == "The new password is the same as the current one.")
        change.password = "a-new-password"
        change.confirmation = "a-new-password"
        #expect(await change.submit())
        await laptop.syncAll()
        #expect(laptop.isSignedIn)
        await desktop.syncAll()
        #expect(desktop.account == nil)
    }

    /// Signing out everywhere ends this device's session too.
    @Test func signingOutEverywhere() async throws {
        let server = InMemoryReadableServer()
        server.seedAccount(email: "robin@example.com", password: "the-old-password")
        let (laptop, _) = try device(on: server)
        try await laptop.signIn(email: "robin@example.com", password: "the-old-password")
        let (desktop, _) = try device(on: server)
        try await desktop.signIn(email: "robin@example.com", password: "the-old-password")
        try await laptop.signOutEverywhere()
        #expect(laptop.state == .signedOut)
        await desktop.syncAll()
        #expect(desktop.account == nil)
    }
}

/// Account actions that hold a confirmation open until released.
@MainActor
private final class GatedActions: AccountActions {
    var account: String? = "robin@example.com"
    var emailVerified = false
    var signInPrompt: SyncCoordinator.SignInPrompt? { nil }
    private(set) var verifying = false
    private(set) var resends = 0
    private var waiting: CheckedContinuation<Void, Never>?

    func release() {
        waiting?.resume()
        waiting = nil
    }

    func verifyEmail(code: String) async throws {
        verifying = true
        await withCheckedContinuation { waiting = $0 }
        emailVerified = true
    }

    func resendVerification() async throws { resends += 1 }
    func signIn(email: String, password: String) async throws {}
    func signUp(email: String, password: String) async throws {}
    func forgotPassword(email: String) async throws {}
    func resetPassword(email: String, code: String, newPassword: String) async throws {}
    func changePassword(current: String, new: String) async throws {}
    func signOut() async {}
    func signOutEverywhere() async throws {}
}
