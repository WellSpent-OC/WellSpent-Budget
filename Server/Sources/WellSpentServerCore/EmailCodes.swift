import Foundation
import Crypto
import Fluent
import SQLKit
import Vapor

/// What an emailed code proves.
enum EmailCodePurpose: String {
    /// The address is the person's. A password reset goes only to one proved this way.
    case verify
    /// The person may set a new password.
    case reset

    /// A confirmation email may sit unread for a while; a reset is done on the spot.
    var lifetime: TimeInterval {
        switch self {
        case .verify: return 24 * 60 * 60
        case .reset: return 30 * 60
        }
    }
}

/// The codes themselves: how they look, and how they are stored.
enum EmailCode {
    /// Long enough to type from an email, too long to guess in five tries.
    /// 31 symbols to the eighth is about 40 bits.
    static let length = 8
    /// No 0, O, 1, I or L, so a code read off a phone cannot be mistyped.
    static let alphabet = Array("ABCDEFGHJKMNPQRSTUVWXYZ23456789")
    static let maxAttempts = 5

    static func generate() -> String {
        var generator = SystemRandomNumberGenerator()
        return String((0 ..< length).map { _ in alphabet.randomElement(using: &generator)! })
    }

    /// Shown as XXXX-XXXX, because eight letters in a row are hard to copy.
    static func display(_ code: String) -> String {
        "\(code.prefix(4))-\(code.dropFirst(4))"
    }

    /// Accepts the code as typed: any case, with or without the dash or spaces.
    static func normalise(_ typed: String) -> String {
        typed.uppercased().filter { $0.isLetter || $0.isNumber }
    }

    /// A keyed hash under a secret only the server holds. A plain hash of a
    /// 40-bit code could be reversed from a leaked database in minutes.
    static func digest(_ code: String, key: SymmetricKey) -> String {
        Data(HMAC<SHA256>.authenticationCode(for: Data(normalise(code).utf8), using: key)).hexString
    }

    /// Compares in time that does not depend on where the first difference is.
    static func same(_ lhs: String, _ rhs: String) -> Bool {
        let a = Array(lhs.utf8), b = Array(rhs.utf8)
        guard a.count == b.count else { return false }
        var difference: UInt8 = 0
        for index in a.indices { difference |= a[index] ^ b[index] }
        return difference == 0
    }

    /// The development key, public in this file, so a developer needs no setup.
    /// `chooseKey` never lets a production server use it.
    static let developmentKey = SymmetricKey(data: SHA256.hash(data: Data("wellspent development email code key".utf8)))

    /// The secret the codes are hashed under: `EMAIL_CODE_KEY`, 32 bytes in
    /// base64. A production server without one refuses to start.
    static func chooseKey(environment: Environment, configured: String?) throws -> SymmetricKey {
        if let configured, !configured.isEmpty {
            guard let bytes = Data(base64Encoded: configured), bytes.count == 32 else {
                throw Abort(.internalServerError,
                            reason: "EMAIL_CODE_KEY must be 32 bytes in base64 (openssl rand -base64 32)")
            }
            return SymmetricKey(data: bytes)
        }
        // The public development key only where nothing real can be at stake.
        guard environment == .development || environment == .testing else {
            throw Abort(.internalServerError,
                        reason: "EMAIL_CODE_KEY is not set. Make one with: openssl rand -base64 32")
        }
        return developmentKey
    }
}

extension Application {
    private struct EmailCodeKeyKey: StorageKey {
        typealias Value = SymmetricKey
    }

    var emailCodeKey: SymmetricKey {
        get {
            guard let key = storage[EmailCodeKeyKey.self] else {
                fatalError("configure() sets the email code key before any route runs")
            }
            return key
        }
        set { storage[EmailCodeKeyKey.self] = newValue }
    }

    func configureEmailCodeKey() throws {
        emailCodeKey = try EmailCode.chooseKey(environment: environment,
                                               configured: Environment.get("EMAIL_CODE_KEY"))
    }
}

/// How soon a new code may follow the last one sent for the same purpose.
let emailCodeResendGap: TimeInterval = 60

/// Makes a new code for a person and purpose, replacing any earlier one, and
/// returns it for the email. Nil when one was sent within the last minute:
/// nothing is sent, and the code already on its way still works.
///
/// Replacing means a stranger who keeps asking can make an earlier code stop
/// working. Only the hash is stored, so the same code cannot be sent again; the
/// minute's gap and the per-address limits on asking are what keep that in check.
func issueEmailCode(for userID: UUID, purpose: EmailCodePurpose, on database: any Database,
                    key: SymmetricKey) async throws -> String? {
    let now = Date()
    if let last = try await EmailCodeRow.query(on: database)
        .filter(\.$userID == userID).filter(\.$purpose == purpose.rawValue).first(),
       now.timeIntervalSince(last.lastSentAt) < emailCodeResendGap, last.expiresAt > now {
        return nil
    }
    let code = EmailCode.generate()
    try await database.transaction { database in
        try await EmailCodeRow.query(on: database)
            .filter(\.$userID == userID)
            .filter(\.$purpose == purpose.rawValue)
            .delete()
        try await EmailCodeRow(userID: userID, purpose: purpose.rawValue,
                               codeHMAC: EmailCode.digest(code, key: key),
                               expiresAt: now.addingTimeInterval(purpose.lifetime),
                               lastSentAt: now).create(on: database)
    }
    return code
}

/// Uses up a code. True only for the right code, before it expires, within its
/// five tries, and only once.
///
/// The try is counted before the code is compared, in one statement that only
/// counts while tries are left, so five guesses sent at once still get five
/// tries between them, not five each. A right code is spent by a delete that
/// only succeeds if the row is still there, so two uses at once let one through.
func redeemEmailCode(for userID: UUID, purpose: EmailCodePurpose, typed: String,
                     on database: any Database, key: SymmetricKey) async throws -> Bool {
    guard let row = try await EmailCodeRow.query(on: database)
        .filter(\.$userID == userID)
        .filter(\.$purpose == purpose.rawValue)
        .first() else { return false }
    let id = try row.requireID()
    guard row.expiresAt > Date() else {
        try await row.delete(on: database)
        return false
    }
    guard let sql = database as? any SQLDatabase else {
        throw Abort(.internalServerError, reason: "email codes need a SQL database")
    }
    let counted = try await sql.update(EmailCodeRow.schema)
        .set("attempts", to: SQLBinaryExpression(SQLColumn("attempts"), SQLBinaryOperator.add,
                                                 SQLLiteral.numeric("1")))
        .where("id", .equal, SQLBind(id))
        .where("attempts", .lessThan, SQLBind(EmailCode.maxAttempts))
        .returning("attempts")
        .first()
    guard counted != nil else { return false }
    guard EmailCode.same(EmailCode.digest(typed, key: key), row.codeHMAC) else { return false }
    let spent = try await sql.delete(from: EmailCodeRow.schema)
        .where("id", .equal, SQLBind(id))
        .returning("id")
        .first()
    return spent != nil
}

/// Deletes codes past their expiry. Hourly, with the expired sessions.
func purgeExpiredEmailCodes(on database: any Database) async throws {
    try await EmailCodeRow.query(on: database).filter(\.$expiresAt < Date()).delete()
}
