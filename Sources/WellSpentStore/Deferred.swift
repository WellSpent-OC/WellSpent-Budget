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
}

extension Store {
    /// The newest version wins: a record set aside twice keeps only the later one.
    public func deferEnvelope(_ envelope: RecordEnvelope, serverSeq: UInt64) throws {
        let data = try JSONEncoder().encode(envelope)
        try database.write { db in
            try DeferredEnvelopeRow(recordId: envelope.recordID.dbValue,
                                    budgetGroupId: envelope.groupID.dbValue,
                                    recordType: envelope.recordType.rawValue,
                                    envelope: data, serverSeq: Int64(serverSeq)).save(db)
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

    public func deleteDeferredEnvelope(_ id: RecordID) throws {
        _ = try database.write { db in try DeferredEnvelopeRow.deleteOne(db, key: id.dbValue) }
    }
}
