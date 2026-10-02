import Testing
import Foundation
import Crypto
import GRDB
@testable import WellSpentSync
import WellSpentCrypto
import WellSpentModel
import WellSpentStore

/// One person with their own database, keys and engine. Two of these talking to
/// the same transport is a full end-to-end test of sharing.
private final class Peer {
    let userID: UserID
    let identity: IdentityKeyPair
    let device: DeviceKeyPair
    let store: Store
    let keyRing: KeyRing
    let engine: SyncEngine

    init(transport: any SyncTransport, userID: UserID = UserID()) throws {
        self.userID = userID
        identity = IdentityKeyPair.generate()
        device = DeviceKeyPair()
        store = Store(database: try WellSpentDatabase.inMemory())
        keyRing = KeyRing(store: store, identity: identity, userID: userID)
        engine = SyncEngine(store: store, keyRing: keyRing, transport: transport,
                            identity: identity, device: device, userID: userID)
    }

    var publicKeys: IdentityPublicKeys { identity.publicKeys }

    /// The same person on the same device, reaching the server another way.
    func engine(through transport: any SyncTransport) -> SyncEngine {
        SyncEngine(store: store, keyRing: keyRing, transport: transport,
                   identity: identity, device: device, userID: userID)
    }
}

/// A server that is slow to answer a push. `whilePushing` runs once, after the
/// server has taken the batch and before the reply comes back. That is the
/// window in which a person can still be saving edits.
private final class SlowServer: SyncTransport, @unchecked Sendable {
    let server: InMemoryTransport
    var whilePushing: (() throws -> Void)?

    init(_ server: InMemoryTransport) {
        self.server = server
    }

    func push(_ envelopes: [RecordEnvelope], group: GroupID) async throws -> PushResult {
        let result = try await server.push(envelopes, group: group)
        try whilePushing?()
        whilePushing = nil
        return result
    }
    func pull(group: GroupID, since: UInt64, limit: Int) async throws -> PullResult {
        try await server.pull(group: group, since: since, limit: limit)
    }
    func membershipLog(group: GroupID, since: UInt64) async throws -> [MembershipLogEntry] {
        try await server.membershipLog(group: group, since: since)
    }
    func wrappedKeys(group: GroupID, for user: UserID) async throws -> [WrappedKey] {
        try await server.wrappedKeys(group: group, for: user)
    }
}

/// A server that refuses the records a test names, with the reason it names,
/// and passes everything else through. For a test that needs a refusal
/// without first building the state that would make a server refuse.
private final class RefusingServer: SyncTransport, @unchecked Sendable {
    let server: InMemoryTransport
    var refuse: [RecordID: String] = [:]
    /// How many envelopes were refused in all, counting each time one was sent.
    private(set) var refusedSends = 0

    init(_ server: InMemoryTransport) {
        self.server = server
    }

    func push(_ envelopes: [RecordEnvelope], group: GroupID) async throws -> PushResult {
        let passed = try await server.push(envelopes.filter { refuse[$0.recordID] == nil }, group: group)
        var rejected = passed.rejected
        for envelope in envelopes {
            guard let reason = refuse[envelope.recordID] else { continue }
            rejected[envelope.recordID] = reason
            refusedSends += 1
        }
        return PushResult(accepted: passed.accepted, rejected: rejected, serverSeq: passed.serverSeq)
    }
    func pull(group: GroupID, since: UInt64, limit: Int) async throws -> PullResult {
        try await server.pull(group: group, since: since, limit: limit)
    }
    func membershipLog(group: GroupID, since: UInt64) async throws -> [MembershipLogEntry] {
        try await server.membershipLog(group: group, since: since)
    }
    func wrappedKeys(group: GroupID, for user: UserID) async throws -> [WrappedKey] {
        try await server.wrappedKeys(group: group, for: user)
    }
}

/// A connection that loses the reply to every push. The server has done the
/// work by then. The app just never hears that it did.
private final class LosingReplies: SyncTransport, @unchecked Sendable {
    struct Lost: Error {}
    let server: InMemoryTransport

    init(_ server: InMemoryTransport) {
        self.server = server
    }

    func push(_ envelopes: [RecordEnvelope], group: GroupID) async throws -> PushResult {
        _ = try await server.push(envelopes, group: group)
        throw Lost()
    }
    func pull(group: GroupID, since: UInt64, limit: Int) async throws -> PullResult {
        try await server.pull(group: group, since: since, limit: limit)
    }
    func membershipLog(group: GroupID, since: UInt64) async throws -> [MembershipLogEntry] {
        try await server.membershipLog(group: group, since: since)
    }
    func wrappedKeys(group: GroupID, for user: UserID) async throws -> [WrappedKey] {
        try await server.wrappedKeys(group: group, for: user)
    }
}

/// Builds a group that exists on the fake server, with a founding log entry and
/// keys wrapped for everyone who should have them.
private struct Fixture {
    let transport = InMemoryTransport()
    let group = GroupID()
    var owner: Peer!
    var log: [MembershipLogEntry] = []
    var epoch = Epoch.initial

    init() throws {
        owner = try Peer(transport: transport)
        let founding = try MembershipLogEntry.signed(
            scope: .group(group), sequence: 0, previousHash: MembershipLogEntry.rootHash,
            action: .found, subjectUserID: owner.userID, subjectKeys: owner.publicKeys,
            level: .superadmin, epochAfter: epoch,
            deviceID: owner.device.id, devicePublicKey: owner.device.publicKey,
            author: owner.identity, authorUserID: owner.userID
        )
        log = [founding]
        transport.seed(log: log, for: group)

        // The owner mints the group key and keeps it. Nothing to unwrap yet.
        let groupKey = ScopedKey.generate(scope: .group(group), epoch: epoch)
        try owner.keyRing.remember(groupKey)
    }

    /// Add someone at a level, wrap the current keys for them, and publish both.
    mutating func add(_ peer: Peer, level: AccessLevel, budgets: [BudgetID] = []) throws {
        let entry = try MembershipLogEntry.signed(
            scope: .group(group), sequence: UInt64(log.count), previousHash: log.last!.hash,
            action: .add, subjectUserID: peer.userID, subjectKeys: peer.publicKeys,
            level: level, epochAfter: epoch,
            deviceID: peer.device.id, devicePublicKey: peer.device.publicKey,
            author: owner.identity, authorUserID: owner.userID
        )
        log.append(entry)
        transport.seed(log: log, for: group)

        let groupKey = try owner.keyRing.key(for: .group(group), epoch: epoch)
        transport.seed(keys: [try KeyWrap.wrapToIdentity(
            groupKey, recipient: peer.publicKeys, recipientUserID: peer.userID,
            sender: owner.identity, senderUserID: owner.userID)], for: group)

        for budget in budgets {
            let budgetKey = try owner.keyRing.key(for: .budget(budget), epoch: epoch)
            transport.seed(keys: [try KeyWrap.wrapUnderGroupKey(
                budgetKey, groupKey: groupKey.material, senderUserID: owner.userID)], for: group)
        }
    }

    /// Give the owner a budget, its key, and a group record, all seeded locally.
    mutating func makeBudget(named name: String, limit: Int = 100_000) throws -> Budget {
        let budgetKey = ScopedKey.generate(scope: .budget(BudgetID()), epoch: epoch)
        try owner.keyRing.remember(budgetKey)
        guard case .budget(let budgetID) = budgetKey.scope else { fatalError("unreachable") }

        try owner.store.save(BudgetGroup(id: group, name: "Household"))
        let budget = Budget(id: budgetID, groupID: group, name: name, limit: Money(minorUnits: limit))
        try owner.store.save(budget)
        return budget
    }
}

@Suite("Sync, end to end")
struct SyncTests {

    @Test func ownerPushesAndSharerReceives() async throws {
        var fixture = try Fixture()
        let budget = try fixture.makeBudget(named: "Groceries")

        try fixture.owner.store.save(Transaction(
            budgetID: budget.id, groupID: fixture.group, date: Date(),
            merchant: "Hilltop", amount: Money(minorUnits: -14208)))

        let pushReport = try await fixture.owner.engine.sync(group: fixture.group)
        #expect(pushReport.pushed == 3, "group, budget and transaction")
        #expect(pushReport.rejected == 0)

        let leslie = try Peer(transport: fixture.transport)
        try fixture.add(leslie, level: .write, budgets: [budget.id])

        let pullReport = try await leslie.engine.sync(group: fixture.group)
        #expect(pullReport.applied == 3)
        #expect(pullReport.undecryptable == 0)

        let received = try leslie.store.transactions(in: budget.id)
        #expect(received.count == 1)
        #expect(received.first?.merchant == "Hilltop")
        #expect(received.first?.amount == Money(minorUnits: -14208))

        // And the totals now agree on both machines.
        let theirBudget = try #require(try leslie.store.budget(budget.id))
        let summary = try leslie.store.summary(for: theirBudget)
        #expect(summary.spent == Money(minorUnits: 14208))
    }

    /// The whole promise of the product, stated as a test: the server holds this
    /// data and cannot read any of it.
    @Test func theServerNeverSeesAMerchantOrAnAmount() async throws {
        var fixture = try Fixture()
        let budget = try fixture.makeBudget(named: "Groceries")
        try fixture.owner.store.save(Transaction(
            budgetID: budget.id, groupID: fixture.group, date: Date(),
            merchant: "Hilltop Grocery", note: "weekly shop",
            amount: Money(minorUnits: -14208)))

        _ = try await fixture.owner.engine.sync(group: fixture.group)

        let blobs = fixture.transport.ciphertexts(in: fixture.group)
        #expect(!blobs.isEmpty)
        for blob in blobs {
            let text = String(decoding: blob, as: UTF8.self)
            #expect(!text.contains("Hilltop"))
            #expect(!text.contains("Grocery"))
            #expect(!text.contains("weekly shop"))
            #expect(!text.contains("14208"))
            #expect(blob.range(of: Data("Hilltop".utf8)) == nil)
        }
    }

    /// Padding means every small record is the same size on the wire, so the
    /// length of a merchant name does not leak.
    @Test func ciphertextLengthDoesNotLeakContentLength() async throws {
        var fixture = try Fixture()
        let budget = try fixture.makeBudget(named: "Groceries")

        try fixture.owner.store.save(Transaction(
            budgetID: budget.id, groupID: fixture.group, date: Date(),
            merchant: "A", amount: Money(minorUnits: -1)))
        try fixture.owner.store.save(Transaction(
            budgetID: budget.id, groupID: fixture.group, date: Date(),
            merchant: String(repeating: "B", count: 120), amount: Money(minorUnits: -2)))

        _ = try await fixture.owner.engine.sync(group: fixture.group)

        // Compare like with like: two transactions whose merchant names differ by
        // 119 characters must be indistinguishable by size on the wire.
        let sizes = Set(fixture.transport
            .ciphertexts(in: fixture.group, ofType: .transaction).map(\.count))
        #expect(sizes.count == 1, "transactions should pad to one bucket, got \(sizes)")
    }

    @Test func readerCanReadButTheirWritesAreRefused() async throws {
        var fixture = try Fixture()
        let budget = try fixture.makeBudget(named: "Groceries")
        try fixture.owner.store.save(Transaction(
            budgetID: budget.id, groupID: fixture.group, date: Date(),
            merchant: "Costco", amount: Money(minorUnits: -28631)))
        _ = try await fixture.owner.engine.sync(group: fixture.group)

        let jamie = try Peer(transport: fixture.transport)
        try fixture.add(jamie, level: .read, budgets: [budget.id])

        let report = try await jamie.engine.sync(group: fixture.group)
        #expect(report.applied == 3, "a reader can read")
        #expect(try jamie.store.transactions(in: budget.id).count == 1)

        // Now he tries to write. The engine will not even push, because he is
        // below write, and the server would refuse it anyway.
        try jamie.store.save(Transaction(
            budgetID: budget.id, groupID: fixture.group, date: Date(),
            merchant: "sneaky", amount: Money(minorUnits: -999)))
        let second = try await jamie.engine.sync(group: fixture.group)
        #expect(second.pushed == 0)
        #expect(try jamie.store.outboxCount(in: fixture.group) > 0, "still queued, not lost")

        // The owner never sees it.
        let ownerReport = try await fixture.owner.engine.sync(group: fixture.group)
        #expect(ownerReport.applied == 0)
        #expect(try fixture.owner.store.transactions(in: budget.id).count == 1)
    }

    /// A reader who keeps the key can still produce valid ciphertext. What they
    /// cannot do is get it accepted. This is the test for the claim that
    /// encryption only enforces read.
    @Test func aDemotedMemberForgingARecordIsIgnored() async throws {
        var fixture = try Fixture()
        let budget = try fixture.makeBudget(named: "Groceries")
        let jamie = try Peer(transport: fixture.transport)
        try fixture.add(jamie, level: .read, budgets: [budget.id])
        _ = try await jamie.engine.sync(group: fixture.group)

        // He holds the key, so he can seal something that decrypts perfectly.
        let key = try jamie.keyRing.key(for: .budget(budget.id), epoch: fixture.epoch)
        let forged = try RecordCodec.seal(
            Transaction(budgetID: budget.id, groupID: fixture.group, date: Date(),
                        merchant: "forged", amount: Money(minorUnits: -100000)),
            recordID: RecordID(), recordType: .transaction, groupID: fixture.group,
            budgetID: budget.id, scopeKey: key, lamport: 99,
            author: jamie.userID, device: jamie.device, membershipSequence: 1
        )

        let result = try await fixture.transport.push([forged], group: fixture.group)
        #expect(result.accepted.isEmpty)
        #expect(result.rejected[forged.recordID]?.contains("needs write") == true)
    }

    @Test func concurrentEditsResolveTheSameWayOnBothDevices() async throws {
        var fixture = try Fixture()
        let budget = try fixture.makeBudget(named: "Groceries")
        let transaction = Transaction(budgetID: budget.id, groupID: fixture.group, date: Date(),
                                      merchant: "original", amount: Money(minorUnits: -1000))
        try fixture.owner.store.save(transaction)
        _ = try await fixture.owner.engine.sync(group: fixture.group)

        let leslie = try Peer(transport: fixture.transport)
        try fixture.add(leslie, level: .manage, budgets: [budget.id])
        _ = try await leslie.engine.sync(group: fixture.group)

        // Both edit the same row before either syncs.
        var hers = try #require(try leslie.store.transaction(transaction.id))
        hers.merchant = "Leslie's version"
        try leslie.store.save(hers)

        var his = try #require(try fixture.owner.store.transaction(transaction.id))
        his.merchant = "Robin's version"
        try fixture.owner.store.save(his)

        // She syncs first, then he does, then she pulls his.
        _ = try await leslie.engine.sync(group: fixture.group)
        _ = try await fixture.owner.engine.sync(group: fixture.group)
        _ = try await leslie.engine.sync(group: fixture.group)
        _ = try await fixture.owner.engine.sync(group: fixture.group)

        let hisFinal = try #require(try fixture.owner.store.transaction(transaction.id))
        let hersFinal = try #require(try leslie.store.transaction(transaction.id))
        #expect(hisFinal.merchant == hersFinal.merchant, "both devices must land on the same value")
    }

    /// Losing a conflict must not mean the typing disappears without trace.
    @Test func theLosingEditIsKept() async throws {
        var fixture = try Fixture()
        let budget = try fixture.makeBudget(named: "Groceries")
        let transaction = Transaction(budgetID: budget.id, groupID: fixture.group, date: Date(),
                                      merchant: "original", amount: Money(minorUnits: -1000))
        try fixture.owner.store.save(transaction)
        _ = try await fixture.owner.engine.sync(group: fixture.group)

        let leslie = try Peer(transport: fixture.transport)
        try fixture.add(leslie, level: .manage, budgets: [budget.id])
        _ = try await leslie.engine.sync(group: fixture.group)

        var hers = try #require(try leslie.store.transaction(transaction.id))
        hers.merchant = "hers"
        try leslie.store.save(hers)
        _ = try await leslie.engine.sync(group: fixture.group)

        // He makes many local edits, so his Lamport counter is clearly higher, then
        // pulls hers while his are still queued. Hers loses, and must be kept.
        // His must not be written over: the pull used to replace it with hers,
        // and his push then sent her text under his name.
        for name in ["a", "b", "c", "d", "e"] {
            var his = try #require(try fixture.owner.store.transaction(transaction.id))
            his.merchant = name
            try fixture.owner.store.save(his)
        }
        let report = try await fixture.owner.engine.sync(group: fixture.group)

        #expect(report.conflicts == 1, "got \(report)")
        let kept = try fixture.owner.store.conflicts(for: transaction.id)
        #expect(kept.contains { $0.payloadJSON.contains("hers") }, "the losing edit must be recoverable")
        #expect(try fixture.owner.store.transaction(transaction.id)?.merchant == "e", "his edit stands")

        _ = try await leslie.engine.sync(group: fixture.group)
        #expect(try leslie.store.transaction(transaction.id)?.merchant == "e", "and reaches her")
    }

    /// The other way round. His edit is still queued when a newer one of hers
    /// arrives. Hers wins on every device, so his is kept as a conflict copy and
    /// leaves the queue, rather than going out with her text in it.
    @Test func aQueuedEditThatLosesIsKept() async throws {
        var fixture = try Fixture()
        let budget = try fixture.makeBudget(named: "Groceries")
        let transaction = Transaction(budgetID: budget.id, groupID: fixture.group, date: Date(),
                                      merchant: "original", amount: Money(minorUnits: -1000))
        try fixture.owner.store.save(transaction)
        _ = try await fixture.owner.engine.sync(group: fixture.group)

        let leslie = try Peer(transport: fixture.transport)
        try fixture.add(leslie, level: .manage, budgets: [budget.id])
        _ = try await leslie.engine.sync(group: fixture.group)

        // She edits many times, so her Lamport counter is clearly higher, and sends.
        for name in ["a", "b", "c", "d", "hers"] {
            var hers = try #require(try leslie.store.transaction(transaction.id))
            hers.merchant = name
            try leslie.store.save(hers)
        }
        _ = try await leslie.engine.sync(group: fixture.group)

        var his = try #require(try fixture.owner.store.transaction(transaction.id))
        his.merchant = "his"
        try fixture.owner.store.save(his)
        let report = try await fixture.owner.engine.sync(group: fixture.group)

        #expect(report.conflicts == 1, "got \(report)")
        #expect(report.pushed == 0, "his losing edit does not go out")
        #expect(try fixture.owner.store.outboxCount(in: fixture.group) == 0)
        #expect(try fixture.owner.store.transaction(transaction.id)?.merchant == "hers")
        let kept = try fixture.owner.store.conflicts(for: transaction.id)
        #expect(kept.contains { $0.payloadJSON.contains("\"his\"") }, "his edit must be recoverable")

        _ = try await leslie.engine.sync(group: fixture.group)
        #expect(try leslie.store.transaction(transaction.id)?.merchant == "hers")
    }

    /// A row the server refuses as older than the version it holds can never
    /// be taken, because its Lamport value never changes. It used to stay
    /// queued and go out again on every sync. It now leaves the queue, and
    /// what it said is kept as a conflict copy.
    @Test func aRowRefusedAsOlderLeavesTheQueueAndIsKept() async throws {
        var fixture = try Fixture()
        let budget = try fixture.makeBudget(named: "Groceries")
        _ = try await fixture.owner.engine.sync(group: fixture.group)

        let server = RefusingServer(fixture.transport)
        let owner = fixture.owner.engine(through: server)
        let store = fixture.owner.store
        var renamed = budget
        renamed.name = "Food"
        try store.save(renamed)
        server.refuse[RecordID(budget.id.uuid)] = "a newer version is already stored"

        let first = try await owner.sync(group: fixture.group)
        #expect(first.rejected == 1)
        #expect(try store.outboxCount(in: fixture.group) == 0)
        let kept = try store.conflicts(for: RecordID(budget.id.uuid))
        #expect(kept.contains { $0.payloadJSON.contains("Food") })

        let second = try await owner.sync(group: fixture.group)
        #expect(second.rejected == 0)
        #expect(server.refusedSends == 1, "sent once, not on every sync")
    }

    /// More than a page of refused rows must not hold back what comes after
    /// them. The queue was read two hundred rows at a time, oldest first, and
    /// only that page went out. Once two hundred refused rows filled it,
    /// nothing saved after them ever reached the server. Both kinds of
    /// refusal are tried: one the app now drops, and one it keeps sending.
    @Test(arguments: ["a newer version is already stored", "refused for a reason the app cannot fix"])
    func refusedRowsCannotHoldUpTheQueue(reason: String) async throws {
        var fixture = try Fixture()
        let budget = try fixture.makeBudget(named: "Groceries")
        _ = try await fixture.owner.engine.sync(group: fixture.group)

        let server = RefusingServer(fixture.transport)
        let owner = fixture.owner.engine(through: server)
        let store = fixture.owner.store
        for index in 0 ..< 201 {
            let refused = Transaction(budgetID: budget.id, groupID: fixture.group, date: Date(),
                                      merchant: "Refused \(index)", amount: Money(minorUnits: -1))
            try store.save(refused)
            server.refuse[refused.id] = reason
        }
        var renamed = try #require(try store.group(fixture.group))
        renamed.name = "Home"
        try store.save(renamed)

        let report = try await owner.sync(group: fixture.group)
        #expect(report.rejected == 201, "got \(report)")
        #expect(report.pushed == 1, "the rename got past them")

        let leslie = try Peer(transport: fixture.transport)
        try fixture.add(leslie, level: .read)
        _ = try await leslie.engine.sync(group: fixture.group)
        #expect(try leslie.store.group(fixture.group)?.name == "Home")
    }

    /// A queued row whose record is gone from this Mac's database has nothing
    /// to send. It was read again on every sync, for good, because only rows
    /// the server took were cleared. Nothing in the app removes a record
    /// outright today, so the test does it by hand.
    @Test func aRowWhoseRecordIsGoneLeavesTheQueue() async throws {
        var fixture = try Fixture()
        let budget = try fixture.makeBudget(named: "Groceries")
        _ = try await fixture.owner.engine.sync(group: fixture.group)

        let store = fixture.owner.store
        let gone = Transaction(budgetID: budget.id, groupID: fixture.group, date: Date(),
                               merchant: "Gone", amount: Money(minorUnits: -1))
        try store.save(gone)
        try store.database.write { db in
            try db.execute(sql: "DELETE FROM transactionRecord WHERE id = ?",
                           arguments: [gone.id.uuid.uuidString])
        }
        #expect(try store.outboxCount(in: fixture.group) == 1)

        let report = try await fixture.owner.engine.sync(group: fixture.group)
        #expect(report.pushed == 0)
        #expect(try store.outboxCount(in: fixture.group) == 0)
    }

    /// A row of a record type this build does not know was queued by a newer
    /// build, which will send it. This build has nothing to seal it from, and
    /// used to clear it as if the record were gone.
    @Test func aRowOfAnUnknownTypeStaysQueued() async throws {
        var fixture = try Fixture()
        _ = try fixture.makeBudget(named: "Groceries")
        _ = try await fixture.owner.engine.sync(group: fixture.group)

        let store = fixture.owner.store
        try store.database.write { db in
            try db.execute(sql: """
                INSERT INTO outbox (recordId, recordType, budgetGroupId, lamport, isDeleted, queuedAt)
                VALUES (?, 'somethingFromTheFuture', ?, 1000, 0, ?)
                """, arguments: [RecordID().uuid.uuidString, fixture.group.uuid.uuidString, Date()])
        }

        _ = try await fixture.owner.engine.sync(group: fixture.group)
        #expect(try store.outboxCount(in: fixture.group) == 1, "left for the build that knows it")
    }

    /// A member who can only view never sends what they save, so a row they
    /// queue must not outrank anyone else's edit. It did: the owner's newer
    /// change lost to it and was kept only as a conflict copy, so this Mac
    /// kept text nobody else had, for good. Now it takes the owner's change,
    /// and the row that could never go out becomes the conflict copy.
    @Test func aViewMembersMacTakesNewerEdits() async throws {
        var fixture = try Fixture()
        let budget = try fixture.makeBudget(named: "Groceries")
        _ = try await fixture.owner.engine.sync(group: fixture.group)
        let jamie = try Peer(transport: fixture.transport)
        try fixture.add(jamie, level: .read, budgets: [budget.id])
        _ = try await jamie.engine.sync(group: fixture.group)

        for name in ["Food", "Food and drink"] {
            var renamed = try #require(try jamie.store.budget(budget.id))
            renamed.name = name
            try jamie.store.save(renamed)
        }
        _ = try await jamie.engine.sync(group: fixture.group)

        var raised = try #require(try fixture.owner.store.budget(budget.id))
        raised.limit = Money(minorUnits: 150_000)
        try fixture.owner.store.save(raised)
        _ = try await fixture.owner.engine.sync(group: fixture.group)

        _ = try await jamie.engine.sync(group: fixture.group)
        let seen = try #require(try jamie.store.budget(budget.id))
        #expect(seen.limit.minorUnits == 150_000, "the owner's change reached him")
        #expect(seen.name == "Groceries")
        #expect(try jamie.store.outboxCount(in: fixture.group) == 0)
        #expect(try jamie.store.conflicts(for: RecordID(budget.id.uuid))
            .contains { $0.payloadJSON.contains("Food and drink") })
    }

    /// The same for an edit this Mac may not send: a change to someone else's
    /// transaction by a member who may change only their own. Push drops it,
    /// so it must not outrank the owner's own newer edit on the way in.
    @Test func anEditThisMacMayNotSendGivesWay() async throws {
        var fixture = try Fixture()
        let budget = try fixture.makeBudget(named: "Groceries")
        let his = Transaction(budgetID: budget.id, groupID: fixture.group, date: Date(),
                              merchant: "his", amount: Money(minorUnits: -1000))
        try fixture.owner.store.save(his)
        _ = try await fixture.owner.engine.sync(group: fixture.group)
        let leslie = try Peer(transport: fixture.transport)
        try fixture.add(leslie, level: .write, budgets: [budget.id])
        _ = try await leslie.engine.sync(group: fixture.group)

        for name in ["a", "b", "c"] {
            var changed = try #require(try leslie.store.transaction(his.id))
            changed.merchant = name
            try leslie.store.save(changed)
        }
        var fixed = try #require(try fixture.owner.store.transaction(his.id))
        fixed.merchant = "his, fixed"
        try fixture.owner.store.save(fixed)
        _ = try await fixture.owner.engine.sync(group: fixture.group)

        _ = try await leslie.engine.sync(group: fixture.group)
        #expect(try leslie.store.transaction(his.id)?.merchant == "his, fixed")
        #expect(try leslie.store.outboxCount(in: fixture.group) == 0)
    }

    /// The view member's rule again, for the group's own record. Nothing
    /// stops a view member saving it, and a push would allow it, so only the
    /// view rule keeps the row from outranking the owner's newer name. The
    /// budget test above cannot show that, because the Manage rule holds a
    /// budget back on its own.
    @Test func aViewMembersMacTakesNewerGroupEdits() async throws {
        var fixture = try Fixture()
        _ = try fixture.makeBudget(named: "Groceries")
        _ = try await fixture.owner.engine.sync(group: fixture.group)
        let jamie = try Peer(transport: fixture.transport)
        try fixture.add(jamie, level: .read)
        _ = try await jamie.engine.sync(group: fixture.group)

        for name in ["Ours", "Our place"] {
            var renamed = try #require(try jamie.store.group(fixture.group))
            renamed.name = name
            try jamie.store.save(renamed)
        }
        var renamed = try #require(try fixture.owner.store.group(fixture.group))
        renamed.name = "Home"
        try fixture.owner.store.save(renamed)
        _ = try await fixture.owner.engine.sync(group: fixture.group)

        _ = try await jamie.engine.sync(group: fixture.group)
        #expect(try jamie.store.group(fixture.group)?.name == "Home", "the owner's name reached him")
        #expect(try jamie.store.outboxCount(in: fixture.group) == 0)
        #expect(try jamie.store.conflicts(for: RecordID(fixture.group.uuid))
            .contains { $0.payloadJSON.contains("Our place") })
    }

    // MARK: - Re-seals

    /// A re-seal queued over an edit not yet sent moved the edit up to a fresh
    /// Lamport value. Here his rename reached the server but the reply was
    /// lost, and she changed the limit on top of it. His re-seal then
    /// outranked her change, and his old limit went out over hers on every
    /// Mac. The edit is now weighed at the value it was made at.
    @Test func aReSealDoesNotRaiseTheEditItIsQueuedOver() async throws {
        var fixture = try Fixture()
        let budget = try fixture.makeBudget(named: "Groceries")
        _ = try await fixture.owner.engine.sync(group: fixture.group)
        let leslie = try Peer(transport: fixture.transport)
        try fixture.add(leslie, level: .manage, budgets: [budget.id])
        _ = try await leslie.engine.sync(group: fixture.group)

        let store = fixture.owner.store
        var renamed = try #require(try store.budget(budget.id))
        renamed.name = "Food"
        try store.save(renamed)
        let lossy = fixture.owner.engine(through: LosingReplies(fixture.transport))
        await #expect(throws: LosingReplies.Lost.self) { try await lossy.sync(group: fixture.group) }

        _ = try await leslie.engine.sync(group: fixture.group)
        var lowered = try #require(try leslie.store.budget(budget.id))
        lowered.limit = Money(minorUnits: 40_000)
        try leslie.store.save(lowered)
        _ = try await leslie.engine.sync(group: fixture.group)

        // His next sync queues a re-seal over the row still waiting, as
        // adding someone "from now on" does, then pulls her change.
        try store.queueReseal(of: fixture.group)
        _ = try await fixture.owner.engine.sync(group: fixture.group)
        _ = try await leslie.engine.sync(group: fixture.group)

        for (name, peer) in [("his", fixture.owner!), ("hers", leslie)] {
            let seen = try #require(try peer.store.budget(budget.id))
            #expect(seen.limit.minorUnits == 40_000, "\(name) keeps her lower limit")
            #expect(seen.name == "Food", "\(name) keeps his rename")
        }
    }

    /// An edit saved over a re-seal is an edit again, and is weighed as one.
    /// Still marked as a re-seal, it gave way to an older edit pulled from
    /// someone else, and was written over with no conflict copy.
    @Test func anEditSavedOverAReSealIsWeighedAsAnEdit() async throws {
        var fixture = try Fixture()
        let budget = try fixture.makeBudget(named: "Groceries")
        _ = try await fixture.owner.engine.sync(group: fixture.group)
        let leslie = try Peer(transport: fixture.transport)
        try fixture.add(leslie, level: .manage, budgets: [budget.id])
        _ = try await leslie.engine.sync(group: fixture.group)

        var lowered = try #require(try leslie.store.budget(budget.id))
        lowered.limit = Money(minorUnits: 40_000)
        try leslie.store.save(lowered)
        _ = try await leslie.engine.sync(group: fixture.group)

        // Before pulling hers, his Mac queues a re-seal and he renames the
        // budget, which outranks her change.
        let store = fixture.owner.store
        try store.queueReseal(of: fixture.group)
        var renamed = try #require(try store.budget(budget.id))
        renamed.name = "Food"
        try store.save(renamed)
        _ = try await fixture.owner.engine.sync(group: fixture.group)
        _ = try await leslie.engine.sync(group: fixture.group)

        for (name, peer) in [("his", fixture.owner!), ("hers", leslie)] {
            #expect(try peer.store.budget(budget.id)?.name == "Food", "\(name) has his rename")
        }
        #expect(try store.conflicts(for: RecordID(budget.id.uuid))
            .contains { $0.payloadJSON.contains("40000") }, "her change is kept as a conflict copy")
    }

    /// A re-seal of a record someone else has since deleted has nothing left
    /// to send, so it leaves the queue. Moved above the delete instead, it
    /// would go out live and bring the record back for everyone.
    @Test func aPulledDeleteEndsAReSeal() async throws {
        var fixture = try Fixture()
        let budget = try fixture.makeBudget(named: "Groceries")
        _ = try await fixture.owner.engine.sync(group: fixture.group)
        let leslie = try Peer(transport: fixture.transport)
        try fixture.add(leslie, level: .manage, budgets: [budget.id])
        _ = try await leslie.engine.sync(group: fixture.group)

        var deleted = try #require(try leslie.store.budget(budget.id))
        deleted.isDeleted = true
        try leslie.store.save(deleted)
        _ = try await leslie.engine.sync(group: fixture.group)

        try fixture.owner.store.queueReseal(of: fixture.group)
        _ = try await fixture.owner.engine.sync(group: fixture.group)
        _ = try await leslie.engine.sync(group: fixture.group)

        #expect(try fixture.owner.store.budget(budget.id)?.isDeleted == true)
        #expect(try fixture.owner.store.queuedPush(RecordID(budget.id.uuid)) == nil)
        #expect(try leslie.store.budget(budget.id)?.isDeleted == true, "her delete stands")
    }

    // MARK: - Applying a pulled record

    /// Weighing a pulled record and writing the winner is one transaction.
    /// If a write fails partway, none of it lands. Otherwise her losing edit
    /// left the queue and the record took his text, with no version on file
    /// to say so, and her edit was gone from the screen with nothing sent.
    @Test func applyingAPulledRecordLandsWholeOrNotAtAll() async throws {
        var fixture = try Fixture()
        let budget = try fixture.makeBudget(named: "Groceries")
        _ = try await fixture.owner.engine.sync(group: fixture.group)
        let leslie = try Peer(transport: fixture.transport)
        try fixture.add(leslie, level: .manage, budgets: [budget.id])
        _ = try await leslie.engine.sync(group: fixture.group)

        // Her edit waits to go out. His outranks it and reaches the server.
        var hers = try #require(try leslie.store.budget(budget.id))
        hers.name = "Hers"
        try leslie.store.save(hers)
        for name in ["a", "b", "His"] {
            var his = try #require(try fixture.owner.store.budget(budget.id))
            his.name = name
            try fixture.owner.store.save(his)
        }
        _ = try await fixture.owner.engine.sync(group: fixture.group)

        // The last write in applying his record saves its version. Here it fails.
        let storedID = budget.id.uuid.uuidString
        try leslie.store.database.write { db in
            for event in ["INSERT", "UPDATE"] {
                try db.execute(sql: """
                    CREATE TRIGGER failVersion\(event) BEFORE \(event) ON recordVersion
                    WHEN NEW.recordId = '\(storedID)' BEGIN SELECT RAISE(ABORT, 'disk full'); END
                    """)
            }
        }
        await #expect(throws: (any Error).self) { try await leslie.engine.sync(group: fixture.group) }

        let recordID = RecordID(budget.id.uuid)
        #expect(try leslie.store.budget(budget.id)?.name == "Hers", "nothing was written over")
        #expect(try leslie.store.queuedPush(recordID) != nil, "her edit is still queued")
        #expect(try leslie.store.conflicts(for: recordID).isEmpty, "and no conflict copy was kept")
    }

    /// The in-memory server takes the version it holds, sent again by the
    /// device that wrote it, as the real server does. Without that, a rename
    /// whose reply was lost came back refused as older.
    @Test func theFakeServerTakesTheResendAfterALostReply() async throws {
        var fixture = try Fixture()
        _ = try fixture.makeBudget(named: "Groceries")
        _ = try await fixture.owner.engine.sync(group: fixture.group)

        let store = fixture.owner.store
        var renamed = try #require(try store.group(fixture.group))
        renamed.name = "Home"
        try store.save(renamed)
        let lossy = fixture.owner.engine(through: LosingReplies(fixture.transport))
        await #expect(throws: LosingReplies.Lost.self) { try await lossy.sync(group: fixture.group) }

        let report = try await fixture.owner.engine.sync(group: fixture.group)
        #expect(report.pushed == 1 && report.rejected == 0, "got \(report)")
        #expect(try store.conflicts(for: RecordID(fixture.group.uuid)).isEmpty)
    }

    /// The in-memory server refuses a version older than the one it holds, for
    /// every type, as the real server does. It used to refuse only an older
    /// group record, and took an older budget or transaction over a newer one.
    /// The reason is the older-version one even when what it holds is a
    /// delete: only a group's delete is final, and the app drops a row only
    /// for the older-version reason.
    @Test func theFakeServerRefusesAnOlderVersionOfAnyRecord() async throws {
        var fixture = try Fixture()
        let budget = try fixture.makeBudget(named: "Groceries")
        let spent = Transaction(budgetID: budget.id, groupID: fixture.group, date: Date(),
                                merchant: "Hilltop", amount: Money(minorUnits: -1))
        try fixture.owner.store.save(spent)
        let gone = Transaction(budgetID: budget.id, groupID: fixture.group, date: Date(),
                               merchant: "Costco", amount: Money(minorUnits: -1))
        try fixture.owner.store.save(gone)
        try fixture.owner.store.trash(gone)
        _ = try await fixture.owner.engine.sync(group: fixture.group)
        let before = try await fixture.transport.pull(group: fixture.group, since: 0, limit: 50)

        let owner = fixture.owner!
        let key = try owner.keyRing.key(for: .budget(budget.id), epoch: fixture.epoch)
        let sequence = UInt64(fixture.log.count - 1)
        let olderBudget = try RecordCodec.seal(
            budget, recordID: RecordID(budget.id.uuid), recordType: .budget,
            groupID: fixture.group, budgetID: budget.id, scopeKey: key, lamport: 0,
            author: owner.userID, device: owner.device, membershipSequence: sequence)
        let olderSpend = try RecordCodec.seal(
            spent, recordID: spent.id, recordType: .transaction,
            groupID: fixture.group, budgetID: budget.id, scopeKey: key, lamport: 0,
            author: owner.userID, device: owner.device, membershipSequence: sequence)
        let olderThanTheDelete = try RecordCodec.seal(
            gone, recordID: gone.id, recordType: .transaction,
            groupID: fixture.group, budgetID: budget.id, scopeKey: key, lamport: 0,
            author: owner.userID, device: owner.device, membershipSequence: sequence)

        let result = try await fixture.transport.push([olderBudget, olderSpend, olderThanTheDelete],
                                                      group: fixture.group)
        #expect(result.accepted.isEmpty)
        #expect(result.rejected[RecordID(budget.id.uuid)] == RecordEnvelope.olderVersionRefusal)
        #expect(result.rejected[spent.id] == RecordEnvelope.olderVersionRefusal)
        #expect(result.rejected[gone.id] == RecordEnvelope.olderVersionRefusal)
        let after = try await fixture.transport.pull(group: fixture.group, since: 0, limit: 50)
        #expect(after.envelopes == before.envelopes, "what it held is unchanged")
    }

    /// The in-memory server refuses a Lamport value at or above the ceiling,
    /// as the real one does, and takes the one just below it.
    @Test func theFakeServerRefusesALamportValueAtTheCeiling() async throws {
        var fixture = try Fixture()
        let budget = try fixture.makeBudget(named: "Groceries")
        _ = try await fixture.owner.engine.sync(group: fixture.group)
        let owner = fixture.owner!
        let key = try owner.keyRing.key(for: .budget(budget.id), epoch: fixture.epoch)
        let sequence = UInt64(fixture.log.count - 1)
        func sealed(_ lamport: UInt64) throws -> RecordEnvelope {
            try RecordCodec.seal(
                budget, recordID: RecordID(budget.id.uuid), recordType: .budget,
                groupID: fixture.group, budgetID: budget.id, scopeKey: key, lamport: lamport,
                author: owner.userID, device: owner.device, membershipSequence: sequence)
        }
        let ceiling = UInt64(1) << 62

        for lamport in [UInt64(Int.max), ceiling] {
            let result = try await fixture.transport.push([try sealed(lamport)], group: fixture.group)
            #expect(result.rejected[RecordID(budget.id.uuid)] == "the Lamport value is too large")
        }
        let taken = try await fixture.transport.push([try sealed(ceiling - 1)], group: fixture.group)
        #expect(taken.accepted == [RecordID(budget.id.uuid)])
    }

    /// A server without the ceiling can hand over a forged Lamport value at
    /// the top of the range. Taken in, it left this Mac's clock no room, and
    /// the next save crashed the app. Now it is ignored, and saving goes on.
    @Test func aForgedLamportValueAtTheTopCannotStopThisMacSaving() async throws {
        var fixture = try Fixture()
        let budget = try fixture.makeBudget(named: "Groceries")
        _ = try await fixture.owner.engine.sync(group: fixture.group)
        let server = Smuggling(fixture.transport)
        let leslie = try Peer(transport: server)
        try fixture.add(leslie, level: .write, budgets: [budget.id])
        _ = try await leslie.engine.sync(group: fixture.group)

        var forged = budget
        forged.name = "Forged"
        server.extra = [try RecordCodec.seal(
            forged, recordID: RecordID(budget.id.uuid), recordType: .budget,
            groupID: fixture.group, budgetID: budget.id,
            scopeKey: try fixture.owner.keyRing.key(for: .budget(budget.id), epoch: fixture.epoch),
            lamport: UInt64(Int.max), author: fixture.owner.userID, device: fixture.owner.device,
            membershipSequence: UInt64(fixture.log.count - 1))]
        let report = try await leslie.engine.sync(group: fixture.group)
        #expect(report.ignored == 1, "got \(report)")
        #expect(try leslie.store.budget(budget.id)?.name == "Groceries")

        var mine = try #require(try leslie.store.budget(budget.id))
        mine.name = "Food"
        try leslie.store.save(mine)
        #expect(try leslie.store.syncState(for: fixture.group).lamport < UInt64(1) << 62)
    }

    /// The highest value a server takes is one below the ceiling. A Mac that
    /// pulls it still has room on its clock, and its saves go on.
    @Test func aMacHoldingTheHighestTakenValueKeepsSaving() async throws {
        var fixture = try Fixture()
        let budget = try fixture.makeBudget(named: "Groceries")
        _ = try await fixture.owner.engine.sync(group: fixture.group)
        let leslie = try Peer(transport: fixture.transport)
        try fixture.add(leslie, level: .write, budgets: [budget.id])
        _ = try await leslie.engine.sync(group: fixture.group)

        let highest = (UInt64(1) << 62) - 1
        var renamed = budget
        renamed.name = "Food"
        try await forge(renamed, id: RecordID(budget.id.uuid), type: .budget, budget: budget.id,
                        as: fixture.owner, fixture: fixture, lamport: highest)
        _ = try await leslie.engine.sync(group: fixture.group)
        #expect(try leslie.store.budget(budget.id)?.name == "Food")
        #expect(try leslie.store.syncState(for: fixture.group).lamport == highest)

        for name in ["a", "b", "c"] {
            var mine = try #require(try leslie.store.budget(budget.id))
            mine.name = name
            try leslie.store.save(mine)
        }
        #expect(try leslie.store.syncState(for: fixture.group).lamport == highest + 3)
    }

    @Test func aRejectedPushStaysQueued() async throws {
        var fixture = try Fixture()
        let budget = try fixture.makeBudget(named: "Groceries")

        // A peer who is in the log at write level, but whose records we will make
        // the server refuse by pushing them under the wrong group.
        try fixture.owner.store.save(Transaction(
            budgetID: budget.id, groupID: fixture.group, date: Date(),
            merchant: "fine", amount: Money(minorUnits: -1)))

        let before = try fixture.owner.store.outboxCount(in: fixture.group)
        #expect(before > 0)
        let report = try await fixture.owner.engine.sync(group: fixture.group)
        #expect(report.pushed == before)
        #expect(try fixture.owner.store.outboxCount(in: fixture.group) == 0)
    }

    /// A rename saved while the last rename is still on its way to the server
    /// must go out too. The outbox keeps one row per record, so clearing what
    /// the server took by record alone threw the second rename away unsent.
    @Test func anEditSavedDuringAPushGoesOutNext() async throws {
        var fixture = try Fixture()
        _ = try fixture.makeBudget(named: "Groceries")
        _ = try await fixture.owner.engine.sync(group: fixture.group)

        let slow = SlowServer(fixture.transport)
        let owner = fixture.owner.engine(through: slow)
        let store = fixture.owner.store

        var group = try #require(try store.group(fixture.group))
        group.name = "First"
        try store.save(group)
        group.name = "Second"
        let second = group
        slow.whilePushing = { try store.save(second) }

        _ = try await owner.sync(group: fixture.group)
        #expect(try store.outboxCount(in: fixture.group) == 1, "the second rename is still queued")
        #expect(try await owner.sync(group: fixture.group).pushed == 1)

        let leslie = try Peer(transport: fixture.transport)
        try fixture.add(leslie, level: .read)
        _ = try await leslie.engine.sync(group: fixture.group)
        #expect(try leslie.store.group(fixture.group)?.name == "Second")
    }

    /// The same for a delete. Lost this way, the record stays live on every
    /// other device.
    @Test func aDeleteSavedDuringAPushGoesOutNext() async throws {
        var fixture = try Fixture()
        let budget = try fixture.makeBudget(named: "Groceries")
        _ = try await fixture.owner.engine.sync(group: fixture.group)

        let slow = SlowServer(fixture.transport)
        let owner = fixture.owner.engine(through: slow)
        let store = fixture.owner.store

        var edited = budget
        edited.name = "Food"
        try store.save(edited)
        edited.isDeleted = true
        let deleted = edited
        slow.whilePushing = { try store.save(deleted) }

        _ = try await owner.sync(group: fixture.group)
        _ = try await owner.sync(group: fixture.group)

        let leslie = try Peer(transport: fixture.transport)
        try fixture.add(leslie, level: .read, budgets: [budget.id])
        _ = try await leslie.engine.sync(group: fixture.group)
        // Checked on the record itself. An empty list of live budgets would
        // also pass if the budget had never reached her at all.
        let received = try #require(try leslie.store.budget(budget.id), "the budget reached her")
        #expect(received.isDeleted, "the delete reached her")
        #expect(received.name == "Food")
    }

    /// Somebody who has not been given the key for an epoch counts the records and
    /// moves on, rather than crashing or silently skipping them for good.
    @Test func recordsWeHaveNoKeyForAreCountedNotLost() async throws {
        var fixture = try Fixture()
        let budget = try fixture.makeBudget(named: "Groceries")
        try fixture.owner.store.save(Transaction(
            budgetID: budget.id, groupID: fixture.group, date: Date(),
            merchant: "secret", amount: Money(minorUnits: -500)))
        _ = try await fixture.owner.engine.sync(group: fixture.group)

        // Added to the group, but the budget key is deliberately not wrapped.
        let latecomer = try Peer(transport: fixture.transport)
        try fixture.add(latecomer, level: .write, budgets: [])

        let report = try await latecomer.engine.sync(group: fixture.group)
        #expect(report.undecryptable > 0, "the budget and transaction cannot be opened yet")
        #expect(try latecomer.store.transactions(in: budget.id).isEmpty)
    }

    @Test func membershipIsVerifiedNotTrusted() async throws {
        var fixture = try Fixture()
        _ = try fixture.makeBudget(named: "Groceries")

        // A server that invents a member. The forged entry is signed by a key the
        // chain never established, so the replay refuses it.
        let impostor = try Peer(transport: fixture.transport)
        let forged = try MembershipLogEntry.signed(
            scope: .group(fixture.group), sequence: UInt64(fixture.log.count),
            previousHash: fixture.log.last!.hash, action: .add,
            subjectUserID: impostor.userID, subjectKeys: impostor.publicKeys,
            level: .admin, epochAfter: fixture.epoch,
            deviceID: impostor.device.id, devicePublicKey: impostor.device.publicKey,
            author: impostor.identity, authorUserID: impostor.userID   // signing for himself
        )
        fixture.transport.seed(log: fixture.log + [forged], for: fixture.group)

        await #expect(throws: (any Error).self) {
            _ = try await impostor.engine.sync(group: fixture.group)
        }
    }

    @Test func syncingTwiceChangesNothing() async throws {
        var fixture = try Fixture()
        let budget = try fixture.makeBudget(named: "Groceries")
        try fixture.owner.store.save(Transaction(
            budgetID: budget.id, groupID: fixture.group, date: Date(),
            merchant: "once", amount: Money(minorUnits: -100)))

        _ = try await fixture.owner.engine.sync(group: fixture.group)
        let after = try fixture.owner.store.transactions(in: budget.id).count

        let second = try await fixture.owner.engine.sync(group: fixture.group)
        #expect(second.pushed == 0)
        #expect(try fixture.owner.store.transactions(in: budget.id).count == after)
    }

    /// This Mac's own records come back on the next pull. With a version on
    /// file they are echoes, and nothing is weighed. Weighed, each one tied
    /// with itself and lost, and was kept as a conflict copy of itself.
    @Test func ownRecordsComingBackAreEchoes() async throws {
        var fixture = try Fixture()
        let budget = try fixture.makeBudget(named: "Groceries")
        let spent = Transaction(budgetID: budget.id, groupID: fixture.group, date: Date(),
                                merchant: "once", amount: Money(minorUnits: -100))
        try fixture.owner.store.save(spent)
        _ = try await fixture.owner.engine.sync(group: fixture.group)

        let second = try await fixture.owner.engine.sync(group: fixture.group)
        #expect(second.echoes == 3 && second.conflicts == 0, "got \(second)")
        #expect(try fixture.owner.store.conflicts(for: spent.id).isEmpty)
    }

    /// A record whose push reply was lost has no version on file, but its row
    /// is still queued. It is an echo too. Weighed, it tied with its own row
    /// and lost, and was kept as a conflict copy of itself.
    @Test func aRecordWhoseReplyWasLostIsAnEcho() async throws {
        var fixture = try Fixture()
        let budget = try fixture.makeBudget(named: "Groceries")
        _ = try await fixture.owner.engine.sync(group: fixture.group)

        let spent = Transaction(budgetID: budget.id, groupID: fixture.group, date: Date(),
                                merchant: "once", amount: Money(minorUnits: -100))
        try fixture.owner.store.save(spent)
        let lossy = fixture.owner.engine(through: LosingReplies(fixture.transport))
        await #expect(throws: LosingReplies.Lost.self) { try await lossy.sync(group: fixture.group) }
        #expect(try fixture.owner.store.recordVersion(spent.id) == nil)

        let report = try await fixture.owner.engine.sync(group: fixture.group)
        #expect(report.echoes == 1 && report.conflicts == 0, "got \(report)")
        #expect(try fixture.owner.store.conflicts(for: spent.id).isEmpty)
        #expect(try fixture.owner.store.outboxCount(in: fixture.group) == 0, "the resend was taken")
    }

    // MARK: - Who owns a transaction

    /// Sign a record by hand as `peer` and hand it straight to the server, the way
    /// a modified app could, skipping every check on the sending side.
    private func forge<T: Encodable>(_ value: T, id: RecordID, type: RecordType,
                                     budget: BudgetID?, as peer: Peer,
                                     fixture: Fixture, lamport: UInt64 = 10_000,
                                     isDeleted: Bool = false) async throws {
        let scope: KeyScope = budget.map { .budget($0) } ?? .group(fixture.group)
        let envelope = try RecordCodec.sealData(
            try RecordCodec.encoder.encode(value), recordID: id, recordType: type,
            groupID: fixture.group, budgetID: budget,
            scopeKey: try peer.keyRing.key(for: scope, epoch: fixture.epoch),
            lamport: lamport, author: peer.userID, device: peer.device,
            membershipSequence: UInt64(fixture.log.count - 1), isDeleted: isDeleted)
        _ = try await fixture.transport.push([envelope], group: fixture.group)
    }

    @Test func pushingStampsTheOwnerAndPeersSeeIt() async throws {
        var fixture = try Fixture()
        let budget = try fixture.makeBudget(named: "Groceries")
        let transaction = Transaction(budgetID: budget.id, groupID: fixture.group, date: Date(),
                                      merchant: "Hilltop", amount: Money(minorUnits: -1000))
        try fixture.owner.store.save(transaction)
        #expect(transaction.createdBy == nil, "made before anyone pushed it")
        _ = try await fixture.owner.engine.sync(group: fixture.group)

        #expect(try fixture.owner.store.transaction(transaction.id)?.createdBy == fixture.owner.userID)

        let leslie = try Peer(transport: fixture.transport)
        try fixture.add(leslie, level: .write, budgets: [budget.id])
        _ = try await leslie.engine.sync(group: fixture.group)
        #expect(try leslie.store.transaction(transaction.id)?.createdBy == fixture.owner.userID)
    }

    @Test func someoneWhoCanAddChangesTheirOwnButNotOthers() async throws {
        var fixture = try Fixture()
        let budget = try fixture.makeBudget(named: "Groceries")
        let his = Transaction(budgetID: budget.id, groupID: fixture.group, date: Date(),
                              merchant: "his", amount: Money(minorUnits: -1000))
        try fixture.owner.store.save(his)
        _ = try await fixture.owner.engine.sync(group: fixture.group)

        let leslie = try Peer(transport: fixture.transport)
        try fixture.add(leslie, level: .write, budgets: [budget.id])
        _ = try await leslie.engine.sync(group: fixture.group)

        // Her own: added, then edited. He gets both.
        var hers = Transaction(budgetID: budget.id, groupID: fixture.group, date: Date(),
                               merchant: "hers", amount: Money(minorUnits: -500))
        try leslie.store.save(hers)
        _ = try await leslie.engine.sync(group: fixture.group)
        hers = try #require(try leslie.store.transaction(hers.id))
        hers.merchant = "hers, edited"
        try leslie.store.save(hers)
        _ = try await leslie.engine.sync(group: fixture.group)

        // His: she edits it locally. Her device refuses to send that.
        var changed = try #require(try leslie.store.transaction(his.id))
        changed.merchant = "changed by her"
        try leslie.store.save(changed)
        let report = try await leslie.engine.sync(group: fixture.group)
        #expect(report.rejected == 1, "her device does not send an edit nobody would accept")
        #expect(try leslie.store.outboxCount(in: fixture.group) == 0, "and does not try it again")

        _ = try await fixture.owner.engine.sync(group: fixture.group)
        let received = try #require(try fixture.owner.store.transaction(hers.id))
        #expect(received.merchant == "hers, edited")
        #expect(received.createdBy == leslie.userID)
        #expect(try fixture.owner.store.transaction(his.id)?.merchant == "his")
    }

    @Test func aManagerCanChangeAnyones() async throws {
        var fixture = try Fixture()
        let budget = try fixture.makeBudget(named: "Groceries")
        let his = Transaction(budgetID: budget.id, groupID: fixture.group, date: Date(),
                              merchant: "his", amount: Money(minorUnits: -1000))
        try fixture.owner.store.save(his)
        _ = try await fixture.owner.engine.sync(group: fixture.group)

        let leslie = try Peer(transport: fixture.transport)
        try fixture.add(leslie, level: .manage, budgets: [budget.id])
        _ = try await leslie.engine.sync(group: fixture.group)

        var changed = try #require(try leslie.store.transaction(his.id))
        changed.merchant = "fixed by a manager"
        try leslie.store.save(changed)
        _ = try await leslie.engine.sync(group: fixture.group)

        _ = try await fixture.owner.engine.sync(group: fixture.group)
        let received = try #require(try fixture.owner.store.transaction(his.id))
        #expect(received.merchant == "fixed by a manager")
        #expect(received.createdBy == fixture.owner.userID, "editing does not change the owner")
    }

    /// The checks that matter are on the receiving side, because a modified app
    /// can skip the sending side entirely.
    @Test func forgedEditsAndForgedOwnersAreIgnored() async throws {
        var fixture = try Fixture()
        let budget = try fixture.makeBudget(named: "Groceries")
        let his = Transaction(budgetID: budget.id, groupID: fixture.group, date: Date(),
                              merchant: "his", amount: Money(minorUnits: -1000))
        try fixture.owner.store.save(his)
        _ = try await fixture.owner.engine.sync(group: fixture.group)

        let leslie = try Peer(transport: fixture.transport)
        try fixture.add(leslie, level: .write, budgets: [budget.id])
        _ = try await leslie.engine.sync(group: fixture.group)

        // 1. Editing his transaction.
        var edited = try #require(try leslie.store.transaction(his.id))
        edited.merchant = "forged edit"
        try await forge(edited, id: his.id, type: .transaction, budget: budget.id,
                        as: leslie, fixture: fixture)
        #expect(try await fixture.owner.engine.sync(group: fixture.group).ignored == 1)

        // 2. Taking it over by changing the owner. Sent as a newer version,
        // because the same version from the same device is taken as the
        // first forgery sent again, and stores nothing.
        var taken = edited
        taken.createdBy = leslie.userID
        try await forge(taken, id: his.id, type: .transaction, budget: budget.id,
                        as: leslie, fixture: fixture, lamport: 10_001)
        #expect(try await fixture.owner.engine.sync(group: fixture.group).ignored == 1)

        // 3. Adding a new one in his name.
        let framed = Transaction(budgetID: budget.id, groupID: fixture.group, date: Date(),
                                 merchant: "framed", amount: Money(minorUnits: -99_999),
                                 createdBy: fixture.owner.userID)
        try await forge(framed, id: framed.id, type: .transaction, budget: budget.id,
                        as: leslie, fixture: fixture)

        #expect(try await fixture.owner.engine.sync(group: fixture.group).ignored == 1)

        #expect(try fixture.owner.store.transaction(his.id)?.merchant == "his")
        #expect(try fixture.owner.store.transaction(his.id)?.createdBy == fixture.owner.userID)
        #expect(try fixture.owner.store.transaction(framed.id) == nil)
    }

    @Test func onlyYouCanSetYourNameInAGroup() async throws {
        var fixture = try Fixture()
        let budget = try fixture.makeBudget(named: "Groceries")
        _ = try await fixture.owner.engine.sync(group: fixture.group)

        let leslie = try Peer(transport: fixture.transport)
        try fixture.add(leslie, level: .write, budgets: [budget.id])
        _ = try await leslie.engine.sync(group: fixture.group)

        try leslie.store.save(MemberProfile(groupID: fixture.group, userID: leslie.userID,
                                             displayName: "Leslie"))
        _ = try await leslie.engine.sync(group: fixture.group)

        // And a forged one naming him something else. The server refuses it,
        // since it is not on her own profile's ID, so it arrives only through
        // a server that let it through.
        let forged = MemberProfile(groupID: fixture.group, userID: fixture.owner.userID,
                                   displayName: "Not Robin")
        let envelope = try RecordCodec.seal(
            forged, recordID: forged.id, recordType: .memberProfile, groupID: fixture.group,
            budgetID: nil, scopeKey: try leslie.keyRing.key(for: .group(fixture.group), epoch: fixture.epoch),
            lamport: 10_000, author: leslie.userID, device: leslie.device,
            membershipSequence: UInt64(fixture.log.count - 1))
        #expect(try await fixture.transport.push([envelope], group: fixture.group).accepted.isEmpty)
        let server = Smuggling(fixture.transport)
        server.extra = [envelope]

        let report = try await fixture.owner.engine(through: server).sync(group: fixture.group)
        #expect(report.ignored == 1)
        let names = try fixture.owner.store.profiles(in: fixture.group)
        #expect(names.map(\.displayName) == ["Leslie"])
        #expect(names.first?.userID == leslie.userID)
    }

    @Test func aMemberProfileHasTheSameIDOnEveryDevice() {
        let group = GroupID(), user = UserID()
        #expect(MemberProfile.recordID(group: group, user: user)
                    == MemberProfile.recordID(group: group, user: user))
        #expect(MemberProfile.recordID(group: group, user: user)
                    != MemberProfile.recordID(group: group, user: UserID()))
    }

    // MARK: - Record types this build does not know

    /// A newer app adds a kind of record this one has never heard of. Syncing
    /// must carry on, and the record must be kept for after an update.
    @Test func anUnknownRecordTypeIsSetAsideNotFatal() async throws {
        var fixture = try Fixture()
        let budget = try fixture.makeBudget(named: "Groceries")
        _ = try await fixture.owner.engine.sync(group: fixture.group)

        let leslie = try Peer(transport: fixture.transport)
        try fixture.add(leslie, level: .write, budgets: [budget.id])

        let future = RecordType(rawValue: "somethingFromTheFuture")
        let futureID = RecordID()
        let envelope = try RecordCodec.sealData(
            Data("{}".utf8), recordID: futureID, recordType: future, groupID: fixture.group,
            budgetID: nil,
            scopeKey: try fixture.owner.keyRing.key(for: .group(fixture.group), epoch: fixture.epoch),
            lamport: 50, author: fixture.owner.userID, device: fixture.owner.device,
            membershipSequence: UInt64(fixture.log.count - 1))
        _ = try await fixture.transport.push([envelope], group: fixture.group)
        try fixture.owner.store.save(Transaction(budgetID: budget.id, groupID: fixture.group,
                                                 date: Date(), merchant: "after it",
                                                 amount: Money(minorUnits: -100)))
        _ = try await fixture.owner.engine.sync(group: fixture.group)

        let report = try await leslie.engine.sync(group: fixture.group)
        #expect(report.deferred == 1)
        #expect(try leslie.store.transactions(in: budget.id).map(\.merchant) == ["after it"],
                "everything else still arrives")
        let kept = try leslie.store.deferredEnvelopes(in: fixture.group)
        #expect(kept.map(\.0.recordID) == [futureID])
        #expect(kept.first?.0.recordType == future, "kept exactly as it came")
    }

    /// After an update, what an older build set aside is applied, once.
    @Test func setAsideRecordsApplyOnceTheTypeIsKnown() async throws {
        var fixture = try Fixture()
        let budget = try fixture.makeBudget(named: "Groceries")
        _ = try await fixture.owner.engine.sync(group: fixture.group)

        let leslie = try Peer(transport: fixture.transport)
        try fixture.add(leslie, level: .write, budgets: [budget.id])
        _ = try await leslie.engine.sync(group: fixture.group)

        // As an older build would have left it: a record sitting in the
        // set-aside table, in a type this build does know.
        let transaction = Transaction(budgetID: budget.id, groupID: fixture.group, date: Date(),
                                      merchant: "set aside", amount: Money(minorUnits: -100),
                                      createdBy: fixture.owner.userID)
        let envelope = try RecordCodec.seal(
            transaction, recordID: transaction.id, recordType: .transaction,
            groupID: fixture.group, budgetID: budget.id,
            scopeKey: try fixture.owner.keyRing.key(for: .budget(budget.id), epoch: fixture.epoch),
            lamport: 60, author: fixture.owner.userID, device: fixture.owner.device,
            membershipSequence: UInt64(fixture.log.count - 1))
        try leslie.store.deferEnvelope(envelope, serverSeq: 1)

        let report = try await leslie.engine.sync(group: fixture.group)
        #expect(report.applied >= 1)
        #expect(try leslie.store.transaction(transaction.id)?.merchant == "set aside")
        #expect(try leslie.store.deferredEnvelopes(in: fixture.group).isEmpty)
    }

    // MARK: - Deleting a group

    /// Only the group's founder or an admin deletes it for everyone. A delete
    /// from anyone else is ignored when it arrives, even from a server that let
    /// it through, because the receiving side is where the rule has to hold.
    @Test func aGroupDeleteFromBelowAdminIsIgnored() async throws {
        var fixture = try Fixture()
        let budget = try fixture.makeBudget(named: "Groceries")
        _ = try await fixture.owner.engine.sync(group: fixture.group)

        let leslie = try Peer(transport: fixture.transport)
        try fixture.add(leslie, level: .write, budgets: [budget.id])
        _ = try await leslie.engine.sync(group: fixture.group)

        let server = Smuggling(fixture.transport)
        let jamie = try Peer(transport: server)
        try fixture.add(jamie, level: .read, budgets: [budget.id])
        _ = try await jamie.engine.sync(group: fixture.group)
        #expect(try jamie.store.group(fixture.group)?.isDeleted == false)

        var gone = try #require(try leslie.store.group(fixture.group))
        gone.isDeleted = true
        server.extra = [try RecordCodec.seal(
            gone, recordID: RecordID(fixture.group.uuid), recordType: .groupMeta,
            groupID: fixture.group, budgetID: nil,
            scopeKey: try leslie.keyRing.key(for: .group(fixture.group), epoch: fixture.epoch),
            lamport: 10_000, author: leslie.userID, device: leslie.device,
            membershipSequence: UInt64(fixture.log.count - 1), isDeleted: true)]

        let report = try await jamie.engine.sync(group: fixture.group)
        #expect(report.ignored == 1)
        #expect(try jamie.store.group(fixture.group)?.isDeleted == false)
    }

    /// Deleting a group is final. Her rename, newer than anything he had seen,
    /// must not undo his delete on his Mac, and his delete must win on hers
    /// even though her version of the group is ahead of it.
    @Test func aGroupDeleteBeatsANewerEditEverywhere() async throws {
        var fixture = try Fixture()
        let budget = try fixture.makeBudget(named: "Groceries")
        _ = try await fixture.owner.engine.sync(group: fixture.group)
        let leslie = try Peer(transport: fixture.transport)
        try fixture.add(leslie, level: .write, budgets: [budget.id])
        _ = try await leslie.engine.sync(group: fixture.group)

        for name in ["a", "b", "c", "d", "e", "f"] {
            var renamed = try #require(try leslie.store.group(fixture.group))
            renamed.name = name
            try leslie.store.save(renamed)
        }
        _ = try await leslie.engine.sync(group: fixture.group)

        var gone = try #require(try fixture.owner.store.group(fixture.group))
        gone.isDeleted = true
        try fixture.owner.store.save(gone)
        _ = try await fixture.owner.engine.sync(group: fixture.group)
        #expect(try fixture.owner.store.group(fixture.group)?.isDeleted == true,
                "her rename does not bring it back for him")

        _ = try await leslie.engine.sync(group: fixture.group)
        #expect(try leslie.store.group(fixture.group)?.isDeleted == true,
                "his delete wins over her newer rename")

        // And a live record sent after the delete is refused, so a member who
        // syncs later still finds it deleted.
        var late = try #require(try leslie.store.group(fixture.group))
        late.isDeleted = false
        late.name = "back"
        try await forge(late, id: RecordID(fixture.group.uuid), type: .groupMeta, budget: nil,
                        as: leslie, fixture: fixture)
        let stored = try await fixture.transport.pull(group: fixture.group, since: 0, limit: 100)
        #expect(stored.envelopes.first { $0.recordType == .groupMeta }?.isDeleted == true)
    }

    /// A member who reads this group, with a server that can slip records
    /// into his pull, and a second group he belongs to.
    private func readerWithAnotherGroup(_ fixture: inout Fixture)
        async throws -> (jamie: Peer, server: Smuggling, other: GroupID, otherKey: ScopedKey) {
        let budget = try fixture.makeBudget(named: "Groceries")
        _ = try await fixture.owner.engine.sync(group: fixture.group)
        let server = Smuggling(fixture.transport)
        let jamie = try Peer(transport: server)
        try fixture.add(jamie, level: .read, budgets: [budget.id])
        _ = try await jamie.engine.sync(group: fixture.group)

        let other = GroupID()
        let otherKey = ScopedKey.generate(scope: .group(other), epoch: .initial)
        try jamie.keyRing.remember(otherKey)
        try jamie.store.save(BudgetGroup(id: other, name: "Book Club"), queue: false)
        return (jamie, server, other, otherKey)
    }

    /// A server can put another group's record in this group's page. It would
    /// be judged against this group's members, so the founder here could
    /// delete a group of someone else's that he also holds the key to.
    @Test func aRecordForAnotherGroupInThisPullIsIgnored() async throws {
        var fixture = try Fixture()
        let (jamie, server, other, otherKey) = try await readerWithAnotherGroup(&fixture)

        var gone = BudgetGroup(id: other, name: "Book Club")
        gone.isDeleted = true
        server.extra = [try RecordCodec.seal(
            gone, recordID: RecordID(other.uuid), recordType: .groupMeta, groupID: other,
            budgetID: nil, scopeKey: otherKey, lamport: 10_000, author: fixture.owner.userID,
            device: fixture.owner.device, membershipSequence: UInt64(fixture.log.count - 1),
            isDeleted: true)]

        let report = try await jamie.engine.sync(group: fixture.group)
        #expect(report.ignored == 1)
        #expect(try jamie.store.group(other)?.isDeleted == false)
    }

    /// A group record describes the group it travels in. One that names
    /// another group would be judged by this group's members and then saved
    /// over the other group.
    @Test func aGroupRecordDescribingAnotherGroupIsIgnored() async throws {
        var fixture = try Fixture()
        let (jamie, server, other, _) = try await readerWithAnotherGroup(&fixture)

        server.extra = [try RecordCodec.seal(
            BudgetGroup(id: other, name: "Taken"), recordID: RecordID(fixture.group.uuid),
            recordType: .groupMeta, groupID: fixture.group, budgetID: nil,
            scopeKey: try fixture.owner.keyRing.key(for: .group(fixture.group), epoch: fixture.epoch),
            lamport: 10_000, author: fixture.owner.userID, device: fixture.owner.device,
            membershipSequence: UInt64(fixture.log.count - 1))]

        let report = try await jamie.engine.sync(group: fixture.group)
        #expect(report.ignored == 1)
        #expect(try jamie.store.group(other)?.name == "Book Club")
    }

    /// Only the group's own record may use the group's ID. A record of any
    /// other type on it is refused when it arrives.
    @Test func anotherRecordOnTheGroupsIDIsIgnored() async throws {
        var fixture = try Fixture()
        let (jamie, server, _, _) = try await readerWithAnotherGroup(&fixture)

        let taken = Budget(id: BudgetID(fixture.group.uuid), groupID: fixture.group, name: "Taken",
                           limit: Money(minorUnits: 1))
        server.extra = [try RecordCodec.seal(
            taken, recordID: RecordID(fixture.group.uuid), recordType: .budget,
            groupID: fixture.group, budgetID: nil,
            scopeKey: try fixture.owner.keyRing.key(for: .group(fixture.group), epoch: fixture.epoch),
            lamport: 10_000, author: fixture.owner.userID, device: fixture.owner.device,
            membershipSequence: UInt64(fixture.log.count - 1))]

        let report = try await jamie.engine.sync(group: fixture.group)
        #expect(report.ignored == 1)
        #expect(try jamie.store.budget(taken.id) == nil)
    }

    /// The in-memory server refuses what the real one refuses: another type
    /// of record on the group's ID, and a group record pushed through some
    /// other group.
    @Test func theFakeServerKeepsTheGroupsRecordToItself() async throws {
        var fixture = try Fixture()
        _ = try fixture.makeBudget(named: "Groceries")
        _ = try await fixture.owner.engine.sync(group: fixture.group)
        let key = try fixture.owner.keyRing.key(for: .group(fixture.group), epoch: fixture.epoch)
        let sequence = UInt64(fixture.log.count - 1)

        let other = try RecordCodec.sealData(
            Data("{}".utf8), recordID: RecordID(fixture.group.uuid),
            recordType: RecordType(rawValue: "somethingElse"), groupID: fixture.group,
            budgetID: nil, scopeKey: key, lamport: 10_000, author: fixture.owner.userID,
            device: fixture.owner.device, membershipSequence: sequence, isDeleted: true)
        var elsewhere = BudgetGroup(id: GroupID(), name: "Someone else's")
        elsewhere.isDeleted = true
        let through = try RecordCodec.seal(
            elsewhere, recordID: RecordID(elsewhere.id.uuid), recordType: .groupMeta,
            groupID: fixture.group, budgetID: nil, scopeKey: key, lamport: 10_000,
            author: fixture.owner.userID, device: fixture.owner.device,
            membershipSequence: sequence, isDeleted: true)

        let result = try await fixture.transport.push([other, through], group: fixture.group)
        #expect(result.accepted.isEmpty)
        #expect(result.rejected.count == 2)
    }

    /// A group this Mac holds as deleted stays deleted when a live record of
    /// it arrives, even with no version on file to compare. That is a waiting
    /// group turned down here while a pull was already on its way.
    @Test func aLiveGroupRecordDoesNotUndoADeleteWithNoVersion() async throws {
        var fixture = try Fixture()
        let budget = try fixture.makeBudget(named: "Groceries")
        _ = try await fixture.owner.engine.sync(group: fixture.group)
        let jamie = try Peer(transport: fixture.transport)
        try fixture.add(jamie, level: .read, budgets: [budget.id])
        var turnedDown = BudgetGroup(id: fixture.group, name: "Household")
        turnedDown.isDeleted = true
        try jamie.store.save(turnedDown, queue: false)

        let report = try await jamie.engine.sync(group: fixture.group)
        #expect(report.conflicts == 1)
        #expect(try jamie.store.group(fixture.group)?.isDeleted == true)
    }

    /// The group's own record must use the group's ID. One on any other ID
    /// has no version here to lose to, so it would rename the group however
    /// old it was.
    @Test func aGroupRecordOnAnotherIDIsIgnored() async throws {
        var fixture = try Fixture()
        let (jamie, server, _, _) = try await readerWithAnotherGroup(&fixture)

        server.extra = [try RecordCodec.seal(
            BudgetGroup(id: fixture.group, name: "Taken"), recordID: RecordID(),
            recordType: .groupMeta, groupID: fixture.group, budgetID: nil,
            scopeKey: try fixture.owner.keyRing.key(for: .group(fixture.group), epoch: fixture.epoch),
            lamport: 1, author: fixture.owner.userID, device: fixture.owner.device,
            membershipSequence: UInt64(fixture.log.count - 1))]

        let report = try await jamie.engine.sync(group: fixture.group)
        #expect(report.ignored == 1)
        #expect(try jamie.store.group(fixture.group)?.name == "Household")
    }

    /// The in-memory server finds a stored record by its ID alone, as the
    /// real one does. A record pushed as another type, or into another group,
    /// must not change the one it finds.
    @Test func theFakeServerKeepsAStoredRecordToItsGroupAndType() async throws {
        var fixture = try Fixture()
        let budget = try fixture.makeBudget(named: "Groceries")
        _ = try await fixture.owner.engine.sync(group: fixture.group)

        // A second group, which anyone may found.
        let other = GroupID()
        fixture.transport.seed(log: [try MembershipLogEntry.signed(
            scope: .group(other), sequence: 0, previousHash: MembershipLogEntry.rootHash,
            action: .found, subjectUserID: fixture.owner.userID,
            subjectKeys: fixture.owner.publicKeys, level: .superadmin, epochAfter: .initial,
            deviceID: fixture.owner.device.id, devicePublicKey: fixture.owner.device.publicKey,
            author: fixture.owner.identity, authorUserID: fixture.owner.userID)], for: other)
        let key = try fixture.owner.keyRing.key(for: .budget(budget.id), epoch: fixture.epoch)
        func envelope(_ type: RecordType, in group: GroupID) throws -> RecordEnvelope {
            try RecordCodec.seal(
                budget, recordID: RecordID(budget.id.uuid), recordType: type, groupID: group,
                budgetID: budget.id, scopeKey: key, lamport: 10_000, author: fixture.owner.userID,
                device: fixture.owner.device, membershipSequence: 0, isDeleted: true)
        }

        let asAnotherType = try await fixture.transport.push([try envelope(.transaction, in: fixture.group)],
                                                             group: fixture.group)
        let intoAnotherGroup = try await fixture.transport.push([try envelope(.budget, in: other)],
                                                                group: other)
        for result in [asAnotherType, intoAnotherGroup] {
            #expect(result.accepted.isEmpty)
            #expect(result.rejected[RecordID(budget.id.uuid)] == "another record already has this ID")
        }
    }

    // MARK: - A second founding entry

    /// A member who can only view appends a founding entry naming herself,
    /// and a server lets it through. Every app replays the log for itself, so
    /// it refuses the log, and with it the group delete her new rank allowed.
    @Test func aSecondFoundingEntryIsRefusedByEveryApp() async throws {
        var fixture = try Fixture()
        let budget = try fixture.makeBudget(named: "Groceries")
        _ = try await fixture.owner.engine.sync(group: fixture.group)
        let mallory = try Peer(transport: fixture.transport)
        try fixture.add(mallory, level: .read, budgets: [budget.id])
        _ = try await mallory.engine.sync(group: fixture.group)
        let server = Smuggling(fixture.transport)
        let jamie = try Peer(transport: server)
        try fixture.add(jamie, level: .read, budgets: [budget.id])
        _ = try await jamie.engine.sync(group: fixture.group)

        let sequence = UInt64(fixture.log.count)
        fixture.transport.append(try MembershipLogEntry.signed(
            scope: .group(fixture.group), sequence: sequence, previousHash: fixture.log.last!.hash,
            action: .found, subjectUserID: mallory.userID, subjectKeys: mallory.publicKeys,
            level: .superadmin, epochAfter: fixture.epoch,
            deviceID: mallory.device.id, devicePublicKey: mallory.device.publicKey,
            author: mallory.identity, authorUserID: mallory.userID), to: fixture.group)
        var gone = try #require(try mallory.store.group(fixture.group))
        gone.isDeleted = true
        server.extra = [try RecordCodec.seal(
            gone, recordID: RecordID(fixture.group.uuid), recordType: .groupMeta,
            groupID: fixture.group, budgetID: nil,
            scopeKey: try mallory.keyRing.key(for: .group(fixture.group), epoch: fixture.epoch),
            lamport: 10_000, author: mallory.userID, device: mallory.device,
            membershipSequence: sequence, isDeleted: true)]

        let refused = SyncError.membershipRefused(
            String(describing: MembershipLogError.foundingEntryNotFirst(atSequence: sequence)))
        await #expect(throws: refused) { _ = try await jamie.engine.sync(group: fixture.group) }
        #expect(try jamie.store.group(fixture.group)?.isDeleted == false)
        #expect(try jamie.store.membershipLog(for: fixture.group).count == fixture.log.count,
                "her entry is not kept")
    }

    // MARK: - What is sealed inside an envelope

    /// Someone who can add sends his transaction under a fresh ID, with no
    /// owner and the delete flag set. The server takes any fresh ID. His Mac
    /// judged ownership by that ID, found nothing, made her the owner, and
    /// saved the record inside over his.
    @Test func aTransactionCannotBeTakenOverUnderAFreshID() async throws {
        var fixture = try Fixture()
        let budget = try fixture.makeBudget(named: "Groceries")
        let his = Transaction(budgetID: budget.id, groupID: fixture.group, date: Date(),
                              merchant: "Hilltop", amount: Money(minorUnits: -1000))
        try fixture.owner.store.save(his)
        _ = try await fixture.owner.engine.sync(group: fixture.group)

        let leslie = try Peer(transport: fixture.transport)
        try fixture.add(leslie, level: .write, budgets: [budget.id])
        _ = try await leslie.engine.sync(group: fixture.group)

        var taken = try #require(try leslie.store.transaction(his.id))
        taken.createdBy = nil
        try await forge(taken, id: RecordID(), type: .transaction, budget: budget.id,
                        as: leslie, fixture: fixture, isDeleted: true)

        let report = try await fixture.owner.engine.sync(group: fixture.group)
        #expect(report.ignored == 1)
        let kept = try #require(try fixture.owner.store.transaction(his.id))
        #expect(!kept.isDeleted)
        #expect(kept.createdBy == fixture.owner.userID)
    }

    /// Mallory can only view Household, and she founded Book Club, which Robin
    /// joined. Through Book Club, where she may do anything, she sends a budget
    /// under a fresh ID whose contents are Household's Groceries, deleted. It
    /// was judged by Book Club's members and saved over Groceries.
    @Test func aBudgetSentThroughAnotherGroupCannotOverwriteThisOne() async throws {
        var fixture = try Fixture()
        let budget = try fixture.makeBudget(named: "Groceries")
        _ = try await fixture.owner.engine.sync(group: fixture.group)
        let mallory = try Peer(transport: fixture.transport)
        try fixture.add(mallory, level: .read, budgets: [budget.id])
        _ = try await mallory.engine.sync(group: fixture.group)
        let club = try bookClub(foundedBy: mallory, members: [fixture.owner], on: fixture.transport)

        var gone = try #require(try mallory.store.budget(budget.id))
        gone.isDeleted = true
        let envelope = try RecordCodec.seal(
            gone, recordID: RecordID(), recordType: .budget, groupID: club.group, budgetID: nil,
            scopeKey: club.key, lamport: 10_000, author: mallory.userID, device: mallory.device,
            membershipSequence: 1, isDeleted: true)
        #expect(try await fixture.transport.push([envelope], group: club.group).accepted
                    == [envelope.recordID], "the server cannot see inside it")

        let report = try await fixture.owner.engine.sync(group: club.group)
        #expect(report.ignored == 1)
        let kept = try #require(try fixture.owner.store.budget(budget.id))
        #expect(!kept.isDeleted)
        #expect(kept.groupID == fixture.group)
    }

    /// A server that reuses IDs. Two Book Club records arrive on Groceries' ID
    /// at a Lamport value no real edit will pass, one with Household's
    /// contents and one moved into Book Club, and a budget arrives on
    /// Household's own ID. Each one either moved a record or took over its
    /// version, so the owner's later renames were kept as conflicts.
    @Test func aRecordReusingAnIDFromAnotherGroupIsIgnored() async throws {
        var fixture = try Fixture()
        let budget = try fixture.makeBudget(named: "Groceries")
        _ = try await fixture.owner.engine.sync(group: fixture.group)
        let mallory = try Peer(transport: fixture.transport)
        try fixture.add(mallory, level: .read, budgets: [budget.id])
        _ = try await mallory.engine.sync(group: fixture.group)
        let server = Smuggling(fixture.transport)
        let jamie = try Peer(transport: server)
        try fixture.add(jamie, level: .read, budgets: [budget.id])
        _ = try await jamie.engine.sync(group: fixture.group)
        let club = try bookClub(foundedBy: mallory, members: [jamie], on: fixture.transport)

        var hijacked = try #require(try mallory.store.budget(budget.id))
        hijacked.name = "Hijacked"
        var moved = hijacked
        moved.groupID = club.group
        let onTheGroupsID = Budget(id: BudgetID(fixture.group.uuid), groupID: club.group,
                                   name: "Taken", limit: Money(minorUnits: 1))
        let budgetKey = try mallory.keyRing.key(for: .budget(budget.id), epoch: fixture.epoch)
        func smuggle(_ value: Budget, on id: UUID, budgetID: BudgetID?, key: ScopedKey) throws
            -> RecordEnvelope {
            try RecordCodec.seal(
                value, recordID: RecordID(id), recordType: .budget, groupID: club.group,
                budgetID: budgetID, scopeKey: key, lamport: 1 << 60, author: mallory.userID,
                device: mallory.device, membershipSequence: 1)
        }
        server.extra = [
            try smuggle(hijacked, on: budget.id.uuid, budgetID: budget.id, key: budgetKey),
            try smuggle(moved, on: budget.id.uuid, budgetID: budget.id, key: budgetKey),
            try smuggle(onTheGroupsID, on: fixture.group.uuid, budgetID: nil, key: club.key),
        ]
        #expect(try await jamie.engine.sync(group: club.group).ignored == 3)

        var renamed = try #require(try fixture.owner.store.budget(budget.id))
        renamed.name = "Food"
        try fixture.owner.store.save(renamed)
        var home = try #require(try fixture.owner.store.group(fixture.group))
        home.name = "Home"
        try fixture.owner.store.save(home)
        _ = try await fixture.owner.engine.sync(group: fixture.group)

        let report = try await jamie.engine.sync(group: fixture.group)
        #expect(report.conflicts == 0)
        let kept = try #require(try jamie.store.budget(budget.id))
        #expect(kept.name == "Food")
        #expect(kept.groupID == fixture.group)
        #expect(try jamie.store.group(fixture.group)?.name == "Home")
    }

    /// A transaction is shown in the budget it names. One sent to Household
    /// naming a Book Club budget was judged by Household's members and then
    /// shown in Book Club, where its sender can only view.
    @Test func aTransactionNamingAnotherGroupsBudgetIsIgnored() async throws {
        var fixture = try Fixture()
        let budget = try fixture.makeBudget(named: "Groceries")
        _ = try await fixture.owner.engine.sync(group: fixture.group)
        let mallory = try Peer(transport: fixture.transport)
        try fixture.add(mallory, level: .write, budgets: [budget.id])
        _ = try await mallory.engine.sync(group: fixture.group)
        let leslie = try Peer(transport: fixture.transport)
        let club = try bookClub(foundedBy: leslie, members: [mallory, fixture.owner],
                                on: fixture.transport)

        let novels = Budget(groupID: club.group, name: "Novels", limit: Money(minorUnits: 5_000))
        let novelsKey = ScopedKey.generate(scope: .budget(novels.id), epoch: .initial)
        try leslie.keyRing.remember(novelsKey)
        fixture.transport.seed(keys: [try KeyWrap.wrapUnderGroupKey(
            novelsKey, groupKey: club.key.material, senderUserID: leslie.userID)], for: club.group)
        try leslie.store.save(BudgetGroup(id: club.group, name: "Book Club"))
        try leslie.store.save(novels)
        _ = try await leslie.engine.sync(group: club.group)
        _ = try await fixture.owner.engine.sync(group: club.group)
        _ = try await mallory.engine.sync(group: club.group)
        #expect(try fixture.owner.store.budget(novels.id)?.name == "Novels")

        let filed = Transaction(budgetID: novels.id, groupID: fixture.group, date: Date(),
                                merchant: "Filed elsewhere", amount: Money(minorUnits: -100))
        try await forge(filed, id: filed.id, type: .transaction, budget: novels.id,
                        as: mallory, fixture: fixture)

        let report = try await fixture.owner.engine.sync(group: fixture.group)
        #expect(report.ignored == 1)
        #expect(try fixture.owner.store.transactions(in: novels.id).isEmpty)
    }

    /// Every kind of record an honest app sends is taken whole by the others.
    @Test func everyKindOfRecordArrivesWhole() async throws {
        var fixture = try Fixture()
        let budget = try fixture.makeBudget(named: "Groceries")
        let owner = fixture.owner!
        try owner.store.save(Transaction(budgetID: budget.id, groupID: fixture.group, date: Date(),
                                         merchant: "Hilltop", amount: Money(minorUnits: -100)))
        try owner.store.save(Receipt(groupID: fixture.group, budgetID: budget.id, filename: "a.jpg",
                                     byteCount: 1, plaintextSHA256: Data([1])))
        try owner.store.save(Receipt(groupID: fixture.group, filename: "b.jpg", byteCount: 1,
                                     plaintextSHA256: Data([2])))
        try owner.store.save(ImportedStatement(groupID: fixture.group, filename: "march.csv",
                                               format: "csv"))
        try owner.store.save(MemberProfile(groupID: fixture.group, userID: owner.userID,
                                           displayName: "Robin"))
        #expect(try await owner.engine.sync(group: fixture.group).pushed == 7)

        let leslie = try Peer(transport: fixture.transport)
        try fixture.add(leslie, level: .write, budgets: [budget.id])
        let report = try await leslie.engine.sync(group: fixture.group)
        #expect(report.applied == 7)
        #expect(report.ignored == 0)
    }

    /// A record can change under its queued row: a pull can save a newer
    /// version that names another budget without queueing anything. The
    /// envelope is sealed for the budget the record is in now, or every
    /// other member would refuse it.
    @Test func anEnvelopeNamesTheBudgetItsRecordIsIn() async throws {
        var fixture = try Fixture()
        let groceries = try fixture.makeBudget(named: "Groceries")
        let eatingOut = Budget(groupID: fixture.group, name: "Eating out", limit: Money(minorUnits: 1))
        try fixture.owner.keyRing.remember(ScopedKey.generate(scope: .budget(eatingOut.id),
                                                              epoch: fixture.epoch))
        try fixture.owner.store.save(eatingOut)
        var transaction = Transaction(budgetID: groceries.id, groupID: fixture.group, date: Date(),
                                      merchant: "Sunrise Cafe", amount: Money(minorUnits: -100))
        try fixture.owner.store.save(transaction)
        transaction.budgetID = eatingOut.id
        try fixture.owner.store.save(transaction, queue: false)
        _ = try await fixture.owner.engine.sync(group: fixture.group)

        let sent = try await fixture.transport.pull(group: fixture.group, since: 0, limit: 100)
        #expect(sent.envelopes.first { $0.recordID == transaction.id }?.budgetID == eatingOut.id)

        let leslie = try Peer(transport: fixture.transport)
        try fixture.add(leslie, level: .write, budgets: [groceries.id, eatingOut.id])
        _ = try await leslie.engine.sync(group: fixture.group)
        #expect(try leslie.store.transactions(in: eatingOut.id).map(\.merchant) == ["Sunrise Cafe"])
    }

    // MARK: - Budgets take a manager

    /// Add is for transactions. A budget change from someone at Add is not
    /// sent, the server refuses it, and a member's app ignores one a server
    /// let through. A manager's change goes everywhere.
    @Test func onlyAManagerChangesABudget() async throws {
        var fixture = try Fixture()
        let budget = try fixture.makeBudget(named: "Groceries")
        _ = try await fixture.owner.engine.sync(group: fixture.group)
        let leslie = try Peer(transport: fixture.transport)
        try fixture.add(leslie, level: .write, budgets: [budget.id])
        _ = try await leslie.engine.sync(group: fixture.group)
        let server = Smuggling(fixture.transport)
        let jamie = try Peer(transport: server)
        try fixture.add(jamie, level: .read, budgets: [budget.id])
        _ = try await jamie.engine.sync(group: fixture.group)

        // Her app does not send it.
        var hers = try #require(try leslie.store.budget(budget.id))
        hers.isDeleted = true
        try leslie.store.save(hers)
        let report = try await leslie.engine.sync(group: fixture.group)
        #expect(report.pushed == 0)
        #expect(report.rejected == 1)
        #expect(try leslie.store.outboxCount(in: fixture.group) == 0)

        // The server refuses it when a modified app sends it anyway.
        let key = try leslie.keyRing.key(for: .budget(budget.id), epoch: fixture.epoch)
        let forged = try RecordCodec.seal(
            hers, recordID: RecordID(budget.id.uuid), recordType: .budget, groupID: fixture.group,
            budgetID: budget.id, scopeKey: key, lamport: 10_000, author: leslie.userID,
            device: leslie.device, membershipSequence: UInt64(fixture.log.count - 1), isDeleted: true)
        let refused = try await fixture.transport.push([forged], group: fixture.group)
        #expect(refused.rejected[forged.recordID] == "only a manager can change a budget")

        // A member's app ignores it when a server lets it through.
        server.extra = [forged]
        #expect(try await jamie.engine.sync(group: fixture.group).ignored == 1)
        #expect(try jamie.store.budget(budget.id)?.isDeleted == false)

        // A manager's change goes everywhere.
        let manager = try Peer(transport: fixture.transport)
        try fixture.add(manager, level: .manage, budgets: [budget.id])
        _ = try await manager.engine.sync(group: fixture.group)
        var renamed = try #require(try manager.store.budget(budget.id))
        renamed.name = "Food"
        try manager.store.save(renamed)
        #expect(try await manager.engine.sync(group: fixture.group).pushed == 1)
        _ = try await jamie.engine.sync(group: fixture.group)
        #expect(try jamie.store.budget(budget.id)?.name == "Food")
    }

    // MARK: - Member profile IDs

    /// A member profile's ID is worked out from the group and the person, so
    /// Mallory can work out Jamie's before he joins. The in-memory server, as
    /// the real one does, keeps that ID for his own profile: nothing else may
    /// take it, in any group, and his profile still goes through.
    @Test func theFakeServerKeepsAProfileIDForItsOwner() async throws {
        var fixture = try Fixture()
        let budget = try fixture.makeBudget(named: "Groceries")
        _ = try await fixture.owner.engine.sync(group: fixture.group)
        let mallory = try Peer(transport: fixture.transport)
        let jamie = try Peer(transport: fixture.transport)
        let club = try bookClub(foundedBy: mallory, members: [], on: fixture.transport)

        let jamies = MemberProfile.recordID(group: fixture.group, user: jamie.userID)
        let squat = MemberProfile(groupID: fixture.group, userID: jamie.userID, displayName: "Taken")
        func envelope(_ type: RecordType) throws -> RecordEnvelope {
            try RecordCodec.seal(
                squat, recordID: jamies, recordType: type, groupID: club.group, budgetID: nil,
                scopeKey: club.key, lamport: 1, author: mallory.userID, device: mallory.device,
                membershipSequence: 0)
        }
        for type in [RecordType.transaction, .memberProfile] {
            let refused = try await fixture.transport.push([try envelope(type)], group: club.group)
            #expect(refused.rejected[jamies] == "that ID belongs to a member profile")
        }

        try fixture.add(jamie, level: .write, budgets: [budget.id])
        _ = try await jamie.engine.sync(group: fixture.group)
        try jamie.store.save(MemberProfile(groupID: fixture.group, userID: jamie.userID,
                                           displayName: "Jamie"))
        let report = try await jamie.engine.sync(group: fixture.group)
        #expect(report.pushed == 1)
        #expect(report.rejected == 0)
    }
}

/// Book Club: a second group that `founder` made, with `members` added at
/// View and its key sealed to each of them. Their Macs already show it.
private func bookClub(foundedBy founder: Peer, members: [Peer], on transport: InMemoryTransport)
    throws -> (group: GroupID, key: ScopedKey) {
    let group = GroupID()
    var log = [try MembershipLogEntry.signed(
        scope: .group(group), sequence: 0, previousHash: MembershipLogEntry.rootHash,
        action: .found, subjectUserID: founder.userID, subjectKeys: founder.publicKeys,
        level: .superadmin, epochAfter: .initial,
        deviceID: founder.device.id, devicePublicKey: founder.device.publicKey,
        author: founder.identity, authorUserID: founder.userID)]
    for member in members {
        log.append(try MembershipLogEntry.signed(
            scope: .group(group), sequence: UInt64(log.count), previousHash: log.last!.hash,
            action: .add, subjectUserID: member.userID, subjectKeys: member.publicKeys,
            level: .read, epochAfter: .initial,
            deviceID: member.device.id, devicePublicKey: member.device.publicKey,
            author: founder.identity, authorUserID: founder.userID))
    }
    transport.seed(log: log, for: group)

    let key = ScopedKey.generate(scope: .group(group), epoch: .initial)
    try founder.keyRing.remember(key)
    for member in members {
        transport.seed(keys: [try KeyWrap.wrapToIdentity(
            key, recipient: member.publicKeys, recipientUserID: member.userID,
            sender: founder.identity, senderUserID: founder.userID)], for: group)
        try member.store.save(BudgetGroup(id: group, name: "Book Club"), queue: false)
    }
    return (group, key)
}

/// A server that also serves whatever a test hands it, the way a server
/// that skips a rule, or an older one, could.
private final class Smuggling: SyncTransport, @unchecked Sendable {
    let inner: InMemoryTransport
    var extra: [RecordEnvelope] = []

    init(_ inner: InMemoryTransport) { self.inner = inner }

    func push(_ envelopes: [RecordEnvelope], group: GroupID) async throws -> PushResult {
        try await inner.push(envelopes, group: group)
    }
    func pull(group: GroupID, since: UInt64, limit: Int) async throws -> PullResult {
        let page = try await inner.pull(group: group, since: since, limit: limit)
        defer { extra = [] }
        return PullResult(envelopes: page.envelopes + extra, serverSeq: page.serverSeq,
                          hasMore: page.hasMore)
    }
    func membershipLog(group: GroupID, since: UInt64) async throws -> [MembershipLogEntry] {
        try await inner.membershipLog(group: group, since: since)
    }
    func wrappedKeys(group: GroupID, for user: UserID) async throws -> [WrappedKey] {
        try await inner.wrappedKeys(group: group, for: user)
    }
}
