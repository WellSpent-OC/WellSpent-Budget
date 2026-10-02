import Foundation
import WellSpentCrypto

/// Everything that gets encrypted and synced conforms to this.
///
/// `id` is generated on the client, before the record has ever reached a server.
/// That is not laziness, it is the only thing that works offline: a device has to
/// be able to name a record it just created without asking permission.
public protocol SyncedRecord: Codable, Sendable, Identifiable {
    associatedtype Key: OpaqueID
    var id: Key { get }
    var updatedAt: Date { get set }
    var isDeleted: Bool { get set }
    static var recordType: RecordType { get }
}

// MARK: - Group

/// The unit of sharing, and therefore the unit of encryption.
///
/// Every budget belongs to exactly one group. Sharing a single budget on its own
/// means putting it in a group by itself. That keeps one key per group rather than
/// a web of per-budget grants, and it is why the sidebar has no other grouping.
public struct BudgetGroup: SyncedRecord, Equatable {
    public var id: GroupID
    public var name: String
    public var note: String
    public var createdAt: Date
    public var updatedAt: Date
    public var isDeleted: Bool

    public static var recordType: RecordType { .groupMeta }

    public init(id: GroupID = GroupID(), name: String, note: String = "",
                createdAt: Date = Date(), updatedAt: Date = Date(), isDeleted: Bool = false) {
        self.id = id
        self.name = name
        self.note = note
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.isDeleted = isDeleted
    }
}

// MARK: - Budget

/// When a budget's spending counter goes back to zero.
public enum ResetSchedule: Codable, Sendable, Equatable {
    /// Every month, on these days. The old schema stored this as a comma-separated
    /// string called `reset_dates` and handed the client an array. Same idea,
    /// without the string parsing.
    case monthly(days: [Int])
    case weekly(weekday: Int)      // 1 = Sunday, matching Calendar
    case never

    public static let firstOfMonth = ResetSchedule.monthly(days: [1])

    public var isValid: Bool {
        switch self {
        case .monthly(let days): return !days.isEmpty && days.allSatisfy { (1 ... 31).contains($0) }
        case .weekly(let weekday): return (1 ... 7).contains(weekday)
        case .never: return true
        }
    }
}

public struct Budget: SyncedRecord, Equatable {
    public var id: BudgetID
    public var groupID: GroupID
    public var name: String
    public var limit: Money
    public var reset: ResetSchedule
    public var colorIndex: Int
    public var sortOrder: Int
    public var createdAt: Date
    public var updatedAt: Date
    public var isDeleted: Bool

    public static var recordType: RecordType { .budget }

    public init(id: BudgetID = BudgetID(), groupID: GroupID, name: String, limit: Money,
                reset: ResetSchedule = .firstOfMonth, colorIndex: Int = 0, sortOrder: Int = 0,
                createdAt: Date = Date(), updatedAt: Date = Date(), isDeleted: Bool = false) {
        self.id = id
        self.groupID = groupID
        self.name = name
        self.limit = limit
        self.reset = reset
        self.colorIndex = colorIndex
        self.sortOrder = sortOrder
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.isDeleted = isDeleted
    }
}

// MARK: - Transaction

/// Where a transaction came from, which drives what the app is allowed to
/// overwrite when a statement is imported again.
public enum TransactionSource: String, Codable, Sendable {
    case manual
    case statement
    case receipt
}

public struct Transaction: SyncedRecord, Equatable {
    public var id: RecordID
    public var budgetID: BudgetID
    public var groupID: GroupID
    public var date: Date
    public var merchant: String
    public var note: String
    /// Negative is money out. A budget counts spending, so most rows are negative.
    public var amount: Money
    public var source: TransactionSource
    public var receiptID: RecordID?
    /// Set when this row came from a statement, so re-importing the same file does
    /// not duplicate it. Computed locally and kept inside the encrypted record,
    /// never handed to the server as an index it could correlate on.
    public var importFingerprint: String?
    /// Who added it. A member who can only add may change their own transactions
    /// and nobody else's, so this is checked on every incoming edit: it has to
    /// match the signed author of the first version, and it can never change.
    /// Nil until the record is first pushed, which stamps it with the signed-in
    /// person, so transactions made before signing in still get an owner.
    public var createdBy: UserID?
    public var createdAt: Date
    public var updatedAt: Date
    public var isDeleted: Bool

    public static var recordType: RecordType { .transaction }

    public init(id: RecordID = RecordID(), budgetID: BudgetID, groupID: GroupID, date: Date,
                merchant: String, note: String = "", amount: Money,
                source: TransactionSource = .manual, receiptID: RecordID? = nil,
                importFingerprint: String? = nil, createdBy: UserID? = nil,
                createdAt: Date = Date(), updatedAt: Date = Date(), isDeleted: Bool = false) {
        self.id = id
        self.budgetID = budgetID
        self.groupID = groupID
        self.date = date
        self.merchant = merchant
        self.note = note
        self.amount = amount
        self.source = source
        self.receiptID = receiptID
        self.importFingerprint = importFingerprint
        self.createdBy = createdBy
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.isDeleted = isDeleted
    }
}

// MARK: - Member profile

/// The name a member shows to the rest of a group.
///
/// The membership log knows people only by ID, and the server knows their email,
/// which is not something to show everyone else in the group. So each person
/// writes their own name into each group they are in, sealed with that group's
/// key like everything else. One record per person per group, and only that
/// person may write it.
public struct MemberProfile: SyncedRecord, Equatable {
    public var id: RecordID
    public var groupID: GroupID
    public var userID: UserID
    public var displayName: String
    public var updatedAt: Date
    public var isDeleted: Bool

    public static var recordType: RecordType { .memberProfile }

    public init(groupID: GroupID, userID: UserID, displayName: String,
                updatedAt: Date = Date(), isDeleted: Bool = false) {
        self.id = Self.recordID(group: groupID, user: userID)
        self.groupID = groupID
        self.userID = userID
        self.displayName = displayName
        self.updatedAt = updatedAt
        self.isDeleted = isDeleted
    }

    /// The same on every device, so a name set twice updates one record rather
    /// than making two.
    public static func recordID(group: GroupID, user: UserID) -> RecordID {
        .memberProfile(group: group, user: user)
    }
}

// MARK: - Receipt

/// What optical character recognition pulled off a scan, with how sure it was.
public struct ExtractedField: Codable, Sendable, Equatable {
    public var value: String
    /// 0 to 1. Below `ExtractedField.needsChecking` the UI asks a human to look.
    public var confidence: Double

    public static let needsChecking = 0.85

    public init(value: String, confidence: Double) {
        self.value = value
        self.confidence = confidence
    }

    public var isConfident: Bool { confidence >= ExtractedField.needsChecking }
}

public struct Receipt: SyncedRecord, Equatable {
    public var id: RecordID
    public var groupID: GroupID
    public var budgetID: BudgetID?
    public var filename: String
    public var mediaType: String
    public var byteCount: Int
    /// Of the plaintext, so the same scan filed twice is recognised locally.
    public var plaintextSHA256: Data
    public var capturedAt: Date
    public var merchant: ExtractedField?
    public var total: ExtractedField?
    public var date: ExtractedField?
    public var tax: ExtractedField?
    public var rawText: String
    public var transactionID: RecordID?
    public var createdAt: Date
    public var updatedAt: Date
    public var isDeleted: Bool

    public static var recordType: RecordType { .receipt }

    public init(id: RecordID = RecordID(), groupID: GroupID, budgetID: BudgetID? = nil,
                filename: String, mediaType: String = "image/jpeg", byteCount: Int,
                plaintextSHA256: Data, capturedAt: Date = Date(),
                merchant: ExtractedField? = nil, total: ExtractedField? = nil,
                date: ExtractedField? = nil, tax: ExtractedField? = nil,
                rawText: String = "", transactionID: RecordID? = nil,
                createdAt: Date = Date(), updatedAt: Date = Date(), isDeleted: Bool = false) {
        self.id = id
        self.groupID = groupID
        self.budgetID = budgetID
        self.filename = filename
        self.mediaType = mediaType
        self.byteCount = byteCount
        self.plaintextSHA256 = plaintextSHA256
        self.capturedAt = capturedAt
        self.merchant = merchant
        self.total = total
        self.date = date
        self.tax = tax
        self.rawText = rawText
        self.transactionID = transactionID
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.isDeleted = isDeleted
    }

    /// Anything the reader was unsure about, so the UI can point at it.
    public var fieldsNeedingCheck: [String] {
        var names: [String] = []
        if let merchant, !merchant.isConfident { names.append("merchant") }
        if let total, !total.isConfident { names.append("total") }
        if let date, !date.isConfident { names.append("date") }
        if let tax, !tax.isConfident { names.append("tax") }
        return names
    }
}

// MARK: - Statement

public struct ImportedStatement: SyncedRecord, Equatable {
    public var id: RecordID
    public var groupID: GroupID
    public var filename: String
    public var format: String
    public var accountHint: String
    public var importedAt: Date
    public var rowCount: Int
    public var addedCount: Int
    public var skippedCount: Int
    public var createdAt: Date
    public var updatedAt: Date
    public var isDeleted: Bool

    public static var recordType: RecordType { .statement }

    public init(id: RecordID = RecordID(), groupID: GroupID, filename: String, format: String,
                accountHint: String = "", importedAt: Date = Date(), rowCount: Int = 0,
                addedCount: Int = 0, skippedCount: Int = 0, createdAt: Date = Date(),
                updatedAt: Date = Date(), isDeleted: Bool = false) {
        self.id = id
        self.groupID = groupID
        self.filename = filename
        self.format = format
        self.accountHint = accountHint
        self.importedAt = importedAt
        self.rowCount = rowCount
        self.addedCount = addedCount
        self.skippedCount = skippedCount
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.isDeleted = isDeleted
    }
}
