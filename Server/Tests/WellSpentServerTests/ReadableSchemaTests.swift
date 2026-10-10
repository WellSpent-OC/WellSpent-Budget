import Testing
import Foundation
import Fluent
import SQLKit
import Vapor
import VaporTesting
@testable import WellSpentServerCore

private func withConfiguredApp(_ body: (Application) async throws -> Void) async throws {
    let app = try await Application.make(.testing)
    do {
        try await configure(app)
        try await app.asyncBoot()
        try await body(app)
    } catch {
        try? await app.asyncShutdown()
        throw error
    }
    try await app.asyncShutdown()
}

/// The tables and columns `AddReadableSync` adds for readable sync. Nothing reads
/// them yet; these tests pin the shape the next changes build on, and that the
/// migration is safe on a database already in use.
@Suite("Server, readable sync schema", .serialized)
struct ReadableSchemaTests {
    /// A readable record keeps its owner, and the pull cursor is unique per group
    /// as it is for sealed records.
    @Test func aReadableRecordIsStoredWithItsOwnerAndOrdering() async throws {
        try await withConfiguredApp { app in
            let group = UUID()
            let owner = UUID()
            let record = SyncRecordRow(id: UUID(), groupID: group, budgetID: UUID(),
                                       recordType: "transaction", body: #"{"merchant":"Hilltop"}"#,
                                       createdBy: owner, clientID: UUID(), lamport: 7,
                                       isDeleted: false, serverSeq: 1)
            try await record.create(on: app.db)

            let stored = try #require(try await SyncRecordRow.find(record.id, on: app.db))
            #expect(stored.body == #"{"merchant":"Hilltop"}"#)
            #expect(stored.createdByUserID == owner && stored.updatedByUserID == owner)
            #expect(stored.firstSeq == 1)

            let clash = SyncRecordRow(id: UUID(), groupID: group, budgetID: nil,
                                      recordType: "budget", body: "{}", createdBy: owner,
                                      clientID: UUID(), lamport: 8, isDeleted: false, serverSeq: 1)
            await #expect(throws: (any Error).self, "two records may not share a sequence") {
                try await clash.create(on: app.db)
            }
        }
    }

    /// One live code per person and purpose, so asking again cannot stack codes.
    @Test func oneLiveEmailCodePerPersonAndPurpose() async throws {
        try await withConfiguredApp { app in
            let user = UUID()
            let later = Date().addingTimeInterval(1800)
            try await EmailCodeRow(userID: user, purpose: "reset", codeHMAC: "a",
                                   expiresAt: later, lastSentAt: Date()).create(on: app.db)
            try await EmailCodeRow(userID: user, purpose: "verify", codeHMAC: "b",
                                   expiresAt: later, lastSentAt: Date()).create(on: app.db)
            await #expect(throws: (any Error).self) {
                try await EmailCodeRow(userID: user, purpose: "reset", codeHMAC: "c",
                                       expiresAt: later, lastSentAt: Date()).create(on: app.db)
            }
        }
    }

    /// A session is found by its token's hash, so two may never share one.
    @Test func sessionTokenHashesAreUnique() async throws {
        try await withConfiguredApp { app in
            let hash = "session-\(UUID().uuidString)"
            let now = Date()
            try await SessionRow(userID: UUID(), tokenHash: hash, deviceLabel: "Family desktop",
                                 lastUsedAt: now, expiresAt: now.addingTimeInterval(86_400))
                .create(on: app.db)
            await #expect(throws: (any Error).self) {
                try await SessionRow(userID: UUID(), tokenHash: hash, deviceLabel: nil,
                                     lastUsedAt: now, expiresAt: now).create(on: app.db)
            }
        }
    }

    /// The live server already holds groups and invites. The migration adds its
    /// columns to them without touching what is there: a group made before it
    /// reads back with a next sequence of 0 and no import key.
    @Test func groupsMadeBeforeTheMigrationGainTheNewColumns() async throws {
        try await withConfiguredApp { app in
            try await AddReadableSync().revert(on: app.db)
            let sql = try #require(app.db as? any SQLDatabase)
            let group = UUID()
            let founder = UUID()
            try await sql.insert(into: GroupRow.schema)
                .columns("id", "founder_id", "epoch", "max_lamport")
                .values(SQLBind(group), SQLBind(founder), SQLBind(0), SQLBind(12))
                .run()

            try await AddReadableSync().prepare(on: app.db)

            let stored = try #require(try await GroupRow.find(group, on: app.db))
            #expect(stored.lastSeq == 0)
            #expect(stored.importKey == nil && stored.deletedAt == nil)
            #expect(stored.maxLamport == 12 && stored.founderID == founder)
        }
    }

    /// Fluent marks a migration done only after it returns. A start cut short
    /// must not leave the server unable to start, so a second run finds what is
    /// already there and keeps it.
    @Test func theMigrationRunsAgainAfterAStartCutShort() async throws {
        try await withConfiguredApp { app in
            let group = GroupRow(id: UUID(), founderID: UUID())
            group.lastSeq = 5
            try await group.create(on: app.db)

            try await AddReadableSync().prepare(on: app.db)

            #expect(try await GroupRow.find(group.id, on: app.db)?.lastSeq == 5)
        }
    }

    /// The way back after a bad deploy: reverting removes everything it added,
    /// and running it again brings it back.
    @Test func revertingRemovesItAndItCanBeAddedAgain() async throws {
        try await withConfiguredApp { app in
            try await AddReadableSync().revert(on: app.db)
            await #expect(throws: (any Error).self, "the readable table is gone") {
                _ = try await SyncRecordRow.query(on: app.db).first()
            }
            try await AddReadableSync().prepare(on: app.db)
            let record = SyncRecordRow(id: UUID(), groupID: UUID(), budgetID: nil, recordType: "budget",
                                       body: "{}", createdBy: UUID(), clientID: UUID(), lamport: 1,
                                       isDeleted: false, serverSeq: 1)
            try await record.create(on: app.db)
            #expect(try await SyncRecordRow.find(record.id, on: app.db)?.body == "{}", "the table works again")
            // And the columns on tables already in use came back too.
            let user = UserRow(id: UUID(), email: "schema-roundtrip@example.com", passwordHash: "x",
                               identitySigning: Data(), identityKEM: Data())
            user.emailVerifiedAt = Date(timeIntervalSince1970: 1_790_000_000)
            user.passwordChangedAt = Date(timeIntervalSince1970: 1_790_000_100)
            try await user.create(on: app.db)
            let storedUser = try #require(try await UserRow.find(user.id, on: app.db))
            #expect(storedUser.emailVerifiedAt != nil && storedUser.passwordChangedAt != nil)
            let invite = InviteRow(inviteHash: Data([1, 2, 3]), groupID: UUID(), inviterUserID: UUID(),
                                   level: 5, historyAccess: "all", expiresAt: Date())
            invite.acceptedByUserID = UUID()
            try await invite.create(on: app.db)
            #expect(try await InviteRow.find(invite.id, on: app.db)?.acceptedByUserID != nil)
        }
    }
}
