import Foundation
import GRDB
import WellSpentCrypto
import WellSpentModel

public extension Store {
    /// The transaction in `group` holding an import fingerprint, deleted or
    /// not, if there is one. The database allows one per group, counting
    /// deleted rows, so this is what a save would clash with.
    func transaction(withFingerprint fingerprint: String, in group: GroupID) throws -> RecordID? {
        try database.read { db in
            try String.fetchOne(db, sql: """
                SELECT id FROM transactionRecord WHERE budgetGroupId = ? AND importFingerprint = ?
                """, arguments: [group.dbValue, fingerprint])
                .map { RecordID(try RowCoding.uuid($0)) }
        }
    }

    /// Saves a row imported from a statement. A deleted row holding the
    /// same mark, such as one whose budget was deleted, gives it up first
    /// and keeps it to one side to send, as it does for a live row arriving
    /// from the server. Saved plainly, the two clashed and the import
    /// stopped partway.
    func saveImported(_ transaction: Transaction) throws {
        try inOneTransaction { store in
            if let fingerprint = transaction.importFingerprint,
               let holder = try store.transaction(withFingerprint: fingerprint, in: transaction.groupID),
               holder != transaction.id, var held = try store.transaction(holder), held.isDeleted {
                held.importFingerprint = nil
                try store.save(held, queue: false)
                try store.holdFingerprint(fingerprint, for: holder)
            }
            try store.save(transaction)
        }
    }

    /// Keeps a fingerprint this Mac cleared from a pulled transaction, because
    /// it already held another row with it. It goes back out with the row.
    func holdFingerprint(_ fingerprint: String, for id: RecordID) throws {
        try database.write { db in
            try db.execute(sql: """
                INSERT INTO heldFingerprint (recordId, fingerprint) VALUES (?, ?)
                ON CONFLICT(recordId) DO UPDATE SET fingerprint = excluded.fingerprint
                """, arguments: [id.dbValue, fingerprint])
        }
    }

    /// The fingerprint kept for a transaction, if one was cleared on arrival.
    func heldFingerprint(for id: RecordID) throws -> String? {
        try database.read { db in
            try String.fetchOne(db, sql: "SELECT fingerprint FROM heldFingerprint WHERE recordId = ?",
                                arguments: [id.dbValue])
        }
    }

    /// Whether a save failed for a reason that will happen again, the same
    /// way, however often it is tried: a constraint. A full disk or an input
    /// or output error can clear up, and is not this.
    static func isLastingFailure(_ error: any Error) -> Bool {
        (error as? DatabaseError)?.resultCode == .SQLITE_CONSTRAINT
    }
}
