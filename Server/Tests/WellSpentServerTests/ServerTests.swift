import Testing
import Foundation
// Fluent, because these tests read rows back directly to check what the server
// actually stored. Without it the query builder's API is not in scope, and the
// failure reads as "cannot infer key path type from context".
import Fluent
import Vapor
import VaporTesting
import Crypto
@testable import WellSpentServerCore
import WellSpentCrypto

private func withConfiguredApp(_ body: (Application) async throws -> Void) async throws {
    let app = try await Application.make(.testing)
    do {
        try await configure(app)
        // Boot explicitly. Without this the first request through the in-memory
        // responder can arrive before the router is built, which shows up as a
        // 404 on a route that is plainly registered.
        try await app.asyncBoot()
        try await body(app)
    } catch {
        try? await app.asyncShutdown()
        throw error
    }
    try await app.asyncShutdown()
}

/// A person, on the client side of the wire.
private struct Account {
    let identity = IdentityKeyPair.generate()
    let device = DeviceKeyPair()
    let email: String
    var userID = UUID()
    var token = ""

    init(email: String) { self.email = email }

    var publicKeys: IdentityPublicKeys { identity.publicKeys }
    var bearer: HTTPHeaders {
        var headers = HTTPHeaders()
        headers.bearerAuthorization = .init(token: token)
        return headers
    }
}

private struct SignUpBody: Content {
    let email: String
    let password: String
    let identitySigning: Data
    let identityKEM: Data
    let escrowNonce: Data?
    let escrowCiphertext: Data?
}

private struct TokenBody: Content {
    let userID: UUID
    let token: String
    let expiresOn: Date
}

private struct PushBody: Content { let envelopes: [RecordEnvelope] }
private struct PushReply: Content {
    let accepted: [UUID]
    let rejected: [String: String]
    let serverSeq: Int
}
private struct PullReply: Content {
    let envelopes: [RecordEnvelope]
    let serverSeq: Int
    let hasMore: Bool
}
private struct LogBody: Content {
    let entry: MembershipLogEntry
    let wrappedKeys: [WrappedKey]
}

private func register(_ account: inout Account, on app: Application) async throws {
    var created: Account?
    let body = SignUpBody(email: account.email, password: "a-long-enough-password",
                          identitySigning: account.publicKeys.signing,
                          identityKEM: account.publicKeys.kem,
                          escrowNonce: nil, escrowCiphertext: nil)
    let snapshot = account
    try await app.testing().test(.POST, "api/v1/signup", beforeRequest: { request in
        try request.content.encode(body)
    }, afterResponse: { response async throws in
        #expect(response.status == .ok)
        let reply = try response.content.decode(TokenBody.self)
        var updated = snapshot
        updated.userID = reply.userID
        updated.token = reply.token
        created = updated
    })
    account = try #require(created)
}

/// Found a group by posting its first log entry, which is what the real client does.
private func foundGroup(_ owner: Account, groupID: UUID, on app: Application) async throws
    -> [MembershipLogEntry] {
    let entry = try MembershipLogEntry.signed(
        scope: .group(GroupID(groupID)), sequence: 0,
        previousHash: MembershipLogEntry.rootHash, action: .found,
        subjectUserID: UserID(owner.userID), subjectKeys: owner.publicKeys,
        level: .superadmin, epochAfter: .initial,
        deviceID: owner.device.id, devicePublicKey: owner.device.publicKey,
        author: owner.identity, authorUserID: UserID(owner.userID)
    )
    try await app.testing().test(.POST, "api/v1/groups/\(groupID)/log",
                                 headers: owner.bearer,
                                 beforeRequest: { request in
        try request.content.encode(LogBody(entry: entry, wrappedKeys: []))
    }, afterResponse: { response async throws in
        #expect(response.status == .created)
    })
    return [entry]
}

/// Adds someone, with the group key sealed to them when one is given, and
/// registers their device by their own entry, as their app does.
private func addMember(_ member: Account, to groupID: UUID, level: AccessLevel,
                       log: inout [MembershipLogEntry], owner: Account,
                       sealing groupKey: ScopedKey? = nil,
                       on app: Application) async throws {
    let keys = try groupKey.map {
        [try KeyWrap.wrapToIdentity($0, recipient: member.publicKeys,
                                    recipientUserID: UserID(member.userID),
                                    sender: owner.identity, senderUserID: UserID(owner.userID))]
    } ?? []
    let entry = try MembershipLogEntry.signed(
        scope: .group(GroupID(groupID)), sequence: UInt64(log.count),
        previousHash: log.last!.hash, action: .add,
        subjectUserID: UserID(member.userID), subjectKeys: member.publicKeys,
        level: level, epochAfter: .initial,
        author: owner.identity, authorUserID: UserID(owner.userID)
    )
    log.append(entry)
    try await app.testing().test(.POST, "api/v1/groups/\(groupID)/log",
                                 headers: owner.bearer,
                                 beforeRequest: { request in
        try request.content.encode(LogBody(entry: entry, wrappedKeys: keys))
    }, afterResponse: { response async throws in
        #expect(response.status == .created)
    })

    // Their device, registered by their own entry, as their app does.
    let device = try MembershipLogEntry.signed(
        scope: .group(GroupID(groupID)), sequence: UInt64(log.count),
        previousHash: log.last!.hash, action: .addDevice,
        subjectUserID: UserID(member.userID), subjectKeys: nil,
        level: level, epochAfter: .initial,
        deviceID: member.device.id, devicePublicKey: member.device.publicKey,
        author: member.identity, authorUserID: UserID(member.userID)
    )
    log.append(device)
    try await app.testing().test(.POST, "api/v1/groups/\(groupID)/log",
                                 headers: member.bearer,
                                 beforeRequest: { request in
        try request.content.encode(LogBody(entry: device, wrappedKeys: []))
    }, afterResponse: { response async throws in
        #expect(response.status == .created)
    })
}

private func makeEnvelope(_ account: Account, groupID: UUID, budgetID: UUID,
                          key: ScopedKey, lamport: UInt64, text: String) throws -> RecordEnvelope {
    struct Payload: Codable { let merchant: String }
    return try RecordCodec.seal(
        Payload(merchant: text), recordID: RecordID(), recordType: .transaction,
        groupID: GroupID(groupID), budgetID: BudgetID(budgetID), scopeKey: key,
        lamport: lamport, author: UserID(account.userID), device: account.device,
        membershipSequence: 0
    )
}

@Suite("Server, accounts", .serialized)
struct AccountTests {

    /// The invites table already stored only a hash. Tokens did not, so a read
    /// of this database was a set of usable thirty day sessions.
    @Test func theStoredTokenIsOnlyAHash() async throws {
        try await withConfiguredApp { app in
            var robin = Account(email: "hashed@example.com")
            try await register(&robin, on: app)

            let stored = try await TokenRow.query(on: app.db)
                .filter(\.$userID == robin.userID).first()
            let row = try #require(stored)
            #expect(row.valueHash != robin.token, "the database holds a usable session")
            #expect(row.valueHash == tokenDigest(robin.token))

            // The token the client was handed still works. A 403 rather than a
            // 401 is how we know the bearer itself was accepted.
            try await app.testing().test(.GET, "api/v1/groups/\(UUID())/log",
                                         headers: robin.bearer) { response async throws in
                #expect(response.status != .unauthorized)
            }
        }
    }

    /// Clearing the token on the device is not signing out. Without this the
    /// session stays live for thirty days and nobody can cancel it.
    @Test func signingOutRevokesTheToken() async throws {
        try await withConfiguredApp { app in
            var robin = Account(email: "revoke@example.com")
            try await register(&robin, on: app)

            try await app.testing().test(.POST, "api/v1/signout",
                                         headers: robin.bearer) { response async throws in
                #expect(response.status == .noContent)
            }
            try await app.testing().test(.GET, "api/v1/groups/\(UUID())/pull",
                                         headers: robin.bearer) { response async throws in
                #expect(response.status == .unauthorized)
            }
            let remaining = try await TokenRow.query(on: app.db)
                .filter(\.$userID == robin.userID).count()
            #expect(remaining == 0)
        }
    }

    /// A health check that answers 200 with no database tells a restart policy
    /// and every uptime monitor that all is well.
    @Test func healthFailsWhenTheDatabaseIsUnreachable() async throws {
        let app = try await Application.make(.testing)
        do {
            // A path that cannot be opened, so every query fails at connect time.
            // Built by hand rather than through configure(), which reads
            // DATABASE_URL from the environment and would point at Postgres in CI.
            app.databases.use(.sqlite(.file("/nonexistent-directory/nope.sqlite"),
                                      connectionPoolTimeout: .seconds(2)), as: .sqlite)
            app.databases.default(to: .sqlite)
            try registerRoutes(app)
            try await app.asyncBoot()

            try await app.testing().test(.GET, "health") { response async throws in
                #expect(response.status == .serviceUnavailable)
            }
        } catch {
            try? await app.asyncShutdown()
            throw error
        }
        try await app.asyncShutdown()
    }
    @Test func healthCheck() async throws {
        try await withConfiguredApp { app in
            try await app.testing().test(.GET, "health") { response async throws in
                #expect(response.status == .ok)
            }
        }
    }

    @Test func signUpThenSignIn() async throws {
        try await withConfiguredApp { app in
            var robin = Account(email: "robin@example.com")
            try await register(&robin, on: app)
            #expect(!robin.token.isEmpty)

            struct SignIn: Content { let email: String; let password: String }
            try await app.testing().test(.POST, "api/v1/signin", beforeRequest: { request in
                try request.content.encode(SignIn(email: "robin@example.com",
                                                  password: "a-long-enough-password"))
            }, afterResponse: { response async throws in
                #expect(response.status == .ok)
                #expect(!(try response.content.decode(TokenBody.self)).token.isEmpty)
            })
        }
    }

    @Test func duplicateEmailIsRefused() async throws {
        try await withConfiguredApp { app in
            var robin = Account(email: "dup@example.com")
            try await register(&robin, on: app)

            let body = SignUpBody(email: "dup@example.com", password: "another-long-password",
                                  identitySigning: robin.publicKeys.signing,
                                  identityKEM: robin.publicKeys.kem,
                                  escrowNonce: nil, escrowCiphertext: nil)
            try await app.testing().test(.POST, "api/v1/signup", beforeRequest: { request in
                try request.content.encode(body)
            }, afterResponse: { response async throws in
                #expect(response.status == .conflict)
            })
        }
    }

    /// Distinct status codes, unlike the old API which answered 400 for
    /// everything including a wrong password.
    @Test func wrongPasswordIsUnauthorizedNotBadRequest() async throws {
        try await withConfiguredApp { app in
            var robin = Account(email: "pw@example.com")
            try await register(&robin, on: app)

            struct SignIn: Content { let email: String; let password: String }
            try await app.testing().test(.POST, "api/v1/signin", beforeRequest: { request in
                try request.content.encode(SignIn(email: "pw@example.com", password: "wrong"))
            }, afterResponse: { response async throws in
                #expect(response.status == .unauthorized)
            })
        }
    }

    /// An unknown address and a wrong password must look identical, or the sign-in
    /// endpoint becomes a list of who has an account.
    @Test func unknownEmailLooksTheSameAsAWrongPassword() async throws {
        try await withConfiguredApp { app in
            struct SignIn: Content { let email: String; let password: String }
            try await app.testing().test(.POST, "api/v1/signin", beforeRequest: { request in
                try request.content.encode(SignIn(email: "nobody@example.com", password: "x"))
            }, afterResponse: { response async throws in
                #expect(response.status == .unauthorized)
                #expect(!response.body.string.contains("not found"))
            })
        }
    }

    @Test func noTokenMeansNoAccess() async throws {
        try await withConfiguredApp { app in
            try await app.testing().test(.GET, "api/v1/groups/\(UUID())/pull") { response async throws in
                #expect(response.status == .unauthorized)
            }
        }
    }
}

@Suite("Server, sync", .serialized)
struct SyncRouteTests {

    /// The membership log is the social graph in full: who shares money with
    /// whom, at what level, since when. It was readable by anyone who knew a
    /// group UUID, with no token at all.
    @Test func anUnauthenticatedCallerCannotReadTheGroupLog() async throws {
        try await withConfiguredApp { app in
            var robin = Account(email: "logauth@example.com")
            try await register(&robin, on: app)
            let groupID = UUID()
            _ = try await foundGroup(robin, groupID: groupID, on: app)

            try await app.testing().test(.GET, "api/v1/groups/\(groupID)/log") { response async throws in
                #expect(response.status == .unauthorized)
                #expect(!response.body.string.contains(robin.userID.uuidString),
                        "member ids must not reach an anonymous caller")
            }
        }
    }

    @Test func aStrangerCannotReadTheGroupLogButAMemberCan() async throws {
        try await withConfiguredApp { app in
            var robin = Account(email: "logowner@example.com")
            var stranger = Account(email: "logstranger@example.com")
            var jamie = Account(email: "logmember@example.com")
            try await register(&robin, on: app)
            try await register(&stranger, on: app)
            try await register(&jamie, on: app)

            let groupID = UUID()
            var log = try await foundGroup(robin, groupID: groupID, on: app)

            try await app.testing().test(.GET, "api/v1/groups/\(groupID)/log",
                                         headers: stranger.bearer) { response async throws in
                #expect(response.status == .forbidden)
            }

            try await addMember(jamie, to: groupID, level: .read, log: &log,
                                owner: robin, on: app)
            try await app.testing().test(.GET, "api/v1/groups/\(groupID)/log",
                                         headers: jamie.bearer) { response async throws in
                #expect(response.status == .ok)
                #expect(try response.content.decode([MembershipLogEntry].self).count == 3)
            }
        }
    }

    /// The pull cursor is server_seq. Two rows in a group sharing one means a
    /// client pulling "since N" silently skips the other, so the database has to
    /// be the thing that refuses it.
    @Test func twoRecordsCannotShareAServerSequence() async throws {
        try await withConfiguredApp { app in
            let groupID = UUID()
            func row() -> RecordRow {
                RecordRow(id: UUID(), groupID: groupID, budgetID: nil,
                          recordType: "transaction", serverSeq: 7, lamport: 1,
                          authorUserID: UUID(), authorDeviceID: UUID(),
                          isDeleted: false, envelope: Data([0x7B, 0x7D]))
            }
            try await row().save(on: app.db)
            await #expect(throws: (any Error).self) {
                try await row().save(on: app.db)
            }
        }
    }

    /// Only bites on Postgres with a real connection pool, which is what the
    /// Postgres CI job is for. On SQLite writes serialise through one connection
    /// and this passes either way.
    @Test func concurrentPushesGetDistinctSequences() async throws {
        try await withConfiguredApp { app in
            var robin = Account(email: "concurrent@example.com")
            try await register(&robin, on: app)
            let groupID = UUID()
            _ = try await foundGroup(robin, groupID: groupID, on: app)

            let budgetID = UUID()
            let key = ScopedKey.generate(scope: .budget(BudgetID(budgetID)))
            let envelopes = [
                try makeEnvelope(robin, groupID: groupID, budgetID: budgetID,
                                 key: key, lamport: 1, text: "a"),
                try makeEnvelope(robin, groupID: groupID, budgetID: budgetID,
                                 key: key, lamport: 2, text: "b"),
            ]

            // An immutable copy: a closure handed to addTask cannot capture a
            // mutable local without risking a race.
            let owner = robin
            try await withThrowingTaskGroup(of: Void.self) { tasks in
                for envelope in envelopes {
                    tasks.addTask {
                        try await app.testing().test(.POST, "api/v1/groups/\(groupID)/push",
                                                     headers: owner.bearer,
                                                     beforeRequest: { request in
                            try request.content.encode(PushBody(envelopes: [envelope]))
                        }, afterResponse: { response async throws in
                            #expect(response.status == .ok)
                            #expect(try response.content.decode(PushReply.self).accepted.count == 1)
                        })
                    }
                }
                try await tasks.waitForAll()
            }

            let stored = try await RecordRow.query(on: app.db)
                .filter(\.$groupID == groupID).all()
            #expect(stored.count == 2)
            #expect(Set(stored.map(\.serverSeq)).count == 2,
                    "a repeated sequence loses a record for every client that pulls past it")
        }
    }
    @Test func pushThenPull() async throws {
        try await withConfiguredApp { app in
            var robin = Account(email: "sync@example.com")
            try await register(&robin, on: app)

            let groupID = UUID()
            _ = try await foundGroup(robin, groupID: groupID, on: app)

            let budgetID = UUID()
            let key = ScopedKey.generate(scope: .budget(BudgetID(budgetID)))
            let envelope = try makeEnvelope(robin, groupID: groupID, budgetID: budgetID,
                                            key: key, lamport: 1, text: "Hilltop")

            try await app.testing().test(.POST, "api/v1/groups/\(groupID)/push",
                                         headers: robin.bearer,
                                         beforeRequest: { request in
                try request.content.encode(PushBody(envelopes: [envelope]))
            }, afterResponse: { response async throws in
                #expect(response.status == .ok)
                let reply = try response.content.decode(PushReply.self)
                #expect(reply.accepted == [envelope.recordID.uuid])
                #expect(reply.rejected.isEmpty)
            })

            try await app.testing().test(.GET, "api/v1/groups/\(groupID)/pull?since=0",
                                         headers: robin.bearer) { response async throws in
                #expect(response.status == .ok)
                let reply = try response.content.decode(PullReply.self)
                #expect(reply.envelopes.count == 1)

                // And it really is still sealed.
                let opened = try RecordCodec.openData(
                    from: reply.envelopes[0], scopeKey: key,
                    deviceKey: robin.device.signing.publicKey, authorLevel: .write)
                #expect(String(decoding: opened, as: UTF8.self).contains("Hilltop"))
            }
        }
    }

    /// A pull limit below one used to reach `rows.prefix(limit)`, which traps on a
    /// negative length and takes the whole server down. Any account could send it
    /// against a group it founded itself.
    @Test func aPullLimitBelowOneCannotStopTheServer() async throws {
        try await withConfiguredApp { app in
            var robin = Account(email: "limit@example.com")
            try await register(&robin, on: app)

            let groupID = UUID()
            _ = try await foundGroup(robin, groupID: groupID, on: app)

            let budgetID = UUID()
            let key = ScopedKey.generate(scope: .budget(BudgetID(budgetID)))
            let envelope = try makeEnvelope(robin, groupID: groupID, budgetID: budgetID,
                                            key: key, lamport: 1, text: "Hilltop")
            try await app.testing().test(.POST, "api/v1/groups/\(groupID)/push",
                                         headers: robin.bearer,
                                         beforeRequest: { request in
                try request.content.encode(PushBody(envelopes: [envelope]))
            }, afterResponse: { response async throws in
                #expect(response.status == .ok)
            })

            for limit in ["-1", "0", "-2", "\(Int.min)"] {
                try await app.testing().test(.GET,
                                             "api/v1/groups/\(groupID)/pull?since=0&limit=\(limit)",
                                             headers: robin.bearer) { response async throws in
                    #expect(response.status == .ok, "limit \(limit)")
                    let reply = try response.content.decode(PullReply.self)
                    #expect(reply.envelopes.count == 1, "limit \(limit) is read as 1")
                }
            }
        }
    }

    /// One bad record must not take the batch down with it. The old API used
    /// `break`, so a 200 record push with one bad row processed almost nothing.
    @Test func oneBadRecordDoesNotSinkTheBatch() async throws {
        try await withConfiguredApp { app in
            var robin = Account(email: "batch@example.com")
            try await register(&robin, on: app)

            let groupID = UUID()
            _ = try await foundGroup(robin, groupID: groupID, on: app)

            let budgetID = UUID()
            let key = ScopedKey.generate(scope: .budget(BudgetID(budgetID)))
            let good1 = try makeEnvelope(robin, groupID: groupID, budgetID: budgetID,
                                         key: key, lamport: 1, text: "one")
            let good2 = try makeEnvelope(robin, groupID: groupID, budgetID: budgetID,
                                         key: key, lamport: 2, text: "two")

            // Tampered: the ciphertext is changed, so the signature no longer holds.
            var bytes = good1.ciphertext
            bytes[bytes.startIndex] ^= 0xFF
            let bad = RecordEnvelope(
                version: good1.version, recordID: RecordID(), recordType: good1.recordType,
                groupID: good1.groupID, budgetID: good1.budgetID, keyEpoch: good1.keyEpoch,
                ciphersuite: good1.ciphersuite, payloadKind: good1.payloadKind,
                nonce: good1.nonce, ciphertext: bytes, lamport: 3,
                authorUserID: good1.authorUserID, authorDeviceID: good1.authorDeviceID,
                membershipSequence: good1.membershipSequence, isDeleted: false,
                signature: good1.signature
            )

            try await app.testing().test(.POST, "api/v1/groups/\(groupID)/push",
                                         headers: robin.bearer,
                                         beforeRequest: { request in
                try request.content.encode(PushBody(envelopes: [good1, bad, good2]))
            }, afterResponse: { response async throws in
                let reply = try response.content.decode(PushReply.self)
                #expect(reply.accepted.count == 2, "both good records must land")
                #expect(reply.rejected.count == 1)
                #expect(reply.rejected[bad.recordID.uuid.uuidString]?
                    .contains("signature") == true)
            })
        }
    }

    @Test func aStrangerCannotPull() async throws {
        try await withConfiguredApp { app in
            var robin = Account(email: "owner2@example.com")
            var stranger = Account(email: "stranger@example.com")
            try await register(&robin, on: app)
            try await register(&stranger, on: app)

            let groupID = UUID()
            _ = try await foundGroup(robin, groupID: groupID, on: app)

            try await app.testing().test(.GET, "api/v1/groups/\(groupID)/pull",
                                         headers: stranger.bearer) { response async throws in
                #expect(response.status == .forbidden)
            }
        }
    }

    /// The other half of "encryption only enforces read". The reader holds the
    /// key and can produce perfectly valid ciphertext; the server is what stops it.
    @Test func aReaderCannotPush() async throws {
        try await withConfiguredApp { app in
            var robin = Account(email: "owner3@example.com")
            var jamie = Account(email: "reader@example.com")
            try await register(&robin, on: app)
            try await register(&jamie, on: app)

            let groupID = UUID()
            var log = try await foundGroup(robin, groupID: groupID, on: app)
            try await addMember(jamie, to: groupID, level: .read, log: &log, owner: robin, on: app)

            // He can read.
            try await app.testing().test(.GET, "api/v1/groups/\(groupID)/pull",
                                         headers: jamie.bearer) { response async throws in
                #expect(response.status == .ok)
            }

            // He cannot write, even with a valid signature over valid ciphertext.
            let budgetID = UUID()
            let key = ScopedKey.generate(scope: .budget(BudgetID(budgetID)))
            let envelope = try makeEnvelope(jamie, groupID: groupID, budgetID: budgetID,
                                            key: key, lamport: 1, text: "sneaky")
            try await app.testing().test(.POST, "api/v1/groups/\(groupID)/push",
                                         headers: jamie.bearer,
                                         beforeRequest: { request in
                try request.content.encode(PushBody(envelopes: [envelope]))
            }, afterResponse: { response async throws in
                #expect(response.status == .forbidden)
            })
        }
    }

    /// A valid auth token must not be enough to rewrite who had what level.
    @Test func aForgedMembershipEntryIsRefused() async throws {
        try await withConfiguredApp { app in
            var robin = Account(email: "owner4@example.com")
            var impostor = Account(email: "impostor@example.com")
            try await register(&robin, on: app)
            try await register(&impostor, on: app)

            let groupID = UUID()
            let log = try await foundGroup(robin, groupID: groupID, on: app)

            // He signs himself in as an admin, with his own real token.
            let forged = try MembershipLogEntry.signed(
                scope: .group(GroupID(groupID)), sequence: 1, previousHash: log[0].hash,
                action: .add, subjectUserID: UserID(impostor.userID),
                subjectKeys: impostor.publicKeys, level: .admin, epochAfter: .initial,
                deviceID: impostor.device.id, devicePublicKey: impostor.device.publicKey,
                author: impostor.identity, authorUserID: UserID(impostor.userID)
            )
            try await app.testing().test(.POST, "api/v1/groups/\(groupID)/log",
                                         headers: impostor.bearer,
                                         beforeRequest: { request in
                try request.content.encode(LogBody(entry: forged, wrappedKeys: []))
            }, afterResponse: { response async throws in
                #expect(response.status == .badRequest)
                #expect(response.body.string.contains("refused"))
            })

            // And he still cannot read.
            try await app.testing().test(.GET, "api/v1/groups/\(groupID)/pull",
                                         headers: impostor.bearer) { response async throws in
                #expect(response.status == .forbidden)
            }
        }
    }

    /// A member who can only view appends a second founding entry, signed by
    /// her own key, naming herself. It was accepted, and from then on she was
    /// the founder and a superadmin here and on every member's Mac.
    @Test func aSecondFoundingEntryIsRefused() async throws {
        try await withConfiguredApp { app in
            var robin = Account(email: "refound-owner@example.com")
            var mallory = Account(email: "refound-viewer@example.com")
            try await register(&robin, on: app)
            try await register(&mallory, on: app)

            let groupID = UUID()
            var log = try await foundGroup(robin, groupID: groupID, on: app)
            try await addMember(mallory, to: groupID, level: .read, log: &log, owner: robin, on: app)

            let refounding = try MembershipLogEntry.signed(
                scope: .group(GroupID(groupID)), sequence: UInt64(log.count),
                previousHash: log.last!.hash, action: .found,
                subjectUserID: UserID(mallory.userID), subjectKeys: mallory.publicKeys,
                level: .superadmin, epochAfter: .initial,
                deviceID: mallory.device.id, devicePublicKey: mallory.device.publicKey,
                author: mallory.identity, authorUserID: UserID(mallory.userID)
            )
            try await app.testing().test(.POST, "api/v1/groups/\(groupID)/log",
                                         headers: mallory.bearer,
                                         beforeRequest: { request in
                try request.content.encode(LogBody(entry: refounding, wrappedKeys: []))
            }, afterResponse: { response async throws in
                #expect(response.status == .badRequest)
                #expect(response.body.string.contains("foundingEntryNotFirst"))
            })

            let state = try await membershipState(groupID: groupID, on: app.db)
            #expect(state.founder == UserID(robin.userID))
            #expect(state.level(of: UserID(mallory.userID)) == .read)
            #expect(!state.mayDeleteGroup(UserID(mallory.userID)))
        }
    }

    /// The server must never accept a record signed by a device it has not seen
    /// enrolled, even when the author and token are genuine.
    @Test func anUnenrolledDeviceIsRefused() async throws {
        try await withConfiguredApp { app in
            var robin = Account(email: "device@example.com")
            try await register(&robin, on: app)

            let groupID = UUID()
            _ = try await foundGroup(robin, groupID: groupID, on: app)

            var withNewLaptop = robin
            withNewLaptop = Account(email: robin.email)      // a different device key
            withNewLaptop.userID = robin.userID
            withNewLaptop.token = robin.token

            let budgetID = UUID()
            let key = ScopedKey.generate(scope: .budget(BudgetID(budgetID)))
            let envelope = try makeEnvelope(withNewLaptop, groupID: groupID, budgetID: budgetID,
                                            key: key, lamport: 1, text: "from an unknown laptop")

            try await app.testing().test(.POST, "api/v1/groups/\(groupID)/push",
                                         headers: robin.bearer,
                                         beforeRequest: { request in
                try request.content.encode(PushBody(envelopes: [envelope]))
            }, afterResponse: { response async throws in
                let reply = try response.content.decode(PushReply.self)
                #expect(reply.accepted.isEmpty)
                #expect(reply.rejected.count == 1)
            })
        }
    }

    @Test func serverSequenceAdvancesMonotonically() async throws {
        try await withConfiguredApp { app in
            var robin = Account(email: "seq@example.com")
            try await register(&robin, on: app)

            let groupID = UUID()
            _ = try await foundGroup(robin, groupID: groupID, on: app)
            let budgetID = UUID()
            let key = ScopedKey.generate(scope: .budget(BudgetID(budgetID)))

            var sequences: [Int] = []
            for index in 1 ... 3 {
                let envelope = try makeEnvelope(robin, groupID: groupID, budgetID: budgetID,
                                                key: key, lamport: UInt64(index), text: "n\(index)")
                try await app.testing().test(.POST, "api/v1/groups/\(groupID)/push",
                                             headers: robin.bearer,
                                             beforeRequest: { request in
                    try request.content.encode(PushBody(envelopes: [envelope]))
                }, afterResponse: { response async throws in
                    sequences.append(try response.content.decode(PushReply.self).serverSeq)
                })
            }
            #expect(sequences == sequences.sorted())
            #expect(Set(sequences).count == 3, "a sequence that repeats loses records")
        }
    }

    /// The app sends a row again when it never heard back about the first
    /// send, for example when the reply was lost after the server saved it.
    /// It seals the row afresh, so the bytes differ, but it is the same version
    /// from the same device. That is taken as already stored. The tie rule
    /// used to compare the device with itself and refuse it, and the app sent
    /// the row again on every sync.
    @Test func aSameDeviceResendIsTakenAsAlreadyStored() async throws {
        try await withConfiguredApp { app in
            var robin = Account(email: "resend@example.com")
            try await register(&robin, on: app)

            let groupID = UUID()
            _ = try await foundGroup(robin, groupID: groupID, on: app)
            let budgetID = UUID()
            let key = ScopedKey.generate(scope: .budget(BudgetID(budgetID)))
            let recordID = RecordID()
            struct Payload: Codable { let merchant: String }
            func sealed(lamport: UInt64) throws -> RecordEnvelope {
                try RecordCodec.seal(
                    Payload(merchant: "Hilltop"), recordID: recordID, recordType: .transaction,
                    groupID: GroupID(groupID), budgetID: BudgetID(budgetID), scopeKey: key,
                    lamport: lamport, author: UserID(robin.userID), device: robin.device,
                    membershipSequence: 0)
            }

            let first = try sealed(lamport: 5)
            let taken = try await push(first, to: groupID, as: robin, on: app)
            #expect(taken.accepted == [recordID.uuid])

            let resend = try sealed(lamport: 5)
            #expect(resend.ciphertext != first.ciphertext, "sealed afresh, as the app does")
            let again = try await push(resend, to: groupID, as: robin, on: app)
            #expect(again.accepted == [recordID.uuid], "refused: \(again.rejected)")
            #expect(again.serverSeq == taken.serverSeq, "nothing new was stored")
            let stored = try #require(try await RecordRow.find(recordID.uuid, on: app.db))
            #expect(try JSONDecoder().decode(RecordEnvelope.self, from: stored.envelope) == first)

            // An older version from the same device is still refused.
            let older = try await push(try sealed(lamport: 4), to: groupID, as: robin, on: app)
            #expect(older.rejected[recordID.uuid.uuidString] == "a newer version is already stored")
        }
    }

    /// The resend rule takes only a device's own stored version. Another
    /// device's version at the same Lamport value still goes to the tie rule,
    /// where the higher device ID wins. Both orders are tried, so the stored
    /// row is checked whichever device sorts higher.
    @Test func anotherDeviceAtTheSameLamportValueGoesToTheTieRule() async throws {
        try await withConfiguredApp { app in
            var robin = Account(email: "tie-founder@example.com")
            var leslie = Account(email: "tie-writer@example.com")
            try await register(&robin, on: app)
            try await register(&leslie, on: app)

            let groupID = UUID()
            var log = try await foundGroup(robin, groupID: groupID, on: app)
            try await addMember(leslie, to: groupID, level: .write, log: &log, owner: robin, on: app)
            let budgetID = UUID()
            let key = ScopedKey.generate(scope: .budget(BudgetID(budgetID)))
            struct Payload: Codable { let merchant: String }
            func sealed(_ recordID: RecordID, by account: Account) throws -> RecordEnvelope {
                try RecordCodec.seal(
                    Payload(merchant: account.email), recordID: recordID, recordType: .transaction,
                    groupID: GroupID(groupID), budgetID: BudgetID(budgetID), scopeKey: key,
                    lamport: 5, author: UserID(account.userID), device: account.device,
                    membershipSequence: 0)
            }
            let (high, low) = leslie.device.id.uuid.uuidString > robin.device.id.uuid.uuidString
                ? (leslie, robin) : (robin, leslie)

            // The lower device first: the higher one's version replaces it.
            let replaced = RecordID()
            #expect(try await push(try sealed(replaced, by: low), to: groupID, as: low, on: app)
                .accepted == [replaced.uuid])
            #expect(try await push(try sealed(replaced, by: high), to: groupID, as: high, on: app)
                .accepted == [replaced.uuid])
            let stored = try #require(try await RecordRow.find(replaced.uuid, on: app.db))
            #expect(stored.authorDeviceID == high.device.id.uuid, "the higher device's version is stored")

            // The higher device first: the lower one's version is refused.
            let kept = RecordID()
            #expect(try await push(try sealed(kept, by: high), to: groupID, as: high, on: app)
                .accepted == [kept.uuid])
            let refused = try await push(try sealed(kept, by: low), to: groupID, as: low, on: app)
            #expect(refused.rejected[kept.uuid.uuidString] == "a newer version is already stored")
        }
    }

    /// A Lamport value at or above the ceiling is refused like any other bad
    /// record, and the server keeps answering. Above Int.max, converting it
    /// stopped the server process for every user. At Int.max it was stored,
    /// and every app that pulled it crashed on its next save in that group.
    /// The value just below the ceiling is still taken, in a group whose
    /// values have climbed that far.
    @Test func aLamportValueAtOrAboveTheCeilingIsRefused() async throws {
        try await withConfiguredApp { app in
            var robin = Account(email: "too-large@example.com")
            try await register(&robin, on: app)

            let groupID = UUID()
            _ = try await foundGroup(robin, groupID: groupID, on: app)
            let budgetID = UUID()
            let key = ScopedKey.generate(scope: .budget(BudgetID(budgetID)))
            let recordID = RecordID()
            struct Payload: Codable { let merchant: String }
            func sealed(lamport: UInt64) throws -> RecordEnvelope {
                try RecordCodec.seal(
                    Payload(merchant: "Hilltop"), recordID: recordID, recordType: .transaction,
                    groupID: GroupID(groupID), budgetID: BudgetID(budgetID), scopeKey: key,
                    lamport: lamport, author: UserID(robin.userID), device: robin.device,
                    membershipSequence: 0)
            }
            let ceiling = UInt64(1) << 62
            let refused = [UInt64(Int.max) + 1, UInt64(Int.max), ceiling]

            for lamport in refused {
                let fresh = try await push(try sealed(lamport: lamport), to: groupID, as: robin, on: app)
                #expect(fresh.rejected[recordID.uuid.uuidString] == "the Lamport value is too large",
                        "\(lamport) on a new record")
            }
            #expect(try await push(try sealed(lamport: 1), to: groupID, as: robin, on: app)
                .accepted == [recordID.uuid], "the server is still answering")
            for lamport in refused {
                let onTop = try await push(try sealed(lamport: lamport), to: groupID, as: robin, on: app)
                #expect(onTop.rejected[recordID.uuid.uuidString] == "the Lamport value is too large",
                        "\(lamport) on a stored record")
            }
            let group = try #require(try await GroupRow.find(groupID, on: app.db))
            group.maxLamport = Int(ceiling - 2)
            try await group.save(on: app.db)
            #expect(try await push(try sealed(lamport: ceiling - 1), to: groupID, as: robin, on: app)
                .accepted == [recordID.uuid], "just below the ceiling is taken")
        }
    }

    // MARK: - Deleting a group

    /// The group's own record, live or deleted, sealed by `account`.
    private func groupRecord(_ account: Account, groupID: UUID, key: ScopedKey,
                             lamport: UInt64, isDeleted: Bool) throws -> RecordEnvelope {
        struct Payload: Codable { let name: String }
        return try RecordCodec.seal(
            Payload(name: "Household"), recordID: RecordID(groupID), recordType: .groupMeta,
            groupID: GroupID(groupID), budgetID: nil, scopeKey: key, lamport: lamport,
            author: UserID(account.userID), device: account.device, membershipSequence: 0,
            isDeleted: isDeleted)
    }

    private func push(_ envelope: RecordEnvelope, to groupID: UUID, as account: Account,
                      on app: Application) async throws -> PushReply {
        var reply: PushReply?
        try await app.testing().test(.POST, "api/v1/groups/\(groupID)/push",
                                     headers: account.bearer,
                                     beforeRequest: { request in
            try request.content.encode(PushBody(envelopes: [envelope]))
        }, afterResponse: { response async throws in
            #expect(response.status == .ok)
            reply = try response.content.decode(PushReply.self)
        })
        return try #require(reply)
    }

    /// Deleting the group deletes it for every member, so it takes the founder
    /// or an admin. Manage is enough to rename it, and not enough to delete it.
    @Test func onlyTheFounderOrAnAdminDeletesAGroup() async throws {
        try await withConfiguredApp { app in
            var robin = Account(email: "group-founder@example.com")
            var leslie = Account(email: "group-manager@example.com")
            var jamie = Account(email: "group-admin@example.com")
            try await register(&robin, on: app)
            try await register(&leslie, on: app)
            try await register(&jamie, on: app)

            let groupID = UUID()
            var log = try await foundGroup(robin, groupID: groupID, on: app)
            try await addMember(leslie, to: groupID, level: .manage, log: &log, owner: robin, on: app)
            try await addMember(jamie, to: groupID, level: .admin, log: &log, owner: robin, on: app)
            let key = ScopedKey.generate(scope: .group(GroupID(groupID)))

            let renamed = try groupRecord(leslie, groupID: groupID, key: key, lamport: 3, isDeleted: false)
            #expect(try await push(renamed, to: groupID, as: leslie, on: app).accepted == [groupID])

            let hers = try groupRecord(leslie, groupID: groupID, key: key, lamport: 5, isDeleted: true)
            let refused = try await push(hers, to: groupID, as: leslie, on: app)
            #expect(refused.accepted.isEmpty)
            #expect(refused.rejected[groupID.uuidString]?.contains("founder or an admin") == true)

            let admins = try groupRecord(jamie, groupID: groupID, key: key, lamport: 6, isDeleted: true)
            #expect(try await push(admins, to: groupID, as: jamie, on: app).accepted == [groupID])
        }
    }

    /// A group's delete is final. It replaces a newer live version, and no live
    /// version sent after it brings the group back, so every member who syncs
    /// later finds it deleted.
    @Test func aGroupDeleteIsFinal() async throws {
        try await withConfiguredApp { app in
            var robin = Account(email: "final-founder@example.com")
            var leslie = Account(email: "final-manager@example.com")
            try await register(&robin, on: app)
            try await register(&leslie, on: app)

            let groupID = UUID()
            var log = try await foundGroup(robin, groupID: groupID, on: app)
            try await addMember(leslie, to: groupID, level: .manage, log: &log, owner: robin, on: app)
            let key = ScopedKey.generate(scope: .group(GroupID(groupID)))

            let rename = try groupRecord(leslie, groupID: groupID, key: key, lamport: 9, isDeleted: false)
            #expect(try await push(rename, to: groupID, as: leslie, on: app).accepted == [groupID])

            let delete = try groupRecord(robin, groupID: groupID, key: key, lamport: 2, isDeleted: true)
            #expect(try await push(delete, to: groupID, as: robin, on: app).accepted == [groupID],
                    "older than her rename, and still a delete")

            let late = try groupRecord(leslie, groupID: groupID, key: key, lamport: 12, isDeleted: false)
            let refused = try await push(late, to: groupID, as: leslie, on: app)
            #expect(refused.rejected[groupID.uuidString] == "the group has been deleted")

            try await app.testing().test(.GET, "api/v1/groups/\(groupID)/pull?since=0",
                                         headers: robin.bearer) { response async throws in
                let reply = try response.content.decode(PullReply.self)
                #expect(reply.envelopes.first { $0.recordType == .groupMeta }?.isDeleted == true)
            }
        }
    }

    /// Only the group's own record may use the group's ID. A member at write
    /// could take it over with a record of another type. A delete marked the
    /// group deleted here, so every rename after it was refused, and a live
    /// one could undo the founder's delete.
    @Test func anotherRecordCannotTakeOverTheGroupsRecord() async throws {
        try await withConfiguredApp { app in
            var robin = Account(email: "takeover-founder@example.com")
            var leslie = Account(email: "takeover-writer@example.com")
            try await register(&robin, on: app)
            try await register(&leslie, on: app)

            let groupID = UUID()
            var log = try await foundGroup(robin, groupID: groupID, on: app)
            try await addMember(leslie, to: groupID, level: .write, log: &log, owner: robin, on: app)
            let key = ScopedKey.generate(scope: .group(GroupID(groupID)))

            let named = try groupRecord(robin, groupID: groupID, key: key, lamport: 1, isDeleted: false)
            #expect(try await push(named, to: groupID, as: robin, on: app).accepted == [groupID])

            struct Payload: Codable { let name: String }
            let otherType = try RecordCodec.seal(
                Payload(name: "x"), recordID: RecordID(groupID),
                recordType: RecordType(rawValue: "somethingElse"), groupID: GroupID(groupID),
                budgetID: nil, scopeKey: key, lamport: 5, author: UserID(leslie.userID),
                device: leslie.device, membershipSequence: 0, isDeleted: true)
            let asBudget = try RecordCodec.seal(
                Payload(name: "x"), recordID: RecordID(groupID), recordType: .budget,
                groupID: GroupID(groupID), budgetID: nil, scopeKey: key, lamport: 6,
                author: UserID(leslie.userID), device: leslie.device, membershipSequence: 0)
            for envelope in [otherType, asBudget] {
                let refused = try await push(envelope, to: groupID, as: leslie, on: app)
                #expect(refused.accepted.isEmpty)
                #expect(refused.rejected[groupID.uuidString] == "record ID does not match its type")
            }

            let renamed = try groupRecord(robin, groupID: groupID, key: key, lamport: 2, isDeleted: false)
            #expect(try await push(renamed, to: groupID, as: robin, on: app).accepted == [groupID],
                    "the group's record is still the group's")
        }
    }

    /// A group record pushed through some other group, one the pusher founded,
    /// was judged by that group's log and then landed on this group's record.
    @Test func aGroupRecordCannotBePushedThroughAnotherGroup() async throws {
        try await withConfiguredApp { app in
            var robin = Account(email: "through-victim@example.com")
            var leslie = Account(email: "through-founder@example.com")
            try await register(&robin, on: app)
            try await register(&leslie, on: app)

            let household = UUID(), hers = UUID()
            _ = try await foundGroup(robin, groupID: household, on: app)
            _ = try await foundGroup(leslie, groupID: hers, on: app)
            let key = ScopedKey.generate(scope: .group(GroupID(household)))
            let named = try groupRecord(robin, groupID: household, key: key, lamport: 1, isDeleted: false)
            #expect(try await push(named, to: household, as: robin, on: app).accepted == [household])

            struct Payload: Codable { let name: String }
            let delete = try RecordCodec.seal(
                Payload(name: "Household"), recordID: RecordID(household), recordType: .groupMeta,
                groupID: GroupID(hers), budgetID: nil, scopeKey: key, lamport: 99,
                author: UserID(leslie.userID), device: leslie.device, membershipSequence: 0,
                isDeleted: true)
            let refused = try await push(delete, to: hers, as: leslie, on: app)
            #expect(refused.accepted.isEmpty)

            try await app.testing().test(.GET, "api/v1/groups/\(household)/pull?since=0",
                                         headers: robin.bearer) { response async throws in
                let reply = try response.content.decode(PullReply.self)
                #expect(reply.envelopes.first { $0.recordType == .groupMeta }?.isDeleted == false)
            }
        }
    }

    /// Rows are found by ID alone. A record pushed as another type, or through
    /// another group, must not change the row it finds. This is the only thing
    /// that stops a record of any type but the group's own being taken over
    /// from another group.
    @Test func aStoredRecordKeepsItsGroupAndType() async throws {
        try await withConfiguredApp { app in
            var robin = Account(email: "stored-owner@example.com")
            var leslie = Account(email: "stored-writer@example.com")
            try await register(&robin, on: app)
            try await register(&leslie, on: app)

            let household = UUID(), hers = UUID()
            var log = try await foundGroup(robin, groupID: household, on: app)
            try await addMember(leslie, to: household, level: .write, log: &log, owner: robin, on: app)
            _ = try await foundGroup(leslie, groupID: hers, on: app)

            let budgetID = UUID()
            let key = ScopedKey.generate(scope: .budget(BudgetID(budgetID)))
            let his = try makeEnvelope(robin, groupID: household, budgetID: budgetID,
                                       key: key, lamport: 1, text: "Hilltop")
            #expect(try await push(his, to: household, as: robin, on: app).accepted == [his.recordID.uuid])

            struct Payload: Codable { let merchant: String }
            func envelope(_ type: RecordType, in group: UUID) throws -> RecordEnvelope {
                try RecordCodec.seal(
                    Payload(merchant: "taken"), recordID: his.recordID, recordType: type,
                    groupID: GroupID(group), budgetID: BudgetID(budgetID), scopeKey: key,
                    lamport: 99, author: UserID(leslie.userID), device: leslie.device,
                    membershipSequence: 0, isDeleted: true)
            }
            let asAnotherType = try await push(try envelope(.receipt, in: household), to: household,
                                               as: leslie, on: app)
            let throughHers = try await push(try envelope(.transaction, in: hers), to: hers,
                                             as: leslie, on: app)
            for refused in [asAnotherType, throughHers] {
                #expect(refused.accepted.isEmpty)
                #expect(refused.rejected[his.recordID.uuid.uuidString] == "another record already has this ID")
            }

            try await app.testing().test(.GET, "api/v1/groups/\(household)/pull?since=0",
                                         headers: robin.bearer) { response async throws in
                let reply = try response.content.decode(PullReply.self)
                let stored = reply.envelopes.first { $0.recordID == his.recordID }
                #expect(stored?.isDeleted == false)
                #expect(stored?.recordType == .transaction)
            }
        }
    }

    /// Add is for transactions. Someone at Add deleted every budget in a group
    /// for everyone, and the role says nothing about budgets. A budget now
    /// takes Manage; the type travels in the clear, so the server can judge it.
    @Test func aBudgetTakesAManager() async throws {
        try await withConfiguredApp { app in
            var robin = Account(email: "budget-founder@example.com")
            var leslie = Account(email: "budget-writer@example.com")
            var jamie = Account(email: "budget-manager@example.com")
            try await register(&robin, on: app)
            try await register(&leslie, on: app)
            try await register(&jamie, on: app)

            let groupID = UUID()
            var log = try await foundGroup(robin, groupID: groupID, on: app)
            try await addMember(leslie, to: groupID, level: .write, log: &log, owner: robin, on: app)
            try await addMember(jamie, to: groupID, level: .manage, log: &log, owner: robin, on: app)

            let budgetID = UUID()
            let key = ScopedKey.generate(scope: .budget(BudgetID(budgetID)))
            struct Payload: Codable { let name: String }
            func budget(_ account: Account, lamport: UInt64, isDeleted: Bool) throws -> RecordEnvelope {
                try RecordCodec.seal(
                    Payload(name: "Groceries"), recordID: RecordID(budgetID), recordType: .budget,
                    groupID: GroupID(groupID), budgetID: BudgetID(budgetID), scopeKey: key,
                    lamport: lamport, author: UserID(account.userID), device: account.device,
                    membershipSequence: 0, isDeleted: isDeleted)
            }

            let made = try budget(robin, lamport: 1, isDeleted: false)
            #expect(try await push(made, to: groupID, as: robin, on: app).accepted == [budgetID])

            let deleted = try budget(leslie, lamport: 2, isDeleted: true)
            let refused = try await push(deleted, to: groupID, as: leslie, on: app)
            #expect(refused.accepted.isEmpty)
            #expect(refused.rejected[budgetID.uuidString] == "only a manager can change a budget")

            let hers = try makeEnvelope(leslie, groupID: groupID, budgetID: budgetID, key: key,
                                        lamport: 3, text: "Hilltop")
            #expect(try await push(hers, to: groupID, as: leslie, on: app).accepted == [hers.recordID.uuid],
                    "her transactions still go in")

            let renamed = try budget(jamie, lamport: 4, isDeleted: false)
            #expect(try await push(renamed, to: groupID, as: jamie, on: app).accepted == [budgetID])
        }
    }

    /// A member profile's ID is worked out from the group and the person.
    /// Mallory worked out Jamie's before he joined Household and took it in a
    /// group she founded, and Jamie's profile was refused from then on, so
    /// every member saw "A member" in place of his name.
    @Test func aProfileIDCannotBeTakenBeforeItsOwnerUsesIt() async throws {
        try await withConfiguredApp { app in
            var robin = Account(email: "profile-founder@example.com")
            var jamie = Account(email: "profile-joiner@example.com")
            var mallory = Account(email: "profile-squatter@example.com")
            try await register(&robin, on: app)
            try await register(&jamie, on: app)
            try await register(&mallory, on: app)

            let household = UUID(), hers = UUID()
            var log = try await foundGroup(robin, groupID: household, on: app)
            _ = try await foundGroup(mallory, groupID: hers, on: app)
            let jamies = RecordID.memberProfile(group: GroupID(household), user: UserID(jamie.userID))
            #expect(jamies.isNameBased)

            struct Payload: Codable { let name: String }
            func profile(_ account: Account, in group: UUID, type: RecordType = .memberProfile)
                throws -> RecordEnvelope {
                try RecordCodec.seal(
                    Payload(name: "Jamie"), recordID: jamies, recordType: type,
                    groupID: GroupID(group), budgetID: nil,
                    scopeKey: ScopedKey.generate(scope: .group(GroupID(group))), lamport: 1,
                    author: UserID(account.userID), device: account.device, membershipSequence: 0)
            }
            for type in [RecordType.transaction, .memberProfile] {
                let refused = try await push(try profile(mallory, in: hers, type: type),
                                             to: hers, as: mallory, on: app)
                #expect(refused.rejected[jamies.uuid.uuidString] == "that ID belongs to a member profile")
            }

            try await addMember(jamie, to: household, level: .write, log: &log, owner: robin, on: app)
            #expect(try await push(try profile(jamie, in: household), to: household, as: jamie,
                                   on: app).accepted == [jamies.uuid])

            let someoneElses = try profile(robin, in: household)
            let refused = try await push(someoneElses, to: household, as: robin, on: app)
            #expect(refused.rejected[jamies.uuid.uuidString] == "that ID belongs to a member profile",
                    "a profile sits on its sender's own ID")
        }
    }
}

@Suite("Server, invites", .serialized)
struct InviteRouteTests {

    /// The acceptance was overwritable by anyone holding the hash, as often as
    /// they liked, and what it destroys is the sealed blob the inviter waits for.
    @Test func anInviteCannotBeAcceptedTwice() async throws {
        try await withConfiguredApp { app in
            var robin = Account(email: "accept-once@example.com")
            try await register(&robin, on: app)
            let groupID = UUID()
            _ = try await foundGroup(robin, groupID: groupID, on: app)

            let secret = InviteSecret()
            struct CreateBody: Content {
                let inviteHash: Data; let groupID: UUID; let level: Int
                let historyAccess: String; let expiresAt: Date
            }
            try await app.testing().test(.POST, "api/v1/invites", headers: robin.bearer,
                                         beforeRequest: { request in
                try request.content.encode(CreateBody(
                    inviteHash: secret.id, groupID: groupID, level: AccessLevel.write.rawValue,
                    historyAccess: "all", expiresAt: Date().addingTimeInterval(86_400)))
            }, afterResponse: { response async throws in
                #expect(response.status == .created)
            })

            struct AcceptBody: Content { let inviteHash: Data; let acceptance: Data }
            let real = Data(repeating: 0xAA, count: 32)
            try await app.testing().test(.POST, "api/v1/invites/accept",
                                         beforeRequest: { request in
                try request.content.encode(AcceptBody(inviteHash: secret.id, acceptance: real))
            }, afterResponse: { response async throws in
                #expect(response.status == .ok)
            })
            try await app.testing().test(.POST, "api/v1/invites/accept",
                                         beforeRequest: { request in
                try request.content.encode(AcceptBody(inviteHash: secret.id,
                                                      acceptance: Data(repeating: 0xBB, count: 32)))
            }, afterResponse: { response async throws in
                #expect(response.status == .conflict)
            })

            let saved = try await InviteRow.query(on: app.db)
                .filter(\.$inviteHash == secret.id).first()
            let row = try #require(saved)
            #expect(row.acceptance == real, "the first acceptance has to survive")
        }
    }

    @Test func repeatedInviteAcceptancesAreThrottled() async throws {
        try await withConfiguredApp { app in
            struct AcceptBody: Content { let inviteHash: Data; let acceptance: Data }
            // An unknown hash, so only the rate limit is under test.
            let unknown = InviteSecret()
            var statuses: [HTTPResponseStatus] = []
            for _ in 0 ..< (RateLimiter.Limit.inviteLookup.attempts + 3) {
                try await app.testing().test(.POST, "api/v1/invites/accept",
                                             beforeRequest: { request in
                    try request.content.encode(AcceptBody(inviteHash: unknown.id,
                                                          acceptance: Data([1])))
                }, afterResponse: { response async throws in
                    statuses.append(response.status)
                })
            }
            #expect(statuses.last == .tooManyRequests, "got \(statuses)")
        }
    }
    /// The server stores a hash it cannot reverse, and an acceptance it cannot
    /// open. That is what stops it answering an invite in the recipient's place.
    @Test func inviteRoundTrip() async throws {
        try await withConfiguredApp { app in
            var robin = Account(email: "inviter@example.com")
            try await register(&robin, on: app)

            let groupID = UUID()
            _ = try await foundGroup(robin, groupID: groupID, on: app)

            let secret = InviteSecret()
            struct CreateBody: Content {
                let inviteHash: Data
                let groupID: UUID
                let level: Int
                let historyAccess: String
                let expiresAt: Date
            }
            try await app.testing().test(.POST, "api/v1/invites", headers: robin.bearer,
                                         beforeRequest: { request in
                try request.content.encode(CreateBody(
                    inviteHash: secret.id, groupID: groupID, level: AccessLevel.write.rawValue,
                    historyAccess: "all", expiresAt: Date().addingTimeInterval(86_400)))
            }, afterResponse: { response async throws in
                #expect(response.status == .created)
            })

            struct LookupReply: Content {
                let groupID: UUID
                let level: Int
                let inviterSigning: Data
                let inviterKEM: Data
            }
            try await app.testing().test(.GET, "api/v1/invites/\(secret.id.hexString)") { response async throws in
                #expect(response.status == .ok)
                let reply = try response.content.decode(LookupReply.self)
                #expect(reply.groupID == groupID)
                #expect(reply.level == AccessLevel.write.rawValue)
                #expect(reply.inviterKEM == robin.publicKeys.kem)
            }
        }
    }

    @Test func anUnknownInviteHashIsNotFound() async throws {
        try await withConfiguredApp { app in
            let unknown = InviteSecret()
            try await app.testing().test(.GET, "api/v1/invites/\(unknown.id.hexString)") { response async throws in
                #expect(response.status == .notFound)
            }
        }
    }
}

@Suite("Server, abuse protection", .serialized)
struct AbuseProtectionTests {

    /// "Runs once at boot and then hourly" was half true: there was no
    /// scheduler, so a long-lived process purged once and never again, and the
    /// rate limiter's dictionary grew for the life of the process.
    ///
    /// Built by hand rather than with withConfiguredApp, because the handler
    /// needs an interval a test can wait for.
    @Test func housekeepingRunsAfterBoot() async throws {
        let app = try await Application.make(.testing)
        do {
            try await configure(app)
            app.lifecycle.use(Housekeeping(every: .milliseconds(50), sweepWindow: 0))
            try await app.asyncBoot()

            let user = UserRow(id: UUID(), email: "housekeeping@example.com",
                               passwordHash: "x", identitySigning: Data([1]),
                               identityKEM: Data([2]))
            try await user.save(on: app.db)
            let userID = try user.requireID()
            // Already expired, and inserted after configure() purged at boot, so
            // only a scheduled tick can remove it.
            try await TokenRow(userID: userID, valueHash: "expired-digest",
                               expiresOn: Date().addingTimeInterval(-60)).save(on: app.db)
            _ = await app.rateLimiter.allow("housekeeping-key", limit: .signIn)

            var tokens = 1
            for _ in 0 ..< 40 {
                try await Task.sleep(for: .milliseconds(50))
                tokens = try await TokenRow.query(on: app.db)
                    .filter(\.$userID == userID).count()
                if tokens == 0 { break }
            }
            #expect(tokens == 0, "the scheduled token purge never ran")

            let remaining = await app.rateLimiter.count(for: "housekeeping-key")
            #expect(remaining == 0, "the limiter's dictionary is never swept, so it grows forever")
        } catch {
            try? await app.asyncShutdown()
            throw error
        }
        // A shutdown that returns proves the timer task was cancelled rather
        // than left running.
        try await app.asyncShutdown()
    }

    /// Reading the first X-Forwarded-For hop made the limiter forgeable: both
    /// Cloudflare and fly-proxy append the address they saw, so the first entry
    /// is whatever the client typed and the last is the truth.
    @Test func theCallerAddressIsTheProxysViewNotTheClientsClaim() async throws {
        setenv("TRUSTED_PROXY", "1", 1)
        defer { unsetenv("TRUSTED_PROXY") }

        try await withConfiguredApp { app in
            func address(_ headers: HTTPHeaders) -> String {
                Request(application: app, method: .POST, url: URI(string: "/"),
                        headers: headers, on: app.eventLoopGroup.next()).callerAddress
            }

            var forged = HTTPHeaders()
            forged.add(name: .xForwardedFor, value: "203.0.113.9, 198.51.100.7")
            #expect(address(forged) == "198.51.100.7", "the last hop, not the first")

            var connecting = HTTPHeaders()
            connecting.add(name: .xForwardedFor, value: "203.0.113.9, 198.51.100.7")
            connecting.add(name: "CF-Connecting-IP", value: "198.51.100.42")
            #expect(address(connecting) == "198.51.100.42",
                    "a header the client cannot set wins over one it can")
        }
    }

    /// The same thing end to end: rotating the part of the header a caller
    /// controls must not hand them a fresh allowance.
    @Test func aForgedForwardedHeaderDoesNotBuyMoreAttempts() async throws {
        setenv("TRUSTED_PROXY", "1", 1)
        defer { unsetenv("TRUSTED_PROXY") }

        try await withConfiguredApp { app in
            struct SignInBody: Content { let email: String; let password: String }
            var statuses: [HTTPResponseStatus] = []

            for attempt in 0 ..< (RateLimiter.Limit.signIn.attempts + 1) {
                var headers = HTTPHeaders()
                // A different claimed origin every time, same real one.
                headers.add(name: .xForwardedFor, value: "203.0.113.\(attempt), 198.51.100.7")
                try await app.testing().test(.POST, "api/v1/signin", headers: headers,
                                             beforeRequest: { request in
                    try request.content.encode(SignInBody(email: "nobody@example.com",
                                                          password: "a-long-enough-password"))
                }, afterResponse: { response async throws in
                    statuses.append(response.status)
                })
            }

            #expect(statuses.last == .tooManyRequests, "got \(statuses)")
        }
    }
    @Test func aShortPasswordIsRefused() async throws {
        try await withConfiguredApp { app in
            let body = SignUpBody(email: "short@example.com", password: "tiny",
                                  identitySigning: Data(repeating: 1, count: 32),
                                  identityKEM: Data(repeating: 2, count: 32),
                                  escrowNonce: nil, escrowCiphertext: nil)
            try await app.testing().test(.POST, "api/v1/signup", beforeRequest: { request in
                try request.content.encode(body)
            }, afterResponse: { response async throws in
                #expect(response.status == .badRequest)
                #expect(response.body.string.contains("10 characters"))
            })
        }
    }

    /// Sign-in had nothing in front of it, so a password could be guessed as fast
    /// as the network allowed, and each guess costs the server a bcrypt.
    @Test func repeatedSignInAttemptsAreThrottled() async throws {
        try await withConfiguredApp { app in
            var robin = Account(email: "throttled@example.com")
            try await register(&robin, on: app)

            struct SignIn: Content { let email: String; let password: String }
            var statuses: [HTTPResponseStatus] = []

            for _ in 0 ..< (RateLimiter.Limit.signIn.attempts + 3) {
                try await app.testing().test(.POST, "api/v1/signin", beforeRequest: { request in
                    try request.content.encode(SignIn(email: "throttled@example.com",
                                                      password: "wrong-password"))
                }, afterResponse: { response async throws in
                    statuses.append(response.status)
                })
            }

            #expect(statuses.contains(.tooManyRequests), "it should start refusing, got \(statuses)")
            #expect(statuses.last == .tooManyRequests)
        }
    }

    @Test func theLimiterExpiresOldAttempts() async throws {
        // A clock we control, so this does not depend on wall time.
        nonisolated(unsafe) var now = Date(timeIntervalSince1970: 1_000_000)
        let limiter = RateLimiter(clock: { now })
        let limit = RateLimiter.Limit(attempts: 2, window: 60)

        #expect(await limiter.allow("k", limit: limit))
        #expect(await limiter.allow("k", limit: limit))
        #expect(!(await limiter.allow("k", limit: limit)), "third attempt inside the window")

        now = now.addingTimeInterval(61)
        #expect(await limiter.allow("k", limit: limit), "the window has rolled")
    }

    @Test func theLimiterSweepsKeysItNoLongerNeeds() async throws {
        nonisolated(unsafe) var now = Date(timeIntervalSince1970: 1_000_000)
        let limiter = RateLimiter(clock: { now })
        _ = await limiter.allow("k", limit: .signIn)
        #expect(await limiter.count(for: "k") == 1)

        now = now.addingTimeInterval(7200)
        await limiter.sweep()
        #expect(await limiter.count(for: "k") == 0)
    }

    @Test func differentCallersHaveSeparateAllowances() async throws {
        let limiter = RateLimiter()
        let limit = RateLimiter.Limit(attempts: 1, window: 600)

        #expect(await limiter.allow("signin:1.1.1.1", limit: limit))
        #expect(!(await limiter.allow("signin:1.1.1.1", limit: limit)))
        #expect(await limiter.allow("signin:2.2.2.2", limit: limit),
                "one caller being throttled must not lock out everyone else")
    }
}

@Suite("Server, finishing invites and publishing keys", .serialized)
struct SharingRouteTests {
    private struct CreateBody: Content {
        let inviteHash: Data; let groupID: UUID; let level: Int
        let historyAccess: String; let expiresAt: Date
    }
    private struct AcceptBody: Content { let inviteHash: Data; let acceptance: Data }
    private struct PendingReply: Content {
        let inviteHash: Data; let level: Int; let historyAccess: String
        let expiresAt: Date; let acceptance: Data?
    }
    private struct KeysBody: Content { let wrappedKeys: [WrappedKey] }

    private func invite(_ secret: InviteSecret, to groupID: UUID, by account: Account,
                        on app: Application) async throws {
        try await app.testing().test(.POST, "api/v1/invites", headers: account.bearer,
                                     beforeRequest: { request in
            try request.content.encode(CreateBody(
                inviteHash: secret.id, groupID: groupID, level: AccessLevel.write.rawValue,
                historyAccess: "all", expiresAt: Date().addingTimeInterval(86_400)))
        }, afterResponse: { response async throws in
            #expect(response.status == .created)
        })
    }

    /// The inviter collects the sealed answer here. Someone who may not invite
    /// cannot list invites, and so cannot learn who is about to join.
    @Test func theInviterCollectsTheAnswerAndOthersCannot() async throws {
        try await withConfiguredApp { app in
            var robin = Account(email: "collect@example.com")
            var leslie = Account(email: "collect-l@example.com")
            try await register(&robin, on: app)
            try await register(&leslie, on: app)
            let groupID = UUID()
            var log = try await foundGroup(robin, groupID: groupID, on: app)
            try await addMember(leslie, to: groupID, level: .write, log: &log, owner: robin, on: app)

            let secret = InviteSecret()
            try await invite(secret, to: groupID, by: robin, on: app)
            let answer = Data(repeating: 0xAB, count: 40)
            try await app.testing().test(.POST, "api/v1/invites/accept", beforeRequest: { request in
                try request.content.encode(AcceptBody(inviteHash: secret.id, acceptance: answer))
            })

            try await app.testing().test(.GET, "api/v1/groups/\(groupID)/invites",
                                         headers: robin.bearer) { response async throws in
                #expect(response.status == .ok)
                let pending = try response.content.decode([PendingReply].self)
                #expect(pending.count == 1)
                #expect(pending.first?.acceptance == answer)
            }
            try await app.testing().test(.GET, "api/v1/groups/\(groupID)/invites",
                                         headers: leslie.bearer) { response async throws in
                #expect(response.status == .forbidden, "can add, so cannot see invites")
            }
        }
    }

    @Test func onlyTheInviterOrAManagerDeletesAnInvite() async throws {
        try await withConfiguredApp { app in
            var robin = Account(email: "delete@example.com")
            var leslie = Account(email: "delete-l@example.com")
            try await register(&robin, on: app)
            try await register(&leslie, on: app)
            let groupID = UUID()
            var log = try await foundGroup(robin, groupID: groupID, on: app)
            try await addMember(leslie, to: groupID, level: .write, log: &log, owner: robin, on: app)

            let secret = InviteSecret()
            try await invite(secret, to: groupID, by: robin, on: app)

            try await app.testing().test(.DELETE, "api/v1/invites/\(secret.id.hexString)",
                                         headers: leslie.bearer) { response async throws in
                #expect(response.status == .forbidden)
            }
            try await app.testing().test(.DELETE, "api/v1/invites/\(secret.id.hexString)",
                                         headers: robin.bearer) { response async throws in
                #expect(response.status == .noContent)
            }
            try await app.testing().test(.GET, "api/v1/invites/\(secret.id.hexString)") { response async throws in
                #expect(response.status == .notFound, "gone once deleted")
            }
        }
    }

    /// A manager may publish a key for a budget she made, and nobody below
    /// Manage may, because only a manager makes budgets. Only budget keys sealed
    /// under the group key: a key sealed to a person is a grant of access, and
    /// those only travel with the membership entry that allows them.
    @Test func membersPublishBudgetKeysButNothingElse() async throws {
        try await withConfiguredApp { app in
            var robin = Account(email: "keys@example.com")
            var leslie = Account(email: "keys-l@example.com")
            var reader = Account(email: "keys-r@example.com")
            var adder = Account(email: "keys-a@example.com")
            try await register(&robin, on: app)
            try await register(&leslie, on: app)
            try await register(&reader, on: app)
            try await register(&adder, on: app)
            let groupID = UUID()
            let groupKey = ScopedKey.generate(scope: .group(GroupID(groupID)))
            var log = try await foundGroup(robin, groupID: groupID, on: app)
            try await addMember(leslie, to: groupID, level: .manage, log: &log, owner: robin,
                                sealing: groupKey, on: app)
            try await addMember(reader, to: groupID, level: .read, log: &log, owner: robin, on: app)
            try await addMember(adder, to: groupID, level: .write, log: &log, owner: robin, on: app)

            let budgetKey = ScopedKey.generate(scope: .budget(BudgetID()))
            let budgetWrap = try KeyWrap.wrapUnderGroupKey(
                budgetKey, groupKey: groupKey.material, senderUserID: UserID(leslie.userID))
            let personWrap = try KeyWrap.wrapToIdentity(
                groupKey, recipient: reader.publicKeys, recipientUserID: UserID(reader.userID),
                sender: leslie.identity, senderUserID: UserID(leslie.userID))

            try await app.testing().test(.POST, "api/v1/groups/\(groupID)/keys",
                                         headers: leslie.bearer, beforeRequest: { request in
                try request.content.encode(KeysBody(wrappedKeys: [budgetWrap]))
            }, afterResponse: { response async throws in
                #expect(response.status == .created)
            })
            try await app.testing().test(.POST, "api/v1/groups/\(groupID)/keys",
                                         headers: leslie.bearer, beforeRequest: { request in
                try request.content.encode(KeysBody(wrappedKeys: [personWrap]))
            }, afterResponse: { response async throws in
                #expect(response.status == .badRequest, "a key sealed to a person is refused")
            })
            for account in [reader, adder] {
                try await app.testing().test(.POST, "api/v1/groups/\(groupID)/keys",
                                             headers: account.bearer, beforeRequest: { request in
                    try request.content.encode(KeysBody(wrappedKeys: [budgetWrap]))
                }, afterResponse: { response async throws in
                    #expect(response.status == .forbidden, "below Manage, so cannot add budgets")
                })
            }
        }
    }
}

/// Keys, devices, IDs and Lamport values: what one member could take from the
/// others before anything here was checked.
@Suite("Server, what members may take", .serialized)
struct TakeoverTests {
    private struct KeysBody: Content { let wrappedKeys: [WrappedKey] }

    /// Posts an entry to a group's log, with keys, and returns the status and
    /// the reason given.
    private func post(_ entry: MembershipLogEntry, keys: [WrappedKey] = [], to groupID: UUID,
                      as account: Account, on app: Application) async throws
        -> (status: HTTPResponseStatus, reason: String) {
        var answer: (HTTPResponseStatus, String)?
        try await app.testing().test(.POST, "api/v1/groups/\(groupID)/log", headers: account.bearer,
                                     beforeRequest: { request in
            try request.content.encode(LogBody(entry: entry, wrappedKeys: keys))
        }, afterResponse: { response async throws in
            answer = (response.status, response.body.string)
        })
        return try #require(answer)
    }

    private func upload(_ keys: [WrappedKey], to groupID: UUID, as account: Account,
                        on app: Application) async throws -> HTTPResponseStatus {
        var status: HTTPResponseStatus?
        try await app.testing().test(.POST, "api/v1/groups/\(groupID)/keys", headers: account.bearer,
                                     beforeRequest: { request in
            try request.content.encode(KeysBody(wrappedKeys: keys))
        }, afterResponse: { response async throws in
            status = response.status
        })
        return try #require(status)
    }

    private func keys(in groupID: UUID, as account: Account, on app: Application) async throws
        -> [WrappedKey] {
        var keys: [WrappedKey]?
        try await app.testing().test(.GET, "api/v1/groups/\(groupID)/keys",
                                     headers: account.bearer) { response async throws in
            keys = try response.content.decode([WrappedKey].self)
        }
        return try #require(keys)
    }

    private func push(_ envelopes: [RecordEnvelope], to groupID: UUID, as account: Account,
                      on app: Application) async throws -> PushReply {
        var reply: PushReply?
        try await app.testing().test(.POST, "api/v1/groups/\(groupID)/push", headers: account.bearer,
                                     beforeRequest: { request in
            try request.content.encode(PushBody(envelopes: envelopes))
        }, afterResponse: { response async throws in
            #expect(response.status == .ok)
            reply = try response.content.decode(PushReply.self)
        })
        return try #require(reply)
    }

    /// An entry signed by `author`, next in `log`.
    private func entry(_ action: MembershipAction, subject: Account, keys: IdentityPublicKeys? = nil,
                       level: AccessLevel = .read, device: DeviceID? = nil, devicePublicKey: Data? = nil,
                       epochAfter: Epoch = .initial, by author: Account,
                       after log: [MembershipLogEntry], in groupID: UUID) throws -> MembershipLogEntry {
        try MembershipLogEntry.signed(
            scope: .group(GroupID(groupID)), sequence: UInt64(log.count),
            previousHash: log.last!.hash, action: action, subjectUserID: UserID(subject.userID),
            subjectKeys: keys, level: level, epochAfter: epochAfter,
            deviceID: device, devicePublicKey: devicePublicKey,
            author: author.identity, authorUserID: UserID(author.userID))
    }

    /// Keys travel only with a manager's entry. Mallory can only view. She sent
    /// keys of her own with the entry that registers her laptop, the server
    /// stored them, and every member's app took them in place of its own. A
    /// manager's keys are checked one by one, and the first key stored for a
    /// scope, epoch and recipient is the one that stays.
    @Test func keysTravelOnlyWithAManagersEntry() async throws {
        try await withConfiguredApp { app in
            var robin = Account(email: "trust-keys-founder@example.com")
            var leslie = Account(email: "trust-keys-manager@example.com")
            var mallory = Account(email: "trust-keys-viewer@example.com")
            var jamie = Account(email: "trust-keys-joiner@example.com")
            var stranger = Account(email: "trust-keys-stranger@example.com")
            try await register(&robin, on: app)
            try await register(&leslie, on: app)
            try await register(&mallory, on: app)
            try await register(&jamie, on: app)
            try await register(&stranger, on: app)
            let groupID = UUID()
            let groupKey = ScopedKey.generate(scope: .group(GroupID(groupID)))
            var log = try await foundGroup(robin, groupID: groupID, on: app)
            try await addMember(leslie, to: groupID, level: .manage, log: &log, owner: robin,
                                sealing: groupKey, on: app)
            try await addMember(mallory, to: groupID, level: .read, log: &log, owner: robin, on: app)

            let budgetKey = ScopedKey.generate(scope: .budget(BudgetID()))
            func toPerson(_ recipient: Account, from sender: Account,
                          key: ScopedKey = groupKey) throws -> WrappedKey {
                try KeyWrap.wrapToIdentity(key, recipient: recipient.publicKeys,
                                           recipientUserID: UserID(recipient.userID),
                                           sender: sender.identity, senderUserID: UserID(sender.userID))
            }
            func underGroup(_ key: ScopedKey = budgetKey, from sender: Account) throws -> WrappedKey {
                try KeyWrap.wrapUnderGroupKey(key, groupKey: groupKey.material,
                                              senderUserID: UserID(sender.userID))
            }

            let laptop = DeviceKeyPair()
            let hers = try entry(.addDevice, subject: mallory, device: laptop.id,
                                 devicePublicKey: laptop.publicKey, by: mallory, after: log, in: groupID)
            let planted = try [toPerson(robin, from: mallory), underGroup(from: mallory)]
            #expect(try await post(hers, keys: planted, to: groupID, as: mallory, on: app).status
                        == .forbidden)
            #expect(try await keys(in: groupID, as: robin, on: app).isEmpty, "none was stored")
            #expect(try await post(hers, to: groupID, as: mallory, on: app).status == .created,
                    "the entry on its own goes in")
            log.append(hers)

            let adding = try entry(.add, subject: jamie, keys: jamie.publicKeys, by: leslie,
                                   after: log, in: groupID)
            let otherGroup = ScopedKey.generate(scope: .group(GroupID()))
            let refused: [(String, WrappedKey)] = [
                ("sent as someone else", try toPerson(jamie, from: robin)),
                ("for another group", try toPerson(jamie, from: leslie, key: otherGroup)),
                ("to someone not in the group", try toPerson(stranger, from: leslie)),
                ("for an epoch not reached", try underGroup(
                    ScopedKey.generate(scope: .budget(BudgetID()), epoch: Epoch(1)), from: leslie)),
            ]
            for (why, key) in refused {
                #expect(try await post(adding, keys: [key], to: groupID, as: leslie, on: app).status
                            == .badRequest, "\(why)")
            }
            let real = try [toPerson(jamie, from: leslie), underGroup(from: leslie)]
            #expect(try await post(adding, keys: real, to: groupID, as: leslie, on: app).status == .created)

            #expect(try await upload([try underGroup(from: leslie)], to: groupID, as: leslie, on: app)
                        == .created)
            let held = try await keys(in: groupID, as: jamie, on: app)
            #expect(held.count == 2, "one group key and one budget key, the first of each")
            #expect(held.first { $0.scope == budgetKey.scope }?.ciphertext == real[1].ciphertext)
        }
    }

    /// A budget's ID belongs to the first group that uses it. Mallory founded
    /// her own group, where she may publish keys. A key there for Household's
    /// budget took that budget over on the Mac of anyone in both groups, and a
    /// record there on its ID, pushed between Robin publishing its key and
    /// pushing it, kept the budget out for good.
    @Test func aBudgetsIDBelongsToTheGroupThatUsesItFirst() async throws {
        try await withConfiguredApp { app in
            var robin = Account(email: "trust-budget-founder@example.com")
            var mallory = Account(email: "trust-budget-squatter@example.com")
            try await register(&robin, on: app)
            try await register(&mallory, on: app)
            let household = UUID(), hers = UUID()
            _ = try await foundGroup(robin, groupID: household, on: app)
            _ = try await foundGroup(mallory, groupID: hers, on: app)

            let budgetID = UUID()
            let budgetKey = ScopedKey.generate(scope: .budget(BudgetID(budgetID)))
            func wrap(_ key: ScopedKey, in group: UUID, from account: Account) throws -> WrappedKey {
                try KeyWrap.wrapUnderGroupKey(
                    key, groupKey: ScopedKey.generate(scope: .group(GroupID(group))).material,
                    senderUserID: UserID(account.userID))
            }
            #expect(try await upload([try wrap(budgetKey, in: household, from: robin)], to: household,
                                     as: robin, on: app) == .created)

            #expect(try await upload([try wrap(budgetKey, in: hers, from: mallory)], to: hers,
                                     as: mallory, on: app) == .badRequest)
            let profileID = RecordID.memberProfile(group: GroupID(household), user: UserID(robin.userID))
            for id in [household, profileID.uuid] {
                let squat = ScopedKey.generate(scope: .budget(BudgetID(id)))
                #expect(try await upload([try wrap(squat, in: hers, from: mallory)], to: hers,
                                         as: mallory, on: app) == .badRequest,
                        "nor on a group's ID or a profile's")
            }

            struct Payload: Codable { let name: String }
            func record(_ type: RecordType, in group: UUID, by account: Account,
                        budget: UUID?) throws -> RecordEnvelope {
                try RecordCodec.seal(
                    Payload(name: "Gas"), recordID: RecordID(budgetID), recordType: type,
                    groupID: GroupID(group), budgetID: budget.map { BudgetID($0) },
                    scopeKey: budgetKey, lamport: 1, author: UserID(account.userID),
                    device: account.device, membershipSequence: 0)
            }
            let squatted = try await push([try record(.statement, in: hers, by: mallory, budget: nil)],
                                          to: hers, as: mallory, on: app)
            #expect(squatted.rejected[budgetID.uuidString] == "another record already has this ID")
            let retyped = try await push([try record(.transaction, in: household, by: robin,
                                                     budget: budgetID)],
                                         to: household, as: robin, on: app)
            #expect(retyped.rejected[budgetID.uuidString] == "another record already has this ID",
                    "an ID a budget's key uses is for that budget")
            let budget = try await push([try record(.budget, in: household, by: robin, budget: budgetID)],
                                        to: household, as: robin, on: app)
            #expect(budget.accepted == [budgetID])
        }
    }

    /// A manager put her own keys in the founder's place, and a member at View
    /// took the founder's device or cut it off. Either way every member
    /// refused what he sent from then on.
    @Test func aMemberCannotTakeAnotherMembersKeysOrDevice() async throws {
        try await withConfiguredApp { app in
            var robin = Account(email: "trust-device-founder@example.com")
            var leslie = Account(email: "trust-device-manager@example.com")
            var jamie = Account(email: "trust-device-viewer@example.com")
            try await register(&robin, on: app)
            try await register(&leslie, on: app)
            try await register(&jamie, on: app)
            let groupID = UUID()
            var log = try await foundGroup(robin, groupID: groupID, on: app)
            try await addMember(leslie, to: groupID, level: .manage, log: &log, owner: robin, on: app)
            try await addMember(jamie, to: groupID, level: .read, log: &log, owner: robin, on: app)

            let attempts: [(Account, MembershipLogEntry, String)] = [
                (leslie, try entry(.rotateIdentity, subject: robin, keys: leslie.publicKeys,
                                   by: leslie, after: log, in: groupID), "keysAlreadyEstablished"),
                (leslie, try entry(.changeLevel, subject: jamie, keys: jamie.publicKeys,
                                   device: DeviceKeyPair().id, devicePublicKey: leslie.device.publicKey,
                                   by: leslie, after: log, in: groupID), "deviceNotOnItsOwn"),
                (jamie, try entry(.revokeDevice, subject: jamie, device: robin.device.id,
                                  by: jamie, after: log, in: groupID), "notTheirDevice"),
                (jamie, try entry(.revokeDevice, subject: jamie, device: jamie.device.id,
                                  epochAfter: Epoch(1), by: jamie, after: log, in: groupID),
                 "authorNotEntitled"),
            ]
            for (account, attempt, why) in attempts {
                let answer = try await post(attempt, to: groupID, as: account, on: app)
                #expect(answer.status == .badRequest)
                #expect(answer.reason.contains(why), "got \(answer.reason)")
            }
            // His device ID registered as hers is hers alone, and his stays his.
            let squat = try entry(.addDevice, subject: jamie, device: robin.device.id,
                                  devicePublicKey: jamie.device.publicKey, by: jamie,
                                  after: log, in: groupID)
            #expect(try await post(squat, to: groupID, as: jamie, on: app).status == .created)

            let budgetID = UUID()
            let his = try makeEnvelope(robin, groupID: groupID, budgetID: budgetID,
                                       key: ScopedKey.generate(scope: .budget(BudgetID(budgetID))),
                                       lamport: 1, text: "Hilltop")
            #expect(try await push([his], to: groupID, as: robin, on: app).accepted == [his.recordID.uuid],
                    "his device is still his")
        }
    }

    /// A group's ID is also its record's ID. A group founded on someone's
    /// profile ID, or a record's, hid that record on the Mac of everyone who
    /// answered the group's link.
    @Test func aGroupCannotBeFoundedOnAnIDInUse() async throws {
        try await withConfiguredApp { app in
            var robin = Account(email: "trust-found-founder@example.com")
            var mallory = Account(email: "trust-found-squatter@example.com")
            try await register(&robin, on: app)
            try await register(&mallory, on: app)
            let household = UUID()
            _ = try await foundGroup(robin, groupID: household, on: app)
            let budgetID = UUID()
            let his = try makeEnvelope(robin, groupID: household, budgetID: budgetID,
                                       key: ScopedKey.generate(scope: .budget(BudgetID(budgetID))),
                                       lamport: 1, text: "Hilltop")
            #expect(try await push([his], to: household, as: robin, on: app).accepted.count == 1)

            let profileID = RecordID.memberProfile(group: GroupID(household), user: UserID(robin.userID))
            for id in [profileID.uuid, his.recordID.uuid, UUID()] {
                let founding = try MembershipLogEntry.signed(
                    scope: .group(GroupID(id)), sequence: 0, previousHash: MembershipLogEntry.rootHash,
                    action: .found, subjectUserID: UserID(mallory.userID), subjectKeys: mallory.publicKeys,
                    level: .superadmin, epochAfter: .initial,
                    deviceID: mallory.device.id, devicePublicKey: mallory.device.publicKey,
                    author: mallory.identity, authorUserID: UserID(mallory.userID))
                try await app.testing().test(.POST, "api/v1/groups/\(id)/log", headers: mallory.bearer,
                                             beforeRequest: { request in
                    try request.content.encode(LogBody(entry: founding, wrappedKeys: []))
                }, afterResponse: { response async throws in
                    if id == profileID.uuid || id == his.recordID.uuid {
                        #expect(response.status == .badRequest)
                        #expect(response.body.string.contains("already in use"))
                    } else {
                        #expect(response.status == .created, "a fresh ID is fine")
                    }
                })
            }
        }
    }

    /// Renaming the group renames it for every member. Add is for
    /// transactions, so it takes a manager, as a budget does.
    @Test func renamingTheGroupTakesAManager() async throws {
        try await withConfiguredApp { app in
            var robin = Account(email: "trust-rename-founder@example.com")
            var leslie = Account(email: "trust-rename-writer@example.com")
            var jamie = Account(email: "trust-rename-manager@example.com")
            try await register(&robin, on: app)
            try await register(&leslie, on: app)
            try await register(&jamie, on: app)
            let groupID = UUID()
            var log = try await foundGroup(robin, groupID: groupID, on: app)
            try await addMember(leslie, to: groupID, level: .write, log: &log, owner: robin, on: app)
            try await addMember(jamie, to: groupID, level: .manage, log: &log, owner: robin, on: app)
            let key = ScopedKey.generate(scope: .group(GroupID(groupID)))
            struct Payload: Codable { let name: String }
            func renamed(by account: Account, lamport: UInt64) throws -> RecordEnvelope {
                try RecordCodec.seal(
                    Payload(name: "Home"), recordID: RecordID(groupID), recordType: .groupMeta,
                    groupID: GroupID(groupID), budgetID: nil, scopeKey: key, lamport: lamport,
                    author: UserID(account.userID), device: account.device, membershipSequence: 0)
            }

            let hers = try await push([try renamed(by: leslie, lamport: 3)], to: groupID, as: leslie, on: app)
            #expect(hers.rejected[groupID.uuidString] == "only a manager can change the group")
            let his = try await push([try renamed(by: jamie, lamport: 4)], to: groupID, as: jamie, on: app)
            #expect(his.accepted == [groupID])
        }
    }

    /// A member at Add set her own Mac's clock just under the ceiling, and the
    /// stock app signed the next value. Every Mac that pulled it had no room
    /// left to save in the group. A value too far above the group's highest
    /// is refused, judged against the highest stored before the push.
    @Test func aLamportValueTooFarAheadOfTheGroupIsRefused() async throws {
        try await withConfiguredApp { app in
            var robin = Account(email: "trust-lead-founder@example.com")
            try await register(&robin, on: app)
            let groupID = UUID()
            _ = try await foundGroup(robin, groupID: groupID, on: app)
            let budgetID = UUID()
            let key = ScopedKey.generate(scope: .budget(BudgetID(budgetID)))
            func spent(_ lamport: UInt64) throws -> RecordEnvelope {
                try makeEnvelope(robin, groupID: groupID, budgetID: budgetID, key: key,
                                 lamport: lamport, text: "Hilltop")
            }
            let lead = UInt64(1) << 24
            let tooFar = "the Lamport value is too far ahead of the group"

            #expect(try await push([try spent(5)], to: groupID, as: robin, on: app).accepted.count == 1)
            let ahead = try spent(5 + lead + 1)
            #expect(try await push([ahead], to: groupID, as: robin, on: app)
                .rejected[ahead.recordID.uuid.uuidString] == tooFar)

            let first = try spent(5 + lead), second = try spent(5 + 2 * lead)
            let both = try await push([first, second], to: groupID, as: robin, on: app)
            #expect(both.accepted == [first.recordID.uuid], "one push climbs once")
            #expect(both.rejected[second.recordID.uuid.uuidString] == tooFar)
            #expect(try await push([second], to: groupID, as: robin, on: app).accepted.count == 1,
                    "the next is judged against the new highest")
        }
    }

    /// The migration fills in each group's highest value from the records it
    /// holds, leaving out any at or above the ceiling, which would let every
    /// later value through.
    @Test func theHighestStoredValueIsFilledInFromRecords() async throws {
        try await withConfiguredApp { app in
            var robin = Account(email: "trust-fill-founder@example.com")
            try await register(&robin, on: app)
            let groupID = UUID()
            _ = try await foundGroup(robin, groupID: groupID, on: app)
            let budgetID = UUID()
            let key = ScopedKey.generate(scope: .budget(BudgetID(budgetID)))
            for lamport: UInt64 in [3, 9] {
                let envelope = try makeEnvelope(robin, groupID: groupID, budgetID: budgetID, key: key,
                                                lamport: lamport, text: "Hilltop")
                #expect(try await push([envelope], to: groupID, as: robin, on: app).accepted.count == 1)
            }
            // Stored before the ceiling existed.
            let forged = try makeEnvelope(robin, groupID: groupID, budgetID: budgetID, key: key,
                                          lamport: 1, text: "forged")
            try await RecordRow(
                id: forged.recordID.uuid, groupID: groupID, budgetID: budgetID,
                recordType: RecordType.transaction.rawValue, serverSeq: 100,
                lamport: Int(RecordEnvelope.lamportCeiling) + 5, authorUserID: robin.userID,
                authorDeviceID: robin.device.id.uuid, isDeleted: false,
                envelope: try JSONEncoder().encode(forged)).save(on: app.db)

            let group = try #require(try await GroupRow.find(groupID, on: app.db))
            group.maxLamport = 0
            try await group.save(on: app.db)
            try await fillGroupMaxLamport(on: app.db)
            #expect(try await GroupRow.find(groupID, on: app.db)?.maxLamport == 9)
        }
    }

    // MARK: Epochs, budget-key slots and the migration

    /// The epoch is a 32-bit number. Mallory founded a group at its top value,
    /// then posted an entry that moves the epoch. Working out the next one
    /// overflowed and stopped the server process, on every post. A group
    /// starts at the first epoch, and the next is worked out without
    /// overflowing.
    @Test func aGroupAtTheTopEpochCannotStopTheServer() async throws {
        try await withConfiguredApp { app in
            var mallory = Account(email: "trust-top-epoch@example.com")
            try await register(&mallory, on: app)
            let groupID = UUID()
            let atTop = try MembershipLogEntry.signed(
                scope: .group(GroupID(groupID)), sequence: 0, previousHash: MembershipLogEntry.rootHash,
                action: .found, subjectUserID: UserID(mallory.userID), subjectKeys: mallory.publicKeys,
                level: .superadmin, epochAfter: Epoch(UInt32.max),
                deviceID: mallory.device.id, devicePublicKey: mallory.device.publicKey,
                author: mallory.identity, authorUserID: UserID(mallory.userID))
            let founding = try await post(atTop, to: groupID, as: mallory, on: app)
            #expect(founding.status == .badRequest)
            #expect(founding.reason.contains("epochNotNext"), "got \(founding.reason)")

            let fresh = UUID()
            let log = try await foundGroup(mallory, groupID: fresh, on: app)
            let jump = try entry(.rotate, subject: mallory, level: .superadmin,
                                 epochAfter: Epoch(UInt32.max), by: mallory, after: log, in: fresh)
            let jumped = try await post(jump, to: fresh, as: mallory, on: app)
            #expect(jumped.status == .badRequest)
            #expect(jumped.reason.contains("epochNotNext"), "got \(jumped.reason)")
            try await app.testing().test(.GET, "health") { response async throws in
                #expect(response.status == .ok, "still running")
            }
        }
    }

    /// The server keeps the first key for each slot and cannot open a key to
    /// check it. Mallory, a manager added "from now on", holds no key for the
    /// first epoch, and filled its empty slot for Groceries with junk. The real
    /// key sent later was dropped without a word. A budget key now comes only
    /// from someone who holds that epoch's group key.
    @Test func aBudgetKeyComesOnlyFromSomeoneHoldingTheGroupKey() async throws {
        try await withConfiguredApp { app in
            var robin = Account(email: "trust-slot-founder@example.com")
            var mallory = Account(email: "trust-slot-manager@example.com")
            try await register(&robin, on: app)
            try await register(&mallory, on: app)
            let groupID = UUID()
            var log = try await foundGroup(robin, groupID: groupID, on: app)

            // Mallory joins "from now on": a new epoch, its key sealed to both.
            let next = ScopedKey.generate(scope: .group(GroupID(groupID)), epoch: Epoch(1))
            let adding = try entry(.add, subject: mallory, keys: mallory.publicKeys, level: .manage,
                                   epochAfter: Epoch(1), by: robin, after: log, in: groupID)
            let sealed = try [robin, mallory].map {
                try KeyWrap.wrapToIdentity(next, recipient: $0.publicKeys, recipientUserID: UserID($0.userID),
                                           sender: robin.identity, senderUserID: UserID(robin.userID))
            }
            #expect(try await post(adding, keys: sealed, to: groupID, as: robin, on: app).status == .created)
            log.append(adding)

            let groceries = BudgetID()
            func budgetKey(_ epoch: Epoch, from account: Account) throws -> WrappedKey {
                try KeyWrap.wrapUnderGroupKey(ScopedKey.generate(scope: .budget(groceries), epoch: epoch),
                                              groupKey: next.material, senderUserID: UserID(account.userID))
            }
            #expect(try await upload([try budgetKey(.initial, from: mallory)], to: groupID, as: mallory,
                                     on: app) == .badRequest, "she never held the first epoch's key")
            #expect(try await upload([try budgetKey(Epoch(1), from: mallory)], to: groupID, as: mallory,
                                     on: app) == .created, "she holds this one")
            #expect(try await upload([try budgetKey(.initial, from: robin)], to: groupID, as: robin,
                                     on: app) == .created, "he founded it and made the first one")
        }
    }

    /// Fluent records a migration as done only after it returns. A start cut
    /// short after the column went in tried to add it again on every start
    /// after, and the server could not start. Now a second run finds the
    /// column and fills every group again, which never lowers a value: a
    /// group already above its records keeps its value.
    @Test func theMigrationRunsAgainAfterAStartCutShort() async throws {
        try await withConfiguredApp { app in
            var robin = Account(email: "trust-rerun-founder@example.com")
            try await register(&robin, on: app)
            var highest: [UUID: Int] = [:]
            for lamports: [UInt64] in [[3, 9], [4], []] {
                let groupID = UUID()
                _ = try await foundGroup(robin, groupID: groupID, on: app)
                let budgetID = UUID()
                let key = ScopedKey.generate(scope: .budget(BudgetID(budgetID)))
                for lamport in lamports {
                    let envelope = try makeEnvelope(robin, groupID: groupID, budgetID: budgetID,
                                                    key: key, lamport: lamport, text: "Hilltop")
                    #expect(try await push([envelope], to: groupID, as: robin, on: app).accepted.count == 1)
                }
                let group = try #require(try await GroupRow.find(groupID, on: app.db))
                let alreadyAbove = lamports == [4]
                group.maxLamport = alreadyAbove ? 100 : 0
                try await group.save(on: app.db)
                highest[groupID] = alreadyAbove ? 100 : Int(lamports.max() ?? 0)
            }

            try await AddGroupMaxLamport().prepare(on: app.db)
            for (groupID, value) in highest {
                #expect(try await GroupRow.find(groupID, on: app.db)?.maxLamport == value)
            }
        }
    }

    // MARK: Shared device IDs, sign-up keys and self-sealed keys

    /// Two people can each register one device ID as their own. Mallory sent
    /// her version of Robin's record at his Lamport value under his device
    /// ID, and the server took it as his version sent again: it answered
    /// that it had it, and kept his. Now the person counts as well as the
    /// device, and a tie between them is broken by who wrote it, so what the
    /// server says it took is what it holds.
    @Test func anotherPersonUnderTheSameDeviceIDIsNotAResend() async throws {
        try await withConfiguredApp { app in
            var robin = Account(email: "trust-echo-founder@example.com")
            var mallory = Account(email: "trust-echo-manager@example.com")
            try await register(&robin, on: app)
            try await register(&mallory, on: app)
            let groupID = UUID()
            var log = try await foundGroup(robin, groupID: groupID, on: app)
            try await addMember(mallory, to: groupID, level: .manage, log: &log, owner: robin, on: app)
            let borrowed = DeviceKeyPair(id: robin.device.id)
            let squat = try entry(.addDevice, subject: mallory, device: borrowed.id,
                                  devicePublicKey: borrowed.publicKey, by: mallory, after: log, in: groupID)
            #expect(try await post(squat, to: groupID, as: mallory, on: app).status == .created)

            let budgetID = UUID()
            let key = ScopedKey.generate(scope: .budget(BudgetID(budgetID)))
            let his = try makeEnvelope(robin, groupID: groupID, budgetID: budgetID, key: key,
                                       lamport: 5, text: "Hilltop")
            #expect(try await push([his], to: groupID, as: robin, on: app).accepted.count == 1)
            struct Payload: Codable { let merchant: String }
            let hers = try RecordCodec.seal(
                Payload(merchant: "Changed"), recordID: his.recordID, recordType: .transaction,
                groupID: GroupID(groupID), budgetID: BudgetID(budgetID), scopeKey: key, lamport: 5,
                author: UserID(mallory.userID), device: borrowed, membershipSequence: 0)
            let reply = try await push([hers], to: groupID, as: mallory, on: app)

            try await app.testing().test(.GET, "api/v1/groups/\(groupID)/pull?since=0",
                                         headers: robin.bearer) { response async throws in
                let stored = try response.content.decode(PullReply.self).envelopes
                    .first { $0.recordID == his.recordID }
                if reply.accepted.contains(his.recordID.uuid) {
                    #expect(stored?.authorUserID == UserID(mallory.userID), "taken means stored")
                } else {
                    #expect(reply.rejected[his.recordID.uuid.uuidString] == RecordEnvelope.olderVersionRefusal)
                    #expect(stored?.authorUserID == UserID(robin.userID))
                }
            }
        }
    }

    /// A manager could put keys she made on someone's ID, before they joined
    /// or before their first sync, and the log keeps a person's keys once
    /// they sign with them. An add or a level change now carries the keys
    /// the person signed up with, or none.
    @Test func anAddCarriesThePersonsOwnKeys() async throws {
        try await withConfiguredApp { app in
            var robin = Account(email: "trust-signup-founder@example.com")
            var jamie = Account(email: "trust-signup-joiner@example.com")
            try await register(&robin, on: app)
            try await register(&jamie, on: app)
            let groupID = UUID()
            let log = try await foundGroup(robin, groupID: groupID, on: app)
            let made = IdentityKeyPair.generate()

            for action in [MembershipAction.add, .changeLevel] {
                let squat = try entry(action, subject: jamie, keys: made.publicKeys, level: .read,
                                      by: robin, after: log, in: groupID)
                let answer = try await post(squat, to: groupID, as: robin, on: app)
                #expect(answer.status == .badRequest)
                #expect(answer.reason.contains("not that person's keys"), "got \(answer.reason)")
            }
            let real = try entry(.add, subject: jamie, keys: jamie.publicKeys, level: .read,
                                 by: robin, after: log, in: groupID)
            #expect(try await post(real, to: groupID, as: robin, on: app).status == .created)
        }
    }

    /// The server cannot open a key, so a group key a manager sealed to
    /// herself in the same request counted as proof she held that epoch. On
    /// the log route she could attach one for an epoch she never held, and a
    /// junk budget key with it. Only the entry that starts an epoch can
    /// bring its own group key.
    @Test func aGroupKeySealedToOneselfProvesNothingUnlessTheEntryStartsTheEpoch() async throws {
        try await withConfiguredApp { app in
            var robin = Account(email: "trust-self-founder@example.com")
            var mallory = Account(email: "trust-self-manager@example.com")
            var jamie = Account(email: "trust-self-joiner@example.com")
            try await register(&robin, on: app)
            try await register(&mallory, on: app)
            try await register(&jamie, on: app)
            let groupID = UUID()
            var log = try await foundGroup(robin, groupID: groupID, on: app)

            // Mallory joins "from now on": a new epoch, its key sealed to both.
            let next = ScopedKey.generate(scope: .group(GroupID(groupID)), epoch: Epoch(1))
            let adding = try entry(.add, subject: mallory, keys: mallory.publicKeys, level: .manage,
                                   epochAfter: Epoch(1), by: robin, after: log, in: groupID)
            let sealed = try [robin, mallory].map {
                try KeyWrap.wrapToIdentity(next, recipient: $0.publicKeys, recipientUserID: UserID($0.userID),
                                           sender: robin.identity, senderUserID: UserID(robin.userID))
            }
            #expect(try await post(adding, keys: sealed, to: groupID, as: robin, on: app).status == .created)
            log.append(adding)

            let junk = ScopedKey.generate(scope: .group(GroupID(groupID)), epoch: .initial)
            let keys = [
                try KeyWrap.wrapToIdentity(junk, recipient: mallory.publicKeys,
                                           recipientUserID: UserID(mallory.userID),
                                           sender: mallory.identity, senderUserID: UserID(mallory.userID)),
                try KeyWrap.wrapUnderGroupKey(ScopedKey.generate(scope: .budget(BudgetID()), epoch: .initial),
                                              groupKey: junk.material, senderUserID: UserID(mallory.userID)),
            ]
            let addsJamie = try entry(.add, subject: jamie, keys: jamie.publicKeys, level: .read,
                                      epochAfter: Epoch(1), by: mallory, after: log, in: groupID)
            #expect(try await post(addsJamie, keys: keys, to: groupID, as: mallory, on: app).status
                        == .badRequest)
            #expect(try await post(addsJamie, to: groupID, as: mallory, on: app).status == .created,
                    "the entry on its own goes in")
        }
    }

    // MARK: Who starts an epoch, keyless adds and stored authors

    /// Registering a device needs only View, and its entry could name any
    /// epoch. Mallory's named the next one, and the server took it for the
    /// entry that started that epoch. Robin's "from now on" invite was then
    /// refused, because a budget key comes only from someone who holds the
    /// epoch's group key, and so was every budget key he published for that
    /// epoch later. A device entry now names the current epoch, and only an
    /// entry that moves the epoch starts one.
    @Test func aDeviceEntryCannotStandInForTheStartOfAnEpoch() async throws {
        try await withConfiguredApp { app in
            var robin = Account(email: "trust-start-founder@example.com")
            var mallory = Account(email: "trust-start-viewer@example.com")
            var jamie = Account(email: "trust-start-joiner@example.com")
            try await register(&robin, on: app)
            try await register(&mallory, on: app)
            try await register(&jamie, on: app)
            let groupID = UUID()
            var log = try await foundGroup(robin, groupID: groupID, on: app)
            try await addMember(mallory, to: groupID, level: .read, log: &log, owner: robin, on: app)

            let laptop = DeviceKeyPair()
            let ahead = try entry(.addDevice, subject: mallory, device: laptop.id,
                                  devicePublicKey: laptop.publicKey, epochAfter: Epoch(1),
                                  by: mallory, after: log, in: groupID)
            #expect(try await post(ahead, to: groupID, as: mallory, on: app).status == .badRequest)

            let next = ScopedKey.generate(scope: .group(GroupID(groupID)), epoch: Epoch(1))
            func budgetKey() throws -> WrappedKey {
                try KeyWrap.wrapUnderGroupKey(ScopedKey.generate(scope: .budget(BudgetID()), epoch: Epoch(1)),
                                              groupKey: next.material, senderUserID: UserID(robin.userID))
            }
            let adding = try entry(.add, subject: jamie, keys: jamie.publicKeys, level: .read,
                                   epochAfter: Epoch(1), by: robin, after: log, in: groupID)
            let sealed = try [robin, mallory, jamie].map {
                try KeyWrap.wrapToIdentity(next, recipient: $0.publicKeys, recipientUserID: UserID($0.userID),
                                           sender: robin.identity, senderUserID: UserID(robin.userID))
            }
            let answer = try await post(adding, keys: sealed + [try budgetKey()], to: groupID, as: robin, on: app)
            #expect(answer.status == .created, "got \(answer.reason)")
            #expect(try await upload([try budgetKey()], to: groupID, as: robin, on: app) == .created,
                    "he started the epoch, so a budget added later gets its key too")
        }
    }

    /// Both servers compare the keys an add carries with the person's
    /// sign-up keys, and an add with none got round that. Mallory added
    /// Jamie with no keys and a junk group key for him, then removed him.
    /// When Robin later added him with "Everything so far", the server kept
    /// her key in Jamie's slot and dropped Robin's, so Jamie read nothing.
    /// An add that leaves someone a member with no keys is refused now.
    @Test func anAddWithNoKeysIsRefused() async throws {
        try await withConfiguredApp { app in
            var robin = Account(email: "trust-keyless-founder@example.com")
            var mallory = Account(email: "trust-keyless-manager@example.com")
            var jamie = Account(email: "trust-keyless-joiner@example.com")
            try await register(&robin, on: app)
            try await register(&mallory, on: app)
            try await register(&jamie, on: app)
            let groupID = UUID()
            let groupKey = ScopedKey.generate(scope: .group(GroupID(groupID)))
            var log = try await foundGroup(robin, groupID: groupID, on: app)
            try await addMember(mallory, to: groupID, level: .manage, log: &log, owner: robin,
                                sealing: groupKey, on: app)

            let madeUp = IdentityKeyPair.generate()
            let junk = try KeyWrap.wrapToIdentity(
                ScopedKey.generate(scope: .group(GroupID(groupID))), recipient: madeUp.publicKeys,
                recipientUserID: UserID(jamie.userID), sender: mallory.identity,
                senderUserID: UserID(mallory.userID))
            let keyless = try entry(.add, subject: jamie, level: .read, by: mallory, after: log, in: groupID)
            let answer = try await post(keyless, keys: [junk], to: groupID, as: mallory, on: app)
            #expect(answer.status == .badRequest)
            #expect(answer.reason.contains("memberWithoutKeys"), "got \(answer.reason)")
            if answer.status == .created {
                log.append(keyless)
                let out = try entry(.remove, subject: jamie, level: .none, by: mallory, after: log, in: groupID)
                _ = try await post(out, to: groupID, as: mallory, on: app)
                log.append(out)
            }

            let adding = try entry(.add, subject: jamie, keys: jamie.publicKeys, level: .read,
                                   by: robin, after: log, in: groupID)
            let real = try KeyWrap.wrapToIdentity(groupKey, recipient: jamie.publicKeys,
                                                  recipientUserID: UserID(jamie.userID),
                                                  sender: robin.identity, senderUserID: UserID(robin.userID))
            #expect(try await post(adding, keys: [real], to: groupID, as: robin, on: app).status == .created)

            let held = try #require(try await keys(in: groupID, as: jamie, on: app).first {
                $0.scope == .group(GroupID(groupID)) && $0.epoch == .initial
            })
            #expect(held.senderUserID == UserID(robin.userID), "Robin's key is the one in his slot")
            let opened = try? KeyWrap.unwrapToIdentity(held, recipient: jamie.identity, sender: robin.publicKeys)
            #expect(opened?.rawBytes == groupKey.rawBytes)
        }
    }

    /// The author column was not updated when a second person's version
    /// replaced a record, before the resend check and the tie rule read it.
    /// On such a row the version's own author sending it again after a lost
    /// reply was refused as older, and the app dropped the row as a
    /// conflict. Who wrote the stored version is read from its envelope.
    @Test func aStaleAuthorColumnDoesNotDecideAResend() async throws {
        try await withConfiguredApp { app in
            var robin = Account(email: "trust-stale-founder@example.com")
            try await register(&robin, on: app)
            let groupID = UUID()
            _ = try await foundGroup(robin, groupID: groupID, on: app)
            let budgetID = UUID()
            let key = ScopedKey.generate(scope: .budget(BudgetID(budgetID)))
            let his = try makeEnvelope(robin, groupID: groupID, budgetID: budgetID, key: key,
                                       lamport: 5, text: "Hilltop")
            #expect(try await push([his], to: groupID, as: robin, on: app).accepted.count == 1)

            let row = try #require(try await RecordRow.find(his.recordID.uuid, on: app.db))
            row.authorUserID = UUID(uuidString: "FFFFFFFF-FFFF-FFFF-FFFF-FFFFFFFFFFFF")!
            try await row.save(on: app.db)

            let reply = try await push([his], to: groupID, as: robin, on: app)
            #expect(reply.accepted == [his.recordID.uuid], "got \(reply.rejected)")
        }
    }

    /// Mallory knew Jamie's sign-up keys, so she added him with them and a
    /// junk group key sealed to him, then removed him without moving the
    /// epoch. The server keeps the first key for each slot, so when Robin
    /// later added him with everything so far, Jamie was handed the junk key
    /// and read nothing. The entry that leaves someone out of the group now
    /// takes the group keys stored for them, in the same transaction.
    @Test func aRemovalTakesTheGroupKeysStoredForThePerson() async throws {
        try await withConfiguredApp { app in
            var robin = Account(email: "trust-cleared-founder@example.com")
            var mallory = Account(email: "trust-cleared-manager@example.com")
            var jamie = Account(email: "trust-cleared-joiner@example.com")
            try await register(&robin, on: app)
            try await register(&mallory, on: app)
            try await register(&jamie, on: app)
            let groupID = UUID()
            let groupKey = ScopedKey.generate(scope: .group(GroupID(groupID)))
            var log = try await foundGroup(robin, groupID: groupID, on: app)
            try await addMember(mallory, to: groupID, level: .manage, log: &log, owner: robin,
                                sealing: groupKey, on: app)

            let junk = try KeyWrap.wrapToIdentity(
                ScopedKey.generate(scope: .group(GroupID(groupID))), recipient: jamie.publicKeys,
                recipientUserID: UserID(jamie.userID), sender: mallory.identity,
                senderUserID: UserID(mallory.userID))
            let adding = try entry(.add, subject: jamie, keys: jamie.publicKeys, level: .read,
                                   by: mallory, after: log, in: groupID)
            #expect(try await post(adding, keys: [junk], to: groupID, as: mallory, on: app).status == .created)
            log.append(adding)
            let out = try entry(.remove, subject: jamie, level: .none, by: mallory, after: log, in: groupID)
            #expect(try await post(out, to: groupID, as: mallory, on: app).status == .created)
            log.append(out)
            let left = try await WrappedKeyRow.query(on: app.db)
                .filter(\.$groupID == groupID).filter(\.$recipientUserID == jamie.userID).count()
            #expect(left == 0, "his slot is empty again")

            let back = try entry(.add, subject: jamie, keys: jamie.publicKeys, level: .read,
                                 by: robin, after: log, in: groupID)
            let real = try KeyWrap.wrapToIdentity(groupKey, recipient: jamie.publicKeys,
                                                  recipientUserID: UserID(jamie.userID),
                                                  sender: robin.identity, senderUserID: UserID(robin.userID))
            #expect(try await post(back, keys: [real], to: groupID, as: robin, on: app).status == .created)

            let held = try #require(try await keys(in: groupID, as: jamie, on: app).first {
                $0.scope == .group(GroupID(groupID)) && $0.epoch == .initial
            })
            let opened = try? KeyWrap.unwrapToIdentity(held, recipient: jamie.identity, sender: robin.publicKeys)
            #expect(opened?.rawBytes == groupKey.rawBytes, "he reads everything so far")
        }
    }

    /// A group key sealed to a member was taken with any entry from a
    /// manager. Mallory attached a junk key for an epoch Leslie never held,
    /// since she joined "from now on", to an entry registering her own
    /// laptop, and filled Leslie's empty slot. A group key now goes only to
    /// the person an entry adds, or for the epoch the entry starts.
    @Test func olderGroupKeysTravelOnlyWithTheirOwnEntry() async throws {
        try await withConfiguredApp { app in
            var robin = Account(email: "trust-older-founder@example.com")
            var mallory = Account(email: "trust-older-manager@example.com")
            var leslie = Account(email: "trust-older-joiner@example.com")
            try await register(&robin, on: app)
            try await register(&mallory, on: app)
            try await register(&leslie, on: app)
            let groupID = UUID()
            let first = ScopedKey.generate(scope: .group(GroupID(groupID)))
            var log = try await foundGroup(robin, groupID: groupID, on: app)
            try await addMember(mallory, to: groupID, level: .manage, log: &log, owner: robin,
                                sealing: first, on: app)

            // Leslie joins "from now on": a new epoch, its key sealed to all three.
            let next = ScopedKey.generate(scope: .group(GroupID(groupID)), epoch: Epoch(1))
            let adding = try entry(.add, subject: leslie, keys: leslie.publicKeys, level: .read,
                                   epochAfter: Epoch(1), by: robin, after: log, in: groupID)
            let sealed = try [robin, mallory, leslie].map {
                try KeyWrap.wrapToIdentity(next, recipient: $0.publicKeys, recipientUserID: UserID($0.userID),
                                           sender: robin.identity, senderUserID: UserID(robin.userID))
            }
            #expect(try await post(adding, keys: sealed, to: groupID, as: robin, on: app).status == .created)
            log.append(adding)

            let junk = try KeyWrap.wrapToIdentity(
                ScopedKey.generate(scope: .group(GroupID(groupID))), recipient: leslie.publicKeys,
                recipientUserID: UserID(leslie.userID), sender: mallory.identity,
                senderUserID: UserID(mallory.userID))
            let laptop = DeviceKeyPair()
            let hers = try entry(.addDevice, subject: mallory, device: laptop.id,
                                 devicePublicKey: laptop.publicKey, epochAfter: Epoch(1),
                                 by: mallory, after: log, in: groupID)
            let answer = try await post(hers, keys: [junk], to: groupID, as: mallory, on: app)
            #expect(answer.status == .badRequest)
            #expect(answer.reason.contains("the person an entry adds"), "got \(answer.reason)")
            #expect(try await post(hers, to: groupID, as: mallory, on: app).status == .created,
                    "the entry on its own goes in")
        }
    }
}
