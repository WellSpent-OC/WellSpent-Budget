import Foundation
import GRDB
import WellSpentCrypto
import WellSpentModel

// An extension's records and repeat rules. Both hold what only their own
// reader needs, so each row is a few columns to find it by and a JSON body.

struct ExtensionRecordRow: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "extensionRecord"

    var id: String
    var budgetGroupId: String
    var recordType: String
    var extensionId: String
    var kind: String
    var sourceKey: String?
    var body: String
    var updatedAt: Date
    var isDeleted: Bool

    init<V>(_ model: ExtensionRecord<V>) {
        id = model.id.dbValue
        budgetGroupId = model.groupID.dbValue
        recordType = V.recordType.rawValue
        extensionId = model.extensionID
        kind = model.kind
        sourceKey = model.sourceKey
        body = model.body
        updatedAt = model.updatedAt
        isDeleted = model.isDeleted
    }

    func model<V>() throws -> ExtensionRecord<V> {
        var record = ExtensionRecord<V>(groupID: GroupID(try RowCoding.uuid(budgetGroupId)), extensionID: extensionId,
                                        kind: kind, sourceKey: sourceKey, body: body, updatedAt: updatedAt,
                                        isDeleted: isDeleted)
        record.id = RecordID(try RowCoding.uuid(id))
        return record
    }
}

struct RepeatRuleRow: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "repeatRule"

    var id: String
    var budgetGroupId: String
    var budgetId: String
    var createdBy: String?
    var body: String
    var isDeleted: Bool

    init(_ model: RepeatRule) throws {
        id = model.id.dbValue
        budgetGroupId = model.groupID.dbValue
        budgetId = model.budgetID.dbValue
        createdBy = model.createdBy?.dbValue
        body = try RowCoding.encode(model)
        isDeleted = model.isDeleted
    }

    func model() throws -> RepeatRule {
        try RowCoding.decode(RepeatRule.self, from: body)
    }
}

public extension Store {
    // MARK: - Extension records

    /// Saves an extension's record. Saved again with nothing changed, it
    /// writes and sends nothing, so an import that runs often doesn't make
    /// every member's device download what it already holds.
    func save<V>(_ record: ExtensionRecord<V>, queue: Bool = true) throws {
        try database.write { db in
            if queue, let held = try ExtensionRecordRow.fetchOne(db, key: record.id.dbValue),
               held.recordType == V.recordType.rawValue, held.body == record.body,
               held.isDeleted == record.isDeleted { return }
            try ExtensionRecordRow(record).save(db)
            if queue {
                try enqueue(db, recordId: record.id.dbValue, type: V.recordType, groupId: record.groupID.dbValue,
                            budgetId: nil, isDeleted: record.isDeleted)
            }
        }
    }

    /// The record with this ID, deleted or not, if it is of this type.
    func extensionRecord<V>(_ id: RecordID) throws -> ExtensionRecord<V>? {
        try database.read { db in
            guard let row = try ExtensionRecordRow.fetchOne(db, key: id.dbValue),
                  row.recordType == V.recordType.rawValue else { return nil }
            return try row.model()
        }
    }

    /// The live records of one kind in a group, for one extension.
    func extensionRecords<V>(in group: GroupID, extensionID: String, kind: String) throws -> [ExtensionRecord<V>] {
        try database.read { db in
            try ExtensionRecordRow
                .filter(Column("budgetGroupId") == group.dbValue && Column("extensionId") == extensionID
                    && Column("kind") == kind && Column("recordType") == V.recordType.rawValue
                    && Column("isDeleted") == false)
                .order(Column("id"))
                .fetchAll(db).map { try $0.model() }
        }
    }

    // MARK: - Repeat rules

    /// Saves what a repeat made, at Lamport 0, unless this ID is already held.
    /// A deleted one counts as held, so a month someone deleted doesn't come
    /// back. Real values start at 1, so an offline device's copy can never
    /// undo an edit. True when it was new.
    @discardableResult
    public func saveMade(_ transaction: Transaction) throws -> Bool {
        try database.write { db in
            guard try TransactionRow.fetchOne(db, key: transaction.id.dbValue) == nil else { return false }
            try TransactionRow(transaction).save(db)
            try OutboxRow(recordId: transaction.id.dbValue, recordType: RecordType.transaction.rawValue,
                          budgetGroupId: transaction.groupID.dbValue, budgetId: transaction.budgetID.dbValue,
                          lamport: 0, isDeleted: false, queuedAt: Date(), isReseal: false, editLamport: nil).save(db)
            return true
        }
    }

    /// A made transaction the server won't take: its queue row and its row go.
    /// Only ever a row with no version on file, so nothing anyone saw is lost.
    public func dropMade(_ push: PendingPush) throws {
        try database.write { db in
            _ = try OutboxRow.deleteOne(db, key: push.recordID.dbValue)
            _ = try TransactionRow.deleteOne(db, key: push.recordID.dbValue)
        }
    }

    func save(_ rule: RepeatRule, queue: Bool = true) throws {
        try database.write { db in
            try RepeatRuleRow(rule).save(db)
            if queue {
                try enqueue(db, recordId: rule.id.dbValue, type: .repeatRule, groupId: rule.groupID.dbValue,
                            budgetId: rule.budgetID.dbValue, isDeleted: rule.isDeleted)
            }
        }
    }

    /// Makes an entry a rule's bill for its month, in one write: the rule, the
    /// entry under the rule's ID for that month, and the old row deleted. So
    /// no sync or failure can catch the entry counted twice, or not at all.
    func startRepeat(_ rule: RepeatRule, firstBill: Transaction, replacing entry: Transaction) throws {
        var old = entry
        old.isDeleted = true
        old.updatedAt = Date()
        try database.write { db in
            try RepeatRuleRow(rule).save(db)
            try enqueue(db, recordId: rule.id.dbValue, type: .repeatRule, groupId: rule.groupID.dbValue,
                        budgetId: rule.budgetID.dbValue, isDeleted: false)
            try TransactionRow(old).save(db)
            try enqueue(db, recordId: old.id.dbValue, type: .transaction, groupId: old.groupID.dbValue,
                        budgetId: old.budgetID.dbValue, isDeleted: true)
            try TransactionRow(firstBill).save(db)
            try enqueue(db, recordId: firstBill.id.dbValue, type: .transaction, groupId: firstBill.groupID.dbValue,
                        budgetId: firstBill.budgetID.dbValue, isDeleted: false)
        }
    }

    /// Starts a stopped repeat again, in one write. The months it skips are held
    /// as deleted bills, which is how a month counts as made and doesn't come
    /// back. A month that already has a bill keeps it.
    func restartRepeat(_ rule: RepeatRule, skipping months: [Transaction]) throws {
        try database.write { db in
            try RepeatRuleRow(rule).save(db)
            try enqueue(db, recordId: rule.id.dbValue, type: .repeatRule, groupId: rule.groupID.dbValue,
                        budgetId: rule.budgetID.dbValue, isDeleted: false)
            for bill in months where try TransactionRow.fetchOne(db, key: bill.id.dbValue) == nil {
                try TransactionRow(bill).save(db)
                try enqueue(db, recordId: bill.id.dbValue, type: .transaction, groupId: bill.groupID.dbValue,
                            budgetId: bill.budgetID.dbValue, isDeleted: true)
            }
        }
    }

    func repeatRule(_ id: RecordID) throws -> RepeatRule? {
        try database.read { db in try RepeatRuleRow.fetchOne(db, key: id.dbValue)?.model() }
    }

    /// The live repeat rules in a group.
    func repeatRules(in group: GroupID) throws -> [RepeatRule] {
        try database.read { db in
            try RepeatRuleRow
                .filter(Column("budgetGroupId") == group.dbValue && Column("isDeleted") == false)
                .order(Column("id"))
                .fetchAll(db).map { try $0.model() }
        }
    }
}
