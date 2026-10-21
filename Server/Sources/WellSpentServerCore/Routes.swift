import Foundation
import Fluent
import Vapor
import Crypto
import WellSpentCrypto

enum ServerError: Error, AbortError {
    case emailTaken
    case passwordTooShort
    case emailInvalid
    case badCredentials
    case notAMember
    case insufficientLevel(needed: AccessLevel)
    case chainRejected(String)
    case inviteNotFound
    case inviteExpired
    case inviteAlreadyAccepted
    case passwordTooLong
    case badCode

    var status: HTTPResponseStatus {
        switch self {
        case .emailTaken: return .conflict
        case .passwordTooShort, .emailInvalid: return .badRequest
        case .badCredentials: return .unauthorized
        case .notAMember, .insufficientLevel: return .forbidden
        case .chainRejected: return .badRequest
        case .inviteNotFound: return .notFound
        case .inviteExpired: return .gone
        case .inviteAlreadyAccepted: return .conflict
        case .passwordTooLong, .badCode: return .badRequest
        }
    }

    /// Distinct status codes, unlike the old API which answered `400` for
    /// everything including authentication failures, so a client could not tell a
    /// wrong password from a malformed request without string matching.
    var reason: String {
        switch self {
        case .emailTaken: return "that email already has an account"
        case .passwordTooShort: return "a password needs at least 10 characters"
        case .emailInvalid: return "that does not look like an email address"
        case .badCredentials: return "email or password is wrong"
        case .notAMember: return "you are not a member of that group"
        case .insufficientLevel(let needed): return "that needs \(needed)"
        case .chainRejected(let why): return "membership entry refused: \(why)"
        case .inviteNotFound: return "no such invite"
        case .inviteExpired: return "that invite has expired"
        case .inviteAlreadyAccepted: return "that invite has already been accepted"
        case .passwordTooLong: return "a password can have at most \(AccountRules.maxPasswordLength) characters"
        // One answer for a wrong code, an expired one, a used one and an
        // unknown address, so it never says which.
        case .badCode: return "that code is wrong or has expired"
        }
    }
}

// MARK: - Routes

public func registerRoutes(_ app: Application) throws {
    // A health check that does not touch the database tells a restart policy and
    // every uptime monitor that a server with no database is perfectly fine.
    // Cheapest honest probe: one indexed row, discarded.
    app.get("health") { request async throws -> [String: String] in
        do {
            _ = try await UserRow.query(on: request.db).first()
        } catch {
            request.logger.error("health check could not reach the database: \(error)")
            throw Abort(.serviceUnavailable, reason: "database unreachable")
        }
        let environment = request.application.storage[ServerEnvironmentKey.self] ?? .development
        return ["status": "ok", "environment": environment.rawValue]
    }

    // The sealed sync's /api/v1 is gone. Every path under it still asks the old
    // app to update (`LegacyAPI`).
    LegacyAPI.register(on: app)

    let v2 = app.grouped("api", "v2")
    try registerAccountRoutesV2(v2)
    try registerGroupRoutesV2(v2)
    try registerSyncRoutesV2(v2)
}

// MARK: - Sessions

/// Tokens are stored as a digest and never in the clear, for the same reason
/// invites are: a read of this database must not hand over live sessions.
///
/// A plain SHA-256 is right and bcrypt would be wrong. The input is 32 bytes of
/// machine randomness, not something a person chose, so there is nothing to slow
/// a guess down for.
func tokenDigest(_ value: String) -> String {
    Data(SHA256.hash(data: Data(value.utf8))).hexString
}

struct AuthenticatedUser: Authenticatable {
    let id: UUID
}

/// What already uses an ID, in any group (`IDClaims`).
func claims(on id: UUID, db: any Database) async throws -> IDClaims {
    var claims = IDClaims()
    claims.isGroup = try await GroupRow.find(id, on: db) != nil
    if let record = try await RecordRow.find(id, on: db) {
        claims.records = [.init(group: record.groupID, type: RecordType(rawValue: record.recordType))]
    }
    claims.budgetKeys = Set(try await WrappedKeyRow.query(on: db)
        .filter(\.$scopeKind == "budget")
        .filter(\.$scopeID == id)
        .all(\.$groupID))
    return claims
}

extension Data {
    init?(hexString: String) {
        let characters = Array(hexString)
        guard characters.count % 2 == 0 else { return nil }
        var bytes = [UInt8]()
        bytes.reserveCapacity(characters.count / 2)
        for index in stride(from: 0, to: characters.count, by: 2) {
            guard let byte = UInt8(String(characters[index ... index + 1]), radix: 16) else { return nil }
            bytes.append(byte)
        }
        self.init(bytes)
    }

    var hexString: String { map { String(format: "%02x", $0) }.joined() }
}
