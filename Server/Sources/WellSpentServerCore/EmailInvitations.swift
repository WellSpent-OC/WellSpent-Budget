import Foundation
import Crypto
import Fluent
import SQLKit
import Vapor
import WellSpentCrypto
import WellSpentModel

struct IncomingInvitationResponse: Content {
    let id: UUID
    let groupID: UUID
    let groupName: String
    let inviterName: String
    let inviteeName: String
    let level: Int
    let historyAccess: String
    let expiresAt: Date
}

enum EmailInvitationRules {
    static let perInviter = 20
    static let perNewInviter = 5
    static let perAddress = 5
    static let maxMailAttempts = 6

    static func name(_ raw: String?) throws -> String {
        let name = (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 50,
              !name.unicodeScalars.contains(where: {
                  $0.properties.generalCategory == .control || $0.properties.generalCategory == .format
              }) else { throw Abort(.badRequest, reason: "names must have 1 to 50 characters and no control characters") }
        return name
    }

    /// A separate purpose for each use of the existing server secret. The
    /// database keeps token hashes, never a link or an authentication code.
    static func token(_ id: UUID, purpose: String = "invitation", key: SymmetricKey) -> String {
        let message = Data("wellspent:\(purpose):v1:\(id.uuidString.lowercased())".utf8)
        return Data(HMAC<SHA256>.authenticationCode(for: message, using: key)).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func addressHash(_ address: String, key: SymmetricKey) -> String {
        Data(HMAC<SHA256>.authenticationCode(for: Data("wellspent:invite-email:v1:\(address)".utf8), using: key)).hexString
    }
}

/// All membership changes and sync pushes take this lock before reading the
/// group's current authority and sequence. SQLite takes a write lock; Postgres
/// takes the row lock. The same lock order is used for accept, remove and cancel.
func holdGroup(_ groupID: UUID, on database: any Database) async throws {
    guard let sql = database as? any SQLDatabase else { throw Abort(.internalServerError) }
    try await sql.update(GroupRow.schema).set("last_seq", to: SQLColumn("last_seq"))
        .where("id", .equal, SQLBind(groupID)).run()
}

func invitationIsPending(_ invite: InviteRow, now: Date = Date()) -> Bool {
    invite.acceptedAt == nil && invite.rejectedAt == nil && invite.cancelledAt == nil &&
        invite.closedAt == nil && invite.expiresAt > now && !InviteRules.outlivesLimit(invite.expiresAt, now: now)
}

/// Used by both acceptance paths and the inbox. A link never overrides the
/// recipient binding of an addressed invitation.
func usableInvitation(_ invite: InviteRow, for user: UserRow, on database: any Database)
    async throws -> (GroupRow, MembershipRow) {
    if let address = invite.inviteeEmail, address != (try AccountRules.normaliseEmail(user.email)) {
        throw ServerError.inviteNotFound
    }
    guard invite.acceptedAt == nil else { throw ServerError.inviteAlreadyAccepted }
    guard invite.rejectedAt == nil else { throw Abort(.conflict, reason: "that invitation was rejected") }
    guard invite.cancelledAt == nil, invite.closedAt == nil else { throw ServerError.inviteNotFound }
    guard invite.expiresAt > Date() else { throw ServerError.inviteExpired }
    guard let group = try await GroupRow.find(invite.groupID, on: database), group.deletedAt == nil else {
        throw ServerError.inviteNotFound
    }
    guard !InviteRules.outlivesLimit(invite.expiresAt), let level = AccessLevel(rawValue: invite.level),
          let inviter = try await MembershipRow.query(on: database)
            .filter(\.$groupID == invite.groupID).filter(\.$userID == invite.inviterUserID).first(),
          let inviterLevel = AccessLevel(rawValue: inviter.level),
          MembershipRules.invite(at: level, holding: inviterLevel) == nil else {
        throw Abort(.gone, reason: InviteRules.noLongerValid)
    }
    if let existing = try await MembershipRow.query(on: database)
        .filter(\.$groupID == invite.groupID).filter(\.$userID == user.requireID()).first(),
       existing.level > AccessLevel.none.rawValue {
        throw Abort(.conflict, reason: "you are already in that group")
    }
    return (group, inviter)
}

func invitationGroupName(_ groupID: UUID, on database: any Database) async throws -> String {
    guard let row = try await SyncRecordRow.find(groupID, on: database), !row.isDeleted,
          row.recordType == RecordType.groupMeta.rawValue,
          let group = try? RecordCodec.decoder.decode(BudgetGroup.self, from: Data(row.body.utf8)) else { return "" }
    return group.name
}

/// A waiting invitation must not survive a join followed by removal and let
/// the removed person back in. A fresh invitation has its own consent step.
func closeAddressedInvitations(groupID: UUID, userID: UUID, on database: any Database) async throws {
    guard let user = try await UserRow.find(userID, on: database),
          let address = try? AccountRules.normaliseEmail(user.email) else { return }
    try await InviteRow.query(on: database).filter(\.$groupID == groupID)
        .filter(\.$inviteeEmail == address).filter(\.$acceptedAt == nil)
        .filter(\.$rejectedAt == nil).filter(\.$cancelledAt == nil).filter(\.$closedAt == nil)
        .set(\.$closedAt, to: Date()).update()
}

func createInvitation(_ body: CreateInviteV2Request, groupID: UUID, user: AuthenticatedUser,
                      request: Request) async throws -> InviteCreatedResponse {
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
    let email = try body.email.map(AccountRules.normaliseEmail)
    let inviteeName = email == nil ? nil : try EmailInvitationRules.name(body.inviteeName)
    let inviterName = email == nil ? nil : try EmailInvitationRules.name(body.inviterName)
    let account = try await request.currentUser()
    if email != nil, account.emailVerifiedAt == nil {
        throw Abort(.forbidden, reason: "confirm your email address before inviting by email")
    }
    let id = UUID()
    let token = email == nil ? urlSafeToken() : EmailInvitationRules.token(id, key: request.application.emailCodeKey)
    let now = Date()
    let expiresAt = now.addingTimeInterval(TimeInterval(days) * 86_400)
    try await request.db.transaction { database in
        // The global email lock comes before the group lock everywhere it is
        // needed. Counts and inserts cannot race, including across groups.
        if email != nil {
            guard let sql = database as? any SQLDatabase else { throw Abort(.internalServerError) }
            try await sql.raw("UPDATE invitation_send_guard SET id = id WHERE id = 1").run()
        }
        try await holdGroup(groupID, on: database)
        let (group, mine) = try await requireMembership(groupID, user: user.id, needed: .manage, on: database)
        guard group.deletedAt == nil else { throw ServerError.notAMember }
        if let refusal = MembershipRules.invite(at: level, holding: AccessLevel(rawValue: mine.level) ?? .none) {
            throw refusal.answer(founder: "the founder cannot be invited")
        }
        if let email {
            if try await InviteRow.query(on: database).filter(\.$groupID == groupID)
                .filter(\.$inviteeEmail == email).filter(\.$acceptedAt == nil)
                .filter(\.$rejectedAt == nil).filter(\.$cancelledAt == nil)
                .filter(\.$closedAt == nil)
                .filter(\.$expiresAt > now).first() != nil {
                throw Abort(.conflict, reason: "that address already has an invitation waiting in this group")
            }
            let since = now.addingTimeInterval(-86_400)
            let sentBy = try await InviteRow.query(on: database).filter(\.$inviterUserID == user.id)
                .filter(\.$inviteeEmail != nil).filter(\.$createdAt > since).count()
            let sentTo = try await InviteRow.query(on: database).filter(\.$inviteeEmail == email)
                .filter(\.$createdAt > since).count()
            let limit = now.timeIntervalSince(account.emailVerifiedAt ?? now) < 3 * 86_400
                ? EmailInvitationRules.perNewInviter : EmailInvitationRules.perInviter
            // UI suites reuse their disposable accounts across many groups.
            // The established mailbox allowance applies only between two
            // reserved test addresses, and never on the live server.
            let forTests = request.application.hasTestMailbox &&
                request.application.storage[ServerEnvironmentKey.self] != .live &&
                TestMailbox.isTestAddress(account.email) && TestMailbox.isTestAddress(email)
            let multiplier = forTests ? 60 : 1
            guard sentBy < limit * multiplier, sentTo < EmailInvitationRules.perAddress * multiplier else {
                throw Abort(.tooManyRequests, reason: "too many invitations today; try again tomorrow")
            }
            // A new request supersedes the old rejection in People, while its
            // terminal answer stays recorded and its old link stays refused.
            try await InviteRow.query(on: database).filter(\.$groupID == groupID)
                .filter(\.$inviteeEmail == email).filter(\.$rejectedAt != nil).filter(\.$closedAt == nil)
                .set(\.$closedAt, to: now).update()
        }
        let invite = InviteRow(id: id, inviteHash: inviteTokenHash(token), groupID: groupID,
                               inviterUserID: user.id, level: level.rawValue,
                               historyAccess: body.historyAccess, expiresAt: expiresAt)
        invite.inviteeEmail = email
        invite.inviteeName = inviteeName
        invite.inviterName = inviterName
        invite.createdAt = now
        if email != nil {
            invite.mailAttempts = 0
            invite.mailNextAttemptAt = now
            invite.mailStopHash = inviteTokenHash(EmailInvitationRules.token(id, purpose: "stop-invite-email",
                                                                           key: request.application.emailCodeKey))
        }
        try await invite.create(on: database)
    }
    if email != nil { await request.application.invitationDelivery.wake(request.application) }
    return InviteCreatedResponse(id: id, token: email == nil ? token : nil, expiresAt: expiresAt)
}

/// Both link and inbox acceptance use the same transaction, with every
/// authorization check repeated after the group lock is held.
func acceptInvitation(id: UUID, userID: UUID, on database: any Database) async throws -> GroupResponse {
    guard let found = try await InviteRow.find(id, on: database) else { throw ServerError.inviteNotFound }
    return try await database.transaction { database in
        try await holdGroup(found.groupID, on: database)
        guard let user = try await UserRow.find(userID, on: database), user.emailVerifiedAt != nil else {
            throw Abort(.forbidden, reason: "confirm your email address before joining a group")
        }
        guard let invite = try await InviteRow.find(id, on: database) else { throw ServerError.inviteNotFound }
        let (group, inviter) = try await usableInvitation(invite, for: user, on: database)
        let fromInvite = HistoryAccess(rawValue: invite.historyAccess) == .fromNow ? group.lastSeq : 0
        let floor = max(fromInvite, inviter.joinedAtSequence)
        guard let sql = database as? any SQLDatabase else { throw Abort(.internalServerError) }
        let taken = try await sql.update(InviteRow.schema)
            .set("accepted_at", to: SQLBind(Date())).set("accepted_by_user_id", to: SQLBind(userID))
            .where("id", .equal, SQLBind(id)).where("accepted_at", .is, SQLLiteral.null)
            .where("rejected_at", .is, SQLLiteral.null).where("cancelled_at", .is, SQLLiteral.null)
            .where("closed_at", .is, SQLLiteral.null).where("expires_at", .greaterThan, SQLBind(Date()))
            .returning("id").first()
        guard taken != nil else { throw Abort(.conflict, reason: "that invitation is no longer pending") }
        // With the group lock held, a second invitation cannot insert a
        // duplicate membership, and removals cannot race this check.
        try await MembershipRow.query(on: database).filter(\.$groupID == invite.groupID)
            .filter(\.$userID == userID).delete()
        let membership = MembershipRow(groupID: invite.groupID, userID: userID,
                                       level: invite.level, joinedAtSequence: floor)
        try await membership.create(on: database)
        if let name = invite.inviteeName {
            try await storeInvitedProfile(name, userID: userID, group: group, on: database)
        }
        try await closeAddressedInvitations(groupID: invite.groupID, userID: userID, on: database)
        return try groupResponse(group, membership: membership)
    }
}

/// View members cannot push records. Store the promised name during acceptance
/// so every level appears in People, without exposing the account's email.
private func storeInvitedProfile(_ name: String, userID: UUID, group: GroupRow,
                                 on database: any Database) async throws {
    let groupID = try group.requireID()
    let profile = MemberProfile(groupID: GroupID(groupID), userID: UserID(userID), displayName: name)
    let body = String(decoding: try RecordCodec.encoder.encode(profile), as: UTF8.self)
    group.lastSeq += 1
    group.maxLamport += 1
    if let old = try await SyncRecordRow.find(profile.id.uuid, on: database) {
        old.body = body
        old.lamport = group.maxLamport
        old.clientID = userID
        old.updatedByUserID = userID
        old.isDeleted = false
        old.serverSeq = group.lastSeq
        try await old.save(on: database)
    } else {
        try await SyncRecordRow(id: profile.id.uuid, groupID: groupID, budgetID: nil,
                                recordType: RecordType.memberProfile.rawValue, body: body,
                                createdBy: userID, clientID: userID, lamport: group.maxLamport,
                                isDeleted: false, serverSeq: group.lastSeq).create(on: database)
    }
    try await group.save(on: database)
}

func registerIncomingInvitationRoutes(_ authed: any RoutesBuilder) {
    authed.get("invitations") { request async throws -> [IncomingInvitationResponse] in
        let user = try await request.currentUser()
        guard user.emailVerifiedAt != nil else {
            throw Abort(.forbidden, reason: "confirm your email address to see invitations")
        }
        let address = try AccountRules.normaliseEmail(user.email)
        let invites = try await InviteRow.query(on: request.db).filter(\.$inviteeEmail == address)
            .filter(\.$acceptedAt == nil).filter(\.$rejectedAt == nil).filter(\.$cancelledAt == nil)
            .filter(\.$closedAt == nil).filter(\.$expiresAt > Date()).sort(\.$createdAt, .descending).all()
        var result: [IncomingInvitationResponse] = []
        for invite in invites {
            do { _ = try await usableInvitation(invite, for: user, on: request.db) }
            catch is AbortError { continue }
            result.append(try await IncomingInvitationResponse(id: invite.requireID(), groupID: invite.groupID,
                groupName: invitationGroupName(invite.groupID, on: request.db),
                inviterName: invite.inviterName ?? "Someone", inviteeName: invite.inviteeName ?? "",
                level: invite.level, historyAccess: invite.historyAccess, expiresAt: invite.expiresAt))
        }
        return result
    }
    authed.post("invitations", ":inviteID", "accept") { request async throws -> GroupResponse in
        let id = try request.parameters.require("inviteID", as: UUID.self)
        let user = try await request.currentUser()
        guard user.emailVerifiedAt != nil else {
            throw Abort(.forbidden, reason: "confirm your email address before joining a group")
        }
        guard let invite = try await InviteRow.find(id, on: request.db),
              invite.inviteeEmail == (try AccountRules.normaliseEmail(user.email)) else { throw ServerError.inviteNotFound }
        return try await acceptInvitation(id: id, userID: user.requireID(), on: request.db)
    }
    authed.post("invitations", ":inviteID", "reject") { request async throws -> HTTPStatus in
        let id = try request.parameters.require("inviteID", as: UUID.self)
        let user = try await request.currentUser()
        guard user.emailVerifiedAt != nil else {
            throw Abort(.forbidden, reason: "confirm your email address before answering an invitation")
        }
        guard let found = try await InviteRow.find(id, on: request.db),
              found.inviteeEmail == (try AccountRules.normaliseEmail(user.email)) else { throw ServerError.inviteNotFound }
        return try await request.db.transaction { database in
            try await holdGroup(found.groupID, on: database)
            guard let invite = try await InviteRow.find(id, on: database) else { throw ServerError.inviteNotFound }
            _ = try await usableInvitation(invite, for: user, on: database)
            guard let sql = database as? any SQLDatabase else { throw Abort(.internalServerError) }
            let changed = try await sql.update(InviteRow.schema).set("rejected_at", to: SQLBind(Date()))
                .where("id", .equal, SQLBind(id)).where("accepted_at", .is, SQLLiteral.null)
                .where("rejected_at", .is, SQLLiteral.null).where("cancelled_at", .is, SQLLiteral.null)
                .where("closed_at", .is, SQLLiteral.null).returning("id").first()
            guard changed != nil else { throw Abort(.conflict, reason: "that invitation is no longer pending") }
            return .noContent
        }
    }
}
