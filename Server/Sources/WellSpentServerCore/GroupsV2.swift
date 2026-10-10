import Foundation
import Crypto
import Fluent
import SQLKit
import Vapor
import WellSpentCrypto
import WellSpentModel

// Groups, members and invites for readable sync, under /api/v2.
//
// The `memberships` table is the one source of truth. There is no signed log to
// replay: the server decides who is in a group and at what level, and checks
// every change itself.

// MARK: - Wire types

struct CreateGroupRequest: Content {
    /// Made by the app, so a group can be used offline before it is ever sent.
    let id: UUID
    /// The key for statement fingerprints, when the app already has one: a
    /// group made before readable sync keeps the key its past imports used, or
    /// every bank line already imported would look new. Made here when absent.
    let importKey: Data?
}

struct GroupResponse: Content {
    let id: UUID
    let founderID: UUID
    /// The caller's own level, on the ladder in `AccessLevel`.
    let level: Int
    /// The key the app uses for statement fingerprints.
    let importKey: Data
    /// Records first stored at or below this sequence are hidden from the caller:
    /// 0 for "everything", the sequence at joining for "from now on".
    let historyFloor: Int
    let deleted: Bool
}

struct MemberResponse: Content {
    let userID: UUID
    let level: Int
}

struct ChangeLevelRequest: Content {
    let level: Int
}

struct CreateInviteV2Request: Content {
    let level: Int
    /// "all" or "fromNow".
    let historyAccess: String
    /// One to `InviteRules.maxDays`; `InviteRules.defaultDays` when left out.
    let expiresInDays: Int?
}

struct InviteCreatedResponse: Content {
    let id: UUID
    /// Shown once. Only its hash is stored, so a read of the database cannot
    /// accept an invite.
    let token: String
    let expiresAt: Date
}

struct InviteInfo: Content {
    let id: UUID
    let level: Int
    let historyAccess: String
    let expiresAt: Date
    let inviterUserID: UUID
}

struct InvitePreviewRequest: Content {
    let token: String
}

struct InvitePreview: Content {
    let groupID: UUID
    let level: Int
    let historyAccess: String
    let expiresAt: Date
}

struct AcceptInviteV2Request: Content {
    let token: String
}

// MARK: - Rules

extension MembershipRules.Refusal {
    /// The server's answer to a refusal. `founder` is the route's own words.
    func answer(founder: String) -> any Error {
        switch self {
        case .notGrantable: return Abort(.badRequest, reason: "that is not a level a member can be given")
        case .founder: return Abort(.forbidden, reason: founder)
        case .notAMember: return Abort(.notFound, reason: "they are not a member")
        case .needs(let level): return ServerError.insufficientLevel(needed: level)
        }
    }
}

enum InviteRules {
    static let defaultDays = 7
    static let maxDays = 30
    static let importKeyLength = 32
    static let noLongerValid = "that invite is no longer valid"

    /// No invite lasts longer than v2 allows. The old API took any expiry a
    /// client sent, so a row from it can claim years.
    static func outlivesLimit(_ expiresAt: Date, now: Date = Date()) -> Bool {
        expiresAt > now.addingTimeInterval(TimeInterval(maxDays) * 86_400)
    }
}

/// 32 random bytes as URL-safe base64, so the token can sit in a link as is.
func urlSafeToken() -> String {
    Data([UInt8].random(count: 32)).base64EncodedString()
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
}

func inviteTokenHash(_ token: String) -> Data {
    Data(SHA256.hash(data: Data(token.utf8)))
}

// MARK: - Lookups

/// The caller's membership, refused unless they hold `needed`. A group that
/// does not exist and one the caller is not in read the same, so nobody can
/// learn which groups exist.
func requireMembership(_ groupID: UUID, user: UUID, needed: AccessLevel, on database: any Database)
    async throws -> (GroupRow, MembershipRow) {
    guard let membership = try await MembershipRow.query(on: database)
        .filter(\.$groupID == groupID).filter(\.$userID == user).first(),
          let level = AccessLevel(rawValue: membership.level), level != .none,
          let group = try await GroupRow.find(groupID, on: database) else {
        throw ServerError.notAMember
    }
    guard level.allows(needed) else { throw ServerError.insufficientLevel(needed: needed) }
    return (group, membership)
}

func groupResponse(_ group: GroupRow, membership: MembershipRow) throws -> GroupResponse {
    GroupResponse(id: try group.requireID(), founderID: group.founderID, level: membership.level,
                  importKey: group.importKey ?? Data(), historyFloor: membership.joinedAtSequence,
                  deleted: group.deletedAt != nil)
}

// MARK: - Routes

func registerGroupRoutesV2(_ routes: any RoutesBuilder) throws {
    let small: HTTPBodyStreamStrategy = .collect(maxSize: "4kb")

    /// Anyone holding the link can see what it is for before joining. Asked
    /// in the body, not the path, so the token never lands in a request log.
    routes.on(.POST, "invites", "preview", body: small) { request async throws -> InvitePreview in
        try await request.enforceRateLimit(.inviteLookup, scope: "v2-invite-lookup")
        let token = try request.content.decode(InvitePreviewRequest.self).token
        guard let invite = try await InviteRow.query(on: request.db)
            .filter(\.$inviteHash == inviteTokenHash(token)).first(),
              invite.acceptedAt == nil else { throw ServerError.inviteNotFound }
        guard invite.expiresAt > Date() else { throw ServerError.inviteExpired }
        guard !InviteRules.outlivesLimit(invite.expiresAt) else {
            throw Abort(.gone, reason: InviteRules.noLongerValid)
        }
        return InvitePreview(groupID: invite.groupID, level: invite.level,
                             historyAccess: invite.historyAccess, expiresAt: invite.expiresAt)
    }

    let authed = routes.grouped(SessionAuthenticator(), AuthenticatedUser.guardMiddleware())

    /// Creates a group with the caller as its founder. Sending the same group
    /// again, after a lost reply, answers as the first time did.
    authed.on(.POST, "groups", body: small) { request async throws -> Response in
        let user = try request.auth.require(AuthenticatedUser.self)
        let body = try request.content.decode(CreateGroupRequest.self)
        if let key = body.importKey, key.count != InviteRules.importKeyLength {
            throw Abort(.badRequest, reason: "an import key is \(InviteRules.importKeyLength) bytes")
        }
        if let existing = try await GroupRow.find(body.id, on: request.db) {
            guard existing.founderID == user.id,
                  let membership = try await MembershipRow.query(on: request.db)
                    .filter(\.$groupID == body.id).filter(\.$userID == user.id).first() else {
                throw Abort(.conflict, reason: "that group already exists")
            }
            // A group made before readable sync has no key yet. Its founder's
            // app brings the one its past imports used. Set only when one is
            // sent, and only while none is set, in one statement, so two
            // devices sending at once cannot race and a device without the old
            // key cannot fix a random one for good.
            if let key = body.importKey, existing.importKey == nil {
                guard let sql = request.db as? any SQLDatabase else {
                    throw Abort(.internalServerError, reason: "groups need a SQL database")
                }
                try await sql.update(GroupRow.schema)
                    .set("import_key", to: SQLBind(key))
                    .where("id", .equal, SQLBind(body.id))
                    .where("import_key", .is, SQLLiteral.null)
                    .run()
            }
            guard let current = try await GroupRow.find(body.id, on: request.db) else { throw ServerError.notAMember }
            return try await groupResponse(current, membership: membership).encodeResponse(for: request)
        }
        // Record IDs are shared by every group, so a group may not take one a
        // record already has: its own record could then never be stored. Nor
        // an ID shaped like a member profile's, which anyone can work out from
        // a group and a person: the profile on it would be refused for good.
        guard !RecordID(body.id).isNameBased,
              try await SyncRecordRow.find(body.id, on: request.db) == nil else {
            throw Abort(.conflict, reason: "that ID is already used")
        }
        let group = GroupRow(id: body.id, founderID: user.id)
        group.importKey = body.importKey ?? Data([UInt8].random(count: InviteRules.importKeyLength))
        let membership = MembershipRow(groupID: body.id, userID: user.id,
                                       level: AccessLevel.superadmin.rawValue, joinedAtSequence: 0)
        try await request.db.transaction { database in
            try await group.create(on: database)
            try await membership.create(on: database)
        }
        return try await groupResponse(group, membership: membership)
            .encodeResponse(status: .created, for: request)
    }

    /// Every group the caller is in, deleted ones too, so a device can let go
    /// of them. A new device learns its groups from here.
    authed.get("groups") { request async throws -> [GroupResponse] in
        let user = try request.auth.require(AuthenticatedUser.self)
        let memberships = try await MembershipRow.query(on: request.db)
            .filter(\.$userID == user.id).filter(\.$level > AccessLevel.none.rawValue).all()
        var groups: [GroupResponse] = []
        for membership in memberships {
            guard let group = try await GroupRow.find(membership.groupID, on: request.db) else { continue }
            groups.append(try groupResponse(group, membership: membership))
        }
        return groups
    }

    let group = authed.grouped("groups", ":groupID")

    group.get("members") { request async throws -> [MemberResponse] in
        let user = try request.auth.require(AuthenticatedUser.self)
        let groupID = try request.parameters.require("groupID", as: UUID.self)
        _ = try await requireMembership(groupID, user: user.id, needed: .read, on: request.db)
        return try await MembershipRow.query(on: request.db)
            .filter(\.$groupID == groupID).filter(\.$level > AccessLevel.none.rawValue).all()
            .map { MemberResponse(userID: $0.userID, level: $0.level) }
    }

    group.on(.PATCH, "members", ":userID", body: small) { request async throws -> HTTPStatus in
        let user = try request.auth.require(AuthenticatedUser.self)
        let groupID = try request.parameters.require("groupID", as: UUID.self)
        let subject = try request.parameters.require("userID", as: UUID.self)
        guard let new = AccessLevel(rawValue: try request.content.decode(ChangeLevelRequest.self).level),
              MembershipRules.grantable.contains(new) else {
            throw Abort(.badRequest, reason: "that is not a level a member can be given")
        }
        let (group, mine) = try await requireMembership(groupID, user: user.id, needed: .manage, on: request.db)
        guard subject != group.founderID else {
            throw Abort(.forbidden, reason: "the founder's level cannot change")
        }
        guard let theirs = try await MembershipRow.query(on: request.db)
            .filter(\.$groupID == groupID).filter(\.$userID == subject).first(),
              let old = AccessLevel(rawValue: theirs.level), old != .none else {
            throw Abort(.notFound, reason: "they are not a member")
        }
        let myLevel = AccessLevel(rawValue: mine.level) ?? .none
        // The whole decision, from the one copy the apps use too.
        if let refusal = MembershipRules.changeLevel(from: old, to: new, ofFounder: subject == group.founderID,
                                                     holding: myLevel) {
            throw refusal.answer(founder: "the founder's level cannot change")
        }
        theirs.level = new.rawValue
        try await theirs.save(on: request.db)
        return .noContent
    }

    /// Removes a member, or, for the caller's own membership, leaves. The
    /// founder can do neither: their group is deleted instead.
    group.delete("members", ":userID") { request async throws -> HTTPStatus in
        let user = try request.auth.require(AuthenticatedUser.self)
        let groupID = try request.parameters.require("groupID", as: UUID.self)
        let subject = try request.parameters.require("userID", as: UUID.self)
        let (group, mine) = try await requireMembership(groupID, user: user.id, needed: .read, on: request.db)
        guard subject != group.founderID else {
            throw Abort(.forbidden, reason: "the founder cannot leave or be removed; delete the group instead")
        }
        if subject == user.id {
            try await mine.delete(on: request.db)
            return .noContent
        }
        guard let theirs = try await MembershipRow.query(on: request.db)
            .filter(\.$groupID == groupID).filter(\.$userID == subject).first(),
              let level = AccessLevel(rawValue: theirs.level), level != .none else {
            throw Abort(.notFound, reason: "they are not a member")
        }
        if let refusal = MembershipRules.remove(level, ofFounder: subject == group.founderID, isSelf: false,
                                                holding: AccessLevel(rawValue: mine.level) ?? .none) {
            throw refusal.answer(founder: "the founder cannot leave or be removed; delete the group instead")
        }
        try await theirs.delete(on: request.db)
        return .noContent
    }

    group.on(.POST, "invites", body: small) { request async throws -> Response in
        let user = try request.auth.require(AuthenticatedUser.self)
        let groupID = try request.parameters.require("groupID", as: UUID.self)
        let body = try request.content.decode(CreateInviteV2Request.self)
        guard let level = AccessLevel(rawValue: body.level), MembershipRules.grantable.contains(level) else {
            throw Abort(.badRequest, reason: "that is not a level a member can be given")
        }
        guard HistoryAccess(rawValue: body.historyAccess) != nil else {
            throw Abort(.badRequest, reason: "history must be \"all\" or \"fromNow\"")
        }
        let days = body.expiresInDays ?? InviteRules.defaultDays
        guard (1 ... InviteRules.maxDays).contains(days) else {
            throw Abort(.badRequest, reason: "an invite lasts 1 to \(InviteRules.maxDays) days")
        }
        let (group, mine) = try await requireMembership(groupID, user: user.id, needed: .manage, on: request.db)
        guard group.deletedAt == nil else { throw ServerError.notAMember }
        let myLevel = AccessLevel(rawValue: mine.level) ?? .none
        if let refusal = MembershipRules.invite(at: level, holding: myLevel) {
            throw refusal.answer(founder: "the founder cannot be invited")
        }
        let token = urlSafeToken()
        let expiresAt = Date().addingTimeInterval(TimeInterval(days) * 86_400)
        let invite = InviteRow(inviteHash: inviteTokenHash(token), groupID: groupID, inviterUserID: user.id,
                               level: level.rawValue, historyAccess: body.historyAccess, expiresAt: expiresAt)
        try await invite.create(on: request.db)
        return try await InviteCreatedResponse(id: try invite.requireID(), token: token, expiresAt: expiresAt)
            .encodeResponse(status: .created, for: request)
    }

    /// Invites not yet accepted and not expired. Managers see them all.
    group.get("invites") { request async throws -> [InviteInfo] in
        let user = try request.auth.require(AuthenticatedUser.self)
        let groupID = try request.parameters.require("groupID", as: UUID.self)
        _ = try await requireMembership(groupID, user: user.id, needed: .manage, on: request.db)
        return try await InviteRow.query(on: request.db)
            .filter(\.$groupID == groupID)
            .filter(\.$acceptedAt == nil)
            .filter(\.$expiresAt > Date())
            .all()
            .map { InviteInfo(id: try $0.requireID(), level: $0.level, historyAccess: $0.historyAccess,
                              expiresAt: $0.expiresAt, inviterUserID: $0.inviterUserID) }
    }

    /// Cancelled by whoever made it, or by any manager.
    group.delete("invites", ":inviteID") { request async throws -> HTTPStatus in
        let user = try request.auth.require(AuthenticatedUser.self)
        let groupID = try request.parameters.require("groupID", as: UUID.self)
        let inviteID = try request.parameters.require("inviteID", as: UUID.self)
        let (_, mine) = try await requireMembership(groupID, user: user.id, needed: .read, on: request.db)
        guard let invite = try await InviteRow.query(on: request.db)
            .filter(\.$id == inviteID).filter(\.$groupID == groupID).first() else {
            throw ServerError.inviteNotFound
        }
        guard invite.inviterUserID == user.id
              || (AccessLevel(rawValue: mine.level) ?? .none).allows(.manage) else {
            throw ServerError.insufficientLevel(needed: .manage)
        }
        try await invite.delete(on: request.db)
        return .noContent
    }

    /// Joins the group an invite is for. One invite adds one person, once:
    /// it is marked used by a statement that only succeeds while it is unused,
    /// and someone already in the group is refused without using it up.
    authed.on(.POST, "invites", "accept", body: small) { request async throws -> GroupResponse in
        let user = try request.auth.require(AuthenticatedUser.self)
        // An invite reaches a person through their address, so it is accepted
        // only by someone who has shown the address is theirs.
        guard try await request.currentUser().emailVerifiedAt != nil else {
            throw Abort(.forbidden, reason: "confirm your email address before joining a group")
        }
        let token = try request.content.decode(AcceptInviteV2Request.self).token
        guard let invite = try await InviteRow.query(on: request.db)
            .filter(\.$inviteHash == inviteTokenHash(token)).first() else {
            throw ServerError.inviteNotFound
        }
        guard invite.acceptedAt == nil else { throw ServerError.inviteAlreadyAccepted }
        guard invite.expiresAt > Date() else { throw ServerError.inviteExpired }
        guard !InviteRules.outlivesLimit(invite.expiresAt) else {
            throw Abort(.gone, reason: InviteRules.noLongerValid)
        }
        guard let group = try await GroupRow.find(invite.groupID, on: request.db),
              group.deletedAt == nil else { throw ServerError.inviteNotFound }
        let existing = try await MembershipRow.query(on: request.db)
            .filter(\.$groupID == invite.groupID).filter(\.$userID == user.id).first()
        if let existing, (AccessLevel(rawValue: existing.level) ?? .none) != .none {
            throw Abort(.conflict, reason: "you are already in that group")
        }
        // An invite speaks for whoever made it, as they are now, not as they
        // were. Removed, or no longer able to give that level, their invites
        // are void: a removed admin could otherwise let herself back in at Admin.
        guard let level = AccessLevel(rawValue: invite.level),
              let inviter = try await MembershipRow.query(on: request.db)
                .filter(\.$groupID == invite.groupID).filter(\.$userID == invite.inviterUserID).first(),
              let inviterLevel = AccessLevel(rawValue: inviter.level),
              MembershipRules.invite(at: level, holding: inviterLevel) == nil else {
            throw Abort(.gone, reason: InviteRules.noLongerValid)
        }
        // Nobody gives more history than they have: an "everything" invite from
        // a member who joined "from now on" starts where they did.
        let fromInvite = HistoryAccess(rawValue: invite.historyAccess) == .fromNow ? group.lastSeq : 0
        let floor = max(fromInvite, inviter.joinedAtSequence)
        let inviteID = try invite.requireID()

        let membership: MembershipRow = try await request.db.transaction { database in
            guard let sql = database as? any SQLDatabase else {
                throw Abort(.internalServerError, reason: "invites need a SQL database")
            }
            let taken = try await sql.update(InviteRow.schema)
                .set("accepted_at", to: SQLBind(Date()))
                .set("accepted_by_user_id", to: SQLBind(user.id))
                .where("id", .equal, SQLBind(inviteID))
                .where("accepted_at", .is, SQLLiteral.null)
                .returning("id")
                .first()
            guard taken != nil else { throw ServerError.inviteAlreadyAccepted }
            // A row left at "none" by an earlier removal is reused, so the
            // unique pair (group, person) still holds.
            if let existing { try await existing.delete(on: database) }
            let membership = MembershipRow(groupID: invite.groupID, userID: user.id,
                                           level: invite.level, joinedAtSequence: floor)
            try await membership.create(on: database)
            return membership
        }
        return try groupResponse(group, membership: membership)
    }
}
