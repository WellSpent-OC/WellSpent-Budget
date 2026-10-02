import Foundation
import Fluent
import Vapor
import WellSpentCrypto

/// Everything the server is allowed to know.
///
/// Read this file as the answer to "what does a stolen database contain?". The
/// social graph is here in full: who shares money with whom, at what level, from
/// when. Record ids, sizes and timestamps are here. Amounts, merchants, budget
/// names and receipt images are not, and cannot be, because the server holds no
/// key that opens them.

final class UserRow: Model, @unchecked Sendable {
    static let schema = "users"

    @ID(custom: "id", generatedBy: .user) var id: UUID?
    @Field(key: "email") var email: String
    @Field(key: "password_hash") var passwordHash: String
    /// The person's public keys, as published in their groups' membership logs.
    @Field(key: "identity_signing") var identitySigning: Data
    @Field(key: "identity_kem") var identityKEM: Data
    @Timestamp(key: "created_at", on: .create) var createdAt: Date?

    init() {}
    init(id: UUID, email: String, passwordHash: String, identitySigning: Data, identityKEM: Data) {
        self.id = id
        self.email = email
        self.passwordHash = passwordHash
        self.identitySigning = identitySigning
        self.identityKEM = identityKEM
    }
}

/// The identity key bundle sealed under a twelve-word recovery code.
///
/// Safe to keep here only because the key is 128 bits of machine randomness. The
/// same blob sealed under a password people chose would be one offline cracking
/// job against every customer at once.
final class EscrowRow: Model, @unchecked Sendable {
    static let schema = "identity_escrow"

    @ID(custom: "id", generatedBy: .user) var id: UUID?
    @Field(key: "user_id") var userID: UUID
    @Field(key: "nonce") var nonce: Data
    @Field(key: "ciphertext") var ciphertext: Data
    @Timestamp(key: "created_at", on: .create) var createdAt: Date?

    init() {}
    init(id: UUID = UUID(), userID: UUID, nonce: Data, ciphertext: Data) {
        self.id = id
        self.userID = userID
        self.nonce = nonce
        self.ciphertext = ciphertext
    }
}

final class TokenRow: Model, @unchecked Sendable {
    static let schema = "tokens"

    @ID(custom: "id", generatedBy: .user) var id: UUID?
    @Field(key: "user_id") var userID: UUID
    /// A SHA-256 of the bearer token, never the token. A column called `value`
    /// holding a digest is how someone writes a bug later, so it is not called
    /// that.
    @Field(key: "value_hash") var valueHash: String
    @Field(key: "expires_on") var expiresOn: Date

    init() {}
    init(id: UUID = UUID(), userID: UUID, valueHash: String, expiresOn: Date) {
        self.id = id
        self.userID = userID
        self.valueHash = valueHash
        self.expiresOn = expiresOn
    }
}

final class GroupRow: Model, @unchecked Sendable {
    static let schema = "groups"

    @ID(custom: "id", generatedBy: .user) var id: UUID?
    @Field(key: "founder_id") var founderID: UUID
    @Field(key: "epoch") var epoch: Int
    @Timestamp(key: "created_at", on: .create) var createdAt: Date?

    init() {}
    init(id: UUID, founderID: UUID, epoch: Int = 0) {
        self.id = id
        self.founderID = founderID
        self.epoch = epoch
    }
}

/// The signed, hash-chained access history.
///
/// The server verifies every entry before storing it, which is the part that
/// matters: holding a valid auth token must not be enough to rewrite who had what
/// level. A client replays this same chain and checks it independently.
final class MembershipEntryRow: Model, @unchecked Sendable {
    static let schema = "membership_log"

    @ID(custom: "id", generatedBy: .user) var id: UUID?
    @Field(key: "group_id") var groupID: UUID
    @Field(key: "sequence") var sequence: Int
    @Field(key: "entry") var entry: Data

    init() {}
    init(id: UUID = UUID(), groupID: UUID, sequence: Int, entry: Data) {
        self.id = id
        self.groupID = groupID
        self.sequence = sequence
        self.entry = entry
    }
}

/// A replay of the log, kept so authorisation is one indexed lookup rather than a
/// full chain walk on every request.
final class MembershipRow: Model, @unchecked Sendable {
    static let schema = "memberships"

    @ID(custom: "id", generatedBy: .user) var id: UUID?
    @Field(key: "group_id") var groupID: UUID
    @Field(key: "user_id") var userID: UUID
    @Field(key: "level") var level: Int
    @Field(key: "joined_at_sequence") var joinedAtSequence: Int

    init() {}
    init(id: UUID = UUID(), groupID: UUID, userID: UUID, level: Int, joinedAtSequence: Int) {
        self.id = id
        self.groupID = groupID
        self.userID = userID
        self.level = level
        self.joinedAtSequence = joinedAtSequence
    }
}

/// Group and budget keys, sealed. The server cannot open any of these.
///
/// One rule is load-bearing: never delete a row for someone who is still a
/// member. Every wrapped key for every epoch is how a restored device regains
/// access to records written before it existed. A cleanup job that prunes old
/// epochs is a data-loss bug with a six month fuse.
final class WrappedKeyRow: Model, @unchecked Sendable {
    static let schema = "wrapped_keys"

    @ID(custom: "id", generatedBy: .user) var id: UUID?
    @Field(key: "group_id") var groupID: UUID
    @Field(key: "scope_kind") var scopeKind: String
    @Field(key: "scope_id") var scopeID: UUID
    @Field(key: "epoch") var epoch: Int
    @OptionalField(key: "recipient_user_id") var recipientUserID: UUID?
    @Field(key: "payload") var payload: Data

    init() {}
    init(id: UUID = UUID(), groupID: UUID, scopeKind: String, scopeID: UUID,
         epoch: Int, recipientUserID: UUID?, payload: Data) {
        self.id = id
        self.groupID = groupID
        self.scopeKind = scopeKind
        self.scopeID = scopeID
        self.epoch = epoch
        self.recipientUserID = recipientUserID
        self.payload = payload
    }
}

/// One sealed record.
///
/// `server_seq` is the ordering the whole sync protocol depends on. The old API
/// pulled with `updated_at >= ?`, which loses records whenever two writes land in
/// the same second or a client's clock is off. A monotonic sequence assigned here
/// cannot do that.
final class RecordRow: Model, @unchecked Sendable {
    static let schema = "records"

    @ID(custom: "id", generatedBy: .user) var id: UUID?
    @Field(key: "group_id") var groupID: UUID
    @OptionalField(key: "budget_id") var budgetID: UUID?
    @Field(key: "record_type") var recordType: String
    @Field(key: "server_seq") var serverSeq: Int
    @Field(key: "lamport") var lamport: Int
    @Field(key: "author_user_id") var authorUserID: UUID
    @Field(key: "author_device_id") var authorDeviceID: UUID
    @Field(key: "is_deleted") var isDeleted: Bool
    /// The whole envelope, encoded. Ciphertext plus its routing header.
    @Field(key: "envelope") var envelope: Data
    @Timestamp(key: "updated_at", on: .update) var updatedAt: Date?

    init() {}
    init(id: UUID, groupID: UUID, budgetID: UUID?, recordType: String, serverSeq: Int,
         lamport: Int, authorUserID: UUID, authorDeviceID: UUID, isDeleted: Bool, envelope: Data) {
        self.id = id
        self.groupID = groupID
        self.budgetID = budgetID
        self.recordType = recordType
        self.serverSeq = serverSeq
        self.lamport = lamport
        self.authorUserID = authorUserID
        self.authorDeviceID = authorDeviceID
        self.isDeleted = isDeleted
        self.envelope = envelope
    }
}

/// A pending invite.
///
/// Note what is absent: the invite secret. The server holds a hash it cannot
/// reverse, which is the whole reason a server in the middle cannot answer an
/// invite in the recipient's place.
final class InviteRow: Model, @unchecked Sendable {
    static let schema = "invites"

    @ID(custom: "id", generatedBy: .user) var id: UUID?
    @Field(key: "invite_hash") var inviteHash: Data
    @Field(key: "group_id") var groupID: UUID
    @Field(key: "inviter_user_id") var inviterUserID: UUID
    @Field(key: "level") var level: Int
    @Field(key: "history_access") var historyAccess: String
    @Field(key: "expires_at") var expiresAt: Date
    @OptionalField(key: "acceptance") var acceptance: Data?
    @OptionalField(key: "accepted_at") var acceptedAt: Date?

    init() {}
    init(id: UUID = UUID(), inviteHash: Data, groupID: UUID, inviterUserID: UUID,
         level: Int, historyAccess: String, expiresAt: Date) {
        self.id = id
        self.inviteHash = inviteHash
        self.groupID = groupID
        self.inviterUserID = inviterUserID
        self.level = level
        self.historyAccess = historyAccess
        self.expiresAt = expiresAt
    }
}
