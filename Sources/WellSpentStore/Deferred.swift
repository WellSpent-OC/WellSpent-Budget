import Foundation
import GRDB
import WellSpentCrypto

/// Envelopes of a type this build cannot read, kept whole until an update can.
struct DeferredEnvelopeRow: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "deferredEnvelope"

    var recordId: String
    var budgetGroupId: String
    var recordType: String
    var envelope: Data
    var serverSeq: Int64
    var authorUserId: String?
    var unreadable: Bool
}

extension Store {
    /// The newest version wins: a record set aside twice keeps only the later one.
    /// `unreadable` says it was set aside because this build cannot read
    /// its type or format, rather than to wait for its budget or because it
    /// could not be saved.
    public func deferEnvelope(_ envelope: RecordEnvelope, serverSeq: UInt64,
                              unreadable: Bool = false) throws {
        let data = try JSONEncoder().encode(envelope)
        try database.write { db in
            try DeferredEnvelopeRow(recordId: envelope.recordID.dbValue,
                                    budgetGroupId: envelope.groupID.dbValue,
                                    recordType: envelope.recordType.rawValue,
                                    envelope: data, serverSeq: Int64(serverSeq),
                                    authorUserId: envelope.authorUserID.dbValue,
                                    unreadable: unreadable).save(db)
        }
    }

    public func deferredEnvelopes(in group: GroupID) throws -> [(RecordEnvelope, UInt64)] {
        try database.read { db in
            try DeferredEnvelopeRow
                .filter(Column("budgetGroupId") == group.dbValue)
                .order(Column("serverSeq"))
                .fetchAll(db)
                .map { (try JSONDecoder().decode(RecordEnvelope.self, from: $0.envelope),
                        UInt64(max(0, $0.serverSeq))) }
        }
    }

    /// How many records are set aside for a group.
    public func deferredCount(in group: GroupID) throws -> Int {
        try database.read { db in
            try DeferredEnvelopeRow.filter(Column("budgetGroupId") == group.dbValue).fetchCount(db)
        }
    }

    /// How many records from `author` are set aside in a group because this
    /// build cannot read them, not counting `except`, which a new copy would
    /// replace.
    public func unreadableCount(in group: GroupID, from author: UserID, except record: RecordID) throws -> Int {
        try database.read { db in
            try DeferredEnvelopeRow
                .filter(Column("budgetGroupId") == group.dbValue)
                .filter(Column("authorUserId") == author.dbValue)
                .filter(Column("unreadable") == true)
                .filter(Column("recordId") != record.dbValue)
                .fetchCount(db)
        }
    }

    public func deleteDeferredEnvelope(_ id: RecordID) throws {
        _ = try database.write { db in try DeferredEnvelopeRow.deleteOne(db, key: id.dbValue) }
    }
}
