import Fluent
import SQLKit
import Vapor

/// Additive, including on SQLite. Old links keep all their existing columns.
struct AddEmailInvitations: AsyncMigration {
    private var columns: [(String, DatabaseSchema.DataType)] {
        [("invitee_email", .string), ("invitee_name", .string), ("inviter_name", .string),
         ("created_at", .datetime), ("rejected_at", .datetime), ("cancelled_at", .datetime),
         ("closed_at", .datetime), ("mail_attempts", .int), ("mail_next_attempt_at", .datetime),
         ("mail_claimed_until", .datetime), ("mail_sent_at", .datetime),
         ("mail_stopped_at", .datetime), ("mail_stop_hash", .data)]
    }

    func prepare(on database: any Database) async throws {
        guard let sql = database as? any SQLDatabase else { throw Abort(.internalServerError) }
        // Probe outside the transaction: a missing column aborts a Postgres transaction.
        var missing: [(String, DatabaseSchema.DataType)] = []
        for (name, type) in columns {
            do { _ = try await sql.select().column(name).from(InviteRow.schema).limit(0).all() }
            catch { missing.append((name, type)) }
        }
        let additions = missing
        try await database.transaction { database in
            for (name, type) in additions {
                try await database.schema(InviteRow.schema).field(.string(name), type).update()
            }
        }
        try await sql.raw("CREATE INDEX IF NOT EXISTS invites_email_idx ON invites (invitee_email)").run()
        // One cross-database lock serializes the two persistent email quotas.
        try await sql.raw("CREATE TABLE IF NOT EXISTS invitation_send_guard (id INTEGER PRIMARY KEY)").run()
        try await sql.raw("INSERT INTO invitation_send_guard (id) VALUES (1) ON CONFLICT DO NOTHING").run()
        try await sql.raw("CREATE TABLE IF NOT EXISTS invite_email_suppressions (address_hash TEXT PRIMARY KEY)").run()
    }

    func revert(on database: any Database) async throws {
        guard let sql = database as? any SQLDatabase else { throw Abort(.internalServerError) }
        try await sql.raw("DROP INDEX IF EXISTS invites_email_idx").run()
        for (name, _) in columns.reversed() {
            try await database.schema(InviteRow.schema).deleteField(.string(name)).update()
        }
        try await sql.raw("DROP TABLE IF EXISTS invitation_send_guard").run()
        try await sql.raw("DROP TABLE IF EXISTS invite_email_suppressions").run()
    }
}
