import Foundation
import Observation

/// The account sheet on any desktop: which step shows, how one step leads to
/// the next, and every word on it. The Mac and Linux sheets only draw it.
///
/// Signed out, it starts at signing in, with creating an account and a
/// forgotten password one step away. Signed in, it starts at the account:
/// confirming the address, changing the password, and signing out.
@MainActor
@Observable
public final class AccountFlow {
    public enum Step: Equatable, Sendable {
        case signIn, signUp, forgotPassword, confirmEmail, account, changePassword

        public var title: String {
            switch self {
            case .signIn: "Sign in"
            case .signUp: "Create an account"
            case .forgotPassword: "Reset your password"
            case .confirmEmail: "Confirm your email"
            case .account: "Your account"
            case .changePassword: "Change your password"
            }
        }
    }

    /// The step showing. One that needs a session falls back to signing in
    /// when the session ends while the sheet is open.
    public var step: Step { isFallingBack ? .signIn : current }

    /// Whether the step showing needs a session this device no longer has.
    private var isFallingBack: Bool {
        guard actions.account == nil else { return false }
        switch current {
        case .account, .changePassword, .confirmEmail: return true
        default: return false
        }
    }
    private var current: Step
    public let signIn: SignInScreen
    public let signUp: SignUpScreen
    public private(set) var confirm: ConfirmEmailScreen
    public let reset: PasswordResetScreen
    public let change: ChangePasswordScreen
    /// Said above the step: why this device was signed out, or what just
    /// went through. Falling back to signing in, the reason the session
    /// ended, not what was said before it did.
    public var notice: String? { isFallingBack ? actions.signInPrompt?.reason : said }
    private var said: String?
    /// Why signing out everywhere did not go through, in words.
    public private(set) var failure: String?
    /// Set when the sheet should close.
    public private(set) var isFinished = false
    /// Whether the sheet is asking before signing out everywhere.
    public private(set) var isAskingToSignOutEverywhere = false
    /// The sync that follows signing in. It runs on after the step moves on,
    /// and after the sheet closes; the toolbar shows it.
    public private(set) var syncing: Task<Void, Never>?
    /// Signing out everywhere, once confirmed.
    public private(set) var signingOutEverywhere: Task<Void, Never>?
    private var isSigningOut = false
    private let actions: any AccountActions
    private let afterSigningIn: @MainActor () async -> Void

    /// `email` and `reason` come from a sign-in prompt: the device was signed
    /// out without being asked to. `afterSigningIn` runs once this device is
    /// signed in, by any route; the app syncs there.
    public init(actions: any AccountActions, email: String? = nil, reason: String? = nil,
                afterSigningIn: @escaping @MainActor () async -> Void = {}) {
        self.actions = actions
        self.afterSigningIn = afterSigningIn
        signIn = SignInScreen(actions: actions, email: email ?? "")
        signUp = SignUpScreen(actions: actions)
        confirm = ConfirmEmailScreen(actions: actions)
        reset = PasswordResetScreen(actions: actions, email: email ?? "")
        change = ChangePasswordScreen(actions: actions)
        current = actions.account == nil ? .signIn : .account
        said = actions.account == nil ? reason : nil
    }

    // MARK: - What the sheet shows

    /// Whether any request is out. Nothing else can be pressed meanwhile.
    public var isWorking: Bool {
        isSigningOut || signIn.isWorking || signUp.isWorking || confirm.isWorking || reset.isWorking
            || change.isWorking
    }

    public var canSubmit: Bool {
        switch step {
        case .signIn: signIn.canSubmit
        case .signUp: signUp.canSubmit
        case .forgotPassword: reset.canSubmit
        case .confirmEmail: confirm.canSubmit
        case .changePassword: change.canSubmit
        case .account: false
        }
    }

    /// The main button's words, or nil on the account step, which has none.
    public var submitLabel: String? {
        switch step {
        case .signIn: Words.signInButton
        case .signUp: Words.createAccountButton
        case .forgotPassword: reset.step == .enterEmail ? Words.sendResetCode : Words.setPassword
        case .confirmEmail: Words.confirm
        case .changePassword: Words.changePasswordButton
        case .account: nil
        }
    }

    /// The button that closes the sheet: Done on the account, which has no
    /// main button, Not now when asking for a code, Cancel elsewhere.
    public var closeLabel: String {
        switch step {
        case .account: Words.done
        case .confirmEmail: Words.notNow
        default: Words.cancel
        }
    }

    /// The step's failure, in words.
    public var currentFailure: String? {
        switch step {
        case .signIn: signIn.failure
        case .signUp: signUp.failure
        case .forgotPassword: reset.failure
        case .confirmEmail: confirm.failure
        case .changePassword: change.failure
        case .account: failure
        }
    }

    /// Where Back goes, or nil where there is no Back.
    public var back: Step? {
        switch step {
        case .signUp, .forgotPassword: .signIn
        case .changePassword: .account
        case .confirmEmail: actions.account == nil ? nil : .account
        case .signIn, .account: nil
        }
    }

    public var signedInAs: String { Words.signedInAs(actions.account ?? "") }

    /// Whether the account step asks for the address to be confirmed.
    public var needsConfirming: Bool { actions.account != nil && !actions.emailVerified }

    /// What the confirm step says above the code.
    public var confirmText: String {
        guard confirm.codeSent else { return ConfirmEmailScreen.reason }
        return Words.enterCode(sentTo: confirm.address)
    }

    public var sendCodeLabel: String { confirm.codeSent ? Words.sendAnotherCode : Words.sendFirstCode }

    /// What the reset's code step says, naming the address the code went to,
    /// so a code step left open for another address is never mistaken.
    public var resetCodeText: String { Words.resetCodeSent(to: reset.email) }

    // MARK: - Moving and acting

    /// Moves between steps: from signing in to creating an account or a
    /// forgotten password, from the account to confirming or changing the
    /// password, and back. Not while a request is out.
    public func go(to next: Step) {
        guard !isWorking, next != step else { return }
        said = nil
        failure = nil
        switch next {
        case .forgotPassword:
            // A reset that finished starts over. One still asking for the
            // address takes the address just typed, over one a sign-in prompt
            // filled in; one waiting for its code keeps the address it went to.
            if reset.step == .done { reset.startOver() }
            if reset.step == .enterEmail, !signIn.email.isEmpty { reset.email = signIn.email }
        case .confirmEmail:
            confirm = ConfirmEmailScreen(actions: actions)
        default:
            break
        }
        current = next
    }

    /// The main button.
    public func submit() async {
        guard !isWorking else { return }
        said = nil
        failure = nil
        switch step {
        // Signed in, the step moves on at once and the sync runs after it,
        // so the sheet never sits idle with a sign-in that could be sent twice.
        case .signIn:
            guard await signIn.submit() else { return }
            if actions.emailVerified { isFinished = true } else { askToConfirm(codeSent: false) }
            startSyncing()
        case .signUp:
            guard await signUp.submit() else { return }
            askToConfirm(codeSent: true)
            startSyncing()
        case .forgotPassword:
            await reset.submit()
            guard reset.step == .done else { return }
            current = .account
            said = PasswordResetScreen.finished
            startSyncing()
        case .confirmEmail:
            guard await confirm.submit() else { return }
            current = .account
            said = Words.confirmed
        case .changePassword:
            guard await change.submit() else { return }
            current = .account
            said = ChangePasswordScreen.finished
        case .account:
            return
        }
    }

    /// Asks for a confirmation code, the first or another.
    public func sendCode() async {
        await confirm.sendCode()
    }

    /// Closes the sheet: Cancel, Not now, or Done. A code not confirmed now
    /// is asked for again on the account step.
    public func close() {
        guard !isWorking else { return }
        isFinished = true
    }

    public func signOut() async {
        guard !isWorking else { return }
        isSigningOut = true
        defer { isSigningOut = false }
        await actions.signOut()
        isFinished = true
    }

    /// Asks first, since every device is signed out.
    public func askToSignOutEverywhere() {
        guard !isWorking else { return }
        isAskingToSignOutEverywhere = true
    }

    public func keepDevicesSignedIn() {
        isAskingToSignOutEverywhere = false
    }

    /// The answer yes: signs out every device, this one too. When it does
    /// not go through, this device stays signed in and the reason shows.
    ///
    /// It starts at once rather than being awaited, and does not depend on
    /// the question still being open: a dialog may close, and clear the
    /// question, before or after its button's action runs.
    public func signOutEverywhere() {
        guard !isWorking else { return }
        isAskingToSignOutEverywhere = false
        failure = nil
        isSigningOut = true
        signingOutEverywhere = Task {
            defer { isSigningOut = false }
            do {
                try await actions.signOutEverywhere()
                isFinished = true
            } catch {
                failure = AccountWording.words(for: error)
            }
        }
    }

    private func askToConfirm(codeSent: Bool) {
        confirm = ConfirmEmailScreen(actions: actions, codeAlreadySent: codeSent)
        current = .confirmEmail
    }

    private func startSyncing() {
        let afterSigningIn = afterSigningIn
        syncing = Task { await afterSigningIn() }
    }

    // MARK: - Words

    public enum Words {
        public static let email = "Email"
        public static let password = "Password"
        public static let confirmation = "Confirm password"
        public static let currentPassword = "Current password"
        public static let newPassword = "New password"
        public static let code = "Code"
        public static let server = "Server"

        public static let signInButton = "Sign in"
        public static let createAccountButton = "Create account"
        public static let sendResetCode = "Send code"
        public static let setPassword = "Set password"
        public static let confirm = "Confirm"
        public static let changePasswordButton = "Change password"
        public static let sendFirstCode = "Send a code"
        public static let sendAnotherCode = "Send another code"
        public static let cancel = "Cancel"

        public static let createAccount = "Create an account"
        public static let forgotPassword = "Forgot your password?"
        public static let back = "Back"
        public static let startOver = "Start over"
        public static let notNow = "Not now"
        public static let done = "Done"
        public static let confirmEmail = "Confirm your email…"
        public static let changePassword = "Change password…"
        public static let signOut = "Sign out"
        public static let signOutEverywhere = "Sign out everywhere…"

        public static let confirmed = "Your email is confirmed."

        public static func signedInAs(_ account: String) -> String { "Signed in as \(account)." }

        /// The server answers the same whether or not the address has an
        /// account, so this cannot say more.
        public static func resetCodeSent(to address: String) -> String {
            "If \(address) has an account and has been confirmed, a code is on its way. It lasts 30 minutes."
        }

        public static func enterCode(sentTo address: String?) -> String {
            "Enter the code sent to \(address ?? "your email")."
        }

        /// Asked before signing out everywhere.
        public static let signOutEverywhereTitle = "Sign out everywhere?"
        public static let signOutEverywhereMessage = """
            Every device signed in to this account is signed out, this one too. \
            Each device keeps its budgets.
            """
        public static let signOutEverywhereButton = "Sign Out Everywhere"

        /// Where the budgets go, and who can read them.
        public static let privacy = """
            Your budgets sync through WellSpent's server. Connections and backups are encrypted. \
            The server can read your budgets. That's how it checks who may change what, and why \
            resetting a forgotten password doesn't lose your budgets.
            """
    }
}
