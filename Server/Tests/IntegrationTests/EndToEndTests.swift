import Testing
import Foundation
// URLSession lives in FoundationNetworking on Linux. The client's own transport
// already does this; this file did not, and nothing noticed because the server
// product does not link WellSpentSync, so no Linux build ever compiled it.
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Vapor
import Crypto
@testable import WellSpentServerCore
import WellSpentCrypto
import WellSpentModel
import WellSpentStore
import WellSpentSync

/// The real client against the real server, over real HTTP.
///
/// Everything else in this repo tests one side in isolation. `InMemoryTransport`
/// enforces the same rules the Vapor server does, but the two had never spoken,
/// and a protocol with two independent implementations and no test between them
/// is a protocol with an undiscovered disagreement in it.
///
/// These are serialized because each one boots an HTTP server on a port.
@Suite("End to end, client to server over HTTP", .serialized)
struct EndToEndTests {

    /// Boots the server on a real port and hands back its base URL.
    private func withServer(_ body: (URL) async throws -> Void) async throws {
        let app = try await Application.make(.testing)
        do {
            try await configure(app)
            app.http.server.configuration.hostname = "127.0.0.1"
            app.http.server.configuration.port = 0        // let the OS choose

            // Not app.startup(): that runs Vapor's command loop, which parses the
            // process arguments and chokes on the test runner's own flags with
            // "Unknown command --test-bundle-path". Starting the HTTP server
            // directly is what is actually wanted here.
            try await app.server.start()

            guard let port = app.http.server.shared.localAddress?.port else {
                Issue.record("server did not report a bound port")
                await app.server.shutdown()
                try await app.asyncShutdown()
                return
            }
            let baseURL = URL(string: "http://127.0.0.1:\(port)")!

            try await body(baseURL)
            await app.server.shutdown()
        } catch {
            await app.server.shutdown()
            try? await app.asyncShutdown()
            throw error
        }
        try await app.asyncShutdown()
    }

    /// One person: their own database, keys, key ring, engine and HTTP client.
    private final class Peer {
        let identity = IdentityKeyPair.generate()
        let device = DeviceKeyPair()
        let store: Store
        let transport: HTTPTransport
        var userID: UserID!
        var keyRing: KeyRing!
        var engine: SyncEngine!

        init(baseURL: URL) throws {
            store = Store(database: try WellSpentDatabase.inMemory())
            // A session per peer, so tokens never leak between them.
            transport = HTTPTransport(baseURL: baseURL,
                                      session: URLSession(configuration: .ephemeral))
        }

        var publicKeys: IdentityPublicKeys { identity.publicKeys }

        func register(email: String) async throws {
            let credentials = try await transport.signUp(
                email: email, password: "a-long-enough-password", identity: publicKeys)
            userID = credentials.userID
            keyRing = KeyRing(store: store, identity: identity, userID: userID)
            engine = SyncEngine(store: store, keyRing: keyRing, transport: transport,
                                identity: identity, device: device, userID: userID)
        }
    }

    /// Founds a group on the server and mints its first keys locally.
    private func foundGroup(_ owner: Peer, budgets: [BudgetID] = []) async throws
        -> (group: GroupID, log: [MembershipLogEntry]) {
        let group = GroupID()
        let founding = try MembershipLogEntry.signed(
            scope: .group(group), sequence: 0, previousHash: MembershipLogEntry.rootHash,
            action: .found, subjectUserID: owner.userID, subjectKeys: owner.publicKeys,
            level: .superadmin, epochAfter: .initial,
            deviceID: owner.device.id, devicePublicKey: owner.device.publicKey,
            author: owner.identity, authorUserID: owner.userID
        )
        try await owner.transport.appendMembership(founding, group: group)

        let groupKey = ScopedKey.generate(scope: .group(group), epoch: .initial)
        try owner.keyRing.remember(groupKey)
        for budget in budgets {
            try owner.keyRing.remember(ScopedKey.generate(scope: .budget(budget), epoch: .initial))
        }
        return (group, [founding])
    }

    /// Adds somebody, and wraps the current keys for them in the same request.
    private func share(_ group: GroupID, log: inout [MembershipLogEntry],
                       from owner: Peer, to guest: Peer,
                       level: AccessLevel, budgets: [BudgetID]) async throws {
        let entry = try MembershipLogEntry.signed(
            scope: .group(group), sequence: UInt64(log.count), previousHash: log.last!.hash,
            action: .add, subjectUserID: guest.userID, subjectKeys: guest.publicKeys,
            level: level, epochAfter: .initial,
            author: owner.identity, authorUserID: owner.userID
        )
        log.append(entry)

        let groupKey = try owner.keyRing.key(for: .group(group), epoch: .initial)
        var wrapped = [try KeyWrap.wrapToIdentity(groupKey, recipient: guest.publicKeys,
                                                  recipientUserID: guest.userID,
                                                  sender: owner.identity, senderUserID: owner.userID)]
        for budget in budgets {
            let budgetKey = try owner.keyRing.key(for: .budget(budget), epoch: .initial)
            wrapped.append(try KeyWrap.wrapUnderGroupKey(budgetKey, groupKey: groupKey.material,
                                                         senderUserID: owner.userID))
        }
        try await owner.transport.appendMembership(entry, group: group, wrappedKeys: wrapped)

        // Their device, registered by their own entry, as their app does.
        let device = try MembershipLogEntry.signed(
            scope: .group(group), sequence: UInt64(log.count), previousHash: log.last!.hash,
            action: .addDevice, subjectUserID: guest.userID, subjectKeys: nil,
            level: level, epochAfter: .initial,
            deviceID: guest.device.id, devicePublicKey: guest.device.publicKey,
            author: guest.identity, authorUserID: guest.userID
        )
        log.append(device)
        try await guest.transport.appendMembership(device, group: group)
    }

    /// What the app does on every sync, around the engine.
    private func appSync(_ peer: Peer, _ group: GroupID) async throws {
        let sharing = Sharing(store: peer.store, keyRing: peer.keyRing, transport: peer.transport,
                              identity: peer.identity, device: peer.device, userID: peer.userID)
        try await sharing.prepare(group: group)
        try await sharing.finishInvites(group: group)
        _ = try await peer.engine.sync(group: group)
        if try await sharing.completeJoin(group: group) {
            _ = try await peer.engine.sync(group: group)
        }
    }

    private func sharing(_ peer: Peer) -> Sharing {
        Sharing(store: peer.store, keyRing: peer.keyRing, transport: peer.transport,
                identity: peer.identity, device: peer.device, userID: peer.userID)
    }

    // MARK: - Tests

    /// The real server stores a record type it has never heard of and hands it
    /// back intact, and a client that cannot read it keeps syncing.
    @Test("an unknown record type passes through the server")
    func unknownRecordTypeOverTheWire() async throws {
        try await withServer { baseURL in
            let robin = try Peer(baseURL: baseURL)
            try await robin.register(email: "future@example.com")
            let (group, _) = try await foundGroup(robin)
            try robin.store.save(BudgetGroup(id: group, name: "Household"))
            _ = try await robin.engine.sync(group: group)

            let future = RecordType(rawValue: "somethingFromTheFuture")
            let envelope = try RecordCodec.sealData(
                Data("{}".utf8), recordID: RecordID(), recordType: future, groupID: group,
                budgetID: nil, scopeKey: try robin.keyRing.key(for: .group(group), epoch: .initial),
                lamport: 99, author: robin.userID, device: robin.device, membershipSequence: 0)
            let result = try await robin.transport.push([envelope], group: group)
            #expect(result.accepted == [envelope.recordID], "refused: \(result.rejected)")

            let page = try await robin.transport.pull(group: group, since: 0, limit: 100)
            let back = try #require(page.envelopes.first { $0.recordID == envelope.recordID })
            #expect(back.recordType == future)
            #expect(back.verifySignature(byDeviceKey: robin.device.signing.publicKey),
                    "the type is signed, so it must come back exactly")
        }
    }

    /// The whole invite flow, with nothing hand-built: a link, an answer sealed
    /// with its secret, and the inviter's app adding the person on its next sync.
    @Test("an invite link adds someone, and they trade transactions both ways")
    func inviteLinkOverTheWire() async throws {
        try await withServer { baseURL in
            let robin = try Peer(baseURL: baseURL)
            try await robin.register(email: "robin-link@example.com")
            let budgetID = BudgetID()
            let (group, _) = try await foundGroup(robin, budgets: [budgetID])
            try robin.store.save(BudgetGroup(id: group, name: "Household"))
            try robin.store.save(Budget(id: budgetID, groupID: group, name: "Groceries",
                                        limit: Money(minorUnits: 100_000)))
            try robin.store.save(Transaction(budgetID: budgetID, groupID: group, date: Date(),
                                             merchant: "Hilltop", amount: Money(minorUnits: -14208)))
            try await appSync(robin, group)

            // Manage, because she makes a budget below, and that takes Manage.
            let link = try await sharing(robin).createInvite(
                group: group, groupName: "Household", level: .manage, historyAccess: .all,
                inviterName: "Robin")

            let leslie = try Peer(baseURL: baseURL)
            try await leslie.register(email: "leslie-link@example.com")
            try await sharing(leslie).join(InviteLink(parsing: link.url)!, displayName: "Leslie")

            try await appSync(robin, group)
            try await appSync(leslie, group)
            #expect(try leslie.store.pendingJoins().isEmpty)
            #expect(try leslie.store.transactions(in: budgetID).map(\.merchant) == ["Hilltop"])

            // Hers, in a budget she makes after joining.
            let gas = Budget(groupID: group, name: "Gas", limit: Money(minorUnits: 20_000))
            try leslie.store.save(gas)
            let fillUp = Transaction(budgetID: gas.id, groupID: group, date: Date(),
                                     merchant: "Milepost", amount: Money(minorUnits: -4500))
            try leslie.store.save(fillUp)
            try await appSync(leslie, group)

            try await appSync(robin, group)
            let received = try #require(try robin.store.transaction(fillUp.id))
            #expect(received.merchant == "Milepost")
            #expect(received.createdBy == leslie.userID)
            #expect(try robin.store.profiles(in: group).map(\.displayName) == ["Leslie"])

            // The invite is gone from the server once used.
            let open = try await robin.transport.invites(in: group)
            #expect(open.isEmpty)
        }
    }

    @Test("a budget created on one machine arrives on another")
    func sharingOverTheWire() async throws {
        try await withServer { baseURL in
            let robin = try Peer(baseURL: baseURL)
            try await robin.register(email: "robin@example.com")

            let budgetID = BudgetID()
            var (group, log) = try await foundGroup(robin, budgets: [budgetID])

            try robin.store.save(BudgetGroup(id: group, name: "Household"))
            let budget = Budget(id: budgetID, groupID: group, name: "Groceries",
                                limit: Money(minorUnits: 100_000))
            try robin.store.save(budget)
            try robin.store.save(Transaction(budgetID: budgetID, groupID: group, date: Date(),
                                             merchant: "Hilltop", amount: Money(minorUnits: -14208)))

            let pushed = try await robin.engine.sync(group: group)
            #expect(pushed.pushed == 3, "group, budget and transaction")
            #expect(pushed.rejected == 0)

            let leslie = try Peer(baseURL: baseURL)
            try await leslie.register(email: "leslie@example.com")
            try await share(group, log: &log, from: robin, to: leslie,
                            level: .write, budgets: [budgetID])

            let pulled = try await leslie.engine.sync(group: group)
            #expect(pulled.applied == 3, "everything should decrypt on the far side")
            #expect(pulled.undecryptable == 0)

            let received = try leslie.store.transactions(in: budgetID)
            #expect(received.count == 1)
            #expect(received.first?.merchant == "Hilltop")
            #expect(received.first?.amount == Money(minorUnits: -14208))

            let theirBudget = try #require(try leslie.store.budget(budgetID))
            #expect(try leslie.store.summary(for: theirBudget).spent == Money(minorUnits: 14208))
        }
    }

    /// The claim the whole design rests on, checked against what is really stored.
    @Test("the server's own database holds no readable content")
    func serverStoresOnlyCiphertext() async throws {
        try await withServer { baseURL in
            let robin = try Peer(baseURL: baseURL)
            try await robin.register(email: "private@example.com")

            let budgetID = BudgetID()
            let (group, _) = try await foundGroup(robin, budgets: [budgetID])
            try robin.store.save(BudgetGroup(id: group, name: "Household"))
            try robin.store.save(Budget(id: budgetID, groupID: group, name: "Groceries",
                                        limit: Money(minorUnits: 100_000)))
            try robin.store.save(Transaction(budgetID: budgetID, groupID: group, date: Date(),
                                             merchant: "Hilltop Grocery", note: "weekly shop",
                                             amount: Money(minorUnits: -14208)))
            _ = try await robin.engine.sync(group: group)

            // Pull the rows straight back out over the wire and look at them.
            let page = try await robin.transport.pull(group: group, since: 0, limit: 100)
            #expect(!page.envelopes.isEmpty)

            for envelope in page.envelopes {
                let blob = envelope.ciphertext
                #expect(blob.range(of: Data("Hilltop".utf8)) == nil)
                #expect(blob.range(of: Data("Grocery".utf8)) == nil)
                #expect(blob.range(of: Data("weekly shop".utf8)) == nil)
                #expect(blob.range(of: Data("14208".utf8)) == nil)
                #expect(blob.range(of: Data("Household".utf8)) == nil)
            }
        }
    }

    @Test("a reader's writes are refused by the real server")
    func readerCannotWrite() async throws {
        try await withServer { baseURL in
            let robin = try Peer(baseURL: baseURL)
            try await robin.register(email: "owner@example.com")

            let budgetID = BudgetID()
            var (group, log) = try await foundGroup(robin, budgets: [budgetID])
            try robin.store.save(BudgetGroup(id: group, name: "Household"))
            try robin.store.save(Budget(id: budgetID, groupID: group, name: "Groceries",
                                        limit: Money(minorUnits: 100_000)))
            _ = try await robin.engine.sync(group: group)

            let jamie = try Peer(baseURL: baseURL)
            try await jamie.register(email: "reader@example.com")
            try await share(group, log: &log, from: robin, to: jamie,
                            level: .read, budgets: [budgetID])

            let read = try await jamie.engine.sync(group: group)
            #expect(read.applied == 2, "a reader can read")

            // He holds the key, so he can produce ciphertext that decrypts
            // perfectly. The server is what stops it being accepted.
            let key = try jamie.keyRing.key(for: .budget(budgetID), epoch: .initial)
            let forged = try RecordCodec.seal(
                Transaction(budgetID: budgetID, groupID: group, date: Date(),
                            merchant: "forged", amount: Money(minorUnits: -100_000)),
                recordID: RecordID(), recordType: .transaction, groupID: group,
                budgetID: budgetID, scopeKey: key, lamport: 99,
                author: jamie.userID, device: jamie.device, membershipSequence: 1)

            await #expect(throws: (any Error).self) {
                _ = try await jamie.transport.push([forged], group: group)
            }
        }
    }

    /// The date inside a signed membership entry crosses the wire. If the two
    /// sides disagree about how a Date encodes, every signature fails to verify
    /// and nothing says why. This is the test that would have caught it.
    @Test("signed membership entries survive the round trip")
    func membershipSignaturesVerifyAfterTheWire() async throws {
        try await withServer { baseURL in
            let robin = try Peer(baseURL: baseURL)
            try await robin.register(email: "signed@example.com")

            var (group, log) = try await foundGroup(robin)
            let leslie = try Peer(baseURL: baseURL)
            try await leslie.register(email: "second@example.com")
            try await share(group, log: &log, from: robin, to: leslie,
                            level: .write, budgets: [])

            let fetched = try await leslie.transport.membershipLog(group: group, since: 0)
            #expect(fetched.count == 3)

            // Replay verifies the hash chain and every signature. If the dates
            // shifted in transit, this throws.
            let state = try MembershipLog.replay(fetched, scope: .group(group))
            #expect(state.level(of: robin.userID) == .superadmin)
            #expect(state.level(of: leslie.userID) == .write)
            #expect(state.devices.count == 2)
        }
    }

    @Test("a stranger cannot read a group they are not in")
    func strangerIsRefused() async throws {
        try await withServer { baseURL in
            let robin = try Peer(baseURL: baseURL)
            try await robin.register(email: "member@example.com")
            let (group, _) = try await foundGroup(robin)

            let stranger = try Peer(baseURL: baseURL)
            try await stranger.register(email: "stranger@example.com")

            await #expect(throws: (any Error).self) {
                _ = try await stranger.transport.pull(group: group, since: 0, limit: 10)
            }
        }
    }

    /// The app founds a group lazily, on its first sync, and decides to found it
    /// from the answer to reading its log. The server answers 403 for a group it
    /// has never seen, the same as for a group you are not in, so a guessed UUID
    /// learns nothing. The app was written against an older server that answered
    /// with an empty log, and on the live server no group could ever be founded.
    /// This pins down the answer the app now relies on.
    @Test("a group the server has never seen reads as forbidden, and its owner can still found it")
    func anUnseenGroupCanBeFounded() async throws {
        try await withServer { baseURL in
            let robin = try Peer(baseURL: baseURL)
            try await robin.register(email: "lazy-founder@example.com")
            let group = GroupID()

            do {
                _ = try await robin.transport.membershipLog(group: group, since: 0)
                Issue.record("an unseen group's log was readable")
            } catch HTTPTransport.Failure.http(let status, _) {
                #expect(status == 403)
            }

            let founding = try MembershipLogEntry.signed(
                scope: .group(group), sequence: 0, previousHash: MembershipLogEntry.rootHash,
                action: .found, subjectUserID: robin.userID, subjectKeys: robin.publicKeys,
                level: .superadmin, epochAfter: .initial,
                deviceID: robin.device.id, devicePublicKey: robin.device.publicKey,
                author: robin.identity, authorUserID: robin.userID
            )
            try await robin.transport.appendMembership(founding, group: group)

            let log = try await robin.transport.membershipLog(group: group, since: 0)
            #expect(log.count == 1)
        }
    }

    /// The other half of the same 403. If the group exists and is someone
    /// else's, the app's attempt to found it must be refused, so treating 403 as
    /// "not founded yet" cannot take over a group.
    @Test("a group someone else founded cannot be founded again")
    func anotherPersonsGroupCannotBeFounded() async throws {
        try await withServer { baseURL in
            let robin = try Peer(baseURL: baseURL)
            try await robin.register(email: "takeover-victim@example.com")
            let (group, _) = try await foundGroup(robin)

            let stranger = try Peer(baseURL: baseURL)
            try await stranger.register(email: "takeover-attempt@example.com")
            let takeover = try MembershipLogEntry.signed(
                scope: .group(group), sequence: 0, previousHash: MembershipLogEntry.rootHash,
                action: .found, subjectUserID: stranger.userID, subjectKeys: stranger.publicKeys,
                level: .superadmin, epochAfter: .initial,
                deviceID: stranger.device.id, devicePublicKey: stranger.device.publicKey,
                author: stranger.identity, authorUserID: stranger.userID
            )

            await #expect(throws: (any Error).self) {
                try await stranger.transport.appendMembership(takeover, group: group)
            }
            let log = try await robin.transport.membershipLog(group: group, since: 0)
            #expect(log.count == 1)
            #expect(log.first?.authorUserID == robin.userID)
        }
    }

    @Test("syncing twice changes nothing")
    func syncIsIdempotent() async throws {
        try await withServer { baseURL in
            let robin = try Peer(baseURL: baseURL)
            try await robin.register(email: "idempotent@example.com")

            let budgetID = BudgetID()
            let (group, _) = try await foundGroup(robin, budgets: [budgetID])
            try robin.store.save(BudgetGroup(id: group, name: "Household"))
            try robin.store.save(Budget(id: budgetID, groupID: group, name: "Groceries",
                                        limit: Money(minorUnits: 100_000)))
            try robin.store.save(Transaction(budgetID: budgetID, groupID: group, date: Date(),
                                             merchant: "once", amount: Money(minorUnits: -100)))

            _ = try await robin.engine.sync(group: group)
            let after = try robin.store.transactions(in: budgetID).count

            let second = try await robin.engine.sync(group: group)
            #expect(second.pushed == 0)
            #expect(try robin.store.transactions(in: budgetID).count == after)
        }
    }

    // MARK: - Deleting a group

    /// The blocker from the review of the first group delete, over the wire.
    /// She deletes a group while still waiting to join. A build that queued
    /// that delete sent it once his app added her, and it landed on his real
    /// group. The server now refuses it, because only the founder or an admin
    /// deletes a group for everyone.
    @Test("a delete queued while waiting to join cannot delete the inviter's group")
    func aWaitingDeleteCannotDeleteTheRealGroup() async throws {
        try await withServer { baseURL in
            let robin = try Peer(baseURL: baseURL)
            try await robin.register(email: "waiting-inviter@example.com")
            let (group, _) = try await foundGroup(robin)
            try robin.store.save(BudgetGroup(id: group, name: "Household"))
            try await appSync(robin, group)
            let link = try await sharing(robin).createInvite(
                group: group, groupName: "Household", level: .write, historyAccess: .all,
                inviterName: "Robin")

            let leslie = try Peer(baseURL: baseURL)
            try await leslie.register(email: "waiting-joiner@example.com")
            try await sharing(leslie).join(InviteLink(parsing: link.url)!, displayName: "Leslie")

            // On the placeholder, both queued: renamed, so her delete outranks
            // his record whatever the device IDs, then deleted.
            var placeholder = try #require(try leslie.store.group(group))
            placeholder.name = "Ours"
            try leslie.store.save(placeholder)
            placeholder.isDeleted = true
            try leslie.store.save(placeholder)

            // Not added yet, so the real server will not even show her the log.
            do {
                _ = try await leslie.transport.membershipLog(group: group, since: 0)
                Issue.record("someone not yet added read the log")
            } catch HTTPTransport.Failure.http(let status, _) {
                #expect(status == 403)
            }

            // His app adds her. Hers registers its device, pulls, and sends the
            // delete it queued while waiting.
            try await appSync(robin, group)
            try await appSync(leslie, group)
            try await appSync(leslie, group)

            _ = try await robin.engine.sync(group: group)
            #expect(try robin.store.group(group)?.isDeleted == false, "his group is still there")
            let page = try await robin.transport.pull(group: group, since: 0, limit: 100)
            #expect(page.envelopes.first { $0.recordType == .groupMeta }?.isDeleted == false)
        }
    }

    /// Deleting a group is final. His delete is older than her renames and
    /// still wins, here and on her Mac, and the rename she queued before it
    /// reached her cannot bring the group back.
    @Test("a group's delete is final, whatever the versions")
    func aGroupDeleteIsFinalOverTheWire() async throws {
        try await withServer { baseURL in
            let robin = try Peer(baseURL: baseURL)
            try await robin.register(email: "wire-final-founder@example.com")
            var (group, log) = try await foundGroup(robin)
            try robin.store.save(BudgetGroup(id: group, name: "Household"))
            _ = try await robin.engine.sync(group: group)

            let leslie = try Peer(baseURL: baseURL)
            try await leslie.register(email: "wire-final-writer@example.com")
            try await share(group, log: &log, from: robin, to: leslie, level: .write, budgets: [])
            _ = try await leslie.engine.sync(group: group)

            for name in ["a", "b", "c", "d", "e"] {
                var renamed = try #require(try leslie.store.group(group))
                renamed.name = name
                try leslie.store.save(renamed)
            }
            _ = try await leslie.engine.sync(group: group)
            var unsent = try #require(try leslie.store.group(group))
            unsent.name = "Home"
            try leslie.store.save(unsent)

            var gone = try #require(try robin.store.group(group))
            gone.isDeleted = true
            try robin.store.save(gone)
            let sent = try await robin.engine.sync(group: group)
            #expect(sent.pushed == 1, "his delete is taken, got \(sent)")
            #expect(try robin.store.group(group)?.isDeleted == true, "her renames do not undo it here")

            // Her rename is still queued when his delete reaches her. It loses
            // to the delete, so it is kept as a conflict copy and never sent.
            // The server's refusal of a late rename is pinned in its own tests.
            let hers = try await leslie.engine.sync(group: group)
            #expect(hers.conflicts == 1, "her late rename is kept, got \(hers)")
            #expect(hers.pushed == 0 && hers.rejected == 0, "and not sent")
            #expect(try leslie.store.outboxCount(in: group) == 0)
            #expect(try leslie.store.conflicts(for: RecordID(group.uuid))
                .contains { $0.payloadJSON.contains("Home") })
            #expect(try leslie.store.group(group)?.isDeleted == true, "his delete wins on her Mac")
            let page = try await robin.transport.pull(group: group, since: 0, limit: 100)
            #expect(page.envelopes.first { $0.recordType == .groupMeta }?.isDeleted == true)
        }
    }

    /// A delete sent again after its reply was lost is the version the server
    /// already holds, from the same device. The server takes it as already
    /// stored and changes nothing, so the app clears the row like any other
    /// it sent. It used to be refused as older, and the app dropped it only
    /// because nothing in a deleted group can become newer.
    @Test("a delete sent twice is taken, and stored once")
    func aResentDeleteIsTakenOnce() async throws {
        try await withServer { baseURL in
            let robin = try Peer(baseURL: baseURL)
            try await robin.register(email: "resent@example.com")
            let (group, _) = try await foundGroup(robin)
            var gone = BudgetGroup(id: group, name: "Household")
            try robin.store.save(gone)
            _ = try await robin.engine.sync(group: group)

            gone.isDeleted = true
            let key = try robin.keyRing.key(for: .group(group), epoch: .initial)
            let delete = try RecordCodec.seal(
                gone, recordID: RecordID(group.uuid), recordType: .groupMeta, groupID: group,
                budgetID: nil, scopeKey: key, lamport: 2, author: robin.userID,
                device: robin.device, membershipSequence: 0, isDeleted: true)
            let first = try await robin.transport.push([delete], group: group)
            #expect(first.accepted == [delete.recordID])

            let again = try await robin.transport.push([delete], group: group)
            #expect(again.accepted == [delete.recordID], "refused: \(again.rejected)")
            #expect(again.serverSeq == first.serverSeq, "nothing new was stored")
        }
    }

    /// The usual way a row got stuck. The server saves a push and the reply
    /// never arrives, so the app sends the same row on its next sync, sealed
    /// afresh at the same Lamport value. The server refused its own duplicate
    /// as older, and the row went out again on every sync. It is now taken as
    /// already stored, and leaves the queue with no conflict.
    @Test("a push whose reply was lost is taken when sent again")
    func aPushWhoseReplyWasLostIsTakenAgain() async throws {
        try await withServer { baseURL in
            let robin = try Peer(baseURL: baseURL)
            try await robin.register(email: "lost-reply@example.com")
            let budgetID = BudgetID()
            let (group, _) = try await foundGroup(robin, budgets: [budgetID])
            try robin.store.save(BudgetGroup(id: group, name: "Household"))
            try robin.store.save(Budget(id: budgetID, groupID: group, name: "Groceries",
                                        limit: Money(minorUnits: 100_000)))
            _ = try await robin.engine.sync(group: group)

            var renamed = try #require(try robin.store.budget(budgetID))
            renamed.name = "Food"
            try robin.store.save(renamed)
            let lossy = SyncEngine(store: robin.store, keyRing: robin.keyRing,
                                   transport: LostReply(robin.transport), identity: robin.identity,
                                   device: robin.device, userID: robin.userID)
            await #expect(throws: LostReply.Lost.self) { try await lossy.sync(group: group) }
            #expect(try robin.store.outboxCount(in: group) == 1, "it cannot tell the push was taken")

            let report = try await robin.engine.sync(group: group)
            #expect(report.pushed == 1, "got \(report)")
            #expect(report.rejected == 0)
            #expect(try robin.store.outboxCount(in: group) == 0)
            #expect(try robin.store.conflicts(for: RecordID(budgetID.uuid)).isEmpty,
                    "its own version is not a conflict")
        }
    }

    /// Household with Groceries and one of Robin's transactions, synced, and
    /// `guest` added at `level` with every key.
    private func household(_ robin: Peer, guest: Peer, level: AccessLevel) async throws
        -> (group: GroupID, groceries: BudgetID, his: Transaction) {
        let groceries = BudgetID()
        var (group, log) = try await foundGroup(robin, budgets: [groceries])
        try robin.store.save(BudgetGroup(id: group, name: "Household"))
        try robin.store.save(Budget(id: groceries, groupID: group, name: "Groceries",
                                    limit: Money(minorUnits: 100_000)))
        let his = Transaction(budgetID: groceries, groupID: group, date: Date(),
                              merchant: "Hilltop", amount: Money(minorUnits: -14208))
        try robin.store.save(his)
        _ = try await robin.engine.sync(group: group)
        try await share(group, log: &log, from: robin, to: guest, level: level, budgets: [groceries])
        _ = try await guest.engine.sync(group: group)
        return (group, groceries, try #require(try robin.store.transaction(his.id)))
    }

    /// Someone at Add sends his transaction under a fresh ID, with no owner
    /// and the delete flag set. The real server takes any fresh ID, so only
    /// his app can refuse it, by checking what is inside against the envelope.
    @Test("a transaction cannot be taken over under a fresh ID")
    func aFreshIDCannotTakeOverATransaction() async throws {
        try await withServer { baseURL in
            let robin = try Peer(baseURL: baseURL), leslie = try Peer(baseURL: baseURL)
            try await robin.register(email: "fresh-id-owner@example.com")
            try await leslie.register(email: "fresh-id-writer@example.com")
            let (group, groceries, his) = try await household(robin, guest: leslie, level: .write)

            var taken = his
            taken.createdBy = nil
            let forged = try RecordCodec.seal(
                taken, recordID: RecordID(), recordType: .transaction, groupID: group,
                budgetID: groceries,
                scopeKey: try leslie.keyRing.key(for: .budget(groceries), epoch: .initial),
                lamport: 99, author: leslie.userID, device: leslie.device, membershipSequence: 1,
                isDeleted: true)
            let sent = try await leslie.transport.push([forged], group: group)
            #expect(sent.accepted == [forged.recordID], "the server cannot see inside it")

            let report = try await robin.engine.sync(group: group)
            #expect(report.ignored == 1)
            let kept = try #require(try robin.store.transaction(his.id))
            #expect(!kept.isDeleted)
            #expect(kept.createdBy == robin.userID)
        }
    }

    /// Mallory can only view Household. She founds Book Club, Robin joins it,
    /// and through it she sends a budget under a fresh ID whose contents are
    /// Household's Groceries, deleted. The real server stores it in Book Club,
    /// and only Robin's app can see that it describes something else.
    @Test("a budget sent through another group cannot overwrite this one")
    func aBudgetThroughAnotherGroupCannotOverwrite() async throws {
        try await withServer { baseURL in
            let robin = try Peer(baseURL: baseURL), mallory = try Peer(baseURL: baseURL)
            try await robin.register(email: "through-owner@example.com")
            try await mallory.register(email: "through-viewer@example.com")
            let (group, groceries, _) = try await household(robin, guest: mallory, level: .read)

            var (club, clubLog) = try await foundGroup(mallory)
            try await share(club, log: &clubLog, from: mallory, to: robin, level: .read, budgets: [])
            let gone = Budget(id: groceries, groupID: group, name: "Groceries",
                              limit: Money(minorUnits: 100_000), isDeleted: true)
            let forged = try RecordCodec.seal(
                gone, recordID: RecordID(), recordType: .budget, groupID: club, budgetID: nil,
                scopeKey: try mallory.keyRing.key(for: .group(club), epoch: .initial),
                lamport: 99, author: mallory.userID, device: mallory.device, membershipSequence: 1,
                isDeleted: true)
            let sent = try await mallory.transport.push([forged], group: club)
            #expect(sent.accepted == [forged.recordID], "the server cannot see inside it")

            let report = try await robin.engine.sync(group: club)
            #expect(report.ignored == 1)
            let kept = try #require(try robin.store.budget(groceries))
            #expect(!kept.isDeleted)
            #expect(kept.groupID == group)
        }
    }

    /// Someone at Add deleted a budget for everyone. Her app no longer sends
    /// it, and the real server refuses it from a modified app.
    @Test("a budget delete from someone at Add goes nowhere")
    func anAddMembersBudgetDeleteGoesNowhere() async throws {
        try await withServer { baseURL in
            let robin = try Peer(baseURL: baseURL), leslie = try Peer(baseURL: baseURL)
            try await robin.register(email: "budget-delete-owner@example.com")
            try await leslie.register(email: "budget-delete-writer@example.com")
            let (group, groceries, _) = try await household(robin, guest: leslie, level: .write)

            var gone = try #require(try leslie.store.budget(groceries))
            gone.isDeleted = true
            try leslie.store.save(gone)
            let report = try await leslie.engine.sync(group: group)
            #expect(report.pushed == 0)
            #expect(report.rejected == 1)

            let forged = try RecordCodec.seal(
                gone, recordID: RecordID(groceries.uuid), recordType: .budget, groupID: group,
                budgetID: groceries,
                scopeKey: try leslie.keyRing.key(for: .budget(groceries), epoch: .initial),
                lamport: 99, author: leslie.userID, device: leslie.device, membershipSequence: 1,
                isDeleted: true)
            let refused = try await leslie.transport.push([forged], group: group)
            #expect(refused.rejected[forged.recordID] == "only a manager can change a budget")

            _ = try await robin.engine.sync(group: group)
            #expect(try robin.store.budget(groceries)?.isDeleted == false)
        }
    }

    @Test("sign in returns a usable token for an existing account")
    func signInWorks() async throws {
        try await withServer { baseURL in
            let peer = try Peer(baseURL: baseURL)
            try await peer.register(email: "returning@example.com")

            let fresh = HTTPTransport(baseURL: baseURL,
                                      session: URLSession(configuration: .ephemeral))
            let credentials = try await fresh.signIn(email: "returning@example.com",
                                                     password: "a-long-enough-password")
            #expect(credentials.userID == peer.userID)
            #expect(!credentials.token.isEmpty)
        }
    }

    @Test("a wrong password is refused")
    func wrongPasswordRefused() async throws {
        try await withServer { baseURL in
            let peer = try Peer(baseURL: baseURL)
            try await peer.register(email: "guarded@example.com")

            let fresh = HTTPTransport(baseURL: baseURL,
                                      session: URLSession(configuration: .ephemeral))
            await #expect(throws: (any Error).self) {
                _ = try await fresh.signIn(email: "guarded@example.com", password: "wrong")
            }
        }
    }

    /// A Mac uses one device ID in every group, and members can read it.
    /// Mallory, who can only view Household, read Leslie's there and
    /// registered it as her own in Side Business before Leslie joined. Leslie
    /// then could never send anything there. A registration now belongs to
    /// the person and the device together, so hers is still hers.
    @Test("a device ID taken first in another group stays its owner's")
    func aDeviceIDTakenFirstStaysItsOwners() async throws {
        try await withServer { baseURL in
            let robin = try Peer(baseURL: baseURL), leslie = try Peer(baseURL: baseURL)
            let mallory = try Peer(baseURL: baseURL)
            try await robin.register(email: "device-robin@example.com")
            try await leslie.register(email: "device-leslie@example.com")
            try await mallory.register(email: "device-mallory@example.com")
            var (household, householdLog) = try await foundGroup(robin)
            try await share(household, log: &householdLog, from: robin, to: leslie, level: .write, budgets: [])
            try await share(household, log: &householdLog, from: robin, to: mallory, level: .read, budgets: [])

            let tools = BudgetID()
            var (side, sideLog) = try await foundGroup(robin, budgets: [tools])
            try robin.store.save(BudgetGroup(id: side, name: "Side Business"))
            try robin.store.save(Budget(id: tools, groupID: side, name: "Tools",
                                        limit: Money(minorUnits: 50_000)))
            try await appSync(robin, side)
            try await share(side, log: &sideLog, from: robin, to: mallory, level: .read, budgets: [tools])

            let seen = try await mallory.transport.membershipLog(group: household, since: 0)
            let hers = try #require(seen.first {
                $0.action == .addDevice && $0.subjectUserID == leslie.userID
            }?.deviceID)
            let squat = try MembershipLogEntry.signed(
                scope: .group(side), sequence: UInt64(sideLog.count), previousHash: sideLog.last!.hash,
                action: .addDevice, subjectUserID: mallory.userID, subjectKeys: nil, level: .read,
                epochAfter: .initial, deviceID: hers, devicePublicKey: mallory.device.publicKey,
                author: mallory.identity, authorUserID: mallory.userID)
            try await mallory.transport.appendMembership(squat, group: side)

            let link = try await sharing(robin).createInvite(
                group: side, groupName: "Side Business", level: .write, historyAccess: .all,
                inviterName: "Robin")
            try await sharing(leslie).join(InviteLink(parsing: link.url)!, displayName: "Leslie")
            try await appSync(robin, side)
            try await appSync(leslie, side)

            let spent = Transaction(budgetID: tools, groupID: side, date: Date(),
                                    merchant: "Hardware", amount: Money(minorUnits: -4200))
            try leslie.store.save(spent)
            try await appSync(leslie, side)
            try await appSync(robin, side)
            #expect(try robin.store.transaction(spent.id)?.merchant == "Hardware")
        }
    }

    /// Over the wire, with the real client. Mallory can only
    /// view. She sent keys of her own with the entry that registers her
    /// laptop, the server kept them, and Robin's app took them in place of
    /// his. Nothing Leslie sealed opened for him after that, on any sync. The
    /// server refuses them, and Robin keeps reading what Leslie adds.
    @Test("a member who can only view cannot hand out keys")
    func aViewMembersKeysAreRefused() async throws {
        try await withServer { baseURL in
            let robin = try Peer(baseURL: baseURL), leslie = try Peer(baseURL: baseURL)
            let mallory = try Peer(baseURL: baseURL)
            try await robin.register(email: "keys-robin@example.com")
            try await leslie.register(email: "keys-leslie@example.com")
            try await mallory.register(email: "keys-mallory@example.com")
            let budgetID = BudgetID()
            var (group, log) = try await foundGroup(robin, budgets: [budgetID])
            try robin.store.save(BudgetGroup(id: group, name: "Household"))
            try robin.store.save(Budget(id: budgetID, groupID: group, name: "Groceries",
                                        limit: Money(minorUnits: 100_000)))
            try await appSync(robin, group)
            try await share(group, log: &log, from: robin, to: leslie, level: .write, budgets: [budgetID])
            try await share(group, log: &log, from: robin, to: mallory, level: .read, budgets: [budgetID])
            try await appSync(leslie, group)
            try await appSync(mallory, group)

            let realGroup = try mallory.keyRing.key(for: .group(group), epoch: .initial)
            let planted = [
                try KeyWrap.wrapToIdentity(ScopedKey.generate(scope: .group(group), epoch: .initial),
                                           recipient: robin.publicKeys, recipientUserID: robin.userID,
                                           sender: mallory.identity, senderUserID: mallory.userID),
                try KeyWrap.wrapUnderGroupKey(ScopedKey.generate(scope: .budget(budgetID), epoch: .initial),
                                              groupKey: realGroup.material, senderUserID: mallory.userID),
            ]
            let laptop = DeviceKeyPair()
            let hers = try MembershipLogEntry.signed(
                scope: .group(group), sequence: UInt64(log.count), previousHash: log.last!.hash,
                action: .addDevice, subjectUserID: mallory.userID, subjectKeys: nil, level: .read,
                epochAfter: .initial, deviceID: laptop.id, devicePublicKey: laptop.publicKey,
                author: mallory.identity, authorUserID: mallory.userID)
            await #expect(throws: (any Error).self) {
                try await mallory.transport.appendMembership(hers, group: group, wrappedKeys: planted)
            }

            let spent = Transaction(budgetID: budgetID, groupID: group, date: Date(),
                                    merchant: "Costco", amount: Money(minorUnits: -9900))
            try leslie.store.save(spent)
            try await appSync(leslie, group)
            try await appSync(robin, group)
            #expect(try robin.store.transaction(spent.id)?.merchant == "Costco")
        }
    }
}

/// A connection that loses the reply to a push. The server has done the work
/// by then. The app just never hears that it did.
private final class LostReply: SyncTransport, @unchecked Sendable {
    struct Lost: Error {}
    let inner: any SyncTransport

    init(_ inner: any SyncTransport) { self.inner = inner }

    func push(_ envelopes: [RecordEnvelope], group: GroupID) async throws -> PushResult {
        _ = try await inner.push(envelopes, group: group)
        throw Lost()
    }
    func pull(group: GroupID, since: UInt64, limit: Int) async throws -> PullResult {
        try await inner.pull(group: group, since: since, limit: limit)
    }
    func membershipLog(group: GroupID, since: UInt64) async throws -> [MembershipLogEntry] {
        try await inner.membershipLog(group: group, since: since)
    }
    func wrappedKeys(group: GroupID, for user: UserID) async throws -> [WrappedKey] {
        try await inner.wrappedKeys(group: group, for: user)
    }
}
