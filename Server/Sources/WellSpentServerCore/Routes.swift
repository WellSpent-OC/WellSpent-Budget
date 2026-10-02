import Foundation
import Fluent
import Vapor
import Crypto
import WellSpentCrypto

// MARK: - Wire types

struct SignUpRequest: Content {
    let email: String
    let password: String
    let identitySigning: Data
    let identityKEM: Data
    /// Optional, but the app sends it. Without an escrow blob, losing the device
    /// means losing the data with no way back.
    let escrowNonce: Data?
    let escrowCiphertext: Data?
}

struct AuthResponse: Content {
    let userID: UUID
    let token: String
    let expiresOn: Date
}

struct SignInRequest: Content {
    let email: String
    let password: String
}

struct PushRequest: Content {
    let envelopes: [RecordEnvelope]
}

struct PushResponse: Content {
    let accepted: [UUID]
    /// Per record, so one bad row never takes the batch down with it.
    let rejected: [String: String]
    let serverSeq: Int
}

struct PullResponse: Content {
    let envelopes: [RecordEnvelope]
    let serverSeq: Int
    let hasMore: Bool
}

struct AppendLogRequest: Content {
    let entry: MembershipLogEntry
    /// Sent together with the entry when the action forces a rotation, so the new
    /// keys and the entry that requires them land in one transaction. A half
    /// applied rotation leaves records nobody can read.
    let wrappedKeys: [WrappedKey]
}

struct CreateInviteRequest: Content {
    let inviteHash: Data
    let groupID: UUID
    let level: Int
    let historyAccess: String
    let expiresAt: Date
}

struct AcceptInviteRequest: Content {
    let inviteHash: Data
    let acceptance: Data
}

/// What an inviter sees of their own invites. `acceptance` is still sealed: only
/// the inviter, holding the secret from the link, can open it.
struct PendingInviteResponse: Content {
    let inviteHash: Data
    let level: Int
    let historyAccess: String
    let expiresAt: Date
    let acceptance: Data?
}

struct UploadKeysRequest: Content {
    let wrappedKeys: [WrappedKey]
}

// MARK: - Errors

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
        return ["status": "ok"]
    }

    let api = app.grouped("api", "v1")
    try registerAccountRoutes(api)

    let authed = api.grouped(TokenAuthenticator())
    try registerSessionRoutes(authed)
    try registerSyncRoutes(authed)
    try registerSharingRoutes(authed)
}

// MARK: Accounts

private func registerAccountRoutes(_ routes: any RoutesBuilder) throws {
    routes.post("signup") { request async throws -> AuthResponse in
        try await request.enforceRateLimit(.signUp, scope: "signup")

        let body = try request.content.decode(SignUpRequest.self)
        let email = body.email.lowercased()

        // A floor, not a policy. The account password protects ciphertext the
        // server cannot read anyway, so its job is to keep a stranger out of the
        // sync stream rather than to protect the data itself. The twelve-word
        // recovery code is what actually guards that.
        guard body.password.count >= 10 else { throw ServerError.passwordTooShort }
        guard email.contains("@"), email.count >= 3 else { throw ServerError.emailInvalid }

        let existing = try await UserRow.query(on: request.db).filter(\.$email == email).first()
        guard existing == nil else { throw ServerError.emailTaken }

        let user = UserRow(id: UUID(), email: email,
                           passwordHash: try Bcrypt.hash(body.password),
                           identitySigning: body.identitySigning,
                           identityKEM: body.identityKEM)
        try await user.save(on: request.db)

        if let nonce = body.escrowNonce, let ciphertext = body.escrowCiphertext {
            try await EscrowRow(userID: try user.requireID(), nonce: nonce,
                                ciphertext: ciphertext).save(on: request.db)
        }

        return try await issueToken(for: user, on: request.db)
    }

    routes.post("signin") { request async throws -> AuthResponse in
        // Bcrypt makes each guess expensive for us as well as the attacker, so an
        // unthrottled sign-in is both a password oracle and a way to exhaust the
        // box's CPU.
        try await request.enforceRateLimit(.signIn, scope: "signin")

        let body = try request.content.decode(SignInRequest.self)
        guard let user = try await UserRow.query(on: request.db)
            .filter(\.$email == body.email.lowercased()).first() else {
            // Same error and the same work either way, so the timing does not say
            // whether the address exists. The old API answered "user not found",
            // which was a free list of who had accounts.
            _ = try? Bcrypt.verify(body.password, created: "$2b$12$" + String(repeating: "x", count: 53))
            throw ServerError.badCredentials
        }
        guard (try? Bcrypt.verify(body.password, created: user.passwordHash)) == true else {
            throw ServerError.badCredentials
        }
        return try await issueToken(for: user, on: request.db)
    }

    /// The escrow blob, fetched during recovery. Useless without the twelve words.
    routes.get("escrow", ":email") { request async throws -> Response in
        guard let email = request.parameters.get("email")?.lowercased(),
              let user = try await UserRow.query(on: request.db).filter(\.$email == email).first(),
              let escrow = try await EscrowRow.query(on: request.db)
                .filter(\.$userID == user.requireID()).first() else {
            throw ServerError.inviteNotFound
        }
        struct Payload: Content { let nonce: Data; let ciphertext: Data }
        return try await Payload(nonce: escrow.nonce, ciphertext: escrow.ciphertext)
            .encodeResponse(for: request)
    }
}

/// Tokens are stored as a digest and never in the clear, for the same reason
/// invites are: a read of this database must not hand over live sessions.
///
/// A plain SHA-256 is right and bcrypt would be wrong. The input is 32 bytes of
/// machine randomness, not something a person chose, so there is nothing to slow
/// a guess down for.
func tokenDigest(_ value: String) -> String {
    Data(SHA256.hash(data: Data(value.utf8))).hexString
}

private func issueToken(for user: UserRow, on db: any Database) async throws -> AuthResponse {
    let value = [UInt8].random(count: 32).base64String()
    let expires = Date().addingTimeInterval(30 * 86_400)
    let token = TokenRow(userID: try user.requireID(),
                         valueHash: tokenDigest(value), expiresOn: expires)
    try await token.save(on: db)
    return AuthResponse(userID: try user.requireID(), token: value, expiresOn: expires)
}

// MARK: Sessions

private func registerSessionRoutes(_ routes: any RoutesBuilder) throws {
    /// Revokes the token that made this request.
    ///
    /// Without it a lost device holds a live session for thirty days and nobody
    /// can cancel it, which is the only lever a person actually wants in that
    /// moment.
    routes.post("signout") { request async throws -> HTTPStatus in
        _ = try request.auth.require(AuthenticatedUser.self)
        guard let bearer = request.headers.bearerAuthorization else { return .noContent }
        try await TokenRow.query(on: request.db)
            .filter(\.$valueHash == tokenDigest(bearer.token))
            .delete()
        return .noContent
    }
}

// MARK: Authentication

struct AuthenticatedUser: Authenticatable {
    let id: UUID
}

struct TokenAuthenticator: AsyncBearerAuthenticator {
    func authenticate(bearer: BearerAuthorization, for request: Request) async throws {
        guard let token = try await TokenRow.query(on: request.db)
            .filter(\.$valueHash == tokenDigest(bearer.token)).first() else { return }
        guard token.expiresOn > Date() else {
            try await token.delete(on: request.db)
            return
        }
        request.auth.login(AuthenticatedUser(id: token.userID))
    }
}

// MARK: Sync

private func registerSyncRoutes(_ routes: any RoutesBuilder) throws {
    let group = routes.grouped("groups", ":groupID")

    group.post("push") { request async throws -> PushResponse in
        let user = try request.auth.require(AuthenticatedUser.self)
        let groupID = try request.parameters.require("groupID", as: UUID.self)
        let body = try request.content.decode(PushRequest.self)

        let state = try await membershipState(groupID: groupID, on: request.db)
        guard state.allows(UserID(user.id), .write) else {
            throw ServerError.insufficientLevel(needed: .write)
        }

        // The sequence is read and then incremented, so two pushes to one group
        // can choose the same number, and the pull cursor depends on it being
        // unique. Both engines refuse that, in different places and at different
        // times: SQLite turns away the second writer with "database is locked",
        // and Postgres lets both in and then refuses the loser at the unique
        // index. Either way it is transient and deserves another go, on a fresh
        // transaction, because a Postgres transaction that has hit an error
        // cannot run another statement.
        //
        // Anything that is not the database complaining is a bug and surfaces
        // immediately rather than being tried five times.
        for attempt in 0 ..< 5 {
            do {
                return try await request.db.transaction { db in
                    try await applyPush(body.envelopes, groupID: groupID,
                                        userID: user.id, state: state, on: db)
                }
            } catch {
                // DatabaseError is a mixin on the driver's own error types and
                // does not inherit Error, so it cannot be a catch pattern.
                guard error is any DatabaseError, attempt < 4 else { throw error }
                // A lock needs time to clear, so back off rather than spin.
                try? await Task.sleep(for: .milliseconds(20 << attempt))
            }
        }
        throw Abort(.conflict, reason: "too many concurrent pushes to this group")
    }

    group.get("pull") { request async throws -> PullResponse in
        let user = try request.auth.require(AuthenticatedUser.self)
        let groupID = try request.parameters.require("groupID", as: UUID.self)
        let since = (try? request.query.get(Int.self, at: "since")) ?? 0
        // Clamped from below as well as above. A negative limit reached
        // `rows.prefix(limit)`, which traps, so one hand-made request from any
        // account stopped the whole server.
        let requested = (try? request.query.get(Int.self, at: "limit")) ?? 200
        let limit = min(max(requested, 1), 500)

        let state = try await membershipState(groupID: groupID, on: request.db)
        guard state.allows(UserID(user.id), .read) else { throw ServerError.notAMember }

        // Someone added with history access "from now" must not be served records
        // from before they joined, even though they could not read them anyway.
        let floor = try await joinSequence(groupID: groupID, userID: user.id, on: request.db)

        let rows = try await RecordRow.query(on: request.db)
            .filter(\.$groupID == groupID)
            .filter(\.$serverSeq > since)
            .sort(\.$serverSeq)
            .limit(limit + 1)
            .all()

        let page = Array(rows.prefix(limit)).filter { $0.serverSeq >= floor }
        let decoder = JSONDecoder()
        return PullResponse(
            envelopes: try page.map { try decoder.decode(RecordEnvelope.self, from: $0.envelope) },
            serverSeq: page.last?.serverSeq ?? since,
            hasMore: rows.count > limit
        )
    }

    group.get("log") { request async throws -> [MembershipLogEntry] in
        // The log is the social graph in full: who shares money with whom, at
        // what level, from when. It was readable by anyone who knew a group
        // UUID. `membershipState` throws for an unknown group, so a guess gets
        // the same answer as a group you are simply not in.
        let user = try request.auth.require(AuthenticatedUser.self)
        let groupID = try request.parameters.require("groupID", as: UUID.self)

        let state = try await membershipState(groupID: groupID, on: request.db)
        guard state.allows(UserID(user.id), .read) else { throw ServerError.notAMember }

        let since = (try? request.query.get(Int.self, at: "since")) ?? 0
        let rows = try await MembershipEntryRow.query(on: request.db)
            .filter(\.$groupID == groupID)
            .filter(\.$sequence >= since)
            .sort(\.$sequence)
            .all()
        let decoder = JSONDecoder()
        return try rows.map { try decoder.decode(MembershipLogEntry.self, from: $0.entry) }
    }

    group.get("keys") { request async throws -> [WrappedKey] in
        let user = try request.auth.require(AuthenticatedUser.self)
        let groupID = try request.parameters.require("groupID", as: UUID.self)

        let state = try await membershipState(groupID: groupID, on: request.db)
        guard state.allows(UserID(user.id), .read) else { throw ServerError.notAMember }

        let rows = try await WrappedKeyRow.query(on: request.db)
            .filter(\.$groupID == groupID)
            .group(.or) { $0.filter(\.$recipientUserID == user.id).filter(\.$recipientUserID == nil) }
            .all()
        let decoder = JSONDecoder()
        return try rows.map { try decoder.decode(WrappedKey.self, from: $0.payload) }
    }
}

// MARK: Sharing

private func registerSharingRoutes(_ routes: any RoutesBuilder) throws {
    /// Append to the access history.
    ///
    /// The server verifies the chain before storing, so a stolen auth token cannot
    /// rewrite who had what level. This is the one place where being a dumb store
    /// is not enough.
    routes.post("groups", ":groupID", "log") { request async throws -> HTTPStatus in
        let user = try request.auth.require(AuthenticatedUser.self)
        let groupID = try request.parameters.require("groupID", as: UUID.self)
        let body = try request.content.decode(AppendLogRequest.self)

        let known = try await storedLog(groupID: groupID, on: request.db)

        // The founding entry creates the group. Anything else must be authored by
        // the caller and must extend the chain we already hold.
        if known.isEmpty {
            guard body.entry.action == .found, body.entry.authorUserID.uuid == user.id else {
                throw ServerError.chainRejected("first entry must found the group")
            }
            // A group's ID is also its record's ID, and an app that holds
            // something under that ID ignores whatever else arrives on it. A
            // group founded on someone's profile ID, or on a record's, hid
            // that record on the Mac of everyone who answered its link. The
            // app picks random IDs, so only a modified one gets here.
            guard try await claims(on: groupID, db: request.db).areFree(forGroup: groupID) else {
                throw ServerError.chainRejected("that group ID is already in use")
            }
            try await GroupRow(id: groupID, founderID: user.id).save(on: request.db)
        } else {
            guard body.entry.authorUserID.uuid == user.id else {
                throw ServerError.chainRejected("entry is not authored by the caller")
            }
        }

        let combined = known + [body.entry]
        let state: MembershipState
        do {
            state = try MembershipLog.replay(combined, scope: .group(GroupID(groupID)))
        } catch {
            throw ServerError.chainRejected(String(describing: error))
        }

        // Keys put on someone's ID must be the ones they signed up with. A
        // manager could put keys she made on a person before they joined, or
        // before their first sync, and lock them out of the group: the log
        // keeps a person's keys once they sign with them.
        if [.add, .changeLevel].contains(body.entry.action), let keys = body.entry.subjectKeys {
            guard let person = try await UserRow.find(body.entry.subjectUserID.uuid, on: request.db),
                  person.identitySigning == keys.signing, person.identityKEM == keys.kem else {
                throw ServerError.chainRejected("those are not that person's keys")
            }
        }

        // Keys travel with an entry when a manager adds someone or starts a new
        // epoch. Any member could attach them to an entry of her own, such as
        // registering her device, and every member's app took them in place of
        // the keys it held.
        if !body.wrappedKeys.isEmpty {
            guard state.allows(UserID(user.id), .manage) else {
                throw ServerError.insufficientLevel(needed: .manage)
            }
            if let why = try await refusal(forKeys: body.wrappedKeys,
                                           groupID: groupID, callerID: user.id, state: state,
                                           log: combined, requestEntry: body.entry,
                                           on: request.db) {
                throw Abort(.badRequest, reason: why)
            }
        }

        // Entry, keys and epoch in one transaction. A rotation that half applies
        // leaves records that nobody can open.
        try await request.db.transaction { db in
            try await MembershipEntryRow(groupID: groupID, sequence: Int(body.entry.sequence),
                                         entry: try JSONEncoder().encode(body.entry)).save(on: db)

            for key in body.wrappedKeys {
                try await storeKey(key, groupID: groupID, on: db)
            }
            // Someone this entry leaves out of the group loses the group keys
            // stored for them, so a junk one cannot outlast them and take the
            // real one's place when they are invited back.
            if let leaving = MembershipLog.groupKeysDropped(by: body.entry, state: state) {
                try await WrappedKeyRow.query(on: db)
                    .filter(\.$groupID == groupID)
                    .filter(\.$scopeKind == "group")
                    .filter(\.$recipientUserID == leaving.uuid)
                    .delete()
            }

            try await MembershipRow.query(on: db).filter(\.$groupID == groupID).delete()
            for (userID, level) in state.levels where level > .none {
                try await MembershipRow(groupID: groupID, userID: userID.uuid, level: level.rawValue,
                                        joinedAtSequence: 0).save(on: db)
            }

            if let group = try await GroupRow.find(groupID, on: db) {
                group.epoch = Int(state.epoch.value)
                try await group.save(on: db)
            }
        }

        return .created
    }

    routes.post("invites") { request async throws -> HTTPStatus in
        let user = try request.auth.require(AuthenticatedUser.self)
        let body = try request.content.decode(CreateInviteRequest.self)

        let state = try await membershipState(groupID: body.groupID, on: request.db)
        guard state.allows(UserID(user.id), .manage) else {
            throw ServerError.insufficientLevel(needed: .manage)
        }

        try await InviteRow(inviteHash: body.inviteHash, groupID: body.groupID,
                            inviterUserID: user.id, level: body.level,
                            historyAccess: body.historyAccess,
                            expiresAt: body.expiresAt).save(on: request.db)
        return .created
    }

    /// A group's open invites, for whoever may invite to it. This is how the
    /// inviter's app collects an answer and finishes adding the person.
    routes.get("groups", ":groupID", "invites") { request async throws -> [PendingInviteResponse] in
        let user = try request.auth.require(AuthenticatedUser.self)
        let groupID = try request.parameters.require("groupID", as: UUID.self)
        let state = try await membershipState(groupID: groupID, on: request.db)
        guard state.allows(UserID(user.id), .manage) else {
            throw ServerError.insufficientLevel(needed: .manage)
        }
        return try await InviteRow.query(on: request.db)
            .filter(\.$groupID == groupID).all()
            .map { PendingInviteResponse(inviteHash: $0.inviteHash, level: $0.level,
                                         historyAccess: $0.historyAccess,
                                         expiresAt: $0.expiresAt, acceptance: $0.acceptance) }
    }

    /// Cancelled, expired, or done with. Whoever made it, or anyone who may
    /// invite to the group.
    routes.delete("invites", ":hash") { request async throws -> HTTPStatus in
        let user = try request.auth.require(AuthenticatedUser.self)
        guard let hash = Data(hexString: try request.parameters.require("hash")),
              let invite = try await InviteRow.query(on: request.db)
                .filter(\.$inviteHash == hash).first() else {
            throw ServerError.inviteNotFound
        }
        if invite.inviterUserID != user.id {
            let state = try await membershipState(groupID: invite.groupID, on: request.db)
            guard state.allows(UserID(user.id), .manage) else {
                throw ServerError.insufficientLevel(needed: .manage)
            }
        }
        try await invite.delete(on: request.db)
        return .noContent
    }

    /// Budget keys, sealed under the group key, for a budget made in a group that
    /// is already shared. Only a manager can add a budget, so only a manager can
    /// publish its key. Only that kind of wrap is accepted here: keys sealed to a
    /// person go through the membership log, with the entry that entitles them.
    routes.post("groups", ":groupID", "keys") { request async throws -> HTTPStatus in
        let user = try request.auth.require(AuthenticatedUser.self)
        let groupID = try request.parameters.require("groupID", as: UUID.self)
        let state = try await membershipState(groupID: groupID, on: request.db)
        guard state.allows(UserID(user.id), .manage) else {
            throw ServerError.insufficientLevel(needed: .manage)
        }
        let body = try request.content.decode(UploadKeysRequest.self)
        if let why = try await refusal(forKeys: body.wrappedKeys,
                                       groupID: groupID, callerID: user.id, state: state,
                                       log: try await storedLog(groupID: groupID, on: request.db),
                                       requestEntry: nil, on: request.db) {
            throw Abort(.badRequest, reason: why)
        }
        try await request.db.transaction { db in
            for key in body.wrappedKeys {
                try await storeKey(key, groupID: groupID, on: db)
            }
        }
        return .created
    }

    /// Anyone holding the link can look the invite up, because the lookup key is
    /// derived from a secret only they have.
    routes.get("invites", ":hash") { request async throws -> Response in
        try await request.enforceRateLimit(.inviteLookup, scope: "invite")

        let hex = try request.parameters.require("hash")
        guard let hash = Data(hexString: hex),
              let invite = try await InviteRow.query(on: request.db)
                .filter(\.$inviteHash == hash).first() else {
            throw ServerError.inviteNotFound
        }
        guard invite.expiresAt > Date() else { throw ServerError.inviteExpired }
        guard let inviter = try await UserRow.find(invite.inviterUserID, on: request.db) else {
            throw ServerError.inviteNotFound
        }

        struct Payload: Content {
            let groupID: UUID
            let level: Int
            let historyAccess: String
            let inviterUserID: UUID
            let inviterSigning: Data
            let inviterKEM: Data
            let expiresAt: Date
        }
        return try await Payload(
            groupID: invite.groupID, level: invite.level, historyAccess: invite.historyAccess,
            inviterUserID: invite.inviterUserID, inviterSigning: inviter.identitySigning,
            inviterKEM: inviter.identityKEM, expiresAt: invite.expiresAt
        ).encodeResponse(for: request)
    }

    /// The sealed acceptance is stored as-is. The server cannot open it, which is
    /// exactly why it cannot answer an invite in the recipient's place.
    routes.post("invites", "accept") { request async throws -> HTTPStatus in
        // Ordered first so an unknown hash is cheap to refuse.
        try await request.enforceRateLimit(.inviteLookup, scope: "invite-accept")

        let body = try request.content.decode(AcceptInviteRequest.self)
        guard let invite = try await InviteRow.query(on: request.db)
            .filter(\.$inviteHash == body.inviteHash).first() else {
            throw ServerError.inviteNotFound
        }
        guard invite.expiresAt > Date() else { throw ServerError.inviteExpired }
        // Once only. This was overwritable by anyone holding the hash, as often
        // as they liked, and what it destroys is the sealed acceptance the
        // inviter is waiting on.
        guard invite.acceptance == nil else { throw ServerError.inviteAlreadyAccepted }

        invite.acceptance = body.acceptance
        invite.acceptedAt = Date()
        try await invite.save(on: request.db)
        return .ok
    }
}

// MARK: - Helpers

func storedLog(groupID: UUID, on db: any Database) async throws -> [MembershipLogEntry] {
    let rows = try await MembershipEntryRow.query(on: db)
        .filter(\.$groupID == groupID).sort(\.$sequence).all()
    let decoder = JSONDecoder()
    return try rows.map { try decoder.decode(MembershipLogEntry.self, from: $0.entry) }
}

// MARK: Keys and IDs

/// Why wrapped keys may not be stored in a group, or nil when they may. The
/// caller has already checked that the sender may manage the group. The rules
/// themselves are `WrappedKey.refusal`, shared with the in-memory server.
func refusal(forKeys keys: [WrappedKey], groupID: UUID, callerID: UUID,
             state: MembershipState, log: [MembershipLogEntry], requestEntry: MembershipLogEntry?,
             on db: any Database) async throws -> String? {
    let decoder = JSONDecoder()
    for key in keys {
        var claimed: IDClaims?
        var holds = true
        if case .budget(let budget) = key.scope {
            claimed = try await claims(on: budget.uuid, db: db)
            let stored = try await WrappedKeyRow.query(on: db)
                .filter(\.$groupID == groupID)
                .filter(\.$scopeKind == "group")
                .filter(\.$scopeID == groupID)
                .filter(\.$epoch == Int(key.epoch.value))
                .filter(\.$recipientUserID == callerID)
                .all()
                .map { try decoder.decode(WrappedKey.self, from: $0.payload) }
            holds = MembershipLog.holdsGroupKey(UserID(callerID), of: GroupID(groupID), at: key.epoch,
                                                log: log, requestEntry: requestEntry,
                                                sentNow: keys, stored: stored)
        }
        if let why = key.refusal(in: GroupID(groupID), with: requestEntry, log: log,
                                 sender: UserID(callerID), state: state, claims: claimed,
                                 senderHoldsGroupKey: holds) {
            return why
        }
    }
    return nil
}

/// Stores a key unless one is already stored for the same scope, epoch and
/// recipient. The first one stays, so every member's app holds the same one.
/// Another, from a manager whose rotation lost a race or from one who means
/// harm, was handed out next to it in no particular order, and each app kept
/// whichever it opened last.
func storeKey(_ key: WrappedKey, groupID: UUID, on db: any Database) async throws {
    let (kind, scopeID) = key.scope.serverParts
    var existing = WrappedKeyRow.query(on: db)
        .filter(\.$groupID == groupID)
        .filter(\.$scopeKind == kind)
        .filter(\.$scopeID == scopeID)
        .filter(\.$epoch == Int(key.epoch.value))
    if let recipient = key.recipientUserID?.uuid {
        existing = existing.filter(\.$recipientUserID == recipient)
    } else {
        existing = existing.filter(\.$recipientUserID == nil)
    }
    guard try await existing.first() == nil else { return }
    try await WrappedKeyRow(
        groupID: groupID, scopeKind: kind, scopeID: scopeID,
        epoch: Int(key.epoch.value), recipientUserID: key.recipientUserID?.uuid,
        payload: try JSONEncoder().encode(key)
    ).save(on: db)
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

func membershipState(groupID: UUID, on db: any Database) async throws -> MembershipState {
    let log = try await storedLog(groupID: groupID, on: db)
    guard !log.isEmpty else { throw ServerError.notAMember }
    do {
        return try MembershipLog.replay(log, scope: .group(GroupID(groupID)))
    } catch {
        throw ServerError.chainRejected(String(describing: error))
    }
}

/// The body of a push, in one transaction so the sequence it allocates cannot be
/// half applied.
///
/// Moved out of the handler unchanged except for the database handle, so that the
/// retry above can run it again on a fresh transaction.
private func applyPush(_ envelopes: [RecordEnvelope], groupID: UUID, userID: UUID,
                       state: MembershipState, on db: any Database) async throws -> PushResponse {
    var accepted: [UUID] = []
    var rejected: [String: String] = [:]
    var sequence = try await nextSequence(groupID: groupID, on: db)
    // Read once, before any of this push is stored, so a push of many records
    // can raise it by one lead at most, not one lead per record.
    let group = try await GroupRow.find(groupID, on: db)
    let highestBefore = UInt64(max(0, group?.maxLamport ?? 0))
    var highest = highestBefore

    for envelope in envelopes {
        // Judged one at a time. The old API used `break` inside this loop, so
        // one bad row left the rest of the batch silently unprocessed.
        guard envelope.groupID.uuid == groupID else {
            rejected[envelope.recordID.uuid.uuidString] = "record is not in this group"
            continue
        }
        guard envelope.authorUserID.uuid == userID else {
            rejected[envelope.recordID.uuid.uuidString] = "author does not match the caller"
            continue
        }
        guard let registration = state.device(envelope.authorDeviceID, of: envelope.authorUserID),
              registration.userID.uuid == userID,
              let signing = try? registration.signingKey,
              envelope.verifySignature(byDeviceKey: signing) else {
            rejected[envelope.recordID.uuid.uuidString] = "signature does not verify"
            continue
        }
        // The group's own record uses the group's ID, and nothing else may.
        // Without this, a record of another type on that ID, or a group record
        // pushed through some other group, could take the group's record over
        // and get round the rules below.
        guard (envelope.recordType == .groupMeta) == (envelope.recordID.uuid == groupID) else {
            rejected[envelope.recordID.uuid.uuidString] = "record ID does not match its type"
            continue
        }
        // Deleting the group deletes it for every member, so it takes more than
        // write. The type and the delete flag travel in the clear, which is
        // what lets the server judge this without reading the record.
        if envelope.recordType == .groupMeta, envelope.isDeleted,
           !state.mayDeleteGroup(UserID(userID)) {
            rejected[envelope.recordID.uuid.uuidString] = "only the founder or an admin can delete the group"
            continue
        }
        // Renaming the group renames it for every member, so it takes a
        // manager, as budgets do. Add is for transactions.
        if envelope.recordType == .groupMeta, !envelope.isDeleted,
           !state.allows(UserID(userID), .manage) {
            rejected[envelope.recordID.uuid.uuidString] = "only a manager can change the group"
            continue
        }
        // A budget is made, changed and deleted by a manager. Write is for
        // transactions, and deleting a budget deletes it for every member.
        if envelope.recordType == .budget, !state.allows(UserID(userID), .manage) {
            rejected[envelope.recordID.uuid.uuidString] = "only a manager can change a budget"
            continue
        }
        // A member profile's ID is worked out from the group and the person,
        // so anyone can work out someone else's before they join. Rows are
        // found by ID in every group, so a record taken there first, of any
        // type and in any group, kept their name out for good. Each profile
        // must sit on its sender's own ID, and no other record on an ID
        // shaped like one.
        let profileIDIsWrong = envelope.recordType == .memberProfile
            ? envelope.recordID != .memberProfile(group: envelope.groupID, user: envelope.authorUserID)
            : envelope.recordID.isNameBased
        if profileIDIsWrong {
            rejected[envelope.recordID.uuid.uuidString] = "that ID belongs to a member profile"
            continue
        }
        // A Lamport value at or above the ceiling is refused. Above Int.max,
        // converting it stopped the server process for every user, and any
        // account could send one to a group of its own. Just below, it left
        // every app that pulled it no room on its clock, and their next save
        // crashed. The ceiling is well under Int.max, so the conversion holds.
        guard envelope.lamport < RecordEnvelope.lamportCeiling else {
            rejected[envelope.recordID.uuid.uuidString] = RecordEnvelope.lamportTooLargeRefusal
            continue
        }
        // Below the ceiling, a value just under it still left every Mac that
        // pulled it no room to save in the group. An honest value is never
        // this far ahead of the group; `lamportLead` says why.
        guard envelope.lamport <= highestBefore + RecordEnvelope.lamportLead else {
            rejected[envelope.recordID.uuid.uuidString] = RecordEnvelope.lamportTooFarAheadRefusal
            continue
        }
        let lamport = Int(envelope.lamport)

        let encoded = try JSONEncoder().encode(envelope)
        let existing = try await RecordRow.find(envelope.recordID.uuid, on: db)
        if let existing {
            // Rows are found by ID alone, so the one found must be this record:
            // the same group and the same type. Otherwise an envelope could
            // overwrite a record it does not describe.
            guard existing.groupID == groupID, existing.recordType == envelope.recordType.rawValue else {
                rejected[envelope.recordID.uuid.uuidString] = "another record already has this ID"
                continue
            }
            // The version stored here, sent again by the device that wrote it.
            // The usual cause is a reply lost on the way back: the app cannot
            // tell its push was taken, so it sends the row again. The tie rule
            // below would compare the device with itself and refuse it, and
            // the app would send it on every sync. It is already stored, so it
            // is taken and nothing changes. The ciphertext is not compared,
            // because the app seals every send afresh with a new nonce.
            // The person and the device together: two people can each
            // register one device ID as their own. Who wrote the stored
            // version is read from its envelope. The author column was not
            // updated when a version was replaced before this check read it,
            // so on older rows it can name whoever first pushed the record.
            let storedAuthor = (try? JSONDecoder().decode(RecordEnvelope.self, from: existing.envelope))?
                .authorUserID.uuid ?? existing.authorUserID
            if existing.lamport == lamport,
               existing.authorDeviceID == envelope.authorDeviceID.uuid,
               storedAuthor == envelope.authorUserID.uuid,
               existing.isDeleted == envelope.isDeleted {
                accepted.append(envelope.recordID.uuid)
                continue
            }
            // Last write wins, decided the same way on every client and here,
            // except that a group's delete is final.
            guard envelope.replaces(lamport: UInt64(existing.lamport),
                                    device: DeviceID(existing.authorDeviceID),
                                    isDeleted: existing.isDeleted,
                                    author: UserID(storedAuthor)) else {
                let reopens = envelope.recordType == .groupMeta && existing.isDeleted && !envelope.isDeleted
                rejected[envelope.recordID.uuid.uuidString] = reopens
                    ? "the group has been deleted"
                    : RecordEnvelope.olderVersionRefusal
                continue
            }
            sequence += 1
            existing.serverSeq = sequence
            existing.lamport = lamport
            existing.isDeleted = envelope.isDeleted
            existing.envelope = encoded
            existing.authorDeviceID = envelope.authorDeviceID.uuid
            existing.authorUserID = userID
            try await existing.save(on: db)
        } else {
            guard try await claims(on: envelope.recordID.uuid, db: db)
                .areFree(forRecordOf: envelope.recordType, in: groupID, id: envelope.recordID.uuid) else {
                rejected[envelope.recordID.uuid.uuidString] = "another record already has this ID"
                continue
            }
            sequence += 1
            try await RecordRow(
                id: envelope.recordID.uuid, groupID: groupID,
                budgetID: envelope.budgetID?.uuid, recordType: envelope.recordType.rawValue,
                serverSeq: sequence, lamport: lamport,
                authorUserID: userID, authorDeviceID: envelope.authorDeviceID.uuid,
                isDeleted: envelope.isDeleted, envelope: encoded
            ).save(on: db)
        }
        highest = max(highest, envelope.lamport)
        accepted.append(envelope.recordID.uuid)
    }

    // Raised, never lowered. Two pushes that change one record at the same
    // moment can both get here, and the second may hold the lower value.
    if highest > highestBefore {
        try await GroupRow.query(on: db)
            .filter(\.$id == groupID)
            .filter(\.$maxLamport < Int(highest))
            .set(\.$maxLamport, to: Int(highest))
            .update()
    }
    return PushResponse(accepted: accepted, rejected: rejected, serverSeq: sequence)
}

private func nextSequence(groupID: UUID, on db: any Database) async throws -> Int {
    let highest = try await RecordRow.query(on: db)
        .filter(\.$groupID == groupID).sort(\.$serverSeq, .descending).first()
    return highest?.serverSeq ?? 0
}

private func joinSequence(groupID: UUID, userID: UUID, on db: any Database) async throws -> Int {
    let row = try await MembershipRow.query(on: db)
        .filter(\.$groupID == groupID).filter(\.$userID == userID).first()
    return row?.joinedAtSequence ?? 0
}

extension KeyScope {
    var serverParts: (kind: String, id: UUID) {
        switch self {
        case .group(let id): return ("group", id.uuid)
        case .budget(let id): return ("budget", id.uuid)
        }
    }
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
