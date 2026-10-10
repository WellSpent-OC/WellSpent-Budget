import Foundation

/// The account rules the server applies (`AccountRules` and `EmailCode` in
/// the server package), checked here first so a screen can say what is
/// wrong before anything is sent. The server checks again.
public enum AccountRules {
    public static let minPasswordLength = 10
    /// Bcrypt reads only the first 72 bytes; the server caps passwords here.
    public static let maxPasswordLength = 128
    /// The longest address the email standard allows.
    public static let maxEmailLength = 254
    public static let codeLength = 8

    /// The address in the one form the server keeps, or nil when the server
    /// would refuse it: trimmed, one Unicode form, lower case, one "@", and a
    /// domain with a dot that does not start, end or double up.
    public static func normalisedEmail(_ raw: String) -> String? {
        let email = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .precomposedStringWithCanonicalMapping.lowercased()
        let parts = email.split(separator: "@", omittingEmptySubsequences: false)
        guard email.count <= maxEmailLength, parts.count == 2, let local = parts.first, let domain = parts.last,
              !local.isEmpty, domain.count >= 3, domain.contains("."), !domain.hasPrefix("."),
              !domain.hasSuffix("."), !domain.contains(".."),
              !email.unicodeScalars.contains(where: { $0.properties.isWhitespace
                  || $0.properties.generalCategory == .control })
        else { return nil }
        return email
    }

    /// What is wrong with a new password, in words, or nil when nothing is.
    public static func passwordProblem(_ password: String) -> String? {
        if password.count < minPasswordLength {
            return "A password needs at least \(minPasswordLength) characters."
        }
        if password.count > maxPasswordLength {
            return "A password can have at most \(maxPasswordLength) characters."
        }
        return nil
    }

    /// A code as typed, in any case, with or without the dash or spaces.
    public static func normalisedCode(_ typed: String) -> String {
        typed.uppercased().filter { $0.isLetter || $0.isNumber }
    }

    /// A code as the email shows it: XXXX-XXXX.
    public static func displayedCode(_ typed: String) -> String {
        let code = normalisedCode(typed)
        guard code.count > 4 else { return code }
        return "\(code.prefix(4))-\(code.dropFirst(4))"
    }

    public static func isWholeCode(_ typed: String) -> Bool {
        normalisedCode(typed).count == codeLength
    }
}
