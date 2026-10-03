import Foundation
import Fluent
import WellSpentCrypto

/// The schema as first shipped. Later changes are migrations of their own, below,
/// because databases in use already hold this one.
///
/// Written against `Migration` rather than the raw SQL the old API used. Fluent's
/// schema builder has no index API at all, only `unique(on:)` and `constraint(_:)`,
/// so every index here is the side effect of a unique constraint. That covers
/// every column the request path filters on: users.email, tokens.value_hash,
/// memberships(group_id, user_id), membership_log(group_id, sequence),
/// records(group_id, server_seq) and invites.invite_hash.
///
/// Not covered: wrapped_keys(group_id, recipient_user_id), which cannot be unique
/// because a recipient holds one row per epoch and scope. Small table, cold path.
/// Add a raw CREATE INDEX here if fetching keys ever gets slow.
struct CreateSchema: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema(UserRow.schema)
            .field("id", .uuid, .identifier(auto: false))
            .field("email", .string, .required)
            .field("password_hash", .string, .required)
            .field("identity_signing", .data, .required)
            .field("identity_kem", .data, .required)
            .field("created_at", .datetime)
            .unique(on: "email")
            .create()

        try await database.schema(EscrowRow.schema)
            .field("id", .uuid, .identifier(auto: false))
            .field("user_id", .uuid, .required)
            .field("nonce", .data, .required)
            .field("ciphertext", .data, .required)
            .field("created_at", .datetime)
            .unique(on: "user_id")
            .create()

        try await database.schema(TokenRow.schema)
            .field("id", .uuid, .identifier(auto: false))
            .field("user_id", .uuid, .required)
            .field("value_hash", .string, .required)
            .field("expires_on", .datetime, .required)
            .unique(on: "value_hash")
            .create()

        try await database.schema(GroupRow.schema)
            .field("id", .uuid, .identifier(auto: false))
            .field("founder_id", .uuid, .required)
            .field("epoch", .int, .required)
            .field("created_at", .datetime)
            .create()

        try await database.schema(MembershipEntryRow.schema)
            .field("id", .uuid, .identifier(auto: false))
            .field("group_id", .uuid, .required)
            .field("sequence", .int, .required)
            .field("entry", .data, .required)
            // The chain has exactly one entry per position. This constraint is
            // what stops a replayed request forking the history.
            .unique(on: "group_id", "sequence")
            .create()

        try await database.schema(MembershipRow.schema)
            .field("id", .uuid, .identifier(auto: false))
            .field("group_id", .uuid, .required)
            .field("user_id", .uuid, .required)
            .field("level", .int, .required)
            .field("joined_at_sequence", .int, .required)
            .unique(on: "group_id", "user_id")
            .create()

        try await database.schema(WrappedKeyRow.schema)
            .field("id", .uuid, .identifier(auto: false))
            .field("group_id", .uuid, .required)
            .field("scope_kind", .string, .required)
            .field("scope_id", .uuid, .required)
            .field("epoch", .int, .required)
            .field("recipient_user_id", .uuid)
            .field("payload", .data, .required)
            .create()

        try await database.schema(RecordRow.schema)
            .field("id", .uuid, .identifier(auto: false))
            .field("group_id", .uuid, .required)
            .field("budget_id", .uuid)
            .field("record_type", .string, .required)
            .field("server_seq", .int, .required)
            .field("lamport", .int, .required)
            .field("author_user_id", .uuid, .required)
            .field("author_device_id", .uuid, .required)
            .field("is_deleted", .bool, .required)
            .field("envelope", .data, .required)
            .field("updated_at", .datetime)
            // The pull cursor is this column. Two concurrent pushes both read the
            // same high-water mark, so the database has to be the thing that
            // refuses the duplicate: a repeated sequence silently loses a record
            // for every client that pulls past it. On Postgres this index is also
            // what makes the pull query a range scan rather than a table scan.
            .unique(on: "group_id", "server_seq")
            .create()

        try await database.schema(InviteRow.schema)
            .field("id", .uuid, .identifier(auto: false))
            .field("invite_hash", .data, .required)
            .field("group_id", .uuid, .required)
            .field("inviter_user_id", .uuid, .required)
            .field("level", .int, .required)
            .field("history_access", .string, .required)
            .field("expires_at", .datetime, .required)
            .field("acceptance", .data)
            .field("accepted_at", .datetime)
            .unique(on: "invite_hash")
            .create()
    }

    func revert(on database: any Database) async throws {
        for schema in [InviteRow.schema, RecordRow.schema, WrappedKeyRow.schema,
                       MembershipRow.schema, MembershipEntryRow.schema, GroupRow.schema,
                       TokenRow.schema, EscrowRow.schema, UserRow.schema] {
            try await database.schema(schema).delete()
        }
    }
}

/// Each group's highest stored Lamport value, so a push can be judged against
/// it without reading every record (`RecordEnvelope.lamportLead`).
///
/// The first migration to run against a database already in use. It adds one
/// column with a default, which Postgres and SQLite both do in place, and then
/// fills it from the records each group already holds. Nothing is deleted or
/// rewritten.
///
/// Both steps run in one transaction, and the column is added only when it is
/// not there. Fluent records a migration as done only after it returns, so a
/// start cut short before that tried to add the column again on every start
/// after, and the server could not start until someone dropped it by hand.
/// Now a second run finds the column, fills it again, which never lowers a
/// value, and finishes.
struct AddGroupMaxLamport: AsyncMigration {
    func prepare(on database: any Database) async throws {
        // Asked outside the transaction: on Postgres a failed statement
        // spoils the transaction it runs in. An empty table answers nil,
        // which still means the column is there.
        let hasColumn: Bool
        do {
            _ = try await GroupRow.query(on: database).max(\.$maxLamport)
            hasColumn = true
        } catch {
            hasColumn = false
        }
        try await database.transaction { database in
            if !hasColumn {
                // A raw default rather than Fluent's SQL helper, so this needs
                // no import beyond Fluent. Both drivers take it as written.
                try await database.schema(GroupRow.schema)
                    .field("max_lamport", .int, .required, .custom("DEFAULT 0"))
                    .update()
            }
            try await fillGroupMaxLamport(on: database)
        }
    }

    func revert(on database: any Database) async throws {
        try await database.schema(GroupRow.schema).deleteField("max_lamport").update()
    }
}

/// Sets each group's highest stored Lamport value from its records. It never
/// lowers one. A value at or above the ceiling is left out: one stored before
/// the ceiling existed would otherwise let every later push through, however
/// far ahead it was.
func fillGroupMaxLamport(on database: any Database) async throws {
    let ceiling = Int(RecordEnvelope.lamportCeiling)
    for group in try await GroupRow.query(on: database).all() {
        let highest = try await RecordRow.query(on: database)
            .filter(\.$groupID == group.requireID())
            .filter(\.$lamport < ceiling)
            .max(\.$lamport) ?? 0
        guard highest > group.maxLamport else { continue }
        group.maxLamport = highest
        try await group.save(on: database)
    }
    let above = try await RecordRow.query(on: database).filter(\.$lamport >= ceiling).count()
    if above > 0 {
        // Not fixed here. Every app now ignores these records, and a Mac that
        // took one in before the upgrade cannot save in that group. See the
        // ceiling in ARCHITECTURE.md.
        database.logger.warning("\(above) stored records have a Lamport value at or above the ceiling")
    }
}
