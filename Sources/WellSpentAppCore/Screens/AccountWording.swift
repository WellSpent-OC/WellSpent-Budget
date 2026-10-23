import Foundation
import WellSpentKeyStore
import WellSpentSync

/// Errors from signing in, signing up, confirming an address and changing
/// a password, in words a person can act on.
public enum AccountWording {
    /// `device` names this device where the words need it. See `SyncWording.device`.
    public static func words(for error: any Error, device: String = SyncWording.device) -> String {
        if let failure = error as? SyncCoordinator.Failure {
            switch failure {
            case .notSignedIn: return "Sign in first."
            case .server(let message), .wrongServer(let message): return message
            case .emailNotConfirmed: return "Confirm your email address first, then try again."
            }
        }
        if let failure = error as? ReadableTransportError {
            switch failure {
            case .sessionEnded: return SyncCoordinator.sessionEndedReason
            case .badCredentials: return "That email or password is wrong."
            case .wrongCurrentPassword: return "Your current password is wrong."
            case .serverNotUpdated: return "This server does not have the new sync yet."
            case .emailInvitationsNotSupported:
                return "Update this WellSpent server before sending email invitations. No email was sent."
            case .http(409, "that email already has an account"):
                return "That email already has an account. Sign in, or reset its password."
            case .http(let status, let reason) where [400, 403, 404, 409, 410, 429].contains(status)
                && !reason.isEmpty:
                return sentence(reason)
            case .http(429, _):
                return "Too many attempts. Try again in a few minutes."
            case .http(let status, _) where status >= 500:
                return notAnswering
            case .http, .malformed:
                // Raw text from the server, or from something in between such
                // as a Wi-Fi login page, is never shown.
                return "The server sent a reply this app could not use. Try again in a few minutes."
            }
        }
        if let failure = error as? KeyStoreError {
            switch failure {
            case .notFound: return "This device could not find what it saved for this account."
            case .locked: return "Unlock the key store first."
            case .wrongPassphrase: return "That passphrase is wrong."
            case .backendFailure: return "This device could not save the sign-in. Try again."
            }
        }
        if let failure = error as? URLError {
            switch failure.code {
            case .notConnectedToInternet, .networkConnectionLost:
                return "This \(device) is not connected to the internet."
            case .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed, .timedOut:
                return "Could not reach the server. Check its address and your connection."
            default:
                return "Could not reach the server. Check your connection and try again."
            }
        }
        return "Something went wrong. Try again."
    }

    static let notAnswering = "The server is not answering right now. Try again in a few minutes."

    /// The server writes its reasons in lower case, to fit in a sentence,
    /// sometimes two joined by a semicolon. Shown on their own, each starts
    /// with a capital and ends with a stop.
    static func sentence(_ reason: String) -> String {
        reason.components(separatedBy: "; ").map { part -> String in
            guard let first = part.first else { return part }
            let capital = first.uppercased() + part.dropFirst()
            return capital.hasSuffix(".") ? capital : capital + "."
        }.joined(separator: " ")
    }
}

/// What the account screens ask of the app. The coordinator does it; a test
/// can stand in.
@MainActor
public protocol AccountActions: AnyObject {
    var account: String? { get }
    var emailVerified: Bool { get }
    /// Why this device was signed out without being asked to, if it was.
    var signInPrompt: SyncCoordinator.SignInPrompt? { get }
    func signIn(email: String, password: String) async throws
    func signUp(email: String, password: String) async throws
    func verifyEmail(code: String) async throws
    func resendVerification() async throws
    func forgotPassword(email: String) async throws
    func resetPassword(email: String, code: String, newPassword: String) async throws
    func changePassword(current: String, new: String) async throws
    func signOut() async
    func signOutEverywhere() async throws
}
