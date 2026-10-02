import Foundation
import GRDB
import WellSpentCrypto
import WellSpentModel

/// The local database. Plaintext, on purpose, and the whole point of local-first.
///
/// Search, totals and reports all run here, instantly, and none of those queries
/// ever reach the server. The server only ever sees sealed blobs.
///
/// At rest this file is protected by FileVault on macOS, Data Protection on iOS,
/// and by LUKS or nothing on Linux. A stolen unlocked machine reads everything.
/// That is true of every local-first app and is stated plainly in ARCHITECTURE.md
/// rather than left for someone to discover.
public final class WellSpentDatabase: Sendable {
    public let writer: any DatabaseWriter
    /// Set only on the copy `transaction` hands its caller. Every read and
    /// write on that copy runs inside the one transaction already open.
    private let joined: Joined?

    /// The open connection, which GRDB hands out only for the length of one
    /// call. The copy holding it never outlives that call, so it is never
    /// used from two places at once.
    private final class Joined: @unchecked Sendable {
        let db: Database
        init(_ db: Database) { self.db = db }
    }

    public init(writer: any DatabaseWriter) throws {
        self.writer = writer
        self.joined = nil
        try WellSpentDatabase.migrator.migrate(writer)
    }

    private init(writer: any DatabaseWriter, joining db: Database) {
        self.writer = writer
        self.joined = Joined(db)
    }

    public static func open(at url: URL) throws -> WellSpentDatabase {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        var config = Configuration()
        config.foreignKeysEnabled = true
        let pool = try DatabasePool(path: url.path, configuration: config)
        return try WellSpentDatabase(writer: pool)
    }

    public static func inMemory() throws -> WellSpentDatabase {
        var config = Configuration()
        config.foreignKeysEnabled = true
        return try WellSpentDatabase(writer: try DatabaseQueue(configuration: config))
    }

    public func read<T>(_ work: (Database) throws -> T) throws -> T {
        if let joined { return try work(joined.db) }
        return try writer.read(work)
    }

    @discardableResult
    public func write<T>(_ work: (Database) throws -> T) throws -> T {
        if let joined { return try work(joined.db) }
        return try writer.write(work)
    }

    /// Runs `work` as one write transaction. The database it is handed joins
    /// that transaction, so several calls made through it land together, and
    /// no other write lands between them. It must not be kept past `work`.
    public func transaction<T>(_ work: (WellSpentDatabase) throws -> T) throws -> T {
        if joined != nil { return try work(self) }
        return try writer.write { db in try work(WellSpentDatabase(writer: writer, joining: db)) }
    }

    // MARK: - Migrations

    public static var migrator: DatabaseMigrator {
        var m = DatabaseMigrator()

        // Real foreign keys, unlike the 2014 schema, which declared
        // `t.belongs_to` and got an indexed column with no constraint. That is why
        // deleting a budget there left orphaned transactions and memberships that
        // crashed the API on load.
        m.registerMigration("v1") { db in
            try db.create(table: "budgetGroup") { t in
                t.primaryKey("id", .text)
                t.column("name", .text).notNull()
                t.column("note", .text).notNull().defaults(to: "")
                t.column("createdAt", .datetime).notNull()
                t.column("updatedAt", .datetime).notNull()
                t.column("isDeleted", .boolean).notNull().defaults(to: false)
            }

            try db.create(table: "budget") { t in
                t.primaryKey("id", .text)
                t.belongsTo("budgetGroup", onDelete: .cascade).notNull()
                t.column("name", .text).notNull()
                t.column("limitMinorUnits", .integer).notNull()
                t.column("currency", .text).notNull()
                t.column("resetJSON", .text).notNull()
                t.column("colorIndex", .integer).notNull().defaults(to: 0)
                t.column("sortOrder", .integer).notNull().defaults(to: 0)
                t.column("createdAt", .datetime).notNull()
                t.column("updatedAt", .datetime).notNull()
                t.column("isDeleted", .boolean).notNull().defaults(to: false)
            }

            try db.create(table: "transactionRecord") { t in
                t.primaryKey("id", .text)
                t.belongsTo("budget", onDelete: .cascade).notNull()
                t.column("budgetGroupId", .text).notNull().indexed()
                t.column("date", .datetime).notNull().indexed()
                t.column("merchant", .text).notNull()
                t.column("note", .text).notNull().defaults(to: "")
                t.column("amountMinorUnits", .integer).notNull()
                t.column("currency", .text).notNull()
                t.column("source", .text).notNull()
                t.column("receiptId", .text)
                t.column("importFingerprint", .text)
                t.column("createdAt", .datetime).notNull()
                t.column("updatedAt", .datetime).notNull()
                t.column("isDeleted", .boolean).notNull().defaults(to: false)
            }
            // Re-importing the same statement must not duplicate rows. A partial
            // index so the many manual rows with no fingerprint do not collide.
            try db.create(
                index: "transactionRecord_on_fingerprint",
                on: "transactionRecord", columns: ["budgetGroupId", "importFingerprint"],
                unique: true, condition: Column("importFingerprint") != nil
            )

            try db.create(table: "receipt") { t in
                t.primaryKey("id", .text)
                t.column("budgetGroupId", .text).notNull().indexed()
                t.column("budgetId", .text).indexed()
                t.column("filename", .text).notNull()
                t.column("mediaType", .text).notNull()
                t.column("byteCount", .integer).notNull()
                t.column("plaintextSHA256", .blob).notNull().indexed()
                t.column("capturedAt", .datetime).notNull()
                t.column("extractedJSON", .text).notNull()
                t.column("rawText", .text).notNull().defaults(to: "")
                t.column("transactionId", .text).indexed()
                t.column("createdAt", .datetime).notNull()
                t.column("updatedAt", .datetime).notNull()
                t.column("isDeleted", .boolean).notNull().defaults(to: false)
            }

            try db.create(table: "importedStatement") { t in
                t.primaryKey("id", .text)
                t.column("budgetGroupId", .text).notNull().indexed()
                t.column("filename", .text).notNull()
                t.column("format", .text).notNull()
                t.column("accountHint", .text).notNull().defaults(to: "")
                t.column("importedAt", .datetime).notNull()
                t.column("rowCount", .integer).notNull().defaults(to: 0)
                t.column("addedCount", .integer).notNull().defaults(to: 0)
                t.column("skippedCount", .integer).notNull().defaults(to: 0)
                t.column("createdAt", .datetime).notNull()
                t.column("updatedAt", .datetime).notNull()
                t.column("isDeleted", .boolean).notNull().defaults(to: false)
            }

            // Writes waiting to be sealed and pushed. Keyed by record so a row
            // edited five times offline pushes once.
            try db.create(table: "outbox") { t in
                t.primaryKey("recordId", .text)
                t.column("recordType", .text).notNull()
                t.column("budgetGroupId", .text).notNull().indexed()
                t.column("budgetId", .text)
                t.column("lamport", .integer).notNull()
                t.column("isDeleted", .boolean).notNull().defaults(to: false)
                t.column("queuedAt", .datetime).notNull()
            }

            // One row per group: how far we have pulled, and our clock.
            try db.create(table: "syncState") { t in
                t.primaryKey("budgetGroupId", .text)
                t.column("serverSeq", .integer).notNull().defaults(to: 0)
                t.column("lamport", .integer).notNull().defaults(to: 0)
                t.column("lastSyncedAt", .datetime)
            }

            // The signed, chained access history, kept locally so the client can
            // replay and verify it rather than trusting what the server says.
            try db.create(table: "membershipEntry") { t in
                t.column("budgetGroupId", .text).notNull()
                t.column("sequence", .integer).notNull()
                t.column("entryJSON", .text).notNull()
                t.primaryKey(["budgetGroupId", "sequence"])
            }

            // Group and budget keys, unwrapped, cached so startup skips the HPKE work.
            try db.create(table: "scopedKey") { t in
                t.column("scopeKind", .text).notNull()
                t.column("scopeId", .text).notNull()
                t.column("epoch", .integer).notNull()
                t.column("material", .blob).notNull()
                t.primaryKey(["scopeKind", "scopeId", "epoch"])
            }

            // What version of each record we last accepted, so an incoming
            // envelope can be compared without decrypting it first.
            try db.create(table: "recordVersion") { t in
                t.primaryKey("recordId", .text)
                t.column("lamport", .integer).notNull()
                t.column("authorDeviceId", .text).notNull()
                t.column("serverSeq", .integer).notNull().defaults(to: 0)
            }

            // Conflict losers, kept rather than discarded. A field someone typed
            // should never vanish with no trace.
            try db.create(table: "conflictCopy") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("recordId", .text).notNull().indexed()
                t.column("recordType", .text).notNull()
                t.column("payloadJSON", .text).notNull()
                t.column("lamport", .integer).notNull()
                t.column("authorDeviceId", .text).notNull()
                t.column("seenAt", .datetime).notNull()
            }
        }

        // Local full-text search over descriptions. This is a real payoff of
        // local-first: the search runs on the device and the server never learns
        // what was searched for.
        m.registerMigration("v1-fts") { db in
            try db.create(virtualTable: "transactionSearch", using: FTS5()) { t in
                t.synchronize(withTable: "transactionRecord")
                t.column("merchant")
                t.column("note")
                t.tokenizer = .porter(wrapping: .unicode61())
            }
        }

        // Sharing: who added each transaction, and the name each member shows the
        // rest of a group.
        m.registerMigration("v2-sharing") { db in
            try db.alter(table: "transactionRecord") { t in
                t.add(column: "createdBy", .text)
            }
            try db.create(table: "memberProfile") { t in
                t.primaryKey("id", .text)
                t.belongsTo("budgetGroup", onDelete: .cascade).notNull()
                t.column("userId", .text).notNull()
                t.column("displayName", .text).notNull()
                t.column("updatedAt", .datetime).notNull()
                t.column("isDeleted", .boolean).notNull().defaults(to: false)
            }
        }

        // Invites this device sent, with the secret that verifies the answer, and
        // groups it asked to join. Both local only: neither ever syncs.
        m.registerMigration("v3-invites") { db in
            try db.create(table: "sentInvite") { t in
                t.primaryKey("id", .blob)
                t.column("budgetGroupId", .text).notNull()
                t.column("secret", .blob).notNull()
                t.column("level", .integer).notNull()
                t.column("historyAccess", .text).notNull()
                t.column("expiresAt", .datetime).notNull()
                t.column("createdAt", .datetime).notNull()
            }
            try db.create(table: "pendingJoin") { t in
                t.primaryKey("budgetGroupId", .text)
                t.column("groupName", .text).notNull()
                t.column("inviterName", .text).notNull()
                t.column("displayName", .text).notNull()
                t.column("level", .integer).notNull()
                t.column("requestedAt", .datetime).notNull()
            }
        }

        // Envelopes from a newer version of the app, in a type this one cannot
        // read yet. Applied after an update rather than lost.
        m.registerMigration("v4-deferred") { db in
            try db.create(table: "deferredEnvelope") { t in
                t.primaryKey("recordId", .text)
                t.column("budgetGroupId", .text).notNull()
                t.column("recordType", .text).notNull()
                t.column("envelope", .blob).notNull()
                t.column("serverSeq", .integer).notNull()
            }
        }

        // Rows queued only to seal a record again under a new key, with no
        // edit of their own. A newer edit pulled from someone else must win
        // over such a row, where it would lose to a real edit made here.
        m.registerMigration("v5-outbox-reseal") { db in
            try db.alter(table: "outbox") { t in
                t.add(column: "isReseal", .boolean).notNull().defaults(to: false)
            }
        }

        // A re-seal queued over an edit not yet sent shares the edit's row.
        // The row keeps the Lamport value the edit was made at, so the edit is
        // weighed as it was, and a value here also says a re-seal is still
        // owed if the edit loses.
        m.registerMigration("v6-outbox-edit-lamport") { db in
            try db.alter(table: "outbox") { t in
                t.add(column: "editLamport", .integer)
            }
        }

        return m
    }
}
