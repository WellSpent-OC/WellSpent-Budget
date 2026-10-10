import Foundation
import GRDB
import WellSpentCrypto
import WellSpentModel

// MARK: - What the server says about a group

/// What the server last said about one group this account belongs to.
public struct ServerGroupInfo: Sendable, Equatable {
    public let groupID: GroupID
    public let founderID: UserID
    public let level: AccessLevel
    /// The key statement lines are fingerprinted with. Empty until the
    /// group's founder has moved it to readable sync.
    public let importKey: Data
    /// The first server sequence this person may see. Zero for full history.
    public let historyFloor: UInt64
    public let deletedOnServer: Bool
    /// When this Mac sent its data up once after the switch. Nil until then.
    public let movedAt: Date?
    /// When the server stopped listing the group for this person, who was
    /// removed or left, and the group was hidden here. Nil while listed.
    public let removedAt: Date?
    public let refreshedAt: Date

    public init(groupID: GroupID, founderID: UserID, level: AccessLevel, importKey: Data,
                historyFloor: UInt64 = 0, deletedOnServer: Bool = false, movedAt: Date? = nil,
                removedAt: Date? = nil, refreshedAt: Date = Date()) {
        self.groupID = groupID
        self.founderID = founderID
        self.level = level
        self.importKey = importKey
        self.historyFloor = historyFloor
        self.deletedOnServer = deletedOnServer
        self.movedAt = movedAt
        self.removedAt = removedAt
        self.refreshedAt = refreshedAt
    }
}

struct ServerGroupRow: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "serverGroup"

    var budgetGroupId: String
    var founderId: String
    var level: Int
    var importKey: Data
    var historyFloor: Int64
    var deletedOnServer: Bool
    var movedAt: Date?
    var removedAt: Date?
    var refreshedAt: Date

    func model() throws -> ServerGroupInfo {
        ServerGroupInfo(groupID: GroupID(try RowCoding.uuid(budgetGroupId)),
                        founderID: UserID(try RowCoding.uuid(founderId)),
                        level: try accessLevel(level), importKey: importKey,
                        historyFloor: UInt64(max(0, historyFloor)),
                        deletedOnServer: deletedOnServer, movedAt: movedAt, removedAt: removedAt,
                        refreshedAt: refreshedAt)
    }
}

struct GroupMemberRow: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "groupMember"

    var budgetGroupId: String
    var userId: String
    var level: Int
}

private func accessLevel(_ raw: Int) throws -> AccessLevel {
    guard let level = AccessLevel(rawValue: raw) else {
        throw StoreError.corruptRow("unknown access level \(raw)")
    }
    return level
}

extension Store {
    public func serverGroup(_ id: GroupID) throws -> ServerGroupInfo? {
        try database.read { db in try ServerGroupRow.fetchOne(db, key: id.dbValue)?.model() }
    }

    public func serverGroups() throws -> [ServerGroupInfo] {
        try database.read { db in
            try ServerGroupRow.order(Column("budgetGroupId")).fetchAll(db).map { try $0.model() }
        }
    }

    /// Saves what the server said. `movedAt` and `removedAt` are this Mac's
    /// own notes, changed only by `markMoved`, `markRemoved` and
    /// `markListedAgain`: a group already on file keeps its own.
    public func saveServerGroup(_ info: ServerGroupInfo) throws {
        try database.write { db in
            try db.execute(sql: """
                INSERT INTO serverGroup (budgetGroupId, founderId, level, importKey, historyFloor,
                                         deletedOnServer, movedAt, removedAt, refreshedAt)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(budgetGroupId) DO UPDATE SET
                    founderId = excluded.founderId, level = excluded.level,
                    importKey = excluded.importKey, historyFloor = excluded.historyFloor,
                    deletedOnServer = excluded.deletedOnServer, refreshedAt = excluded.refreshedAt
                """, arguments: [info.groupID.dbValue, info.founderID.dbValue, info.level.rawValue,
                                 info.importKey, Int64(clamping: info.historyFloor),
                                 info.deletedOnServer, info.movedAt, info.removedAt, info.refreshedAt])
        }
    }

    /// Notes that this person is no longer in a group (removed, or left), and
    /// forgets who is in it. What else is known stays, `movedAt` included, so
    /// a group listed again is never mistaken for one not yet sent up. A
    /// request to leave it is done with.
    public func markRemoved(_ id: GroupID, at date: Date = Date()) throws {
        try database.write { db in
            try db.execute(sql: "UPDATE serverGroup SET removedAt = ? WHERE budgetGroupId = ?",
                           arguments: [date, id.dbValue])
            try db.execute(sql: "DELETE FROM groupMember WHERE budgetGroupId = ?", arguments: [id.dbValue])
            try db.execute(sql: "DELETE FROM leaveRequest WHERE budgetGroupId = ?", arguments: [id.dbValue])
        }
    }

    /// Notes that a group this person was removed from is theirs again. A
    /// request to leave it, made before they came back, is dropped.
    public func markListedAgain(_ id: GroupID) throws {
        try database.write { db in
            try db.execute(sql: "UPDATE serverGroup SET removedAt = NULL WHERE budgetGroupId = ?",
                           arguments: [id.dbValue])
            try db.execute(sql: "DELETE FROM leaveRequest WHERE budgetGroupId = ?", arguments: [id.dbValue])
        }
    }

    /// Notes that this person deleted a shared group they may not delete for
    /// everyone, so the next sync round leaves it for them.
    public func requestLeave(_ id: GroupID, at date: Date = Date()) throws {
        try database.write { db in
            try db.execute(sql: """
                INSERT INTO leaveRequest (budgetGroupId, requestedAt) VALUES (?, ?)
                ON CONFLICT(budgetGroupId) DO NOTHING
                """, arguments: [id.dbValue, date])
        }
    }

    /// Whether this person asked to leave `id` and has not left it yet.
    public func leaveRequested(_ id: GroupID) throws -> Bool {
        try database.read { db in
            try Bool.fetchOne(db, sql: "SELECT EXISTS (SELECT 1 FROM leaveRequest WHERE budgetGroupId = ?)",
                              arguments: [id.dbValue]) ?? false
        }
    }

    /// Moves the group's clock up to a version this Mac has just taken in, so
    /// an edit made next is newer than it. Called as each version is saved,
    /// in the same transaction: an edit made during a pull, or after one that
    /// failed partway, must not go out below the version it was made on.
    public func observeLamport(_ lamport: UInt64, in group: GroupID) throws {
        try database.write { db in
            var state = try SyncStateRow.fetchOne(db, key: group.dbValue)
                ?? SyncStateRow(budgetGroupId: group.dbValue, serverSeq: 0, lamport: 0, lastSyncedAt: nil)
            guard state.lamport < Int64(clamping: lamport) else { return }
            state.lamport = Int64(clamping: lamport)
            try state.save(db)
        }
    }

    /// Notes that this Mac has sent the group's data up after the switch.
    public func markMoved(_ id: GroupID, at date: Date = Date()) throws {
        try database.write { db in
            try db.execute(sql: "UPDATE serverGroup SET movedAt = ? WHERE budgetGroupId = ?",
                           arguments: [date, id.dbValue])
            guard db.changesCount > 0 else { throw StoreError.notFound("server group \(id.dbValue)") }
        }
    }

    /// The group's members as the server last listed them, replacing the
    /// list before.
    public func replaceMembers(_ members: [UserID: AccessLevel], in group: GroupID) throws {
        try database.write { db in
            _ = try GroupMemberRow.filter(Column("budgetGroupId") == group.dbValue).deleteAll(db)
            for (user, level) in members {
                try GroupMemberRow(budgetGroupId: group.dbValue, userId: user.dbValue,
                                   level: level.rawValue).insert(db)
            }
        }
    }

    public func members(in group: GroupID) throws -> [UserID: AccessLevel] {
        try database.read { db in
            var members: [UserID: AccessLevel] = [:]
            for row in try GroupMemberRow.filter(Column("budgetGroupId") == group.dbValue).fetchAll(db) {
                members[UserID(try RowCoding.uuid(row.userId))] = try accessLevel(row.level)
            }
            return members
        }
    }

    // MARK: - What the sealed app left behind

    /// Whether this Mac holds the group's sealed access history, which means
    /// the group was made or joined before the switch.
    public func hasSealedHistory(_ group: GroupID) throws -> Bool {
        try database.read { db in
            try MembershipEntryRow.filter(Column("budgetGroupId") == group.dbValue).fetchCount(db) > 0
        }
    }

    /// Who founded the group, from the first entry of its sealed history. Nil
    /// when there is no history, or its first entry is not a founding one.
    public func foundingSubject(of group: GroupID) throws -> UserID? {
        try database.read { db in
            guard let row = try MembershipEntryRow
                .filter(Column("budgetGroupId") == group.dbValue)
                .order(Column("sequence"))
                .fetchOne(db) else { return nil }
            let entry = try RowCoding.decode(MembershipLogEntry.self, from: row.entryJSON)
            return entry.action == .found ? entry.subjectUserID : nil
        }
    }

    /// The group's first key, which statement lines were fingerprinted with
    /// before the switch. Nil when this Mac holds no key for the group.
    public func oldestGroupKey(_ group: GroupID) throws -> Data? {
        try cachedKeys(scope: .group(group)).first?.rawBytes
    }

    /// The 32 bytes statement lines are fingerprinted with: the server's key
    /// once the group has one, and the group's first sealed key until then.
    /// Both are the same key for a group moved from this Mac, so lines
    /// imported before the switch still match. Nil when neither is held.
    public func importKey(for group: GroupID) throws -> Data? {
        if let key = try serverGroup(group)?.importKey, !key.isEmpty { return key }
        guard let oldest = try oldestGroupKey(group), oldest.count == 32 else { return nil }
        return oldest
    }

    /// Drops the invites the sealed app was waiting on. Readable sync makes
    /// and answers invites on the server, so none of these can complete.
    public func clearSealedInvites() throws {
        try database.write { db in
            try db.execute(sql: "DELETE FROM pendingJoin")
            try db.execute(sql: "DELETE FROM sentInvite")
        }
    }

    // MARK: - Sending everything up once

    /// Which records a re-send covers.
    public enum ResendScope: Sendable, Equatable {
        /// Everything in the group, for its founder, except transactions
        /// another member added and other members' profiles. The server
        /// would refuse those, because the first account to store a record
        /// owns it.
        case everything
        /// Only the transactions this person added and their own profile,
        /// for a member whose founder has already sent the rest.
        case ownRecords
    }

    public struct ResendSummary: Sendable, Equatable {
        /// Sealed records set aside, which can never be read now.
        public var droppedSetAside = 0
        /// Rows queued only to seal a record again, with nothing of their own.
        public var droppedReseals = 0
        /// Queued edits kept, each weighed at the value it was made at.
        public var keptEdits = 0
        /// Records queued to be sent as they stand.
        public var queued = 0
        /// Records left out because someone else owns them.
        public var skipped = 0
    }

    /// Queues every record in `group` that `scope` covers to be sent to the
    /// readable server as it stands, in one database transaction.
    ///
    /// Each record goes out at the Lamport value of the version on file, so
    /// the server weighs it as the old server did, and a re-run after an
    /// interruption sends the same thing again, which the server takes as a
    /// no-op. A record with no version on file gets a fresh value.
    ///
    /// A group deleted here sends only its own delete, and edits queued in
    /// it are dropped. Anything sent into it after the delete lands would be
    /// refused, and nobody could see it anyway.
    ///
    /// Edits already queued stay, at the value they were made at. Rows owed
    /// only a re-seal, and sealed records set aside, are dropped: nothing
    /// will seal or read them again. The pull cursor goes back to the start,
    /// so the next pull compares everything with the server's copy.
    ///
    /// The versions on file, the sealed history and the keys are left alone.
    /// The app from before the switch still needs them if someone goes back.
    @discardableResult
    public func prepareResend(of group: GroupID, scope: ResendScope, me: UserID) throws -> ResendSummary {
        try database.write { db in
            let id = group.dbValue
            var summary = ResendSummary()
            let deletedHere = try GroupRow.fetchOne(db, key: id)?.isDeleted == true

            try db.execute(sql: "DELETE FROM deferredEnvelope WHERE budgetGroupId = ?", arguments: [id])
            summary.droppedSetAside = db.changesCount
            try db.execute(sql: "DELETE FROM outbox WHERE budgetGroupId = ? AND isReseal = 1",
                           arguments: [id])
            summary.droppedReseals = db.changesCount
            try db.execute(sql: """
                UPDATE outbox SET lamport = editLamport, editLamport = NULL
                WHERE budgetGroupId = ? AND editLamport IS NOT NULL
                """, arguments: [id])
            if deletedHere {
                try db.execute(sql: "DELETE FROM outbox WHERE budgetGroupId = ?1 AND recordId != ?1",
                               arguments: [id])
            }
            summary.keptEdits = try OutboxRow.filter(Column("budgetGroupId") == id).fetchCount(db)

            // Every record in the group: (id, type, budget, deleted, whose).
            // `whose` is the person a transaction or profile belongs to, and
            // nil for records nobody owns here, or that predate sharing.
            let candidates = try Row.fetchAll(db, sql: """
                SELECT id, 'groupMeta' AS type, NULL AS budgetId, isDeleted, NULL AS whose
                  FROM budgetGroup WHERE id = ?1
                UNION ALL SELECT id, 'budget', id, isDeleted, NULL FROM budget WHERE budgetGroupId = ?1
                UNION ALL SELECT id, 'transaction', budgetId, isDeleted, createdBy
                  FROM transactionRecord WHERE budgetGroupId = ?1
                UNION ALL SELECT id, 'receipt', budgetId, isDeleted, NULL FROM receipt WHERE budgetGroupId = ?1
                UNION ALL SELECT id, 'statement', NULL, isDeleted, NULL
                  FROM importedStatement WHERE budgetGroupId = ?1
                UNION ALL SELECT id, 'memberProfile', NULL, isDeleted, userId
                  FROM memberProfile WHERE budgetGroupId = ?1
                """, arguments: [id])

            for row in candidates {
                let recordId: String = row["id"]
                let type = RecordType(rawValue: row["type"])
                let whose: String? = row["whose"]
                let isDeleted: Bool = row["isDeleted"]
                let mine = whose == me.dbValue
                let inScope: Bool
                switch (scope, type) {
                case (.everything, .transaction):   inScope = whose == nil || mine
                case (.everything, .memberProfile): inScope = mine
                case (.everything, _):              inScope = true
                case (.ownRecords, .transaction), (.ownRecords, .memberProfile): inScope = mine
                case (.ownRecords, _):              inScope = false
                }
                guard inScope else {
                    if type == .transaction || type == .memberProfile { summary.skipped += 1 }
                    continue
                }
                guard !deletedHere || type == .groupMeta else { continue }
                guard try OutboxRow.fetchOne(db, key: recordId) == nil else { continue }

                let onFile = try RecordVersionRow.fetchOne(db, key: recordId)?.lamport
                let lamport = try onFile ?? bumpLamport(db, groupId: id)
                try OutboxRow(recordId: recordId, recordType: type.rawValue, budgetGroupId: id,
                              budgetId: row["budgetId"], lamport: lamport, isDeleted: isDeleted,
                              queuedAt: Date(), isReseal: true, editLamport: nil).insert(db)
                summary.queued += 1
            }

            try db.execute(sql: "DELETE FROM readablePull WHERE budgetGroupId = ?", arguments: [id])
            return summary
        }
    }

    /// Takes everything in again from the start on the next readable pull.
    /// Unlike `forgetPulls`, the versions on file stay, so what this Mac
    /// already holds is still recognised.
    public func resetPullCursor(in group: GroupID) throws {
        try database.write { db in
            try db.execute(sql: "DELETE FROM readablePull WHERE budgetGroupId = ?", arguments: [group.dbValue])
        }
    }

    /// How far readable sync has pulled a group: the server sequence the
    /// next pull starts after. Kept apart from the sealed app's place.
    public func readableCursor(in group: GroupID) throws -> UInt64 {
        try database.read { db in
            UInt64(max(0, try Int64.fetchOne(db, sql: "SELECT serverSeq FROM readablePull WHERE budgetGroupId = ?",
                                              arguments: [group.dbValue]) ?? 0))
        }
    }

    /// Notes a readable pull: where the next one starts, and the highest
    /// Lamport value seen, which the group's one clock moves past.
    public func recordReadablePull(group: GroupID, serverSeq: UInt64, observedLamport: UInt64) throws {
        try database.write { db in
            try db.execute(sql: """
                INSERT INTO readablePull (budgetGroupId, serverSeq) VALUES (?, ?)
                ON CONFLICT(budgetGroupId) DO UPDATE SET serverSeq = max(serverSeq, excluded.serverSeq)
                """, arguments: [group.dbValue, Int64(clamping: serverSeq)])
            var state = try SyncStateRow.fetchOne(db, key: group.dbValue)
                ?? SyncStateRow(budgetGroupId: group.dbValue, serverSeq: 0, lamport: 0, lastSyncedAt: nil)
            state.lamport = Swift.max(state.lamport, Int64(clamping: observedLamport))
            state.lastSyncedAt = Date()
            try state.save(db)
        }
    }

    /// Forgets the version on file for one record, so the next pull from the
    /// start takes the server's copy whatever it is. For a record the server
    /// refused, whose copy here only this Mac holds.
    public func forgetVersion(_ id: RecordID) throws {
        _ = try database.write { db in try RecordVersionRow.deleteOne(db, key: id.dbValue) }
    }

    /// Where a page of the outbox ended: its last row's Lamport value and record.
    public struct OutboxCursor: Sendable, Equatable {
        public let lamport: UInt64
        public let recordID: RecordID

        public init(lamport: UInt64, recordID: RecordID) {
            self.lamport = lamport
            self.recordID = recordID
        }

        public init(after push: PendingPush) {
            self.init(lamport: push.lamport, recordID: push.recordID)
        }
    }

    /// Records waiting to go out, a page at a time, in (Lamport, record)
    /// order. Re-sent records can share a Lamport value, so paging on the
    /// value alone would skip the rest of a tie at a page's end.
    public func pendingPushes(in group: GroupID, following cursor: OutboxCursor?,
                              limit: Int = 200) throws -> [PendingPush] {
        try database.read { db in
            var request = OutboxRow.filter(Column("budgetGroupId") == group.dbValue)
            if let cursor {
                let lamport = Int64(clamping: cursor.lamport)
                request = request.filter(Column("lamport") > lamport
                    || (Column("lamport") == lamport && Column("recordId") > cursor.recordID.dbValue))
            }
            return try request
                .order(Column("lamport"), Column("recordId"))
                .limit(limit)
                .fetchAll(db)
                .map { try $0.pendingPush() }
        }
    }

    // MARK: - Groups seen only on the server

    /// A stand-in for a group this Mac holds nothing of yet, so its records
    /// have somewhere to land. The group's own record replaces it on the
    /// first pull. A group already held is left as it is.
    public func placeholderGroup(_ id: GroupID, name: String) throws {
        try database.write { db in
            guard try GroupRow.fetchOne(db, key: id.dbValue) == nil else { return }
            try GroupRow(BudgetGroup(id: id, name: name)).insert(db)
        }
    }

    /// Hides a group this account no longer belongs to, on this Mac only.
    /// Nothing is queued, and what was waiting to go out is dropped, because
    /// the server would refuse it.
    public func hideGroup(_ id: GroupID) throws {
        try database.write { db in
            try db.execute(sql: "UPDATE budgetGroup SET isDeleted = 1 WHERE id = ?", arguments: [id.dbValue])
            try db.execute(sql: "DELETE FROM outbox WHERE budgetGroupId = ?", arguments: [id.dbValue])
        }
    }
}

// MARK: - Readable records set aside

/// A readable record this build cannot use yet, kept whole as it arrived.
/// Either its type is one this build does not know, or it is a transaction
/// whose budget has not arrived.
public struct SetAsideRecord: Sendable, Equatable {
    public let recordID: RecordID
    public let groupID: GroupID
    public let recordType: RecordType
    /// The record exactly as the server sent it.
    public let recordJSON: String
    public let serverSeq: UInt64
    public let authorUserID: UserID?
    /// Set aside because this build cannot read its type, rather than to
    /// wait for its budget.
    public let unreadable: Bool

    public init(recordID: RecordID, groupID: GroupID, recordType: RecordType, recordJSON: String,
                serverSeq: UInt64, authorUserID: UserID?, unreadable: Bool) {
        self.recordID = recordID
        self.groupID = groupID
        self.recordType = recordType
        self.recordJSON = recordJSON
        self.serverSeq = serverSeq
        self.authorUserID = authorUserID
        self.unreadable = unreadable
    }
}

struct SetAsideRecordRow: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "setAsideRecord"

    var recordId: String
    var budgetGroupId: String
    var recordType: String
    var recordJSON: String
    var serverSeq: Int64
    var authorUserId: String?
    var unreadable: Bool

    func model() throws -> SetAsideRecord {
        SetAsideRecord(recordID: RecordID(try RowCoding.uuid(recordId)),
                       groupID: GroupID(try RowCoding.uuid(budgetGroupId)),
                       recordType: RecordType(rawValue: recordType), recordJSON: recordJSON,
                       serverSeq: UInt64(max(0, serverSeq)),
                       authorUserID: try authorUserId.map { UserID(try RowCoding.uuid($0)) },
                       unreadable: unreadable)
    }
}

extension Store {
    /// The newest version wins: a record set aside twice keeps only the later one.
    public func setAside(_ record: SetAsideRecord) throws {
        try database.write { db in
            try SetAsideRecordRow(recordId: record.recordID.dbValue, budgetGroupId: record.groupID.dbValue,
                                  recordType: record.recordType.rawValue, recordJSON: record.recordJSON,
                                  serverSeq: Int64(clamping: record.serverSeq),
                                  authorUserId: record.authorUserID?.dbValue,
                                  unreadable: record.unreadable).save(db)
        }
    }

    /// A group's set-aside records, in the order the server stored them.
    public func setAsideRecords(in group: GroupID) throws -> [SetAsideRecord] {
        try database.read { db in
            try SetAsideRecordRow
                .filter(Column("budgetGroupId") == group.dbValue)
                .order(Column("serverSeq"))
                .fetchAll(db)
                .map { try $0.model() }
        }
    }

    public func setAsideCount(in group: GroupID) throws -> Int {
        try database.read { db in
            try SetAsideRecordRow.filter(Column("budgetGroupId") == group.dbValue).fetchCount(db)
        }
    }

    /// How many records from `author` are set aside in a group because this
    /// build cannot read them, not counting `except`, which a new copy would
    /// replace.
    public func unreadableSetAsideCount(in group: GroupID, from author: UserID,
                                        except record: RecordID) throws -> Int {
        try database.read { db in
            try SetAsideRecordRow
                .filter(Column("budgetGroupId") == group.dbValue)
                .filter(Column("authorUserId") == author.dbValue)
                .filter(Column("unreadable") == true)
                .filter(Column("recordId") != record.dbValue)
                .fetchCount(db)
        }
    }

    public func deleteSetAside(_ id: RecordID) throws {
        _ = try database.write { db in try SetAsideRecordRow.deleteOne(db, key: id.dbValue) }
    }
}

// MARK: - Totals, to check the move

/// What one group adds up to here, compared before and after the move and
/// against a fresh download of the server's copy.
public struct GroupTotals: Codable, Sendable, Equatable {
    /// Nil when this Mac holds no record for the group.
    public var groupName: String?
    public var groupDeleted: Bool
    /// In budget ID order. Includes deleted budgets, flagged, and any budget
    /// that live transactions in the group name but the group does not hold.
    public var budgets: [BudgetTotals]
    public var receipts: Int
    public var statements: Int
    public var profiles: Int

    public init(groupName: String?, groupDeleted: Bool, budgets: [BudgetTotals], receipts: Int,
                statements: Int, profiles: Int) {
        self.groupName = groupName
        self.groupDeleted = groupDeleted
        self.budgets = budgets
        self.receipts = receipts
        self.statements = statements
        self.profiles = profiles
    }
}

public struct BudgetTotals: Codable, Sendable, Equatable {
    public var budgetID: String
    /// Nil for a budget the group's transactions name but the group does not hold.
    public var name: String?
    public var limitMinorUnits: Int?
    public var currency: String?
    public var isDeleted: Bool
    /// Live transactions in the group filed under this budget.
    public var transactionCount: Int
    public var transactionSum: Int
}

extension Store {
    /// Live records only, except budgets, which are listed deleted or not.
    public func groupTotals(in group: GroupID) throws -> GroupTotals {
        try database.read { db in
            let id = group.dbValue
            let groupRow = try GroupRow.fetchOne(db, key: id)
            var budgets: [String: BudgetTotals] = [:]
            for row in try BudgetRow.filter(Column("budgetGroupId") == id).fetchAll(db) {
                budgets[row.id] = BudgetTotals(budgetID: row.id, name: row.name,
                                               limitMinorUnits: row.limitMinorUnits, currency: row.currency,
                                               isDeleted: row.isDeleted, transactionCount: 0, transactionSum: 0)
            }
            for row in try Row.fetchAll(db, sql: """
                SELECT budgetId, COUNT(*) AS count, COALESCE(SUM(amountMinorUnits), 0) AS total
                FROM transactionRecord WHERE budgetGroupId = ? AND isDeleted = 0
                GROUP BY budgetId
                """, arguments: [id]) {
                let budgetId: String = row["budgetId"]
                var totals = budgets[budgetId] ?? BudgetTotals(
                    budgetID: budgetId, name: nil, limitMinorUnits: nil, currency: nil,
                    isDeleted: false, transactionCount: 0, transactionSum: 0)
                totals.transactionCount = row["count"]
                totals.transactionSum = row["total"]
                budgets[budgetId] = totals
            }
            func live(_ table: String) throws -> Int {
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \(table) WHERE budgetGroupId = ? AND isDeleted = 0",
                                 arguments: [id]) ?? 0
            }
            return GroupTotals(groupName: groupRow?.name, groupDeleted: groupRow?.isDeleted ?? false,
                               budgets: budgets.values.sorted { $0.budgetID < $1.budgetID },
                               receipts: try live("receipt"), statements: try live("importedStatement"),
                               profiles: try live("memberProfile"))
        }
    }
}

// MARK: - The move's check, kept

/// The outcome of checking one group's move, as it was last saved.
public struct StoredMoveCheck: Sendable, Equatable {
    public let groupID: GroupID
    public let attempts: Int
    public let matches: Bool
    /// The full report, in a form the app layer owns.
    public let reportJSON: String
    public let checkedAt: Date

    public init(groupID: GroupID, attempts: Int, matches: Bool, reportJSON: String, checkedAt: Date = Date()) {
        self.groupID = groupID
        self.attempts = attempts
        self.matches = matches
        self.reportJSON = reportJSON
        self.checkedAt = checkedAt
    }
}

struct MoveCheckRow: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "moveCheck"

    var budgetGroupId: String
    var attempts: Int
    var matches: Bool
    var reportJSON: String
    var checkedAt: Date
}

extension Store {
    public func moveCheck(_ group: GroupID) throws -> StoredMoveCheck? {
        try database.read { db in
            guard let row = try MoveCheckRow.fetchOne(db, key: group.dbValue) else { return nil }
            return StoredMoveCheck(groupID: group, attempts: row.attempts, matches: row.matches,
                                   reportJSON: row.reportJSON, checkedAt: row.checkedAt)
        }
    }

    public func saveMoveCheck(_ check: StoredMoveCheck) throws {
        try database.write { db in
            try MoveCheckRow(budgetGroupId: check.groupID.dbValue, attempts: check.attempts,
                             matches: check.matches, reportJSON: check.reportJSON,
                             checkedAt: check.checkedAt).save(db)
        }
    }
}
