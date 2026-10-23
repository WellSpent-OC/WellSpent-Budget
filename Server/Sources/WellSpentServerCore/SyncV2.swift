import Foundation
import Fluent
import SQLKit
import Vapor
import WellSpentCrypto
import WellSpentModel

// Push and pull of readable records, under /api/v2.
//
// The server reads each record and enforces the rules every app used to check
// for itself after decrypting: who owns a transaction, who may rename a group
// or change a budget, and that a record is the one it claims to be, in the
// group and budget it was sent to. Last write wins, decided the same way the
// apps decide it.

// MARK: - Wire types

struct SyncRecordV2: Content {
    let id: UUID
    /// A `RecordType` name.
    let type: String
    /// The budget the record belongs to; a budget names itself. Nil for records
    /// that belong to the whole group.
    let budgetID: UUID?
    let lamport: UInt64
    /// The writing device. Breaks ties between equal Lamport values.
    let clientID: UUID
    let isDeleted: Bool
    /// The record as JSON, in `RecordCodec`'s encoding.
    let body: String
    /// Filled in on pull, ignored on push: the server decides these.
    var createdBy: UUID?
    var updatedBy: UUID?
    var serverSeq: Int?
}

struct PushV2Request: Content {
    let records: [SyncRecordV2]
}

struct PushV2Response: Content {
    let accepted: [UUID]
    /// Per record, so one bad record never takes the batch down with it.
    let rejected: [String: String]
    let serverSeq: Int
}

struct PullV2Response: Content {
    let records: [SyncRecordV2]
    /// Where to pull from next.
    let serverSeq: Int
    let hasMore: Bool
}

// MARK: - Rules

enum SyncRulesV2 {
    static let maxRecordsPerPush = 500
    static let maxPullPage = 500
    /// One record's JSON. A receipt holds metadata only, so this is generous.
    static let maxBodyBytes = 64 * 1024

    /// Records every member sees whatever their history: the group, its
    /// budgets and who is in it. A "from now on" member needs these to make
    /// sense of anything.
    static let alwaysVisible: [String] = [RecordType.groupMeta.rawValue, RecordType.budget.rawValue,
                                          RecordType.memberProfile.rawValue]

    /// Records that belong to whoever first stored them: someone at Add may
    /// change only their own, a manager anyone's.
    static let owned: Set<RecordType> = [.transaction, .receipt, .statement]

    static let groupDeletedRefusal = "the group has been deleted"
}

/// The IDs inside a record, which must match where it was sent.
private struct ReadableBinding {
    let id: UUID
    let group: GroupID
    let budget: BudgetID?
    /// For a member profile, whose it is.
    let profileUser: UserID?

    init?(_ body: Data, type: RecordType) {
        let decoder = RecordCodec.decoder
        switch type {
        case .groupMeta:
            guard let value = try? decoder.decode(BudgetGroup.self, from: body) else { return nil }
            (id, group, budget, profileUser) = (value.id.uuid, value.id, nil, nil)
        case .budget:
            guard let value = try? decoder.decode(Budget.self, from: body) else { return nil }
            (id, group, budget, profileUser) = (value.id.uuid, value.groupID, value.id, nil)
        case .transaction:
            guard let value = try? decoder.decode(Transaction.self, from: body) else { return nil }
            (id, group, budget, profileUser) = (value.id.uuid, value.groupID, value.budgetID, nil)
        case .receipt:
            guard let value = try? decoder.decode(Receipt.self, from: body) else { return nil }
            (id, group, budget, profileUser) = (value.id.uuid, value.groupID, value.budgetID, nil)
        case .statement:
            guard let value = try? decoder.decode(ImportedStatement.self, from: body) else { return nil }
            (id, group, budget, profileUser) = (value.id.uuid, value.groupID, nil, nil)
        case .memberProfile:
            guard let value = try? decoder.decode(MemberProfile.self, from: body) else { return nil }
            (id, group, budget, profileUser) = (value.id.uuid, value.groupID, nil, value.userID)
        default:
            return nil
        }
    }
}

/// Whether an incoming version replaces the stored one: the rule every app
/// uses, so the server and every device pick the same winner.
///
/// Deleting a group is final: a delete replaces a live version whatever its
/// Lamport value, and a live version never replaces a delete. Otherwise the
/// higher Lamport value wins, then the higher device ID, then the higher
/// author ID.
func replacesV2(type: RecordType, lamport: UInt64, client: UUID, isDeleted: Bool, author: UUID,
                stored: SyncRecordRow) -> Bool {
    if type == .groupMeta, isDeleted != stored.isDeleted { return isDeleted }
    if Int(lamport) != stored.lamport { return Int(lamport) > stored.lamport }
    if client != stored.clientID { return client.uuidString > stored.clientID.uuidString }
    guard author != stored.updatedByUserID else { return false }
    return author.uuidString > stored.updatedByUserID.uuidString
}

// MARK: - Routes

func registerSyncRoutesV2(_ routes: any RoutesBuilder) throws {
    let authed = routes.grouped(SessionAuthenticator(), AuthenticatedUser.guardMiddleware())
    let group = authed.grouped("groups", ":groupID")

    group.on(.POST, "push", body: .collect(maxSize: "16mb")) { request async throws -> PushV2Response in
        let user = try request.auth.require(AuthenticatedUser.self)
        let groupID = try request.parameters.require("groupID", as: UUID.self)
        let body = try request.content.decode(PushV2Request.self)
        guard body.records.count <= SyncRulesV2.maxRecordsPerPush else {
            throw Abort(.payloadTooLarge, reason: "at most \(SyncRulesV2.maxRecordsPerPush) records per push")
        }
        return try await request.db.transaction { database in
            try await applyPushV2(body.records, groupID: groupID, user: user.id, on: database)
        }
    }

    group.get("pull") { request async throws -> PullV2Response in
        let user = try request.auth.require(AuthenticatedUser.self)
        let groupID = try request.parameters.require("groupID", as: UUID.self)
        let since = max(0, (try? request.query.get(Int.self, at: "since")) ?? 0)
        let limit = min(max(1, (try? request.query.get(Int.self, at: "limit")) ?? SyncRulesV2.maxPullPage),
                        SyncRulesV2.maxPullPage)
        // Removed members are refused at once. A deleted group still answers,
        // so every device learns it was deleted.
        let (group, membership) = try await requireMembership(groupID, user: user.id, needed: .read, on: request.db)

        // The history floor is applied in the query, before the page limit.
        // Applied after, a page whose records were all hidden would leave the
        // cursor where it was, and the app would ask for it forever.
        let rows = try await SyncRecordRow.query(on: request.db)
            .filter(\.$groupID == groupID)
            .filter(\.$serverSeq > since)
            .group(.or) { visible in
                visible.filter(\.$recordType ~~ SyncRulesV2.alwaysVisible)
                visible.filter(\.$firstSeq > membership.joinedAtSequence)
            }
            .sort(\.$serverSeq, .ascending)
            .limit(limit + 1)
            .all()
        let hasMore = rows.count > limit
        let page = Array(rows.prefix(limit))
        // With nothing more to see, jump to the group's latest sequence, past
        // any records this member does not see. Never behind the last record
        // handed over: the group was read before the records, so a push that
        // landed in between can put records past the sequence read, and a
        // cursor behind them would hand them over again.
        let lastHandedOver = page.last?.serverSeq ?? since
        let next = hasMore ? lastHandedOver : max(since, group.lastSeq, lastHandedOver)
        return PullV2Response(records: try page.map(wire), serverSeq: next, hasMore: hasMore)
    }
}

private func wire(_ row: SyncRecordRow) throws -> SyncRecordV2 {
    SyncRecordV2(id: try row.requireID(), type: row.recordType, budgetID: row.budgetID,
                 lamport: UInt64(row.lamport), clientID: row.clientID, isDeleted: row.isDeleted,
                 body: row.body, createdBy: row.createdByUserID, updatedBy: row.updatedByUserID,
                 serverSeq: row.serverSeq)
}

/// Judges and stores one push, in one database transaction.
///
/// The transaction starts by touching the group's row, which holds it until
/// commit. So pushes to one group take turns, and sequence numbers become
/// visible in order: a device pulling never skips a lower number that was
/// still being written.
private func applyPushV2(_ records: [SyncRecordV2], groupID: UUID, user: UUID,
                         on database: any Database) async throws -> PushV2Response {
    guard let sql = database as? any SQLDatabase else {
        throw Abort(.internalServerError, reason: "sync needs a SQL database")
    }
    try await sql.update(GroupRow.schema)
        .set("last_seq", to: SQLColumn("last_seq"))
        .where("id", .equal, SQLBind(groupID))
        .run()
    // Membership edits use this lock too. Re-read authority after waiting,
    // so an in-flight push cannot write with a removed member's old level.
    let (group, membership) = try await requireMembership(groupID, user: user, needed: .write, on: database)
    let level = AccessLevel(rawValue: membership.level) ?? .none

    var accepted: [UUID] = []
    var rejected: [String: String] = [:]
    var sequence = group.lastSeq
    // Judged against the highest value before this push, so one push of many
    // records can raise it by one lead at most, not one per record.
    let highestBefore = UInt64(max(0, group.maxLamport))
    var highest = highestBefore
    var deletesGroup = false
    let isFounderOrAdmin = group.founderID == user || level.allows(.admin)

    for record in records {
        let key = record.id.uuidString
        func refuse(_ reason: String) { rejected[key] = reason }

        let type = RecordType(rawValue: record.type)
        guard type.isKnown else { refuse("unknown record type"); continue }
        guard record.body.utf8.count <= SyncRulesV2.maxBodyBytes else {
            refuse("the record is too large"); continue
        }
        // What is stored must be what the record says it is, where it was sent.
        guard let inside = ReadableBinding(Data(record.body.utf8), type: type),
              inside.id == record.id, inside.group.uuid == groupID,
              inside.budget?.uuid == record.budgetID else {
            refuse("the record does not match where it was sent"); continue
        }
        // The group's own record uses the group's ID, and nothing else may.
        guard (type == .groupMeta) == (record.id == groupID) else {
            refuse("record ID does not match its type"); continue
        }
        // A member profile sits on its owner's own ID, worked out from the
        // group and the person; no other record may use an ID shaped like one.
        if type == .memberProfile {
            guard inside.profileUser?.uuid == user,
                  RecordID(record.id) == RecordID.memberProfile(group: GroupID(groupID), user: UserID(user)) else {
                refuse("that ID belongs to a member profile"); continue
            }
        } else if RecordID(record.id).isNameBased {
            refuse("that ID belongs to a member profile"); continue
        }
        guard record.lamport < RecordEnvelope.lamportCeiling else {
            refuse(RecordEnvelope.lamportTooLargeRefusal); continue
        }
        guard record.lamport <= highestBefore + RecordEnvelope.lamportLead else {
            refuse(RecordEnvelope.lamportTooFarAheadRefusal); continue
        }

        let existing = try await SyncRecordRow.find(record.id, on: database)
        // Nor may a new record take another group's ID, which that group's own
        // record would then never be stored under. Only a new one: a record
        // already stored keeps its ID, whatever was founded on it since.
        if existing == nil, type != .groupMeta, try await GroupRow.find(record.id, on: database) != nil {
            refuse("record ID does not match its type"); continue
        }
        if let existing {
            // Records are found by ID alone, so the one found must be this
            // record: the same group and the same type.
            guard existing.groupID == groupID, existing.recordType == type.rawValue else {
                refuse("another record already has this ID"); continue
            }
            // The version stored here, sent again by the device that wrote it,
            // usually after a reply was lost. Already stored, so taken.
            if existing.lamport == Int(record.lamport), existing.clientID == record.clientID,
               existing.updatedByUserID == user, existing.isDeleted == record.isDeleted {
                accepted.append(record.id); continue
            }
        }
        if group.deletedAt != nil {
            refuse(SyncRulesV2.groupDeletedRefusal); continue
        }

        // Who may write this record.
        switch type {
        case .groupMeta:
            if record.isDeleted {
                guard isFounderOrAdmin else { refuse("only the founder or an admin can delete the group"); continue }
            } else {
                guard level.allows(.manage) else { refuse("only a manager can change the group"); continue }
            }
        case .budget:
            guard level.allows(.manage) else { refuse("only a manager can change a budget"); continue }
        default:
            break
        }
        let owner = existing?.createdByUserID ?? user
        if SyncRulesV2.owned.contains(type), owner != user, !level.allows(.manage) {
            refuse("only its owner or a manager can change it"); continue
        }
        // A transaction carries its owner inside, as the apps show it. It must
        // name the owner the server holds, or nobody yet.
        var body = record.body
        if type == .transaction {
            guard var transaction = try? RecordCodec.decoder.decode(Transaction.self, from: Data(body.utf8)) else {
                refuse("the record does not match where it was sent"); continue
            }
            if let claimed = transaction.createdBy, claimed.uuid != owner {
                refuse("a transaction keeps the owner it was made with"); continue
            }
            if transaction.createdBy == nil {
                transaction.createdBy = UserID(owner)
                body = String(decoding: try RecordCodec.encoder.encode(transaction), as: UTF8.self)
            }
        }
        // A transaction or receipt is shown in the budget it names, so that
        // budget must be in this group, when the server has it.
        if type != .budget, let budgetID = record.budgetID,
           let budget = try await SyncRecordRow.find(budgetID, on: database),
           budget.groupID != groupID || budget.recordType != RecordType.budget.rawValue {
            refuse("that budget is not in this group"); continue
        }

        if let existing {
            guard replacesV2(type: type, lamport: record.lamport, client: record.clientID,
                             isDeleted: record.isDeleted, author: user, stored: existing) else {
                let reopens = type == .groupMeta && existing.isDeleted && !record.isDeleted
                refuse(reopens ? SyncRulesV2.groupDeletedRefusal : RecordEnvelope.olderVersionRefusal)
                continue
            }
            sequence += 1
            existing.body = body
            existing.budgetID = record.budgetID
            existing.lamport = Int(record.lamport)
            existing.clientID = record.clientID
            existing.isDeleted = record.isDeleted
            existing.updatedByUserID = user
            existing.serverSeq = sequence
            try await existing.save(on: database)
        } else {
            sequence += 1
            try await SyncRecordRow(id: record.id, groupID: groupID, budgetID: record.budgetID,
                                    recordType: type.rawValue, body: body, createdBy: owner,
                                    clientID: record.clientID, lamport: Int(record.lamport),
                                    isDeleted: record.isDeleted, serverSeq: sequence).create(on: database)
        }
        if type == .groupMeta, record.isDeleted { deletesGroup = true }
        highest = max(highest, record.lamport)
        accepted.append(record.id)
    }

    group.lastSeq = sequence
    if highest > highestBefore { group.maxLamport = Int(highest) }
    if deletesGroup, group.deletedAt == nil { group.deletedAt = Date() }
    try await group.save(on: database)
    return PushV2Response(accepted: accepted, rejected: rejected, serverSeq: sequence)
}
