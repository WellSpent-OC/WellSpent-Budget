import Foundation
import Observation

// What each account screen holds and checks, with no SwiftUI, so the Mac and
// Linux screens share it and tests can drive it. Each screen keeps its fields,
// a problem per field found before sending, the server's answer in words when
// it refuses, and whether a request is out.

/// Signing in on any device.
@MainActor
@Observable
public final class SignInScreen {
    public enum Field: Hashable, Sendable { case email, password }

    public var email: String
    public var password = ""
    public private(set) var problems: [Field: String] = [:]
    public private(set) var failure: String?
    public private(set) var isWorking = false
    private let actions: any AccountActions

    public init(actions: any AccountActions, email: String = "") {
        self.actions = actions
        self.email = email
    }

    public var canSubmit: Bool { !isWorking && !email.isEmpty && !password.isEmpty }

    /// True once signed in.
    public func submit() async -> Bool {
        problems = [:]
        failure = nil
        if AccountRules.normalisedEmail(email) == nil { problems[.email] = "That does not look like an email address." }
        guard problems.isEmpty, canSubmit else { return false }
        isWorking = true
        defer { isWorking = false }
        do {
            try await actions.signIn(email: email, password: password)
            password = ""
            return true
        } catch {
            failure = AccountWording.words(for: error)
            return false
        }
    }
}

/// Creating an account.
@MainActor
@Observable
public final class SignUpScreen {
    public enum Field: Hashable, Sendable { case email, password, confirmation }

    public var email = ""
    public var password = ""
    public var confirmation = ""
    public private(set) var problems: [Field: String] = [:]
    public private(set) var failure: String?
    public private(set) var isWorking = false
    private let actions: any AccountActions

    public init(actions: any AccountActions) {
        self.actions = actions
    }

    public var canSubmit: Bool { !isWorking && !email.isEmpty && !password.isEmpty && !confirmation.isEmpty }

    /// True once the account exists and this device is signed in to it. The
    /// next screen asks for the code emailed to confirm the address.
    public func submit() async -> Bool {
        problems = [:]
        failure = nil
        if AccountRules.normalisedEmail(email) == nil { problems[.email] = "That does not look like an email address." }
        if let problem = AccountRules.passwordProblem(password) { problems[.password] = problem }
        if confirmation != password { problems[.confirmation] = "The two passwords are not the same." }
        guard problems.isEmpty, canSubmit else { return false }
        isWorking = true
        defer { isWorking = false }
        do {
            try await actions.signUp(email: email, password: password)
            password = ""
            confirmation = ""
            return true
        } catch {
            failure = AccountWording.words(for: error)
            return false
        }
    }
}

/// Confirming the address with the code emailed to it. Joining a shared
/// group, and resetting a forgotten password, both need it.
///
/// Every account that existed before readable sync starts unconfirmed, and
/// was never sent a code, so the first step can be asking for one.
@MainActor
@Observable
public final class ConfirmEmailScreen {
    public var code = ""
    /// Whether a code has gone out: at sign-up, or from this screen.
    public private(set) var codeSent: Bool
    public private(set) var failure: String?
    /// Said after a code is asked for.
    public private(set) var note: String?
    public private(set) var isWorking = false
    private let actions: any AccountActions

    public init(actions: any AccountActions, codeAlreadySent: Bool = false) {
        self.actions = actions
        self.codeSent = codeAlreadySent
    }

    /// Why to confirm, for an account that has not.
    nonisolated public static let reason = "Confirm your email so a forgotten password can be reset, and so you can join shared budgets."

    /// The server sends at most one code a minute, and only the newest works.
    nonisolated public static let codeOnItsWay = """
        If a code was sent in the last minute, use that one. Otherwise a new code is on its way. \
        Only the newest code works.
        """

    /// Where the code went.
    public var address: String? { actions.account }
    public var canSubmit: Bool { !isWorking && AccountRules.isWholeCode(code) }
    public var canSendCode: Bool { !isWorking }

    public func submit() async -> Bool {
        guard canSubmit else { return false }
        failure = nil
        note = nil
        isWorking = true
        defer { isWorking = false }
        do {
            try await actions.verifyEmail(code: code)
            return true
        } catch {
            failure = AccountWording.words(for: error)
            return false
        }
    }

    /// Asks for a code, the first or another.
    public func sendCode() async {
        guard canSendCode else { return }
        failure = nil
        note = nil
        isWorking = true
        defer { isWorking = false }
        do {
            try await actions.resendVerification()
            codeSent = true
            note = Self.codeOnItsWay
        } catch {
            failure = AccountWording.words(for: error)
        }
    }
}

/// A forgotten password: the address, then the emailed code and a new
/// password, then done.
@MainActor
@Observable
public final class PasswordResetScreen {
    public enum Step: Equatable, Sendable { case enterEmail, enterCode, done }
    public enum Field: Hashable, Sendable { case email, code, password, confirmation }

    public private(set) var step: Step = .enterEmail
    public var email: String
    public var code = ""
    public var password = ""
    public var confirmation = ""
    public private(set) var problems: [Field: String] = [:]
    public private(set) var failure: String?
    public private(set) var isWorking = false
    private let actions: any AccountActions

    public init(actions: any AccountActions, email: String = "") {
        self.actions = actions
        self.email = email
    }

    /// What the code step says. The server answers the same whether or not
    /// the address has an account, so this cannot say more.
    nonisolated public static let codeSent = """
        If that address has an account and has been confirmed, a code is on its way. \
        It lasts 30 minutes.
        """

    nonisolated public static let finished = "Your password is changed, and you are signed in. Every other device was signed out."

    public var canSubmit: Bool {
        guard !isWorking else { return false }
        switch step {
        case .enterEmail: return !email.isEmpty
        case .enterCode: return AccountRules.isWholeCode(code) && !password.isEmpty && !confirmation.isEmpty
        case .done: return false
        }
    }

    /// Moves to the next step when this one goes through.
    public func submit() async {
        problems = [:]
        failure = nil
        switch step {
        case .enterEmail:
            if AccountRules.normalisedEmail(email) == nil {
                problems[.email] = "That does not look like an email address."
            }
            guard problems.isEmpty, canSubmit else { return }
            await working {
                try await actions.forgotPassword(email: email)
                step = .enterCode
            }
        case .enterCode:
            if !AccountRules.isWholeCode(code) { problems[.code] = "The code has 8 letters and numbers." }
            if let problem = AccountRules.passwordProblem(password) { problems[.password] = problem }
            if confirmation != password { problems[.confirmation] = "The two passwords are not the same." }
            guard problems.isEmpty, canSubmit else { return }
            await working {
                try await actions.resetPassword(email: email, code: code, newPassword: password)
                password = ""
                confirmation = ""
                step = .done
            }
        case .done:
            return
        }
    }

    /// Back to the address, to ask for a code again.
    public func startOver() {
        guard !isWorking else { return }
        step = .enterEmail
        code = ""
        failure = nil
        problems = [:]
    }

    private func working(_ work: () async throws -> Void) async {
        isWorking = true
        defer { isWorking = false }
        do {
            try await work()
        } catch {
            failure = AccountWording.words(for: error)
        }
    }
}

/// Changing the password while signed in.
@MainActor
@Observable
public final class ChangePasswordScreen {
    public enum Field: Hashable, Sendable { case current, password, confirmation }

    public var current = ""
    public var password = ""
    public var confirmation = ""
    public private(set) var problems: [Field: String] = [:]
    public private(set) var failure: String?
    public private(set) var isWorking = false
    private let actions: any AccountActions

    public init(actions: any AccountActions) {
        self.actions = actions
    }

    nonisolated public static let finished = "Your password is changed. Every other device was signed out."

    public var canSubmit: Bool { !isWorking && !current.isEmpty && !password.isEmpty && !confirmation.isEmpty }

    public func submit() async -> Bool {
        problems = [:]
        failure = nil
        if let problem = AccountRules.passwordProblem(password) { problems[.password] = problem }
        if confirmation != password { problems[.confirmation] = "The two passwords are not the same." }
        if password == current, problems[.password] == nil {
            problems[.password] = "The new password is the same as the current one."
        }
        guard problems.isEmpty, canSubmit else { return false }
        isWorking = true
        defer { isWorking = false }
        do {
            try await actions.changePassword(current: current, new: password)
            current = ""
            password = ""
            confirmation = ""
            return true
        } catch {
            failure = AccountWording.words(for: error)
            return false
        }
    }
}
