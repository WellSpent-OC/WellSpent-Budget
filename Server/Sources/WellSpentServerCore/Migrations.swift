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

/// The tables and columns for readable sync, added beside the sealed ones.
///
/// On 2026-10-08 the project dropped end-to-end encryption: the server will store
/// records it can read, check who may change what itself, and let any device sign
/// in. This migration only adds. Nothing that runs today reads or writes what it
/// adds, so a server with it applied behaves exactly as before. The sealed tables
/// go in a later migration, after every account has moved.
///
/// Safe to run again after a start cut short, like `AddGroupMaxLamport`: each
/// table is created only if missing, and each added column is added only if
/// missing.
struct AddReadableSync: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema(SyncRecordRow.schema)
            .field("id", .uuid, .identifier(auto: false))
            .field("group_id", .uuid, .required)
            .field("budget_id", .uuid)
            .field("record_type", .string, .required)
            // The record itself, as JSON the server reads to check it.
            .field("body", .string, .required)
            // Who first stored it. Set once and never changed, because "a member
            // at Add may change only their own entries" needs an owner nobody can
            // rewrite. The sealed table overwrote its author on every update.
            .field("created_by_user_id", .uuid, .required)
            .field("updated_by_user_id", .uuid, .required)
            // Which device wrote it. It only breaks ties between equal Lamport
            // values, so the server does not trust it for anything else.
            .field("client_id", .uuid, .required)
            .field("lamport", .int, .required)
            .field("is_deleted", .bool, .required)
            .field("server_seq", .int, .required)
            // The sequence it was first stored at. A member who joined "from now
            // on" sees records first stored after they joined, and an old record
            // edited later stays hidden from them.
            .field("first_seq", .int, .required)
            .field("created_at", .datetime)
            .field("updated_at", .datetime)
            // The pull cursor, as in `records`: the database refuses a repeated
            // sequence, and on Postgres this index makes the pull a range scan.
            .unique(on: "group_id", "server_seq")
            .ignoreExisting()
            .create()

        try await database.schema(SessionRow.schema)
            .field("id", .uuid, .identifier(auto: false))
            .field("user_id", .uuid, .required)
            .field("token_hash", .string, .required)
            .field("device_label", .string)
            .field("created_at", .datetime)
            .field("last_used_at", .datetime, .required)
            .field("expires_at", .datetime, .required)
            // The person's password_changed_at when the session began. A
            // session counts only while the two still match, so a sign-in that
            // was checking the old password while a reset ran cannot outlive it.
            .field("credential_stamp", .datetime)
            .unique(on: "token_hash")
            .ignoreExisting()
            .create()

        try await database.schema(EmailCodeRow.schema)
            .field("id", .uuid, .identifier(auto: false))
            .field("user_id", .uuid, .required)
            .field("purpose", .string, .required)
            .field("code_hmac", .string, .required)
            .field("expires_at", .datetime, .required)
            .field("attempts", .int, .required)
            .field("last_sent_at", .datetime, .required)
            .field("created_at", .datetime)
            // One live code per person per purpose. Asking again replaces it;
            // the per-address limits on asking keep that from being abused.
            .unique(on: "user_id", "purpose")
            .ignoreExisting()
            .create()

        // Columns on tables already in use. Each one is looked for outside the
        // transaction, because on Postgres a failed statement spoils the
        // transaction it runs in.
        let users = await answers { try await UserRow.query(on: database).count(\.$emailVerifiedAt) }
        let groups = await answers { try await GroupRow.query(on: database).max(\.$lastSeq) }
        let invites = await answers { try await InviteRow.query(on: database).count(\.$acceptedByUserID) }
        // One column per statement: SQLite adds or drops only one at a time.
        try await database.transaction { database in
            if !users {
                try await database.schema(UserRow.schema)
                    .field("email_verified_at", .datetime).update()
                try await database.schema(UserRow.schema)
                    .field("password_changed_at", .datetime).update()
            }
            if !groups {
                // The next sequence number, handed out by one update rather than
                // by reading the highest and retrying on a clash.
                try await database.schema(GroupRow.schema)
                    .field("last_seq", .int, .required, .custom("DEFAULT 0")).update()
                // A per-group key for statement fingerprints, so a bank line
                // imported once is never imported again. Readable on purpose:
                // every member's device needs it, and it opens nothing.
                try await database.schema(GroupRow.schema)
                    .field("import_key", .data).update()
                try await database.schema(GroupRow.schema)
                    .field("deleted_at", .datetime).update()
            }
            if !invites {
                try await database.schema(InviteRow.schema)
                    .field("accepted_by_user_id", .uuid).update()
            }
        }
    }

    /// In one transaction, so a revert cut short leaves everything in place
    /// rather than half of it, which `prepare` could not tell apart from done.
    func revert(on database: any Database) async throws {
        try await database.transaction { database in try await revertAll(on: database) }
    }

    private func revertAll(on database: any Database) async throws {
        let columns = [(InviteRow.schema, "accepted_by_user_id"),
                       (GroupRow.schema, "deleted_at"), (GroupRow.schema, "import_key"),
                       (GroupRow.schema, "last_seq"),
                       (UserRow.schema, "password_changed_at"), (UserRow.schema, "email_verified_at")]
        for (schema, column) in columns {
            try await database.schema(schema).deleteField(.string(column)).update()
        }
        for schema in [EmailCodeRow.schema, SessionRow.schema, SyncRecordRow.schema] {
            try await database.schema(schema).delete()
        }
    }

    /// Whether a query naming a new column runs. An empty table still answers
    /// (with 0 or nil), so only a missing column fails.
    private func answers<T: Sendable>(_ query: () async throws -> T) async -> Bool {
        do {
            _ = try await query()
            return true
        } catch {
            return false
        }
    }
}

/// Sets each group's highest stored Lamport value from its records. It never
/// lowers one. A value at or above the ceiling is left out: one stored before
/// the ceiling existed would otherwise let every later push through, however
/// far ahead it was.
func fillGroupMaxLamport(on database: any Database) async throws {
    let ceiling = Int(RecordEnvelope.lamportCeiling)
    // Only the two columns this needs. A migration runs before the ones after
    // it, so it must not read columns they add: loading whole rows here broke
    // every new database once `AddReadableSync` gave groups a new column.
    let groups = try await GroupRow.query(on: database).field(\.$id).field(\.$maxLamport).all()
    for group in groups {
        let id = try group.requireID()
        let highest = try await RecordRow.query(on: database)
            .filter(\.$groupID == id)
            .filter(\.$lamport < ceiling)
            .max(\.$lamport) ?? 0
        guard highest > group.maxLamport else { continue }
        try await GroupRow.query(on: database)
            .filter(\.$id == id)
            .set(\.$maxLamport, to: highest)
            .update()
    }
    let above = try await RecordRow.query(on: database).filter(\.$lamport >= ceiling).count()
    if above > 0 {
        // Not fixed here. Every app now ignores these records, and a Mac that
        // took one in before the upgrade cannot save in that group. See the
        // ceiling in ARCHITECTURE.md.
        database.logger.warning("\(above) stored records have a Lamport value at or above the ceiling")
    }
}
