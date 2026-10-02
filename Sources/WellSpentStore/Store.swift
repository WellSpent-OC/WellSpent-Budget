import Foundation
import GRDB
import WellSpentCrypto
import WellSpentModel

/// Everything the app does to local data.
///
/// Every write that changes a synced record also queues it in the outbox, in the
/// same transaction. That pairing is the thing that keeps the local database and
/// the server from drifting: there is no code path that saves a transaction and
/// forgets to schedule the push.
public struct Store: Sendable {
    public let database: WellSpentDatabase

    public init(database: WellSpentDatabase) {
        self.database = database
    }

    // MARK: - Groups

    public func save(_ group: BudgetGroup, queue: Bool = true) throws {
        try database.write { db in
            try GroupRow(group).save(db)
            if queue {
                try enqueue(db, recordId: group.id.dbValue, type: .groupMeta,
                            groupId: group.id.dbValue, budgetId: nil, isDeleted: group.isDeleted)
            }
        }
    }

    public func groups(includeDeleted: Bool = false) throws -> [BudgetGroup] {
        try database.read { db in
            var request = GroupRow.all()
            if !includeDeleted { request = request.filter(Column("isDeleted") == false) }
            return try request.order(Column("name")).fetchAll(db).map { try $0.model() }
        }
    }

    public func group(_ id: GroupID) throws -> BudgetGroup? {
        try database.read { db in try GroupRow.fetchOne(db, key: id.dbValue)?.model() }
    }

    // MARK: - Budgets

    public func save(_ budget: Budget, queue: Bool = true) throws {
        try database.write { db in
            try BudgetRow(budget).save(db)
            if queue {
                try enqueue(db, recordId: budget.id.dbValue, type: .budget,
                            groupId: budget.groupID.dbValue, budgetId: budget.id.dbValue,
                            isDeleted: budget.isDeleted)
            }
        }
    }

    public func budgets(in group: GroupID, includeDeleted: Bool = false) throws -> [Budget] {
        try database.read { db in
            var request = BudgetRow.filter(Column("budgetGroupId") == group.dbValue)
            if !includeDeleted { request = request.filter(Column("isDeleted") == false) }
            return try request
                .order(Column("sortOrder"), Column("name"))
                .fetchAll(db).map { try $0.model() }
        }
    }

    public func budget(_ id: BudgetID) throws -> Budget? {
        try database.read { db in try BudgetRow.fetchOne(db, key: id.dbValue)?.model() }
    }

    // MARK: - Member profiles

    public func save(_ profile: MemberProfile, queue: Bool = true) throws {
        try database.write { db in
            try MemberProfileRow(profile).save(db)
            if queue {
                try enqueue(db, recordId: profile.id.dbValue, type: .memberProfile,
                            groupId: profile.groupID.dbValue, budgetId: nil,
                            isDeleted: profile.isDeleted)
            }
        }
    }

    public func profiles(in group: GroupID) throws -> [MemberProfile] {
        try database.read { db in
            try MemberProfileRow
                .filter(Column("budgetGroupId") == group.dbValue)
                .filter(Column("isDeleted") == false)
                .fetchAll(db).map { try $0.model() }
        }
    }

    public func profile(_ id: RecordID) throws -> MemberProfile? {
        try database.read { db in try MemberProfileRow.fetchOne(db, key: id.dbValue)?.model() }
    }

    // MARK: - Transactions

    public func save(_ transaction: Transaction, queue: Bool = true) throws {
        try database.write { db in
            try TransactionRow(transaction).save(db)
            if queue {
                try enqueue(db, recordId: transaction.id.dbValue, type: .transaction,
                            groupId: transaction.groupID.dbValue,
                            budgetId: transaction.budgetID.dbValue,
                            isDeleted: transaction.isDeleted)
            }
        }
    }

    /// Soft delete. A synced record can never be removed outright, because another
    /// device has to learn that it went away. `queue: false` is for a delete
    /// that stays on this Mac.
    public func trash(_ transaction: Transaction, queue: Bool = true) throws {
        var copy = transaction
        copy.isDeleted = true
        copy.updatedAt = Date()
        try save(copy, queue: queue)
    }

    public func transactions(in budget: BudgetID, period: BudgetPeriod? = nil,
                             includeDeleted: Bool = false) throws -> [Transaction] {
        try database.read { db in
            var request = TransactionRow.filter(Column("budgetId") == budget.dbValue)
            if !includeDeleted { request = request.filter(Column("isDeleted") == false) }
            if let period {
                request = request.filter(Column("date") >= period.start && Column("date") < period.end)
            }
            return try request
                .order(Column("date").desc, Column("createdAt").desc)
                .fetchAll(db).map { try $0.model() }
        }
    }

    public func transaction(_ id: RecordID) throws -> Transaction? {
        try database.read { db in try TransactionRow.fetchOne(db, key: id.dbValue)?.model() }
    }

    /// Full-text search, locally. The server never learns what was searched for.
    public func searchTransactions(_ query: String, in group: GroupID? = nil,
                                   limit: Int = 100) throws -> [Transaction] {
        try database.read { db in
            guard let pattern = FTS5Pattern(matchingAllPrefixesIn: query) else { return [] }
            var sql = """
                SELECT t.* FROM transactionRecord t
                JOIN transactionSearch s ON s.rowid = t.rowid
                WHERE transactionSearch MATCH ? AND t.isDeleted = 0
                """
            var arguments: [any DatabaseValueConvertible] = [pattern]
            if let group {
                sql += " AND t.budgetGroupId = ?"
                arguments.append(group.dbValue)
            }
            sql += " ORDER BY t.date DESC LIMIT ?"
            arguments.append(limit)
            return try TransactionRow
                .fetchAll(db, sql: sql, arguments: StatementArguments(arguments))
                .map { try $0.model() }
        }
    }

    // MARK: - Summaries

    /// Spending for one budget over one period, added up in SQL.
    ///
    /// Only money out counts against a budget. A refund arrives as a positive
    /// amount and reduces spending, which is why this sums the negatives and flips
    /// the sign rather than taking absolute values.
    public func summary(for budget: Budget, on date: Date = Date(),
                        calendar: Calendar = .autoupdatingCurrent) throws -> BudgetSummary {
        let period = budget.reset.period(containing: date, calendar: calendar)
        let (total, count) = try database.read { db -> (Int, Int) in
            let row = try Row.fetchOne(db, sql: """
                SELECT COALESCE(SUM(amountMinorUnits), 0) AS total, COUNT(*) AS count
                FROM transactionRecord
                WHERE budgetId = ? AND isDeleted = 0 AND date >= ? AND date < ?
                """, arguments: [budget.id.dbValue, period.start, period.end])
            return (row?["total"] ?? 0, row?["count"] ?? 0)
        }
        return BudgetSummary(
            budget: budget, period: period,
            spent: Money(minorUnits: -total, currency: budget.limit.currency),
            transactionCount: count
        )
    }

    public func summaries(in group: GroupID, on date: Date = Date()) throws -> [BudgetSummary] {
        try budgets(in: group).map { try summary(for: $0, on: date) }
    }

    // MARK: - Receipts and statements

    public func save(_ receipt: Receipt, queue: Bool = true) throws {
        try database.write { db in
            try ReceiptRow(receipt).save(db)
            if queue {
                try enqueue(db, recordId: receipt.id.dbValue, type: .receipt,
                            groupId: receipt.groupID.dbValue, budgetId: receipt.budgetID?.dbValue,
                            isDeleted: receipt.isDeleted)
            }
        }
    }

    public func receipt(_ id: RecordID) throws -> Receipt? {
        try database.read { db in try ReceiptRow.fetchOne(db, key: id.dbValue)?.model() }
    }

    /// The same scan filed twice is recognised by content, not by filename.
    public func receipt(withHash hash: Data) throws -> Receipt? {
        try database.read { db in
            try ReceiptRow.filter(Column("plaintextSHA256") == hash).fetchOne(db)?.model()
        }
    }

    public func receipts(in group: GroupID) throws -> [Receipt] {
        try database.read { db in
            try ReceiptRow
                .filter(Column("budgetGroupId") == group.dbValue && Column("isDeleted") == false)
                .order(Column("capturedAt").desc)
                .fetchAll(db).map { try $0.model() }
        }
    }

    public func save(_ statement: ImportedStatement, queue: Bool = true) throws {
        try database.write { db in
            try StatementRow(statement).save(db)
            if queue {
                try enqueue(db, recordId: statement.id.dbValue, type: .statement,
                            groupId: statement.groupID.dbValue, budgetId: nil,
                            isDeleted: statement.isDeleted)
            }
        }
    }

    public func statements(in group: GroupID) throws -> [ImportedStatement] {
        try database.read { db in
            try StatementRow
                .filter(Column("budgetGroupId") == group.dbValue && Column("isDeleted") == false)
                .order(Column("importedAt").desc)
                .fetchAll(db).map { try $0.model() }
        }
    }

    /// Which of these fingerprints have already been imported into this group.
    public func existingFingerprints(_ fingerprints: [String], in group: GroupID) throws -> Set<String> {
        guard !fingerprints.isEmpty else { return [] }
        return try database.read { db in
            let placeholders = databaseQuestionMarks(count: fingerprints.count)
            var arguments: [any DatabaseValueConvertible] = [group.dbValue]
            arguments.append(contentsOf: fingerprints)
            let rows = try String.fetchAll(db, sql: """
                SELECT importFingerprint FROM transactionRecord
                WHERE budgetGroupId = ? AND isDeleted = 0 AND importFingerprint IN (\(placeholders))
                """, arguments: StatementArguments(arguments))
            return Set(rows)
        }
    }

    // MARK: - Outbox

    /// Queues a record at a fresh Lamport value. `reseal` marks a row queued
    /// only to seal the record again, with no edit of its own.
    ///
    /// An edit not yet sent and a re-seal share one row. An edit already
    /// queued stays an edit, because the record still holds it, and keeps its
    /// own Lamport value and delete flag. That value is what it is weighed at
    /// against other members' versions. The fresh one is only what the row is
    /// sent at, so the server stores the new seal even if it already holds the
    /// edit. Weighing it at the fresh value made an old edit outrank newer
    /// edits from others. An edit saved over a re-seal owes the re-seal too.
    func enqueue(_ db: Database, recordId: String, type: RecordType,
                 groupId: String, budgetId: String?, isDeleted: Bool,
                 reseal: Bool = false) throws {
        let queued = try OutboxRow.fetchOne(db, key: recordId)
        let clock = try bumpLamport(db, groupId: groupId)
        let owesReseal = reseal || queued?.owesReseal == true
        // The edit this row carries, if any: the value it was made at, and
        // whether it deletes the record.
        let edit: (lamport: Int64, isDeleted: Bool)? = reseal
            ? queued.flatMap { $0.isReseal ? nil : ($0.editLamport ?? $0.lamport, $0.isDeleted) }
            : (clock, isDeleted)
        try OutboxRow(recordId: recordId, recordType: type.rawValue, budgetGroupId: groupId,
                      budgetId: budgetId, lamport: clock, isDeleted: edit?.isDeleted ?? isDeleted,
                      queuedAt: Date(), isReseal: edit == nil,
                      editLamport: owesReseal ? edit?.lamport : nil).save(db)
    }

    /// Queues a group's record and its budgets to be sealed again as they
    /// stand, under the group's current key.
    ///
    /// For a member who joined "from now on": they hold only the new key, so
    /// without this they could not read the group or its budgets. These rows
    /// carry no edit, so a newer edit pulled from someone else wins over them,
    /// and they then send that edit under the new key. An edit another member
    /// makes before pulling them can still lose to them, because nobody can
    /// tell a re-seal from an edit (a known gap in ARCHITECTURE.md).
    ///
    /// `budgets` are the ones live when the member was added, read before
    /// the add went out, and nil means the live ones now. The rows are queued
    /// live whatever this Mac holds by then. A removal from this Mac only can
    /// land while the add is on its way. It marks the group and its budgets
    /// deleted here, but they stay live for everyone else, and the new member
    /// is still owed them. An edit already queued keeps its own delete flag.
    public func queueReseal(of group: GroupID, budgets: [BudgetID]? = nil) throws {
        let owed = try budgets ?? self.budgets(in: group).map(\.id)
        try database.write { db in
            let id = group.dbValue
            if try GroupRow.fetchOne(db, key: id) != nil {
                try enqueue(db, recordId: id, type: .groupMeta, groupId: id, budgetId: nil,
                            isDeleted: false, reseal: true)
            }
            for budget in owed {
                guard try BudgetRow.fetchOne(db, key: budget.dbValue) != nil else { continue }
                try enqueue(db, recordId: budget.dbValue, type: .budget, groupId: id,
                            budgetId: budget.dbValue, isDeleted: false, reseal: true)
            }
        }
    }

    /// The IDs of a group's live budgets, or nil when the group itself is
    /// deleted on this Mac. Read together, so a removal cannot land between.
    public func liveBudgets(ifLive group: GroupID) throws -> [BudgetID]? {
        try database.read { db in
            guard let row = try GroupRow.fetchOne(db, key: group.dbValue), !row.isDeleted else {
                return nil
            }
            return try BudgetRow
                .filter(Column("budgetGroupId") == group.dbValue && Column("isDeleted") == false)
                .fetchAll(db)
                .map { BudgetID(try RowCoding.uuid($0.id)) }
        }
    }

    /// Moves a queued row that owes a re-seal to a fresh Lamport value above
    /// `lamport`, so it is newer than a live version this Mac has just taken
    /// in from someone else. From then on the row only seals that version
    /// again: any edit it carried lost to it.
    public func requeue(_ id: RecordID, above lamport: UInt64) throws {
        // Nothing fits above the largest value the clock can hold.
        guard lamport < UInt64(Int64.max) else { return }
        try database.write { db in
            guard var row = try OutboxRow.fetchOne(db, key: id.dbValue) else { return }
            var state = try SyncStateRow.fetchOne(db, key: row.budgetGroupId)
                ?? SyncStateRow(budgetGroupId: row.budgetGroupId, serverSeq: 0, lamport: 0, lastSyncedAt: nil)
            state.lamport = Swift.max(state.lamport, Int64(lamport))
            try state.save(db)
            row.lamport = try bumpLamport(db, groupId: row.budgetGroupId)
            row.isReseal = true
            row.editLamport = nil
            row.isDeleted = false
            try row.save(db)
        }
    }

    /// Runs `body` as one database transaction. The store it is handed joins
    /// that transaction, so what `body` reads cannot change before what it
    /// writes, and a save made elsewhere lands before or after, never between.
    /// It must not be kept past `body`.
    public func inOneTransaction<T>(_ body: (Store) throws -> T) throws -> T {
        try database.transaction { try body(Store(database: $0)) }
    }

    /// Records waiting to go out, oldest first. `after` skips every row up to
    /// and including that Lamport value, so a caller can read the queue a
    /// page at a time.
    public func pendingPushes(in group: GroupID, after lamport: UInt64? = nil,
                              limit: Int = 200) throws -> [PendingPush] {
        try database.read { db in
            var request = OutboxRow.filter(Column("budgetGroupId") == group.dbValue)
            if let lamport { request = request.filter(Column("lamport") > Int64(lamport)) }
            return try request
                .order(Column("lamport"))
                .limit(limit)
                .fetchAll(db)
                .map { try $0.pendingPush() }
        }
    }

    /// The write of this record waiting to go out, if there is one.
    public func queuedPush(_ id: RecordID) throws -> PendingPush? {
        try database.read { db in try OutboxRow.fetchOne(db, key: id.dbValue)?.pendingPush() }
    }

    /// Drops every queued row for these records, whatever was saved last.
    public func clearOutbox(_ ids: [RecordID]) throws {
        guard !ids.isEmpty else { return }
        try database.write { db in
            _ = try OutboxRow.filter(ids.map(\.dbValue).contains(Column("recordId"))).deleteAll(db)
        }
    }

    /// Drops the rows these pushes were read from, and nothing newer.
    ///
    /// A push waits on the network. A record saved again in that time replaces
    /// its row with one at a higher Lamport value, and that row has not been
    /// sent. Matching the Lamport value as well as the record keeps it queued
    /// for the next round.
    public func clearOutbox(_ pushes: [PendingPush]) throws {
        guard !pushes.isEmpty else { return }
        try database.write { db in
            for push in pushes {
                _ = try OutboxRow
                    .filter(Column("recordId") == push.recordID.dbValue)
                    .filter(Column("lamport") == Int64(push.lamport))
                    .deleteAll(db)
            }
        }
    }

    public func outboxCount(in group: GroupID) throws -> Int {
        try database.read { db in
            try OutboxRow.filter(Column("budgetGroupId") == group.dbValue).fetchCount(db)
        }
    }

    /// Everything queued for one group, dropped. For a group whose rows will
    /// never be sent.
    public func clearOutbox(in group: GroupID) throws {
        try database.write { db in
            _ = try OutboxRow.filter(Column("budgetGroupId") == group.dbValue).deleteAll(db)
        }
    }

    /// Whether a write of this record is waiting to go out.
    public func isQueued(_ id: RecordID) throws -> Bool {
        try database.read { db in try OutboxRow.fetchOne(db, key: id.dbValue) != nil }
    }

    /// Whether a delete of the group's own record is waiting to go out. False
    /// when the group was deleted by a pull, which queues nothing.
    public func groupDeleteIsQueued(_ group: GroupID) throws -> Bool {
        try database.read { db in
            try OutboxRow.fetchOne(db, key: group.dbValue)?.isDeleted == true
        }
    }

    /// Forgets what this Mac has pulled for a group, so its next sync takes
    /// everything in again from the start.
    ///
    /// For a group coming back after this Mac removed it on its own. What was
    /// deleted here, and never sent, is replaced by the server's copy. Without
    /// this, the versions kept from the last pull would make every record look
    /// already seen, and the deleted copies here would stay.
    public func forgetPulls(in group: GroupID) throws {
        try database.write { db in
            let id = group.dbValue
            try db.execute(sql: """
                DELETE FROM recordVersion WHERE recordId = ?
                   OR recordId IN (SELECT id FROM budget WHERE budgetGroupId = ?)
                   OR recordId IN (SELECT id FROM transactionRecord WHERE budgetGroupId = ?)
                   OR recordId IN (SELECT id FROM receipt WHERE budgetGroupId = ?)
                   OR recordId IN (SELECT id FROM importedStatement WHERE budgetGroupId = ?)
                   OR recordId IN (SELECT id FROM memberProfile WHERE budgetGroupId = ?)
                """, arguments: [id, id, id, id, id, id])
            try db.execute(sql: "UPDATE syncState SET serverSeq = 0 WHERE budgetGroupId = ?",
                           arguments: [id])
        }
    }

    // MARK: - Sync state

    @discardableResult
    func bumpLamport(_ db: Database, groupId: String) throws -> Int64 {
        var state = try SyncStateRow.fetchOne(db, key: groupId)
            ?? SyncStateRow(budgetGroupId: groupId, serverSeq: 0, lamport: 0, lastSyncedAt: nil)
        // The clock only moves forward. At its largest value there is nowhere
        // to go, and adding one crashed the app, so the save is refused. Only
        // a database that took in a forged value, before the ceiling existed,
        // can get here.
        guard state.lamport < Int64.max else { throw StoreError.clockExhausted(groupId) }
        state.lamport += 1
        try state.save(db)
        return state.lamport
    }

    public func syncState(for group: GroupID) throws -> (serverSeq: UInt64, lamport: UInt64) {
        try database.read { db in
            let row = try SyncStateRow.fetchOne(db, key: group.dbValue)
            return (UInt64(row?.serverSeq ?? 0), UInt64(row?.lamport ?? 0))
        }
    }

    public func recordPull(group: GroupID, serverSeq: UInt64, observedLamport: UInt64) throws {
        try database.write { db in
            var state = try SyncStateRow.fetchOne(db, key: group.dbValue)
                ?? SyncStateRow(budgetGroupId: group.dbValue, serverSeq: 0, lamport: 0, lastSyncedAt: nil)
            state.serverSeq = Swift.max(state.serverSeq, Int64(serverSeq))
            state.lamport = Swift.max(state.lamport, Int64(clamping: observedLamport))
            state.lastSyncedAt = Date()
            try state.save(db)
        }
    }

    // MARK: - Keys and membership

    public func cache(_ key: ScopedKey) throws {
        try database.write { db in
            let (kind, id) = key.scope.parts
            try ScopedKeyRow(scopeKind: kind, scopeId: id, epoch: Int64(key.epoch.value),
                             material: key.rawBytes).save(db)
        }
    }

    public func cachedKey(scope: KeyScope, epoch: Epoch) throws -> ScopedKey? {
        try database.read { db in
            let (kind, id) = scope.parts
            guard let row = try ScopedKeyRow.fetchOne(db, key: [
                "scopeKind": kind, "scopeId": id, "epoch": Int64(epoch.value),
            ]) else { return nil }
            return ScopedKey(scope: scope, epoch: epoch, material: .init(data: row.material))
        }
    }

    /// Every epoch is kept, because records written under an old key must stay
    /// readable after a rotation. Pruning these is a data-loss bug with a long fuse.
    public func cachedKeys(scope: KeyScope) throws -> [ScopedKey] {
        try database.read { db in
            let (kind, id) = scope.parts
            return try ScopedKeyRow
                .filter(Column("scopeKind") == kind && Column("scopeId") == id)
                .order(Column("epoch"))
                .fetchAll(db)
                .map { ScopedKey(scope: scope, epoch: Epoch(UInt32($0.epoch)), material: .init(data: $0.material)) }
        }
    }

    public func append(_ entry: MembershipLogEntry, in group: GroupID) throws {
        try database.write { db in
            try MembershipEntryRow(budgetGroupId: group.dbValue, sequence: Int64(entry.sequence),
                                   entryJSON: try RowCoding.encode(entry)).save(db)
        }
    }

    public func membershipLog(for group: GroupID) throws -> [MembershipLogEntry] {
        try database.read { db in
            try MembershipEntryRow
                .filter(Column("budgetGroupId") == group.dbValue)
                .order(Column("sequence"))
                .fetchAll(db)
                .map { try RowCoding.decode(MembershipLogEntry.self, from: $0.entryJSON) }
        }
    }

    // MARK: - Conflicts

    /// The losing side of a concurrent edit, kept rather than thrown away.
    ///
    /// Last write wins is fine as a rule, but silently discarding what somebody
    /// typed is not. Keeping the loser means the UI can say "your partner changed this
    /// too" instead of the edit simply vanishing.
    public func recordConflict(recordID: RecordID, recordType: RecordType,
                               payloadJSON: String, lamport: UInt64, device: DeviceID) throws {
        try database.write { db in
            try ConflictCopyRow(id: nil, recordId: recordID.dbValue, recordType: recordType.rawValue,
                                payloadJSON: payloadJSON, lamport: Int64(lamport),
                                authorDeviceId: device.dbValue, seenAt: Date()).save(db)
        }
    }

    public func conflicts(for recordID: RecordID) throws -> [(payloadJSON: String, lamport: UInt64, seenAt: Date)] {
        try database.read { db in
            try ConflictCopyRow
                .filter(Column("recordId") == recordID.dbValue)
                .order(Column("seenAt").desc)
                .fetchAll(db)
                .map { ($0.payloadJSON, UInt64($0.lamport), $0.seenAt) }
        }
    }
}

public struct PendingPush: Sendable, Equatable {
    public let recordID: RecordID
    public let recordType: RecordType
    public let groupID: GroupID
    public let budgetID: BudgetID?
    public let lamport: UInt64
    public let isDeleted: Bool
    /// Queued only to be sealed again under a new key, with no edit of its own.
    public let isReseal: Bool
    /// Set when a re-seal is owed on top of an edit made here: the Lamport
    /// value the edit was made at. The row goes out at `lamport`.
    public let editLamport: UInt64?

    /// Whether a re-seal is owed, with or without an edit of its own.
    public var owesReseal: Bool { isReseal || editLamport != nil }
    /// The value an edit in this row is weighed at against other members'
    /// versions: the one it was made at, not the one a re-seal moved it to.
    public var weighedLamport: UInt64 { editLamport ?? lamport }
}

extension OutboxRow {
    func pendingPush() throws -> PendingPush {
        PendingPush(
            recordID: RecordID(try RowCoding.uuid(recordId)),
            recordType: RecordType(rawValue: recordType),
            groupID: GroupID(try RowCoding.uuid(budgetGroupId)),
            budgetID: try budgetId.map { BudgetID(try RowCoding.uuid($0)) },
            lamport: UInt64(lamport),
            isDeleted: isDeleted,
            isReseal: isReseal,
            editLamport: editLamport.map { UInt64($0) }
        )
    }
}

extension KeyScope {
    var parts: (kind: String, id: String) {
        switch self {
        case .group(let id):  return ("group", id.dbValue)
        case .budget(let id): return ("budget", id.dbValue)
        }
    }
}

private func databaseQuestionMarks(count: Int) -> String {
    Array(repeating: "?", count: count).joined(separator: ", ")
}

// MARK: - Record versions

public extension Store {
    /// What we last accepted for this record. Used to decide whether an incoming
    /// envelope wins, without having to decrypt it first.
    func recordVersion(_ id: RecordID) throws -> (lamport: UInt64, device: DeviceID, author: UserID?)? {
        try database.read { db in
            guard let row = try RecordVersionRow.fetchOne(db, key: id.dbValue) else { return nil }
            return (UInt64(row.lamport), DeviceID(try RowCoding.uuid(row.authorDeviceId)),
                    try row.authorUserId.map { UserID(try RowCoding.uuid($0)) })
        }
    }

    /// The type and group of whatever this Mac already holds under a record ID,
    /// or nil when it holds nothing there. Each type has its own table, but the
    /// version kept for a record is found by its ID alone, so a pull must not
    /// let one ID stand for two records.
    func holder(of id: RecordID) throws -> (type: RecordType, group: GroupID)? {
        try database.read { db in
            let tables: [(RecordType, String, String)] = [
                (.groupMeta, "budgetGroup", "id"),
                (.budget, "budget", "budgetGroupId"),
                (.transaction, "transactionRecord", "budgetGroupId"),
                (.receipt, "receipt", "budgetGroupId"),
                (.statement, "importedStatement", "budgetGroupId"),
                (.memberProfile, "memberProfile", "budgetGroupId"),
            ]
            for (type, table, groupColumn) in tables {
                if let group = try String.fetchOne(
                    db, sql: "SELECT \(groupColumn) FROM \(table) WHERE id = ?", arguments: [id.dbValue]) {
                    return (type, GroupID(try RowCoding.uuid(group)))
                }
            }
            return nil
        }
    }

    func setRecordVersion(_ id: RecordID, lamport: UInt64, device: DeviceID, author: UserID? = nil,
                          serverSeq: UInt64) throws {
        try database.write { db in
            try RecordVersionRow(recordId: id.dbValue, lamport: Int64(clamping: lamport),
                                 authorDeviceId: device.dbValue, serverSeq: Int64(serverSeq),
                                 authorUserId: author?.dbValue).save(db)
        }
    }
}
