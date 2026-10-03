import Foundation
import GRDB
import WellSpentCrypto
import WellSpentModel

/// Database rows, kept separate from the domain model on purpose.
///
/// `WellSpentModel` has no GRDB dependency, which matters because the server needs
/// the same types and must not drag SQLite into a Vapor process.
///
/// Money is split into an integer and a currency code rather than stored as JSON,
/// so `SUM(amountMinorUnits)` works. A budget app that cannot add up in SQL is a
/// budget app that loads every row into memory to draw one number.

// MARK: - Helpers

extension OpaqueID {
    var dbValue: String { uuid.uuidString }
}

enum RowCoding {
    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.sortedKeys]
        return e
    }()

    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    static func encode<T: Encodable>(_ value: T) throws -> String {
        String(decoding: try encoder.encode(value), as: UTF8.self)
    }

    static func decode<T: Decodable>(_ type: T.Type, from json: String) throws -> T {
        try decoder.decode(T.self, from: Data(json.utf8))
    }

    static func uuid(_ string: String) throws -> UUID {
        guard let value = UUID(uuidString: string) else {
            throw StoreError.corruptRow("'\(string)' is not a uuid")
        }
        return value
    }
}

public enum StoreError: Error, Equatable, Sendable {
    case corruptRow(String)
    case notFound(String)
    case currencyMismatch(String)
    /// The group's Lamport clock is at its largest value, so nothing more can
    /// be queued in it.
    case clockExhausted(String)
}

// MARK: - Group

struct GroupRow: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "budgetGroup"

    var id: String
    var name: String
    var note: String
    var createdAt: Date
    var updatedAt: Date
    var isDeleted: Bool

    init(_ model: BudgetGroup) {
        id = model.id.dbValue
        name = model.name
        note = model.note
        createdAt = model.createdAt
        updatedAt = model.updatedAt
        isDeleted = model.isDeleted
    }

    func model() throws -> BudgetGroup {
        BudgetGroup(id: GroupID(try RowCoding.uuid(id)), name: name, note: note,
                    createdAt: createdAt, updatedAt: updatedAt, isDeleted: isDeleted)
    }
}

// MARK: - Budget

struct BudgetRow: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "budget"

    var id: String
    var budgetGroupId: String
    var name: String
    var limitMinorUnits: Int
    var currency: String
    var resetJSON: String
    var colorIndex: Int
    var sortOrder: Int
    var createdAt: Date
    var updatedAt: Date
    var isDeleted: Bool

    init(_ model: Budget) throws {
        id = model.id.dbValue
        budgetGroupId = model.groupID.dbValue
        name = model.name
        limitMinorUnits = model.limit.minorUnits
        currency = model.limit.currency.rawValue
        resetJSON = try RowCoding.encode(model.reset)
        colorIndex = model.colorIndex
        sortOrder = model.sortOrder
        createdAt = model.createdAt
        updatedAt = model.updatedAt
        isDeleted = model.isDeleted
    }

    func model() throws -> Budget {
        guard let currencyValue = Currency(rawValue: currency) else {
            throw StoreError.corruptRow("unknown currency '\(currency)'")
        }
        return Budget(
            id: BudgetID(try RowCoding.uuid(id)),
            groupID: GroupID(try RowCoding.uuid(budgetGroupId)),
            name: name,
            limit: Money(minorUnits: limitMinorUnits, currency: currencyValue),
            reset: try RowCoding.decode(ResetSchedule.self, from: resetJSON),
            colorIndex: colorIndex, sortOrder: sortOrder,
            createdAt: createdAt, updatedAt: updatedAt, isDeleted: isDeleted
        )
    }
}

// MARK: - Transaction

struct TransactionRow: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "transactionRecord"

    var id: String
    var budgetId: String
    var budgetGroupId: String
    var date: Date
    var merchant: String
    var note: String
    var amountMinorUnits: Int
    var currency: String
    var source: String
    var receiptId: String?
    var importFingerprint: String?
    var createdBy: String?
    var createdAt: Date
    var updatedAt: Date
    var isDeleted: Bool

    init(_ model: Transaction) {
        id = model.id.dbValue
        budgetId = model.budgetID.dbValue
        budgetGroupId = model.groupID.dbValue
        date = model.date
        merchant = model.merchant
        note = model.note
        amountMinorUnits = model.amount.minorUnits
        currency = model.amount.currency.rawValue
        source = model.source.rawValue
        receiptId = model.receiptID?.dbValue
        importFingerprint = model.importFingerprint
        createdBy = model.createdBy?.dbValue
        createdAt = model.createdAt
        updatedAt = model.updatedAt
        isDeleted = model.isDeleted
    }

    func model() throws -> Transaction {
        guard let currencyValue = Currency(rawValue: currency) else {
            throw StoreError.corruptRow("unknown currency '\(currency)'")
        }
        guard let sourceValue = TransactionSource(rawValue: source) else {
            throw StoreError.corruptRow("unknown source '\(source)'")
        }
        return Transaction(
            id: RecordID(try RowCoding.uuid(id)),
            budgetID: BudgetID(try RowCoding.uuid(budgetId)),
            groupID: GroupID(try RowCoding.uuid(budgetGroupId)),
            date: date, merchant: merchant, note: note,
            amount: Money(minorUnits: amountMinorUnits, currency: currencyValue),
            source: sourceValue,
            receiptID: try receiptId.map { RecordID(try RowCoding.uuid($0)) },
            importFingerprint: importFingerprint,
            createdBy: try createdBy.map { UserID(try RowCoding.uuid($0)) },
            createdAt: createdAt, updatedAt: updatedAt, isDeleted: isDeleted
        )
    }
}

// MARK: - Member profile

struct MemberProfileRow: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "memberProfile"

    var id: String
    var budgetGroupId: String
    var userId: String
    var displayName: String
    var updatedAt: Date
    var isDeleted: Bool

    init(_ model: MemberProfile) {
        id = model.id.dbValue
        budgetGroupId = model.groupID.dbValue
        userId = model.userID.dbValue
        displayName = model.displayName
        updatedAt = model.updatedAt
        isDeleted = model.isDeleted
    }

    func model() throws -> MemberProfile {
        MemberProfile(groupID: GroupID(try RowCoding.uuid(budgetGroupId)),
                      userID: UserID(try RowCoding.uuid(userId)),
                      displayName: displayName, updatedAt: updatedAt, isDeleted: isDeleted)
    }
}

// MARK: - Receipt

/// The four read fields travel together as JSON. They are never queried
/// individually, so columns would buy nothing.
private struct ExtractedBundle: Codable {
    var merchant: ExtractedField?
    var total: ExtractedField?
    var date: ExtractedField?
    var tax: ExtractedField?
}

struct ReceiptRow: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "receipt"

    var id: String
    var budgetGroupId: String
    var budgetId: String?
    var filename: String
    var mediaType: String
    var byteCount: Int
    var plaintextSHA256: Data
    var capturedAt: Date
    var extractedJSON: String
    var rawText: String
    var transactionId: String?
    var createdAt: Date
    var updatedAt: Date
    var isDeleted: Bool

    init(_ model: Receipt) throws {
        id = model.id.dbValue
        budgetGroupId = model.groupID.dbValue
        budgetId = model.budgetID?.dbValue
        filename = model.filename
        mediaType = model.mediaType
        byteCount = model.byteCount
        plaintextSHA256 = model.plaintextSHA256
        capturedAt = model.capturedAt
        extractedJSON = try RowCoding.encode(ExtractedBundle(
            merchant: model.merchant, total: model.total, date: model.date, tax: model.tax))
        rawText = model.rawText
        transactionId = model.transactionID?.dbValue
        createdAt = model.createdAt
        updatedAt = model.updatedAt
        isDeleted = model.isDeleted
    }

    func model() throws -> Receipt {
        let bundle = try RowCoding.decode(ExtractedBundle.self, from: extractedJSON)
        return Receipt(
            id: RecordID(try RowCoding.uuid(id)),
            groupID: GroupID(try RowCoding.uuid(budgetGroupId)),
            budgetID: try budgetId.map { BudgetID(try RowCoding.uuid($0)) },
            filename: filename, mediaType: mediaType, byteCount: byteCount,
            plaintextSHA256: plaintextSHA256, capturedAt: capturedAt,
            merchant: bundle.merchant, total: bundle.total, date: bundle.date, tax: bundle.tax,
            rawText: rawText,
            transactionID: try transactionId.map { RecordID(try RowCoding.uuid($0)) },
            createdAt: createdAt, updatedAt: updatedAt, isDeleted: isDeleted
        )
    }
}

// MARK: - Statement

struct StatementRow: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "importedStatement"

    var id: String
    var budgetGroupId: String
    var filename: String
    var format: String
    var accountHint: String
    var importedAt: Date
    var rowCount: Int
    var addedCount: Int
    var skippedCount: Int
    var createdAt: Date
    var updatedAt: Date
    var isDeleted: Bool

    init(_ model: ImportedStatement) {
        id = model.id.dbValue
        budgetGroupId = model.groupID.dbValue
        filename = model.filename
        format = model.format
        accountHint = model.accountHint
        importedAt = model.importedAt
        rowCount = model.rowCount
        addedCount = model.addedCount
        skippedCount = model.skippedCount
        createdAt = model.createdAt
        updatedAt = model.updatedAt
        isDeleted = model.isDeleted
    }

    func model() throws -> ImportedStatement {
        ImportedStatement(
            id: RecordID(try RowCoding.uuid(id)),
            groupID: GroupID(try RowCoding.uuid(budgetGroupId)),
            filename: filename, format: format, accountHint: accountHint,
            importedAt: importedAt, rowCount: rowCount, addedCount: addedCount,
            skippedCount: skippedCount, createdAt: createdAt, updatedAt: updatedAt,
            isDeleted: isDeleted
        )
    }
}

// MARK: - Sync bookkeeping

struct OutboxRow: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "outbox"

    var recordId: String
    var recordType: String
    var budgetGroupId: String
    var budgetId: String?
    var lamport: Int64
    var isDeleted: Bool
    var queuedAt: Date
    /// Queued only to be sealed again under a new key, with no edit of its own.
    var isReseal: Bool
    /// Set when a re-seal is owed on top of an edit: the Lamport value the
    /// edit was made at. Nil for a plain edit and for a plain re-seal.
    var editLamport: Int64?

    /// Whether a re-seal is owed, with or without an edit of its own.
    var owesReseal: Bool { isReseal || editLamport != nil }
}

struct SyncStateRow: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "syncState"

    var budgetGroupId: String
    var serverSeq: Int64
    var lamport: Int64
    var lastSyncedAt: Date?
}

struct MembershipEntryRow: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "membershipEntry"

    var budgetGroupId: String
    var sequence: Int64
    var entryJSON: String
}

struct ScopedKeyRow: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "scopedKey"

    var scopeKind: String
    var scopeId: String
    var epoch: Int64
    var material: Data
}

struct ConflictCopyRow: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "conflictCopy"

    var id: Int64?
    var recordId: String
    var recordType: String
    var payloadJSON: String
    var lamport: Int64
    var authorDeviceId: String
    var seenAt: Date

    mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}

struct RecordVersionRow: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "recordVersion"

    var recordId: String
    var lamport: Int64
    var authorDeviceId: String
    var serverSeq: Int64
    var authorUserId: String?
}
