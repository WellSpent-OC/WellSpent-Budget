import Foundation
import Crypto
import Fluent
import SQLKit
import Vapor

// Accounts for readable sync, under /api/v2.
//
// No keys: a person signs in with an email and a password on any device, a
// session renews itself while it is used, and a forgotten password is reset by
// a code sent to a confirmed address.

// MARK: - Wire types

struct SignUpV2Request: Content {
    let email: String
    let password: String
    /// What the device calls itself, so the person can tell sessions apart.
    let deviceLabel: String?
}

struct SignInV2Request: Content {
    let email: String
    let password: String
    let deviceLabel: String?
}

struct SessionResponse: Content {
    let userID: UUID
    let token: String
    let expiresAt: Date
    let emailVerified: Bool
}

struct MeResponse: Content {
    let userID: UUID
    let email: String
    let emailVerified: Bool
}

struct SessionInfo: Content {
    let id: UUID
    let deviceLabel: String?
    let createdAt: Date?
    let lastUsedAt: Date
    /// The session that asked.
    let current: Bool
}

struct CodeRequest: Content {
    let code: String
}

struct ForgotPasswordRequest: Content {
    let email: String
}

struct ResetPasswordRequest: Content {
    let email: String
    let code: String
    let newPassword: String
    let deviceLabel: String?
}

struct ChangePasswordRequest: Content {
    let currentPassword: String
    let newPassword: String
}

// MARK: - Rules

enum AccountRules {
    /// The longest address the email standard allows.
    static let maxEmailLength = 254
    static let minPasswordLength = 10
    /// Bcrypt reads only the first 72 bytes, so a longer password is no
    /// stronger. The cap keeps a request from making the server hash megabytes.
    static let maxPasswordLength = 128
    static let maxDeviceLabelLength = 64

    /// One spelling per address: no surrounding spaces, lower case. The account's
    /// files on each device are named from the same form.
    static func normaliseEmail(_ raw: String) throws -> String {
        // One Unicode form, so the same address typed two ways is one account.
        var typed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // An address copied from a link arrives as "mailto:name@example.com".
        // Kept as typed, it made an account nobody could sign in to with the
        // plain address (the go/no-go test, 2026-10-15).
        if typed.lowercased().hasPrefix("mailto:") {
            typed = String(typed.dropFirst("mailto:".count)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let email = typed.precomposedStringWithCanonicalMapping.lowercased()
        let parts = email.split(separator: "@", omittingEmptySubsequences: false)
        guard email.count <= maxEmailLength, parts.count == 2,
              let local = parts.first, let domain = parts.last,
              !local.isEmpty, domain.count >= 3, domain.contains("."),
              !domain.hasPrefix("."), !domain.hasSuffix("."), !domain.contains(".."),
              !email.unicodeScalars.contains(where: { $0.properties.isWhitespace || $0.properties.generalCategory == .control })
        else {
            throw ServerError.emailInvalid
        }
        return email
    }

    static func checkPassword(_ password: String) throws {
        guard password.count >= minPasswordLength else { throw ServerError.passwordTooShort }
        guard password.count <= maxPasswordLength else { throw ServerError.passwordTooLong }
    }

    static func deviceLabel(_ raw: String?) -> String? {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else { return nil }
        return String(trimmed.prefix(maxDeviceLabelLength))
    }
}

// MARK: - Sessions

enum SessionRules {
    /// How long a session lasts unused. Opening the app about once a month keeps
    /// a person signed in, with room to spare.
    static let idleLifetime: TimeInterval = 90 * 24 * 60 * 60
    /// Renew at most this often, so a busy device does not write on every request.
    static let renewAfter: TimeInterval = 24 * 60 * 60

    /// Whether a session's stamp still matches the password. Dates go through
    /// the database, so a difference under a millisecond is rounding, not a change.
    static func sameStamp(_ a: Date?, _ b: Date?) -> Bool {
        switch (a, b) {
        case (nil, nil): return true
        case let (a?, b?): return abs(a.timeIntervalSince(b)) < 0.001
        default: return false
        }
    }
}

/// A new session for a person on one device. The token is returned once and
/// only its SHA-256 is kept.
func issueSession(for user: UserRow, label: String?, on database: any Database) async throws
    -> SessionResponse {
    let value = [UInt8].random(count: 32).base64String()
    let now = Date()
    let expires = now.addingTimeInterval(SessionRules.idleLifetime)
    try await SessionRow(userID: try user.requireID(), tokenHash: tokenDigest(value),
                         deviceLabel: AccountRules.deviceLabel(label),
                         lastUsedAt: now, expiresAt: expires,
                         credentialStamp: user.passwordChangedAt).create(on: database)
    return SessionResponse(userID: try user.requireID(), token: value, expiresAt: expires,
                           emailVerified: user.emailVerifiedAt != nil)
}

struct CurrentSessionKey: StorageKey {
    typealias Value = UUID
}

/// Signs in a request by its session token, and keeps a session in use alive.
struct SessionAuthenticator: AsyncBearerAuthenticator {
    func authenticate(bearer: BearerAuthorization, for request: Request) async throws {
        guard let session = try await SessionRow.query(on: request.db)
            .filter(\.$tokenHash == tokenDigest(bearer.token)).first() else { return }
        let now = Date()
        // A session ends when the password changes after it began. The stamp
        // is checked here, on every request, so a sign-in that was still
        // checking the old password while a reset ran cannot outlive the reset.
        guard session.expiresAt > now,
              let user = try await UserRow.find(session.userID, on: request.db),
              SessionRules.sameStamp(session.credentialStamp, user.passwordChangedAt) else {
            try await session.delete(on: request.db)
            return
        }
        if now.timeIntervalSince(session.lastUsedAt) > SessionRules.renewAfter {
            session.lastUsedAt = now
            session.expiresAt = now.addingTimeInterval(SessionRules.idleLifetime)
            try await session.save(on: request.db)
        }
        request.storage[CurrentSessionKey.self] = try session.requireID()
        request.auth.login(AuthenticatedUser(id: session.userID))
    }
}

/// Deletes sessions past their expiry. Hourly, and once at start.
func purgeExpiredSessions(on database: any Database) async throws {
    try await SessionRow.query(on: database).filter(\.$expiresAt < Date()).delete()
}

// MARK: - Emails

enum AccountEmail {
    static func verify(code: String) -> (subject: String, text: String) {
        ("Your WellSpent code: \(EmailCode.display(code))", """
        Your WellSpent code is \(EmailCode.display(code)).

        Type it in WellSpent to confirm this address is yours. It works for 24 hours.

        If you did not sign up for WellSpent, you can ignore this email.
        """)
    }

    static func reset(code: String) -> (subject: String, text: String) {
        ("Reset your WellSpent password: \(EmailCode.display(code))", """
        Your WellSpent password reset code is \(EmailCode.display(code)).

        Type it in WellSpent to choose a new password. It works for 30 minutes.

        If you did not ask to reset your password, you can ignore this email. \
        Your password stays the same.
        """)
    }

    static let passwordChanged = (subject: "Your WellSpent password was changed", text: """
        The password for your WellSpent account was just changed.

        If you changed it, there is nothing to do.

        If you did not, reset it now from the WellSpent sign-in screen with \
        "Forgot password", which signs every device out.
        """)
}

// MARK: - Routes

func registerAccountRoutesV2(_ routes: any RoutesBuilder) throws {
    // Requests that need no session are small. A tight cap stops a stranger
    // making the server read megabytes before it has checked anything.
    let small: HTTPBodyStreamStrategy = .collect(maxSize: "4kb")

    routes.on(.POST, "signup", body: small) { request async throws -> SessionResponse in
        // Read first, so a test address on staging gets the tests' allowance.
        let body = try request.content.decode(SignUpV2Request.self)
        try await request.enforceRateLimit(.signUp, scope: "v2-signup", email: body.email)
        let email = try AccountRules.normaliseEmail(body.email)
        try AccountRules.checkPassword(body.password)
        guard try await UserRow.query(on: request.db).filter(\.$email == email).first() == nil else {
            throw ServerError.emailTaken
        }
        // The identity columns are left empty: readable accounts have no keys.
        // They go when the sealed tables do.
        let user = UserRow(id: UUID(), email: email, passwordHash: try Bcrypt.hash(body.password),
                           identitySigning: Data(), identityKEM: Data())
        try await user.create(on: request.db)

        if let code = try await issueEmailCode(for: try user.requireID(), purpose: .verify,
                                               on: request.db, key: request.application.emailCodeKey) {
            let message = AccountEmail.verify(code: code)
            request.application.sendInBackground(to: email, subject: message.subject, text: message.text)
        }
        return try await issueSession(for: user, label: body.deviceLabel, on: request.db)
    }

    routes.on(.POST, "signin", body: small) { request async throws -> SessionResponse in
        let body = try request.content.decode(SignInV2Request.self)
        try await request.enforceRateLimit(.signIn, scope: "v2-signin", email: body.email)
        let email = (try? AccountRules.normaliseEmail(body.email)) ?? ""
        // Per account too, so guesses spread over many addresses still slow
        // down for any one account. Looser than per caller, because anyone can
        // spend someone else's allowance.
        try await request.enforceRateLimit(.signInPerAccount, key: "v2-signin-address", for: email)
        guard let user = try await UserRow.query(on: request.db).filter(\.$email == email).first() else {
            // The same answer and the same work either way, so neither says
            // whether the address has an account.
            _ = try? Bcrypt.verify(body.password, created: "$2b$12$" + String(repeating: "x", count: 53))
            throw ServerError.badCredentials
        }
        guard (try? Bcrypt.verify(body.password, created: user.passwordHash)) == true else {
            throw ServerError.badCredentials
        }
        return try await issueSession(for: user, label: body.deviceLabel, on: request.db)
    }

    /// Always answers the same, so it never says whether an address has an
    /// account. The code goes only to a confirmed address, and the work is done
    /// after answering, so the time taken says nothing either.
    routes.on(.POST, "password", "forgot", body: small) { request async throws -> HTTPStatus in
        let body = try request.content.decode(ForgotPasswordRequest.self)
        try await request.enforceRateLimit(.emailCode, scope: "v2-forgot", email: body.email)
        guard let email = try? AccountRules.normaliseEmail(body.email) else { return .noContent }
        try await request.enforceRateLimit(.emailCode, key: "v2-forgot-address", for: email)

        // Everything the work needs is taken now, while the server is surely
        // running. Read from the application later, a request just before
        // shutdown would reach for parts already torn down.
        let database = request.application.db
        let key = request.application.emailCodeKey
        let mailer = request.application.mailer
        let logger = request.application.logger
        Task {
            do {
                guard let user = try await UserRow.query(on: database).filter(\.$email == email).first(),
                      user.emailVerifiedAt != nil,
                      let code = try await issueEmailCode(for: try user.requireID(), purpose: .reset,
                                                          on: database, key: key) else { return }
                let message = AccountEmail.reset(code: code)
                try await mailer.send(to: email, subject: message.subject, text: message.text)
            } catch {
                logger.error("a password reset email could not be sent: \(error)")
            }
        }
        return .noContent
    }

    /// Sets a new password with an emailed code, signs every device out, and
    /// signs this one in.
    routes.on(.POST, "password", "reset", body: small) { request async throws -> SessionResponse in
        let body = try request.content.decode(ResetPasswordRequest.self)
        try await request.enforceRateLimit(.codeCheck, scope: "v2-reset", email: body.email)
        try AccountRules.checkPassword(body.newPassword)
        guard let email = try? AccountRules.normaliseEmail(body.email),
              let user = try await UserRow.query(on: request.db).filter(\.$email == email).first(),
              user.emailVerifiedAt != nil,
              try await redeemEmailCode(for: try user.requireID(), purpose: .reset, typed: body.code,
                                        on: request.db, key: request.application.emailCodeKey) else {
            throw ServerError.badCode
        }
        let userID = try user.requireID()
        let hash = try Bcrypt.hash(body.newPassword)
        try await request.db.transaction { database in
            // Held, so a password change and this reset take turns.
            try await holdAccount(userID, on: database)
            user.passwordHash = hash
            user.passwordChangedAt = Date()
            try await user.save(on: database)
            try await SessionRow.query(on: database).filter(\.$userID == userID).delete()
        }
        request.application.sendInBackground(to: email, subject: AccountEmail.passwordChanged.subject,
                                             text: AccountEmail.passwordChanged.text)
        return try await issueSession(for: user, label: body.deviceLabel, on: request.db)
    }

    let authed = routes.grouped(SessionAuthenticator(), AuthenticatedUser.guardMiddleware())

    authed.get("me") { request async throws -> MeResponse in
        let user = try await request.currentUser()
        return MeResponse(userID: try user.requireID(), email: user.email,
                          emailVerified: user.emailVerifiedAt != nil)
    }

    authed.post("signout") { request async throws -> HTTPStatus in
        if let current = request.storage[CurrentSessionKey.self] {
            try await SessionRow.query(on: request.db).filter(\.$id == current).delete()
        }
        return .noContent
    }

    /// For a lost or sold device: every session for this person ends, this one too.
    authed.post("signout", "everywhere") { request async throws -> HTTPStatus in
        let user = try request.auth.require(AuthenticatedUser.self)
        try await SessionRow.query(on: request.db).filter(\.$userID == user.id).delete()
        return .noContent
    }

    authed.get("sessions") { request async throws -> [SessionInfo] in
        let user = try request.auth.require(AuthenticatedUser.self)
        let current = request.storage[CurrentSessionKey.self]
        return try await SessionRow.query(on: request.db)
            .filter(\.$userID == user.id)
            .sort(\.$lastUsedAt, .descending)
            .all()
            .map { session in
                SessionInfo(id: try session.requireID(), deviceLabel: session.deviceLabel,
                            createdAt: session.createdAt, lastUsedAt: session.lastUsedAt,
                            current: session.id == current)
            }
    }

    authed.delete("sessions", ":sessionID") { request async throws -> HTTPStatus in
        let user = try request.auth.require(AuthenticatedUser.self)
        let sessionID = try request.parameters.require("sessionID", as: UUID.self)
        // Someone else's session reads as missing, not forbidden.
        guard let session = try await SessionRow.query(on: request.db)
            .filter(\.$id == sessionID).filter(\.$userID == user.id).first() else {
            throw Abort(.notFound, reason: "no such session")
        }
        try await session.delete(on: request.db)
        return .noContent
    }

    authed.on(.POST, "email", "verify", body: small) { request async throws -> HTTPStatus in
        let body = try request.content.decode(CodeRequest.self)
        let user = try await request.currentUser()
        try await request.enforceRateLimit(.codeCheck, scope: "v2-verify", email: user.email)
        guard user.emailVerifiedAt == nil else { return .noContent }
        guard try await redeemEmailCode(for: try user.requireID(), purpose: .verify, typed: body.code,
                                        on: request.db, key: request.application.emailCodeKey) else {
            throw ServerError.badCode
        }
        user.emailVerifiedAt = Date()
        try await user.save(on: request.db)
        return .noContent
    }

    authed.post("email", "verify", "resend") { request async throws -> HTTPStatus in
        let user = try await request.currentUser()
        try await request.enforceRateLimit(.emailCode, scope: "v2-verify-resend", email: user.email)
        guard user.emailVerifiedAt == nil else { return .noContent }
        try await request.enforceRateLimit(.emailCode, key: "v2-verify-address", for: user.email)
        if let code = try await issueEmailCode(for: try user.requireID(), purpose: .verify,
                                               on: request.db, key: request.application.emailCodeKey) {
            let message = AccountEmail.verify(code: code)
            request.application.sendInBackground(to: user.email, subject: message.subject, text: message.text)
        }
        return .noContent
    }

    /// Changes the password with the current one, and signs every other device out.
    authed.on(.POST, "password", "change", body: small) { request async throws -> HTTPStatus in
        try await request.enforceRateLimit(.signIn, scope: "v2-change")
        let body = try request.content.decode(ChangePasswordRequest.self)
        let user = try await request.currentUser()
        // 403, not 401: the session is fine, only the password typed is wrong.
        // An app signs out on a 401, which would be the wrong thing here.
        guard (try? Bcrypt.verify(body.currentPassword, created: user.passwordHash)) == true else {
            throw Abort(.forbidden, reason: "the current password is wrong")
        }
        try AccountRules.checkPassword(body.newPassword)
        guard let current = request.storage[CurrentSessionKey.self] else { throw Abort(.unauthorized) }
        guard try await changePassword(of: try user.requireID(), session: current,
                                       to: try Bcrypt.hash(body.newPassword), on: request.db) else {
            throw Abort(.conflict, reason: "the password was just changed somewhere else. Sign in again.")
        }
        request.application.sendInBackground(to: user.email, subject: AccountEmail.passwordChanged.subject,
                                             text: AccountEmail.passwordChanged.text)
        return .noContent
    }
}

/// Holds a person's row until the transaction ends, by touching it. On
/// Postgres the touch takes the row's lock; on SQLite a write transaction
/// holds the whole database. So a password change and a reset take turns.
func holdAccount(_ userID: UUID, on database: any Database) async throws {
    guard let sql = database as? any SQLDatabase else {
        throw Abort(.internalServerError, reason: "accounts need a SQL database")
    }
    try await sql.update(UserRow.schema)
        .set("password_changed_at", to: SQLColumn("password_changed_at"))
        .where("id", .equal, SQLBind(userID))
        .run()
}

/// Sets a new password from a signed-in session, and signs every other device
/// out. False, and nothing changed, when the password changed after this
/// session began: a reset that landed while this request was on its way wins,
/// so whoever reset it keeps it.
func changePassword(of userID: UUID, session: UUID, to hash: String,
                    on database: any Database) async throws -> Bool {
    try await database.transaction { database in
        try await holdAccount(userID, on: database)
        guard let user = try await UserRow.find(userID, on: database),
              let current = try await SessionRow.find(session, on: database),
              current.userID == userID,
              SessionRules.sameStamp(current.credentialStamp, user.passwordChangedAt) else {
            return false
        }
        let changedAt = Date()
        user.passwordHash = hash
        user.passwordChangedAt = changedAt
        try await user.save(on: database)
        // This device stays signed in: its stamp moves with the password.
        current.credentialStamp = changedAt
        try await current.save(on: database)
        try await SessionRow.query(on: database)
            .filter(\.$userID == userID).filter(\.$id != session).delete()
        return true
    }
}

extension Request {
    /// The signed-in person's row. A session whose person was deleted reads as
    /// signed out.
    func currentUser() async throws -> UserRow {
        let user = try auth.require(AuthenticatedUser.self)
        guard let row = try await UserRow.find(user.id, on: db) else {
            throw Abort(.unauthorized)
        }
        return row
    }

    /// Limits one address, whoever is asking, so nobody can fill a person's
    /// inbox. Keyed by a hash of the address, so the limiter holds no addresses.
    /// A test address on a server with the test mailbox gets the tests'
    /// allowance, since a UI test suite signs in to its accounts many times.
    func enforceRateLimit(_ limit: RateLimiter.Limit, key scope: String, for email: String) async throws {
        let forTests = application.hasTestMailbox && TestMailbox.isTestAddress(email)
        let key = "\(forTests ? "test-" : "")\(scope):\(Data(SHA256.hash(data: Data(email.utf8))).hexString)"
        guard await application.rateLimiter.allow(key, limit: forTests ? limit.forTests : limit) else {
            throw Abort(.tooManyRequests, reason: "Too many attempts. Try again in a few minutes.")
        }
    }
}
