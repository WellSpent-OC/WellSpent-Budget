import Foundation
import Fluent

/// One migration, because nothing has shipped yet.
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
