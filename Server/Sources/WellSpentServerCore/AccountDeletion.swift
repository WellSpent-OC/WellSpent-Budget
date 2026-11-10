import Foundation
import Fluent
import SQLKit
import Vapor
import WellSpentCrypto
import WellSpentModel

// Deleting an account, from inside the app (Apple 5.1.1(v), and the terms).
//
// The account and everything only it can see go: its sign-ins, its keys, its
// plan, and every group no one else is in, with all of that group's records. A
// shared group stays for the people still in it, because its budgets are the
// group's. When the person deleting it founded the group, the group passes to
// the next manager, or else the next member, who then pays for it too.
//
// A paid plan from the website is canceled through Paddle first. If Paddle
// refuses, nothing is deleted. A plan from Apple can't be canceled by us; the
// app says so before it asks.

struct DeleteAccountRequest: Content {
    let password: String
}

/// Cancels a Paddle subscription. Set once Paddle's keys are on the server;
/// until then, an account with a Paddle plan can't be deleted from the app.
protocol PaddleCanceling: Sendable {
    func cancel(subscriptionID: String) async throws
}

struct PaddleCancelerKey: StorageKey {
    typealias Value = any PaddleCanceling
}

extension Application {
    var paddleCanceler: (any PaddleCanceling)? {
        get { storage[PaddleCancelerKey.self] }
        set { storage[PaddleCancelerKey.self] = newValue }
    }
}

enum AccountDeletion {
    /// Deletes the account, in one database transaction.
    static func delete(_ userID: UUID, on db: any Database) async throws {
        try await db.transaction { db in
            let memberships = try await MembershipRow.query(on: db).filter(\.$userID == userID).all()
            for membership in memberships {
                try await leave(membership.groupID, user: userID, on: db)
            }
            // Groups they founded and left before, with no one in them now.
            for group in try await GroupRow.query(on: db).filter(\.$founderID == userID).all() {
                guard let id = group.id else { continue }
                try await deleteGroup(id, on: db)
            }
            // Taken over by them, paid by no one now: the founder pays again.
            try await GroupRow.query(on: db).filter(\.$paidByUserID == userID)
                .set(\.$paidByUserID, to: nil).update()

            // Invitations they sent and nobody answered stop working.
            try await InviteRow.query(on: db).filter(\.$inviterUserID == userID)
                .filter(\.$acceptedAt == nil).filter(\.$cancelledAt == nil)
                .set(\.$cancelledAt, to: Date()).update()
            try await InviteRow.query(on: db).filter(\.$acceptedByUserID == userID)
                .set(\.$acceptedByUserID, to: nil).update()

            try await SessionRow.query(on: db).filter(\.$userID == userID).delete()
            try await TokenRow.query(on: db).filter(\.$userID == userID).delete()
            try await EscrowRow.query(on: db).filter(\.$userID == userID).delete()
            try await EmailCodeRow.query(on: db).filter(\.$userID == userID).delete()
            try await WrappedKeyRow.query(on: db).filter(\.$recipientUserID == userID).delete()
            try await OpenHouseRow.query(on: db).filter(\.$userID == userID).delete()
            try await PlanRow.query(on: db).filter(\.$userID == userID).delete()
            try await UserRow.query(on: db).filter(\.$id == userID).delete()
        }
    }

    /// Takes them out of one group: the whole group when they're the last one
    /// in it, otherwise only them, passing the group on if they founded it.
    private static func leave(_ groupID: UUID, user: UUID, on db: any Database) async throws {
        try await holdGroup(groupID, on: db)
        guard let group = try await GroupRow.find(groupID, on: db) else { return }
        let others = try await MembershipRow.query(on: db).filter(\.$groupID == groupID)
            .filter(\.$userID != user).all()
        guard let next = successor(among: others) else {
            try await deleteGroup(groupID, on: db)
            return
        }
        if group.founderID == user {
            group.founderID = next.userID
            next.level = AccessLevel.superadmin.rawValue
            try await next.save(on: db)
        }
        if group.paidByUserID == user { group.paidByUserID = nil }

        // Their name in the group goes with them. The others' devices learn it
        // as a deleted profile with no name, at the group's next sequence and
        // a Lamport value above any they hold, so every device takes it.
        let profile = RecordID.memberProfile(group: GroupID(groupID), user: UserID(user)).uuid
        if let row = try await SyncRecordRow.find(profile, on: db), !row.isDeleted,
           var record = try? RecordCodec.decoder.decode(MemberProfile.self, from: Data(row.body.utf8)) {
            record.displayName = ""
            record.isDeleted = true
            record.updatedAt = Date()
            group.lastSeq += 1
            group.maxLamport = max(group.maxLamport, row.lamport) + 1
            row.body = String(decoding: try RecordCodec.encoder.encode(record), as: UTF8.self)
            row.isDeleted = true
            row.lamport = group.maxLamport
            row.serverSeq = group.lastSeq
            try await row.save(on: db)
        }
        try await group.save(on: db)
        try await MembershipRow.query(on: db).filter(\.$groupID == groupID).filter(\.$userID == user).delete()
    }

    /// Who the group passes to: the highest level left, then whoever joined first.
    static func successor(among members: [MembershipRow]) -> MembershipRow? {
        members.min { first, second in
            if first.level != second.level { return first.level > second.level }
            return (first.joinedAtSequence, first.createdAt ?? .distantPast, first.id?.uuidString ?? "")
                < (second.joinedAtSequence, second.createdAt ?? .distantPast, second.id?.uuidString ?? "")
        }
    }

    /// A group with no one left in it, and everything in it.
    private static func deleteGroup(_ groupID: UUID, on db: any Database) async throws {
        try await SyncRecordRow.query(on: db).filter(\.$groupID == groupID).delete()
        try await RecordRow.query(on: db).filter(\.$groupID == groupID).delete()
        try await WrappedKeyRow.query(on: db).filter(\.$groupID == groupID).delete()
        try await MembershipEntryRow.query(on: db).filter(\.$groupID == groupID).delete()
        try await InviteRow.query(on: db).filter(\.$groupID == groupID).delete()
        try await WTCredentialRow.query(on: db).filter(\.$groupID == groupID).delete()
        try await WTMessageRow.query(on: db).filter(\.$groupID == groupID).delete()
        try await MembershipRow.query(on: db).filter(\.$groupID == groupID).delete()
        try await GroupRow.query(on: db).filter(\.$id == groupID).delete()
    }
}

func registerAccountDeletionRoutes(_ routes: any RoutesBuilder) {
    let authed = routes.grouped(SessionAuthenticator(), AuthenticatedUser.guardMiddleware())

    authed.on(.POST, "account", "delete", body: .collect(maxSize: "4kb")) { request async throws -> HTTPStatus in
        try await request.enforceRateLimit(.signIn, scope: "v2-delete")
        let body = try request.content.decode(DeleteAccountRequest.self)
        let user = try await request.currentUser()
        let userID = try user.requireID()
        // 403, not 401: the session is fine, only the password typed is wrong,
        // and an app signs out on a 401.
        guard (try? Bcrypt.verify(body.password, created: user.passwordHash)) == true else {
            throw Abort(.forbidden, reason: "the password is wrong")
        }
        if let plan = try await PlanRow.query(on: request.db).filter(\.$userID == userID).first(),
           plan.source == "paddle", plan.state != "canceled", let subscription = plan.storeID {
            do {
                guard let canceler = request.application.paddleCanceler else {
                    throw Abort(.serviceUnavailable)
                }
                try await canceler.cancel(subscriptionID: subscription)
            } catch {
                request.logger.warning("account delete: Paddle refused the cancel: \(String(reflecting: error))")
                throw PlanRefusal.pick("paddleCancelFailed", status: 409)
            }
        }
        try await AccountDeletion.delete(userID, on: request.db)
        return .noContent
    }
}
