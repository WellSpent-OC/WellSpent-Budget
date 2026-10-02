import Testing
import Foundation
import Crypto
@testable import WellSpentSync
@testable import WellSpentCrypto
import GRDB
import WellSpentModel
import WellSpentStore

/// One person on one device, with the whole client, over a shared in-memory
/// server. Their engine pulls through `leak`, which can also hand over records
/// the server never stored, the way a server that skips a rule could.
private final class Member {
    let userID: UserID
    let identity = IdentityKeyPair.generate()
    let device: DeviceKeyPair
    let store: Store
    let keyRing: KeyRing
    let session: InMemorySession
    let leak: Leak
    let engine: SyncEngine
    let sharing: Sharing

    init(server: InMemoryTransport, userID: UserID = UserID(), device: DeviceKeyPair = DeviceKeyPair(),
         database: WellSpentDatabase? = nil) throws {
        self.userID = userID
        self.device = device
        store = Store(database: try database ?? WellSpentDatabase.inMemory())
        keyRing = KeyRing(store: store, identity: identity, userID: userID)
        session = server.session(for: userID, keys: identity.publicKeys)
        leak = Leak(session)
        engine = SyncEngine(store: store, keyRing: keyRing, transport: leak,
                            identity: identity, device: device, userID: userID)
        sharing = Sharing(store: store, keyRing: keyRing, transport: session,
                          identity: identity, device: device, userID: userID)
    }

    /// What the app does for a group made on this device: found it on the
    /// server and mint its keys.
    func found(_ group: GroupID, name: String, budgets: [Budget] = []) async throws {
        let founding = try MembershipLogEntry.signed(
            scope: .group(group), sequence: 0, previousHash: MembershipLogEntry.rootHash,
            action: .found, subjectUserID: userID, subjectKeys: identity.publicKeys,
            level: .superadmin, epochAfter: .initial,
            deviceID: device.id, devicePublicKey: device.publicKey,
            author: identity, authorUserID: userID)
        try await session.appendMembership(founding, group: group, wrappedKeys: [])
        try keyRing.remember(ScopedKey.generate(scope: .group(group), epoch: .initial))
        try store.save(BudgetGroup(id: group, name: name))
        for budget in budgets {
            try keyRing.remember(ScopedKey.generate(scope: .budget(budget.id), epoch: .initial))
            try store.save(budget)
        }
    }

    /// What the app does on every sync of a group.
    @discardableResult
    func sync(_ group: GroupID) async throws -> SyncReport {
        try await sharing.prepare(group: group)
        try await sharing.finishInvites(group: group)
        var report = try await engine.sync(group: group)
        if try await sharing.completeJoin(group: group) {
            report = try await engine.sync(group: group)
        }
        return report
    }

    /// Asks `owner` for a link to `group`, answers it, and syncs both apps
    /// until this person is in.
    func join(_ group: GroupID, from owner: Member, level: AccessLevel,
              history: HistoryAccess = .all) async throws {
        let link = try await owner.sharing.createInvite(
            group: group, groupName: "Household", level: level, historyAccess: history,
            inviterName: "Robin")
        try await sharing.join(link, displayName: "Someone")
        try await owner.sync(group)
        try await sync(group)
    }

    func spend(_ merchant: String, in budget: Budget) throws -> Transaction {
        let transaction = Transaction(budgetID: budget.id, groupID: budget.groupID, date: Date(),
                                      merchant: merchant, amount: Money(minorUnits: -1000))
        try store.save(transaction)
        return transaction
    }

    func keyBytes(_ scope: KeyScope, _ epoch: Epoch = .initial) throws -> Data {
        try keyRing.key(for: scope, epoch: epoch).rawBytes
    }

    /// The access history as the server holds it now.
    func membership(of group: GroupID) async throws -> (log: [MembershipLogEntry], state: MembershipState) {
        let log = try await session.membershipLog(group: group, since: 0)
        return (log, try MembershipLog.replay(log, scope: .group(group)))
    }

    /// A record sealed by hand and signed on this device, the way a modified
    /// app could.
    func forge<T: Encodable>(_ value: T, id: RecordID, type: RecordType, group: GroupID,
                             budget: BudgetID?, lamport: UInt64 = 10_000) throws -> RecordEnvelope {
        let scope: KeyScope = budget.map { .budget($0) } ?? .group(group)
        return try RecordCodec.seal(
            value, recordID: id, recordType: type, groupID: group, budgetID: budget,
            scopeKey: try keyRing.key(for: scope, epoch: .initial), lamport: lamport,
            author: userID, device: device, membershipSequence: 0)
    }
}

/// A connection that also serves whatever a test hands it, on the next pull.
private final class Leak: SyncTransport, @unchecked Sendable {
    let inner: any SyncTransport
    var extra: [RecordEnvelope] = []

    init(_ inner: any SyncTransport) { self.inner = inner }

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

/// A connection whose membership calls all fail, as when the server refuses
/// the entry or the network drops.
private final class RefusingEntries: InviteTransport, @unchecked Sendable {
    struct Refused: Error {}
    let inner: InMemorySession

    init(_ inner: InMemorySession) { self.inner = inner }

    func appendMembership(_ entry: MembershipLogEntry, group: GroupID,
                          wrappedKeys: [WrappedKey]) async throws {
        throw Refused()
    }
    func push(_ envelopes: [RecordEnvelope], group: GroupID) async throws -> PushResult {
        try await inner.push(envelopes, group: group)
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
    func createInvite(_ invite: NewInvite) async throws { try await inner.createInvite(invite) }
    func lookupInvite(id: Data) async throws -> InviteLookup { try await inner.lookupInvite(id: id) }
    func acceptInvite(id: Data, sealed: SealedAcceptance) async throws {
        try await inner.acceptInvite(id: id, sealed: sealed)
    }
    func invites(in group: GroupID) async throws -> [PendingInvite] { try await inner.invites(in: group) }
    func deleteInvite(id: Data) async throws { try await inner.deleteInvite(id: id) }
    func uploadKeys(_ keys: [WrappedKey], group: GroupID) async throws {
        try await inner.uploadKeys(keys, group: group)
    }
}

/// A connection that answers a read of the whole log with a made-up chain,
/// and hands over extra keys, the way a server that lies could. A read that
/// extends a log already held gets the real entries.
private final class LyingLog: InviteTransport, @unchecked Sendable {
    let inner: InMemorySession
    let madeUp: [MembershipLogEntry]
    let extraKeys: [WrappedKey]

    init(_ inner: InMemorySession, madeUp: [MembershipLogEntry], extraKeys: [WrappedKey]) {
        self.inner = inner
        self.madeUp = madeUp
        self.extraKeys = extraKeys
    }

    func membershipLog(group: GroupID, since: UInt64) async throws -> [MembershipLogEntry] {
        since == 0 ? madeUp : try await inner.membershipLog(group: group, since: since)
    }
    func wrappedKeys(group: GroupID, for user: UserID) async throws -> [WrappedKey] {
        try await inner.wrappedKeys(group: group, for: user) + extraKeys
    }
    func appendMembership(_ entry: MembershipLogEntry, group: GroupID,
                          wrappedKeys: [WrappedKey]) async throws {
        try await inner.appendMembership(entry, group: group, wrappedKeys: wrappedKeys)
    }
    func push(_ envelopes: [RecordEnvelope], group: GroupID) async throws -> PushResult {
        try await inner.push(envelopes, group: group)
    }
    func pull(group: GroupID, since: UInt64, limit: Int) async throws -> PullResult {
        try await inner.pull(group: group, since: since, limit: limit)
    }
    func createInvite(_ invite: NewInvite) async throws { try await inner.createInvite(invite) }
    func lookupInvite(id: Data) async throws -> InviteLookup { try await inner.lookupInvite(id: id) }
    func acceptInvite(id: Data, sealed: SealedAcceptance) async throws {
        try await inner.acceptInvite(id: id, sealed: sealed)
    }
    func invites(in group: GroupID) async throws -> [PendingInvite] { try await inner.invites(in: group) }
    func deleteInvite(id: Data) async throws { try await inner.deleteInvite(id: id) }
    func uploadKeys(_ keys: [WrappedKey], group: GroupID) async throws {
        try await inner.uploadKeys(keys, group: group)
    }
}

/// A connection that lets `first` run once, just before the first add it
/// sends, the way another member's entry can reach the server first.
private final class Racing: InviteTransport, @unchecked Sendable {
    let inner: InMemorySession
    var first: (() async throws -> Void)?
    init(_ inner: InMemorySession) { self.inner = inner }

    func appendMembership(_ entry: MembershipLogEntry, group: GroupID,
                          wrappedKeys: [WrappedKey]) async throws {
        if entry.action == .add, let run = first {
            first = nil
            try await run()
        }
        try await inner.appendMembership(entry, group: group, wrappedKeys: wrappedKeys)
    }
    func push(_ envelopes: [RecordEnvelope], group: GroupID) async throws -> PushResult {
        try await inner.push(envelopes, group: group)
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
    func createInvite(_ invite: NewInvite) async throws { try await inner.createInvite(invite) }
    func lookupInvite(id: Data) async throws -> InviteLookup { try await inner.lookupInvite(id: id) }
    func acceptInvite(id: Data, sealed: SealedAcceptance) async throws {
        try await inner.acceptInvite(id: id, sealed: sealed)
    }
    func invites(in group: GroupID) async throws -> [PendingInvite] { try await inner.invites(in: group) }
    func deleteInvite(id: Data) async throws { try await inner.deleteInvite(id: id) }
    func uploadKeys(_ keys: [WrappedKey], group: GroupID) async throws {
        try await inner.uploadKeys(keys, group: group)
    }
}

/// Makes this Mac's database refuse to save a transaction with this merchant,
/// for a test of what a pull does with a save it cannot make.
private func refuseToSave(merchant: String, in store: Store) throws {
    try store.database.writer.write { db in
        try db.execute(sql: """
            CREATE TRIGGER refuse_\(merchant) BEFORE INSERT ON transactionRecord
            WHEN NEW.merchant = '\(merchant)' BEGIN SELECT RAISE(ABORT, 'refused here'); END
            """)
    }
}

@Suite("Keys, devices and records nobody may take over")
struct TrustTests {
    let server = InMemoryTransport()
    let household = GroupID()

    private func groceries() -> Budget {
        Budget(groupID: household, name: "Groceries", limit: Money(minorUnits: 100_000))
    }

    // MARK: - Keys

    /// Mallory can only view. She sent keys of her own with the entry that
    /// registers her laptop, and the server kept them. Every member's app then
    /// took her keys in place of the ones it held, and every record sealed
    /// with the real ones stopped opening, on every sync. The in-memory
    /// server refuses them now, as the real one does, and an app handed them
    /// anyway keeps its own.
    @Test func aViewMembersKeysNeverReplaceTheOnesHeld() async throws {
        let robin = try Member(server: server), leslie = try Member(server: server)
        let mallory = try Member(server: server), jamie = try Member(server: server)
        let groceries = groceries()
        try await robin.found(household, name: "Household", budgets: [groceries])
        try await robin.sync(household)
        try await leslie.join(household, from: robin, level: .write)
        try await mallory.join(household, from: robin, level: .read)
        let groupKey = try robin.keyBytes(.group(household))
        let budgetKey = try robin.keyBytes(.budget(groceries.id))

        // Her own keys, in place of the group's and Groceries'.
        let fakeGroup = ScopedKey.generate(scope: .group(household), epoch: .initial)
        let fakeBudget = ScopedKey.generate(scope: .budget(groceries.id), epoch: .initial)
        let realGroup = try mallory.keyRing.key(for: .group(household), epoch: .initial)
        let planted = [
            try KeyWrap.wrapToIdentity(fakeGroup, recipient: robin.identity.publicKeys,
                                       recipientUserID: robin.userID, sender: mallory.identity,
                                       senderUserID: mallory.userID),
            try KeyWrap.wrapUnderGroupKey(fakeBudget, groupKey: realGroup.material,
                                          senderUserID: mallory.userID),
        ]
        let (log, state) = try await mallory.membership(of: household)
        let laptop = DeviceKeyPair()
        let entry = try MembershipLogEntry.signed(
            scope: .group(household), sequence: UInt64(log.count), previousHash: state.head,
            action: .addDevice, subjectUserID: mallory.userID, subjectKeys: nil, level: .read,
            epochAfter: state.epoch, deviceID: laptop.id, devicePublicKey: laptop.publicKey,
            author: mallory.identity, authorUserID: mallory.userID)
        await #expect(throws: (any Error).self, "the server refuses them") {
            try await mallory.session.appendMembership(entry, group: household, wrappedKeys: planted)
        }

        // A server that keeps them anyway.
        server.seed(keys: planted, for: household)
        try await robin.sync(household)
        #expect(try robin.keyBytes(.group(household)) == groupKey)
        #expect(try robin.keyBytes(.budget(groceries.id)) == budgetKey)

        try await jamie.join(household, from: robin, level: .read)
        #expect(try jamie.keyBytes(.group(household)) == groupKey)
        #expect(try jamie.keyBytes(.budget(groceries.id)) == budgetKey)

        let hers = try leslie.spend("Costco", in: groceries)
        try await leslie.sync(household)
        try await robin.sync(household)
        try await jamie.sync(household)
        #expect(try robin.store.transaction(hers.id)?.merchant == "Costco")
        #expect(try jamie.store.transaction(hers.id)?.merchant == "Costco")
    }

    /// Only someone who may manage a group hands out its key. A group key
    /// sealed to Jamie by Mallory, who can only view, is passed over even when
    /// it comes before the real one, which would otherwise never replace it.
    @Test func aGroupKeyIsTakenOnlyFromSomeoneWhoMayManage() async throws {
        let robin = try Member(server: server), mallory = try Member(server: server)
        let jamie = try Member(server: server)
        try await robin.found(household, name: "Household")
        try await robin.sync(household)
        try await mallory.join(household, from: robin, level: .read)
        try await jamie.join(household, from: robin, level: .read)
        let state = try await robin.membership(of: household).state

        let real = try robin.keyRing.key(for: .group(household), epoch: .initial)
        let wraps = [
            try KeyWrap.wrapToIdentity(ScopedKey.generate(scope: .group(household), epoch: .initial),
                                       recipient: jamie.identity.publicKeys, recipientUserID: jamie.userID,
                                       sender: mallory.identity, senderUserID: mallory.userID),
            try KeyWrap.wrapToIdentity(real, recipient: jamie.identity.publicKeys,
                                       recipientUserID: jamie.userID, sender: robin.identity,
                                       senderUserID: robin.userID),
        ]
        let newMac = KeyRing(store: Store(database: try WellSpentDatabase.inMemory()),
                             identity: jamie.identity, userID: jamie.userID)
        #expect(try newMac.absorb(wraps, in: household, membership: state) == 1)
        #expect(try newMac.key(for: .group(household), epoch: .initial).rawBytes == real.rawBytes)
    }

    /// Jamie is in Household and in Book Club, which Mallory founded. She
    /// published a key for Household's Groceries in Book Club. Opened with
    /// Book Club's key, it replaced Jamie's key for Groceries, and Household
    /// stopped syncing for him. The in-memory server refuses it, as the real
    /// one does, and his app does not take a budget key from a group that
    /// does not hold the budget.
    @Test func aBudgetKeyFromAnotherGroupIsNotTakenIn() async throws {
        let robin = try Member(server: server), jamie = try Member(server: server)
        let mallory = try Member(server: server)
        let groceries = groceries()
        try await robin.found(household, name: "Household", budgets: [groceries])
        try await robin.sync(household)
        try await jamie.join(household, from: robin, level: .read)
        let club = GroupID()
        try await mallory.found(club, name: "Book Club")
        try await mallory.sync(club)
        try await jamie.join(club, from: mallory, level: .read)
        let before = try jamie.keyBytes(.budget(groceries.id))

        let clubKey = try mallory.keyRing.key(for: .group(club), epoch: .initial)
        let wrap = try KeyWrap.wrapUnderGroupKey(
            ScopedKey.generate(scope: .budget(groceries.id), epoch: .initial),
            groupKey: clubKey.material, senderUserID: mallory.userID)
        await #expect(throws: (any Error).self, "the server refuses it") {
            try await mallory.session.uploadKeys([wrap], group: club)
        }

        server.seed(keys: [wrap], for: club)
        try await jamie.sync(club)
        #expect(try jamie.keyBytes(.budget(groceries.id)) == before)

        let his = try robin.spend("Sunrise Cafe", in: groceries)
        try await robin.sync(household)
        try await jamie.sync(household)
        #expect(try jamie.store.transaction(his.id)?.merchant == "Sunrise Cafe")
    }

    /// Keys for a new epoch are kept once the server has the entry that starts
    /// it. Kept before, they stayed when the entry was refused, and since a
    /// key this Mac holds is never replaced, the real keys for that epoch,
    /// from whoever did start it, could never come in.
    @Test func keysForAnEpochThatNeverStartedAreNotKept() async throws {
        let robin = try Member(server: server), jamie = try Member(server: server)
        try await robin.found(household, name: "Household", budgets: [groceries()])
        try await robin.sync(household)
        let link = try await robin.sharing.createInvite(
            group: household, groupName: "Household", level: .read, historyAccess: .fromNow,
            inviterName: "Robin")
        try await jamie.sharing.join(link, displayName: "Jamie")

        let refusing = Sharing(store: robin.store, keyRing: robin.keyRing,
                               transport: RefusingEntries(robin.session), identity: robin.identity,
                               device: robin.device, userID: robin.userID)
        await #expect(throws: RefusingEntries.Refused.self) {
            try await refusing.finishInvites(group: household)
        }
        #expect(!robin.keyRing.has(scope: .group(household), epoch: Epoch(1)))

        try await robin.sync(household)
        #expect(robin.keyRing.has(scope: .group(household), epoch: Epoch(1)), "kept once it went in")
    }

    // MARK: - Records that cannot be saved as they are

    /// A budget edited after its transactions sorts after them on the server.
    /// Joining with full history pulled a transaction before its budget, and
    /// saving it failed, so the pull stopped there on every sync and the join
    /// never finished. The transaction is set aside until its budget is in.
    @Test func aTransactionPulledBeforeItsBudgetWaitsForIt() async throws {
        let robin = try Member(server: server), leslie = try Member(server: server)
        let groceries = groceries()
        try await robin.found(household, name: "Household", budgets: [groceries])
        let his = try robin.spend("Hilltop", in: groceries)
        try await robin.sync(household)
        var raised = groceries
        raised.limit = Money(minorUnits: 120_000)
        try robin.store.save(raised)
        try await robin.sync(household)

        let pulled = try await server.pull(group: household, since: 0, limit: 100).envelopes
        let transactionAt = try #require(pulled.firstIndex { $0.recordID == his.id })
        let budgetAt = try #require(pulled.firstIndex { $0.recordID == RecordID(groceries.id.uuid) })
        #expect(transactionAt < budgetAt, "the edited budget sorts after its transaction")

        try await leslie.join(household, from: robin, level: .write)
        #expect(try leslie.store.pendingJoins().isEmpty, "the join finished")
        #expect(try leslie.store.transaction(his.id)?.merchant == "Hilltop")
        #expect(try leslie.store.budget(groceries.id)?.limit.minorUnits == 120_000)
    }

    /// A member added "from now on" gets the group's budgets sealed again
    /// under the new key. Transactions Robin had not sent yet went out before
    /// that re-seal, so they reached Leslie before their budget, and every
    /// sync of hers failed on saving them. They wait for the budget now.
    @Test func aFromNowMembersTransactionsWaitForTheirResealedBudget() async throws {
        let robin = try Member(server: server), leslie = try Member(server: server)
        let groceries = groceries()
        try await robin.found(household, name: "Household", budgets: [groceries])
        try await robin.sync(household)
        let unsent = [try robin.spend("Hilltop", in: groceries), try robin.spend("Costco", in: groceries)]

        try await leslie.join(household, from: robin, level: .write, history: .fromNow)
        let pulled = try await server.pull(group: household, since: 0, limit: 100).envelopes
        let transactionAt = try #require(pulled.firstIndex { $0.recordID == unsent[0].id })
        let budgetAt = try #require(pulled.firstIndex { $0.recordID == RecordID(groceries.id.uuid) })
        #expect(transactionAt < budgetAt, "his transactions went out before the re-seal")

        #expect(try leslie.store.pendingJoins().isEmpty, "the join finished")
        #expect(try leslie.store.budget(groceries.id)?.name == "Groceries")
        for transaction in unsent {
            #expect(try leslie.store.transaction(transaction.id)?.merchant == transaction.merchant)
        }
        try await robin.sync(household)
        let again = try await leslie.sync(household)
        #expect(again.deferred == 0 && again.undecryptable == 0, "got \(again)")
    }

    /// Leslie can add, and her modified app sends a transaction whose sealed
    /// contents do not decode. Saving it failed, so every other member's pull
    /// stopped there on every sync. It is refused, and what comes after it
    /// still arrives.
    @Test func aRecordThatDoesNotDecodeIsPassedOver() async throws {
        let robin = try Member(server: server), leslie = try Member(server: server)
        let groceries = groceries()
        try await robin.found(household, name: "Household", budgets: [groceries])
        try await robin.sync(household)
        try await leslie.join(household, from: robin, level: .write)

        struct Nothing: Codable {}
        let empty = try leslie.forge(Nothing(), id: RecordID(), type: .transaction,
                                     group: household, budget: groceries.id)
        #expect(try await server.push([empty], group: household).accepted == [empty.recordID])
        let after = try leslie.spend("Costco", in: groceries)
        try await leslie.sync(household)

        let report = try await robin.sync(household)
        #expect(report.ignored == 1, "got \(report)")
        #expect(try robin.store.transaction(after.id)?.merchant == "Costco")
        #expect(try await robin.sync(household).ignored == 0, "and it is not tried again")
    }

    /// A record signed by a member, sealed under a key nobody else holds.
    /// Opening it failed with an error the pull did not expect, so the pull
    /// stopped there on every sync. It is counted as one that cannot be
    /// opened, and the pull goes on.
    @Test func aRecordThatDoesNotOpenIsCountedAndPassedOver() async throws {
        let robin = try Member(server: server), leslie = try Member(server: server)
        let groceries = groceries()
        try await robin.found(household, name: "Household", budgets: [groceries])
        try await robin.sync(household)
        try await leslie.join(household, from: robin, level: .write)

        let stray = Transaction(budgetID: groceries.id, groupID: household, date: Date(),
                                merchant: "Stray", amount: Money(minorUnits: -1),
                                createdBy: leslie.userID)
        let sealed = try RecordCodec.seal(
            stray, recordID: stray.id, recordType: .transaction, groupID: household,
            budgetID: groceries.id,
            scopeKey: ScopedKey.generate(scope: .budget(groceries.id), epoch: .initial),
            lamport: 10_000, author: leslie.userID, device: leslie.device, membershipSequence: 0)
        #expect(try await server.push([sealed], group: household).accepted == [sealed.recordID])
        let after = try leslie.spend("Costco", in: groceries)
        try await leslie.sync(household)

        let report = try await robin.sync(household)
        #expect(report.undecryptable == 1, "got \(report)")
        #expect(try robin.store.transaction(stray.id) == nil)
        #expect(try robin.store.transaction(after.id)?.merchant == "Costco")
    }

    // MARK: - What is sealed must match the envelope

    /// Each of these is refused by one check alone, so removing that check
    /// fails this test. Leslie can add, and her modified app sends records
    /// whose sealed contents name something other than their envelope.
    @Test func eachBindingCheckRefusesWhatOnlyItCatches() async throws {
        let robin = try Member(server: server), leslie = try Member(server: server)
        let groceries = groceries()
        let eatingOut = Budget(groupID: household, name: "Eating out", limit: Money(minorUnits: 1))
        try await robin.found(household, name: "Household", budgets: [groceries, eatingOut])
        let his = try robin.spend("Hilltop", in: groceries)
        try await robin.sync(household)
        try await leslie.join(household, from: robin, level: .write)

        // Judged and sealed as Groceries, and saved in Eating out: only the
        // budget comparison catches it.
        let moved = Transaction(budgetID: eatingOut.id, groupID: household, date: Date(),
                                merchant: "Moved", amount: Money(minorUnits: -1),
                                createdBy: leslie.userID)
        // Sent through Household, and saved in another group: only the group
        // comparison catches it. A statement names no budget.
        let elsewhere = ImportedStatement(groupID: GroupID(), filename: "march.csv", format: "csv")
        // On the ID of Robin's transaction, as a receipt in the same group:
        // only the type half of the held-record check catches it.
        let retyped = Receipt(id: his.id, groupID: household, filename: "a.jpg", byteCount: 1,
                              plaintextSHA256: Data([1]))
        let envelopes = [
            try leslie.forge(moved, id: moved.id, type: .transaction, group: household,
                             budget: groceries.id),
            try leslie.forge(elsewhere, id: elsewhere.id, type: .statement, group: household,
                             budget: nil),
            try leslie.forge(retyped, id: his.id, type: .receipt, group: household, budget: nil),
        ]
        robin.leak.extra = envelopes

        let report = try await robin.sync(household)
        #expect(report.ignored == 3, "got \(report)")
        #expect(try robin.store.transaction(moved.id) == nil)
        #expect(try robin.store.statements(in: elsewhere.groupID).isEmpty)
        #expect(try robin.store.receipt(his.id) == nil)
    }

    // MARK: - The group's name

    /// Add is for transactions, and renaming the group renames it for every
    /// member. Leslie's app does not send her rename, the server refuses one
    /// a modified app sends, and Jamie's app ignores one a server let
    /// through. A manager's rename goes everywhere.
    @Test func onlyAManagerRenamesTheGroup() async throws {
        let robin = try Member(server: server), leslie = try Member(server: server)
        let jamie = try Member(server: server), manager = try Member(server: server)
        try await robin.found(household, name: "Household", budgets: [groceries()])
        try await robin.sync(household)
        try await leslie.join(household, from: robin, level: .write)
        try await jamie.join(household, from: robin, level: .read)
        try await manager.join(household, from: robin, level: .manage)

        var hers = try #require(try leslie.store.group(household))
        hers.name = "Leslie's"
        try leslie.store.save(hers)
        let report = try await leslie.sync(household)
        #expect(report.pushed == 0 && report.rejected == 1, "got \(report)")
        #expect(try leslie.store.outboxCount(in: household) == 0,
                "dropped by her app, not refused by the server, which leaves it queued")

        let forged = try leslie.forge(hers, id: RecordID(household.uuid), type: .groupMeta,
                                      group: household, budget: nil)
        let refused = try await server.push([forged], group: household)
        #expect(refused.rejected[forged.recordID] == "only a manager can change the group")

        jamie.leak.extra = [forged]
        #expect(try await jamie.sync(household).ignored == 1)
        #expect(try jamie.store.group(household)?.name == "Household")

        var renamed = try #require(try manager.store.group(household))
        renamed.name = "Home"
        try manager.store.save(renamed)
        #expect(try await manager.sync(household).pushed == 1)
        try await jamie.sync(household)
        #expect(try jamie.store.group(household)?.name == "Home")
    }

    // MARK: - Where a record is filed

    /// A transaction filed in one group under another group's budget is
    /// refused by every other member. It is not sent, and is counted, so this
    /// Mac does not quietly disagree with everyone else.
    @Test func aRowFiledUnderAnotherGroupsBudgetIsNotSent() async throws {
        let robin = try Member(server: server)
        let groceries = groceries()
        let club = GroupID()
        let novels = Budget(groupID: club, name: "Novels", limit: Money(minorUnits: 5_000))
        try await robin.found(household, name: "Household", budgets: [groceries])
        try await robin.found(club, name: "Book Club", budgets: [novels])
        try await robin.sync(household)
        try await robin.sync(club)

        let misfiled = Transaction(budgetID: novels.id, groupID: household, date: Date(),
                                   merchant: "Misfiled", amount: Money(minorUnits: -100))
        try robin.store.save(misfiled)
        let report = try await robin.sync(household)
        #expect(report.pushed == 0 && report.rejected == 1, "got \(report)")
        #expect(try robin.store.outboxCount(in: household) == 0)
    }

    /// A group's ID is also its record's ID. Mallory founded a group on Jamie's
    /// profile ID in Household and sent Robin its link. Robin's Mac then held
    /// a waiting group there, and ignored Jamie's profile for good. The
    /// in-memory server refuses to found it, as the real one does, and
    /// Robin's app refuses a link to it.
    @Test func aLinkToAGroupOnAnIDThisMacHoldsIsRefused() async throws {
        let robin = try Member(server: server), jamie = try Member(server: server)
        let mallory = try Member(server: server)
        try await robin.found(household, name: "Household", budgets: [groceries()])
        try await robin.sync(household)
        try await jamie.join(household, from: robin, level: .write)
        try jamie.store.save(MemberProfile(groupID: household, userID: jamie.userID,
                                           displayName: "Jamie"))
        try await jamie.sync(household)
        try await robin.sync(household)
        #expect(try robin.store.profiles(in: household).map(\.displayName).contains("Jamie"))

        let jamies = GroupID(MemberProfile.recordID(group: household, user: jamie.userID).uuid)
        await #expect(throws: (any Error).self, "the server will not found it") {
            try await mallory.found(jamies, name: "Taken")
        }
        // A server that founds it anyway.
        server.seed(log: [try MembershipLogEntry.signed(
            scope: .group(jamies), sequence: 0, previousHash: MembershipLogEntry.rootHash,
            action: .found, subjectUserID: mallory.userID, subjectKeys: mallory.identity.publicKeys,
            level: .superadmin, epochAfter: .initial,
            deviceID: mallory.device.id, devicePublicKey: mallory.device.publicKey,
            author: mallory.identity, authorUserID: mallory.userID)], for: jamies)
        let link = try await mallory.sharing.createInvite(
            group: jamies, groupName: "Taken", level: .read, historyAccess: .all,
            inviterName: "Mallory")

        await #expect(throws: SharingError.badLink) {
            try await robin.sharing.join(link, displayName: "Robin")
        }
        #expect(try robin.store.pendingJoins().isEmpty)
        try await robin.sync(household)
        #expect(try robin.store.profiles(in: household).map(\.displayName).contains("Jamie"))
    }

    // MARK: - The in-memory server keeps the real one's rules

    /// The in-memory server says it enforces what the real one does. It took
    /// budget keys from anyone, while the real server takes them only from a
    /// manager.
    @Test func theFakeServerTakesBudgetKeysOnlyFromAManager() async throws {
        let robin = try Member(server: server), leslie = try Member(server: server)
        try await robin.found(household, name: "Household", budgets: [groceries()])
        try await robin.sync(household)
        try await leslie.join(household, from: robin, level: .write)

        let groupKey = try leslie.keyRing.key(for: .group(household), epoch: .initial)
        let budget = Budget(groupID: household, name: "Gas", limit: Money(minorUnits: 1))
        let wrap = try KeyWrap.wrapUnderGroupKey(
            ScopedKey.generate(scope: .budget(budget.id), epoch: .initial),
            groupKey: groupKey.material, senderUserID: leslie.userID)
        await #expect(throws: (any Error).self) {
            try await leslie.session.uploadKeys([wrap], group: household)
        }

        // Her own app never sends one: below Manage it mints no budget keys.
        try leslie.store.save(budget)
        let before = try await server.wrappedKeys(group: household, for: leslie.userID).count
        try await leslie.sharing.prepare(group: household)
        #expect(try await server.wrappedKeys(group: household, for: leslie.userID).count == before)
        #expect(!leslie.keyRing.has(scope: .budget(budget.id), epoch: .initial))
    }

    /// A manager publishes a new budget's key before its record goes out, and
    /// the key shows the budget's ID. Mallory, who founded Book Club, pushed a
    /// record there on that ID first, and the budget was refused on every
    /// sync from then on. The ID now belongs to the group that published it.
    @Test func aBudgetsIDIsKeptOnceItsKeyIsPublished() async throws {
        let robin = try Member(server: server), mallory = try Member(server: server)
        try await robin.found(household, name: "Household", budgets: [groceries()])
        try await robin.sync(household)
        try await mallory.join(household, from: robin, level: .read)
        let club = GroupID()
        try await mallory.found(club, name: "Book Club")
        try await mallory.sync(club)

        // Robin's next sync publishes the new budget's key, then pushes it.
        // Mallory's push lands between the two.
        let gas = Budget(groupID: household, name: "Gas", limit: Money(minorUnits: 20_000))
        try robin.store.save(gas)
        try await robin.sharing.prepare(group: household)
        let published = try await mallory.session.wrappedKeys(group: household, for: mallory.userID)
        #expect(published.contains { $0.scope == .budget(gas.id) })
        let squat = try mallory.forge(
            ImportedStatement(id: RecordID(gas.id.uuid), groupID: club, filename: "x", format: "csv"),
            id: RecordID(gas.id.uuid), type: .statement, group: club, budget: nil)
        let refused = try await server.push([squat], group: club)
        #expect(refused.rejected[squat.recordID] == "another record already has this ID")

        let report = try await robin.sync(household)
        #expect(report.rejected == 0, "got \(report)")
        try await mallory.sync(household)
        #expect(try mallory.store.budget(gas.id)?.name == "Gas")
    }

    /// A member at Add set her Mac's clock just under the ceiling, and the
    /// next value the stock app signed left every Mac that pulled it no room
    /// to save in the group. The in-memory server, as the real one does,
    /// refuses a value too far ahead of the group's highest, read once per
    /// push.
    @Test func theFakeServerRefusesAValueTooFarAheadOfTheGroup() async throws {
        let robin = try Member(server: server), leslie = try Member(server: server)
        let groceries = groceries()
        try await robin.found(household, name: "Household", budgets: [groceries])
        try await robin.sync(household)
        try await leslie.join(household, from: robin, level: .write)
        let highest = try #require(try await server.pull(group: household, since: 0, limit: 100)
            .envelopes.map(\.lamport).max())
        let lead = UInt64(1) << 24

        func hers(_ lamport: UInt64) throws -> RecordEnvelope {
            let spent = Transaction(budgetID: groceries.id, groupID: household, date: Date(),
                                    merchant: "Costco", amount: Money(minorUnits: -1),
                                    createdBy: leslie.userID)
            return try leslie.forge(spent, id: spent.id, type: .transaction, group: household,
                                    budget: groceries.id, lamport: lamport)
        }
        let tooFar = try hers(highest + lead + 1)
        #expect(try await server.push([tooFar], group: household).rejected[tooFar.recordID]
                    == "the Lamport value is too far ahead of the group")

        // One push cannot climb twice: both are judged against the highest
        // value stored before it.
        let first = try hers(highest + lead), second = try hers(highest + 2 * lead)
        let result = try await server.push([first, second], group: household)
        #expect(result.accepted == [first.recordID])
        #expect(result.rejected[second.recordID] == "the Lamport value is too far ahead of the group")
        #expect(try await server.push([second], group: household).accepted == [second.recordID],
                "the next push is judged against the new highest")
    }

    // MARK: - Fingerprints, set-aside records and verified logs

    /// Robin and Leslie both import the same joint-account statement before
    /// either pulls the other's rows. Each Mac holds one imported row per
    /// fingerprint, so saving the other's failed, and the pull stopped there
    /// on every sync. The pulled row is kept without its fingerprint.
    @Test func twoMembersImportingTheSameStatementBothKeepSyncing() async throws {
        let robin = try Member(server: server), leslie = try Member(server: server)
        let groceries = groceries()
        try await robin.found(household, name: "Household", budgets: [groceries])
        try await robin.sync(household)
        try await leslie.join(household, from: robin, level: .write)

        func imported(by member: Member) throws -> Transaction {
            let row = Transaction(budgetID: groceries.id, groupID: household, date: Date(),
                                  merchant: "Hilltop", amount: Money(minorUnits: -14208),
                                  source: .statement, importFingerprint: "same-statement-row")
            try member.store.save(row)
            return row
        }
        let his = try imported(by: robin), hers = try imported(by: leslie)
        try await robin.sync(household)
        try await leslie.sync(household)
        try await robin.sync(household)

        for member in [robin, leslie] {
            #expect(try member.store.transaction(his.id) != nil)
            #expect(try member.store.transaction(hers.id) != nil)
        }
        #expect(try leslie.store.transaction(his.id)?.importFingerprint == nil)
        #expect(try leslie.store.transaction(hers.id)?.importFingerprint == "same-statement-row",
                "her own row keeps it, for her next import")
    }

    /// A save this Mac's database refuses for a reason that will repeat is
    /// set aside and counted, and the pull goes on. Thrown, it stopped the
    /// group syncing here for good. Set aside, it is tried again, and saved
    /// once it can be.
    @Test func aRecordThisMacCannotSaveIsKeptAndPassedOver() async throws {
        let robin = try Member(server: server), leslie = try Member(server: server)
        let groceries = groceries()
        try await robin.found(household, name: "Household", budgets: [groceries])
        try await robin.sync(household)
        try await leslie.join(household, from: robin, level: .write)
        try refuseToSave(merchant: "Refused", in: robin.store)

        let refused = try leslie.spend("Refused", in: groceries)
        let after = try leslie.spend("Costco", in: groceries)
        try await leslie.sync(household)

        let report = try await robin.sync(household)
        #expect(report.unsaved == 1, "got \(report)")
        #expect(try robin.store.transaction(after.id)?.merchant == "Costco")
        #expect(try robin.store.transaction(refused.id) == nil)
        #expect(try robin.store.deferredEnvelopes(in: household).map(\.0.recordID) == [refused.id],
                "set aside, not lost")

        try robin.store.database.write { db in try db.execute(sql: "DROP TRIGGER refuse_Refused") }
        try await robin.sync(household)
        #expect(try robin.store.transaction(refused.id)?.merchant == "Refused", "saved once it can be")
        #expect(try robin.store.deferredEnvelopes(in: household).isEmpty)
    }

    /// A transaction set aside for its budget was deleted before it was
    /// applied, and any failure in between lost it with nothing counted. It
    /// leaves only once it has been dealt with, and a save that fails is
    /// counted and kept as a conflict copy.
    @Test func aSetAsideTransactionIsNeverLostWithoutACount() async throws {
        let robin = try Member(server: server), leslie = try Member(server: server)
        let groceries = groceries()
        try await robin.found(household, name: "Household", budgets: [groceries])
        let refused = try robin.spend("Refused", in: groceries)
        try await robin.sync(household)
        var raised = groceries
        raised.limit = Money(minorUnits: 120_000)
        try robin.store.save(raised)
        try await robin.sync(household)

        let link = try await robin.sharing.createInvite(
            group: household, groupName: "Household", level: .write, historyAccess: .all,
            inviterName: "Robin")
        try await leslie.sharing.join(link, displayName: "Leslie")
        try await robin.sync(household)
        try refuseToSave(merchant: "Refused", in: leslie.store)
        try await leslie.sharing.prepare(group: household)
        let report = try await leslie.engine.sync(group: household)
        #expect(report.deferred == 1 && report.unsaved == 1, "got \(report)")
        #expect(try leslie.store.deferredEnvelopes(in: household).map(\.0.recordID) == [refused.id],
                "still set aside, to be tried again")
    }

    /// A transaction whose budget has not arrived stays set aside, untouched,
    /// for as long as that takes, and is applied once the budget comes.
    @Test func aTransactionWaitsAsLongAsItsBudgetDoes() async throws {
        let robin = try Member(server: server), leslie = try Member(server: server)
        let groceries = groceries()
        try await robin.found(household, name: "Household", budgets: [groceries])
        try await robin.sync(household)
        try await leslie.join(household, from: robin, level: .manage)

        // A budget whose record has not gone out yet, with its key published.
        let gas = Budget(groupID: household, name: "Gas", limit: Money(minorUnits: 20_000))
        try robin.store.save(gas, queue: false)
        try await robin.sharing.prepare(group: household)
        let fillUp = try robin.spend("Milepost", in: gas)
        try await robin.sync(household)

        try await leslie.sync(household)
        #expect(try leslie.store.deferredEnvelopes(in: household).count == 1, "set aside")

        // While its budget is missing it is not even opened. Here it could
        // not be: this engine's key ring has nothing in memory, and the key
        // in the database is the wrong one, which a held key never gets
        // replaced over. Opening it on every pull, and deleting it first,
        // lost it the moment that failed.
        try leslie.store.database.write { db in
            try db.execute(sql: "UPDATE scopedKey SET material = randomblob(32) WHERE scopeId = ?",
                           arguments: [gas.id.uuid.uuidString])
        }
        let forgetful = SyncEngine(
            store: leslie.store,
            keyRing: KeyRing(store: leslie.store, identity: leslie.identity, userID: leslie.userID),
            transport: leslie.leak, identity: leslie.identity, device: leslie.device, userID: leslie.userID)
        for _ in 0 ..< 2 {
            _ = try await forgetful.sync(group: household)
            #expect(try leslie.store.transaction(fillUp.id) == nil)
            #expect(try leslie.store.deferredEnvelopes(in: household).count == 1, "still waiting")
        }
        try robin.store.save(gas)
        try await robin.sync(household)
        try await leslie.sync(household)
        #expect(try leslie.store.transaction(fillUp.id)?.merchant == "Milepost")
        #expect(try leslie.store.deferredEnvelopes(in: household).isEmpty)
    }

    /// A record in a format a newer build writes was refused, so it was
    /// passed over for good. It is set aside, as an unknown type is, for
    /// after an update.
    @Test func aRecordInANewerFormatIsSetAside() async throws {
        let robin = try Member(server: server), leslie = try Member(server: server)
        let groceries = groceries()
        try await robin.found(household, name: "Household", budgets: [groceries])
        try await robin.sync(household)
        try await leslie.join(household, from: robin, level: .write)

        let spent = Transaction(budgetID: groceries.id, groupID: household, date: Date(),
                                merchant: "Costco", amount: Money(minorUnits: -1),
                                createdBy: leslie.userID)
        let current = try leslie.forge(spent, id: spent.id, type: .transaction, group: household,
                                       budget: groceries.id)
        let unsigned = RecordEnvelope(
            version: RecordEnvelope.currentVersion + 1, recordID: current.recordID,
            recordType: current.recordType, groupID: current.groupID, budgetID: current.budgetID,
            keyEpoch: current.keyEpoch, ciphersuite: current.ciphersuite,
            payloadKind: current.payloadKind, nonce: current.nonce, ciphertext: current.ciphertext,
            lamport: current.lamport, authorUserID: current.authorUserID,
            authorDeviceID: current.authorDeviceID, membershipSequence: current.membershipSequence,
            isDeleted: false, signature: Data())
        let newer = RecordEnvelope(
            version: unsigned.version, recordID: unsigned.recordID, recordType: unsigned.recordType,
            groupID: unsigned.groupID, budgetID: unsigned.budgetID, keyEpoch: unsigned.keyEpoch,
            ciphersuite: unsigned.ciphersuite, payloadKind: unsigned.payloadKind,
            nonce: unsigned.nonce, ciphertext: unsigned.ciphertext, lamport: unsigned.lamport,
            authorUserID: unsigned.authorUserID, authorDeviceID: unsigned.authorDeviceID,
            membershipSequence: unsigned.membershipSequence, isDeleted: false,
            signature: try leslie.device.signing.signature(for: unsigned.signedBytes()))
        robin.leak.extra = [newer]

        let report = try await robin.sync(household)
        #expect(report.deferred == 1, "got \(report)")
        #expect(try robin.store.deferredEnvelopes(in: household).map(\.0.recordID) == [spent.id])
    }

    /// Before each sync, the key step read the whole log and replayed it on
    /// its own. A server that answered it with a made-up chain, founded with
    /// keys it made, got Leslie's Mac to take its key for the next epoch, and
    /// a key held is never replaced: when the group really got there, she
    /// skipped the real one. The key step now uses the log this Mac has
    /// verified.
    @Test func aMadeUpWholeLogPlantsNoKeys() async throws {
        let robin = try Member(server: server), leslie = try Member(server: server)
        try await robin.found(household, name: "Household", budgets: [groceries()])
        try await robin.sync(household)
        try await leslie.join(household, from: robin, level: .manage)

        let made = IdentityKeyPair.generate(), madeID = UserID()
        func signed(_ action: MembershipAction, subject: UserID, keys: IdentityPublicKeys? = nil,
                    level: AccessLevel, epoch: Epoch, device: DeviceKeyPair? = nil,
                    after log: [MembershipLogEntry]) throws -> MembershipLogEntry {
            try MembershipLogEntry.signed(
                scope: .group(household), sequence: UInt64(log.count),
                previousHash: log.last?.hash ?? MembershipLogEntry.rootHash, action: action,
                subjectUserID: subject, subjectKeys: keys, level: level, epochAfter: epoch,
                deviceID: device?.id, devicePublicKey: device?.publicKey,
                author: made, authorUserID: madeID)
        }
        var chain = [try signed(.found, subject: madeID, keys: made.publicKeys, level: .superadmin,
                                epoch: .initial, after: [])]
        chain.append(try signed(.add, subject: leslie.userID, keys: leslie.identity.publicKeys,
                                level: .manage, epoch: .initial, after: chain))
        chain.append(try signed(.addDevice, subject: leslie.userID, level: .manage,
                                epoch: .initial, device: leslie.device, after: chain))
        chain.append(try signed(.rotate, subject: madeID, level: .superadmin, epoch: Epoch(1),
                                after: chain))
        let planted = try KeyWrap.wrapToIdentity(
            ScopedKey.generate(scope: .group(household), epoch: Epoch(1)),
            recipient: leslie.identity.publicKeys, recipientUserID: leslie.userID,
            sender: made, senderUserID: madeID)

        let lied = Sharing(store: leslie.store, keyRing: leslie.keyRing,
                           transport: LyingLog(leslie.session, madeUp: chain, extraKeys: [planted]),
                           identity: leslie.identity, device: leslie.device, userID: leslie.userID)
        try await lied.prepare(group: household)
        _ = try await lied.finishInvites(group: household)
        #expect(!leslie.keyRing.has(scope: .group(household), epoch: Epoch(1)))
    }

    /// The server refuses a key for an epoch the group has not reached, so
    /// one stored ahead of time cannot win over the real one. The app now
    /// does the same, so a server working with a manager cannot get a key
    /// for the next epoch kept here early.
    @Test func aKeyForAnEpochTheLogHasNotReachedIsNotTaken() async throws {
        let robin = try Member(server: server), leslie = try Member(server: server)
        try await robin.found(household, name: "Household")
        try await robin.sync(household)
        try await leslie.join(household, from: robin, level: .read)
        let state = try await robin.membership(of: household).state

        let early = try KeyWrap.wrapToIdentity(
            ScopedKey.generate(scope: .group(household), epoch: Epoch(1)),
            recipient: leslie.identity.publicKeys, recipientUserID: leslie.userID,
            sender: robin.identity, senderUserID: robin.userID)
        #expect(try leslie.keyRing.absorb([early], in: household, membership: state) == 0)
        #expect(!leslie.keyRing.has(scope: .group(household), epoch: Epoch(1)))
    }

    /// A budget key is opened only with the synced group's own key, and never
    /// for a budget this Mac holds in another group. The earlier tests are
    /// stopped by the rule that a held key is never replaced, so here this
    /// Mac holds no key for the budget yet.
    @Test func aBudgetKeyIsTakenOnlyFromItsOwnGroup() async throws {
        let robin = try Member(server: server), jamie = try Member(server: server)
        let mallory = try Member(server: server)
        try await robin.found(household, name: "Household")
        try await robin.sync(household)
        try await jamie.join(household, from: robin, level: .read)
        let club = GroupID()
        try await mallory.found(club, name: "Book Club")
        try await mallory.sync(club)
        try await jamie.join(club, from: mallory, level: .read)
        let clubState = try await mallory.membership(of: club).state
        let householdKey = try robin.keyRing.key(for: .group(household), epoch: .initial)
        let clubKey = try mallory.keyRing.key(for: .group(club), epoch: .initial)

        // A budget Jamie holds in Household, with no key here yet.
        let gas = Budget(groupID: household, name: "Gas", limit: Money(minorUnits: 1))
        try jamie.store.save(gas, queue: false)
        let underClub = try KeyWrap.wrapUnderGroupKey(
            ScopedKey.generate(scope: .budget(gas.id), epoch: .initial),
            groupKey: clubKey.material, senderUserID: mallory.userID)
        #expect(try jamie.keyRing.absorb([underClub], in: club, membership: clubState) == 0,
                "not for a budget held in another group")

        // A budget he does not hold, sealed under Household's key, served in
        // Book Club.
        let elsewhere = try KeyWrap.wrapUnderGroupKey(
            ScopedKey.generate(scope: .budget(BudgetID()), epoch: .initial),
            groupKey: householdKey.material, senderUserID: robin.userID)
        #expect(try jamie.keyRing.absorb([elsewhere], in: club, membership: clubState) == 0,
                "only with the synced group's own key")
    }

    /// Mallory, a manager, added Jamie before he joined, with keys she made,
    /// signed an entry with them as him, and took him out again. Then Robin's
    /// add of the real Jamie was refused on every sync, and Robin's sync of
    /// the group failed each time. Servers now take an add only with the
    /// person's own sign-up keys, so this takes a server that lies, and then
    /// the invite goes instead and the rest of Robin's sync goes on.
    @Test func anInviteWhoseKeysClashIsDroppedNotRetriedForever() async throws {
        let robin = try Member(server: server), mallory = try Member(server: server)
        let jamie = try Member(server: server)
        try await robin.found(household, name: "Household")
        try await robin.sync(household)
        try await mallory.join(household, from: robin, level: .manage)

        let made = IdentityKeyPair.generate(), madeDevice = DeviceKeyPair()
        let (log, state) = try await mallory.membership(of: household)
        let squat = try MembershipLogEntry.signed(
            scope: .group(household), sequence: UInt64(log.count), previousHash: state.head,
            action: .add, subjectUserID: jamie.userID, subjectKeys: made.publicKeys, level: .read,
            epochAfter: state.epoch, author: mallory.identity, authorUserID: mallory.userID)
        await #expect(throws: (any Error).self, "not his sign-up keys") {
            try await mallory.session.appendMembership(squat, group: household, wrappedKeys: [])
        }
        // A server that takes them anyway.
        server.append(squat, to: household)
        let asHim = try MembershipLogEntry.signed(
            scope: .group(household), sequence: UInt64(log.count + 1), previousHash: squat.hash,
            action: .addDevice, subjectUserID: jamie.userID, subjectKeys: nil, level: .read,
            epochAfter: state.epoch, deviceID: madeDevice.id, devicePublicKey: madeDevice.publicKey,
            author: made, authorUserID: jamie.userID)
        server.append(asHim, to: household)
        // Out again, so his ID is free to invite, with the keys still on it.
        let out = try MembershipLogEntry.signed(
            scope: .group(household), sequence: UInt64(log.count + 2), previousHash: asHim.hash,
            action: .remove, subjectUserID: jamie.userID, subjectKeys: nil, level: .none,
            epochAfter: state.epoch, author: mallory.identity, authorUserID: mallory.userID)
        server.append(out, to: household)

        let link = try await robin.sharing.createInvite(
            group: household, groupName: "Household", level: .write, historyAccess: .all,
            inviterName: "Robin")
        try await jamie.sharing.join(link, displayName: "Jamie")
        try await robin.sync(household)
        #expect(server.inviteCount == 0, "the invite was dropped")
        #expect(try await robin.sync(household).rejected == 0, "and his syncs go on")
    }

    // MARK: - Shared device IDs, failed saves and held fingerprints

    /// A device belongs to a person and a device together, so Mallory could
    /// register Robin's device ID as her own in the same group. Robin's Mac
    /// then took what she signed under it for its own records coming back,
    /// and skipped them, while every other Mac applied them. Ours now means
    /// this person on this device.
    @Test func editsUnderAnotherMembersDeviceIDAreNotSkippedAsEchoes() async throws {
        let robin = try Member(server: server), mallory = try Member(server: server)
        let groceries = groceries()
        try await robin.found(household, name: "Household", budgets: [groceries])
        try await robin.sync(household)
        try await mallory.join(household, from: robin, level: .write)

        let hers = try mallory.spend("Hilltop", in: groceries)
        try await mallory.sync(household)
        try await robin.sync(household)
        #expect(try robin.store.transaction(hers.id)?.amount.minorUnits == -1000)

        // His device ID, registered as hers, with a key of her own.
        let borrowed = DeviceKeyPair(id: robin.device.id)
        let (log, state) = try await mallory.membership(of: household)
        try await mallory.session.appendMembership(try MembershipLogEntry.signed(
            scope: .group(household), sequence: UInt64(log.count), previousHash: state.head,
            action: .addDevice, subjectUserID: mallory.userID, subjectKeys: nil, level: .write,
            epochAfter: state.epoch, deviceID: borrowed.id, devicePublicKey: borrowed.publicKey,
            author: mallory.identity, authorUserID: mallory.userID), group: household, wrappedKeys: [])

        var changed = try #require(try mallory.store.transaction(hers.id))
        changed.amount = Money(minorUnits: -500_000)
        let key = try mallory.keyRing.key(for: .budget(groceries.id), epoch: .initial)
        let envelope = try RecordCodec.seal(
            changed, recordID: hers.id, recordType: .transaction, groupID: household,
            budgetID: groceries.id, scopeKey: key, lamport: 50_000, author: mallory.userID,
            device: borrowed, membershipSequence: 0)
        #expect(try await server.push([envelope], group: household).accepted == [hers.id])

        try await robin.sync(household)
        #expect(try robin.store.transaction(hers.id)?.amount.minorUnits == -500_000)
    }

    /// A save that fails for a reason that can clear up, such as a full disk,
    /// was set aside and passed over for good. It is thrown as before now, so
    /// the pull stops before its cursor moves, and the record comes again.
    @Test func aSaveThatCanSucceedLaterIsNotPassedOver() async throws {
        let robin = try Member(server: server), leslie = try Member(server: server)
        let groceries = groceries()
        try await robin.found(household, name: "Household", budgets: [groceries])
        try await robin.sync(household)
        try await leslie.join(household, from: robin, level: .write)
        let note = String(repeating: "x", count: 2_000)
        var sent: [Transaction] = []
        for index in 0 ..< 40 {
            var row = Transaction(budgetID: groceries.id, groupID: household, date: Date(),
                                  merchant: "Row \(index)", amount: Money(minorUnits: -1))
            row.note = note
            try robin.store.save(row)
            sent.append(row)
        }
        try await robin.sync(household)

        let cursor = try leslie.store.syncState(for: household).serverSeq
        try leslie.store.database.write { db in
            let pages = try Int.fetchOne(db, sql: "PRAGMA page_count") ?? 0
            try db.execute(sql: "PRAGMA max_page_count = \(pages)")
        }
        await #expect(throws: (any Error).self, "the disk is full") {
            try await leslie.engine.sync(group: household)
        }
        #expect(try leslie.store.syncState(for: household).serverSeq == cursor, "the cursor did not move")
        #expect(try leslie.store.deferredEnvelopes(in: household).isEmpty, "nothing was passed over")

        try leslie.store.database.write { db in try db.execute(sql: "PRAGMA max_page_count = 1000000") }
        try await leslie.sync(household)
        for row in sent { #expect(try leslie.store.transaction(row.id)?.merchant == row.merchant) }
    }

    /// A save that fails for good undid moving a queued re-seal above the
    /// newer version it pulled, and the same sync then sent the re-seal with
    /// this Mac's old content over that version, on every Mac. Its row now
    /// waits while the record cannot be saved here.
    @Test func aReSealWaitsWhileTheVersionItMustCarryCannotBeSaved() async throws {
        let robin = try Member(server: server), leslie = try Member(server: server)
        let jamie = try Member(server: server)
        let groceries = groceries()
        try await robin.found(household, name: "Household", budgets: [groceries])
        try await robin.sync(household)
        try await leslie.join(household, from: robin, level: .manage)

        // His clock runs ahead of hers, so his re-seal would outrank her edit.
        for index in 0 ..< 5 { _ = try robin.spend("Row \(index)", in: groceries) }
        try await robin.sync(household)
        var food = try #require(try leslie.store.budget(groceries.id))
        food.name = "Food"
        try leslie.store.save(food)
        try await leslie.sync(household)

        let link = try await robin.sharing.createInvite(
            group: household, groupName: "Household", level: .read, historyAccess: .fromNow,
            inviterName: "Robin")
        try await jamie.sharing.join(link, displayName: "Jamie")
        try robin.store.database.write { db in
            try db.execute(sql: """
                CREATE TRIGGER refuse_food BEFORE UPDATE ON budget WHEN NEW.name = 'Food'
                BEGIN SELECT RAISE(ABORT, 'refused here'); END
                """)
        }
        let report = try await robin.sync(household)
        #expect(report.unsaved == 1, "got \(report)")

        let stored = try await server.pull(group: household, since: 0, limit: 500).envelopes
        let budgetRecord = try #require(stored.first { $0.recordID == RecordID(groceries.id.uuid) })
        #expect(budgetRecord.authorUserID == leslie.userID, "her edit is still what everyone has")
        #expect(try robin.store.queuedPush(RecordID(groceries.id.uuid)) != nil, "his re-seal waits")
    }

    /// A pulled row whose import fingerprint this Mac already held was kept
    /// without it, and a later save here sent it out that way. The member
    /// who imported it lost the fingerprint, and their next overlapping
    /// import added the line again. The fingerprint now goes back out.
    @Test func aClearedFingerprintGoesBackOutWithTheRow() async throws {
        let robin = try Member(server: server), leslie = try Member(server: server)
        let groceries = groceries()
        try await robin.found(household, name: "Household", budgets: [groceries])
        try await robin.sync(household)
        try await leslie.join(household, from: robin, level: .manage)

        func imported(by member: Member) throws -> Transaction {
            let row = Transaction(budgetID: groceries.id, groupID: household, date: Date(),
                                  merchant: "Hilltop", amount: Money(minorUnits: -14208),
                                  source: .statement, importFingerprint: "same-statement-row")
            try member.store.save(row)
            return row
        }
        let his = try imported(by: robin)
        _ = try imported(by: leslie)
        try await robin.sync(household)
        try await leslie.sync(household)
        #expect(try leslie.store.transaction(his.id)?.importFingerprint == nil)

        var noted = try #require(try leslie.store.transaction(his.id))
        noted.note = "Shared"
        try leslie.store.save(noted)
        try await leslie.sync(household)
        try await robin.sync(household)
        let mine = try #require(try robin.store.transaction(his.id))
        #expect(mine.note == "Shared")
        #expect(mine.importFingerprint == "same-statement-row", "his import still knows the row")
    }

    /// The inviter kept the keys for a new epoch but not the entry that
    /// started it. A server that left that entry out of later reads could
    /// get a second "from now on" invite to start the same epoch again, and
    /// its keys were written over the first ones.
    @Test func finishingAnInviteKeepsItsOwnEntry() async throws {
        let robin = try Member(server: server), jamie = try Member(server: server)
        try await robin.found(household, name: "Household", budgets: [groceries()])
        try await robin.sync(household)
        let link = try await robin.sharing.createInvite(
            group: household, groupName: "Household", level: .read, historyAccess: .fromNow,
            inviterName: "Robin")
        try await jamie.sharing.join(link, displayName: "Jamie")
        let before = try robin.store.membershipLog(for: household).count

        let added = try await robin.sharing.finishInvites(group: household)
        #expect(added.count == 1)
        let kept = try robin.store.membershipLog(for: household)
        #expect(kept.count == before + 1)
        #expect(kept.last?.subjectUserID == jamie.userID && kept.last?.epochAfter == Epoch(1))
    }

    /// A record of a type or format this build cannot read was set aside
    /// before anyone checked who sent it, and without a limit, so a member at
    /// View, or a server that lies, could fill every Mac with them. Only
    /// someone who may write gets one set aside, and only so many from each
    /// sender, so one member at Add cannot use up the room other members'
    /// records need. Transactions waiting for their budget are not counted.
    @Test func onlySoManyUnreadableRecordsAreSetAsideAndOnlyFromAWriter() async throws {
        let robin = try Member(server: server), mallory = try Member(server: server)
        try await robin.found(household, name: "Household")
        try await robin.sync(household)
        try await mallory.join(household, from: robin, level: .read)

        struct Future: Codable { let value: Int }
        func future(from member: Member) throws -> RecordEnvelope {
            try RecordCodec.seal(
                Future(value: 1), recordID: RecordID(), recordType: RecordType(rawValue: "future"),
                groupID: household, budgetID: nil,
                scopeKey: try member.keyRing.key(for: .group(household), epoch: .initial),
                lamport: 10_000, author: member.userID, device: member.device, membershipSequence: 0)
        }
        robin.leak.extra = [try future(from: mallory)]
        #expect(try await robin.sync(household).ignored == 1, "she can only view")
        #expect(try robin.store.deferredEnvelopes(in: household).isEmpty)

        let leslie = try Member(server: server)
        try await leslie.join(household, from: robin, level: .write)
        func fill(from member: Member, unreadable: Bool, prefix: String) throws {
            let filler = try JSONEncoder().encode(try future(from: member))
            try robin.store.database.write { db in
                try db.execute(sql: """
                    WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM n WHERE i < ?)
                    INSERT INTO deferredEnvelope
                        (recordId, budgetGroupId, recordType, envelope, serverSeq, authorUserId, unreadable)
                    SELECT ? || i, ?, 'future', ?, 0, ?, ? FROM n
                    """, arguments: [SyncEngine.setAsideLimit, prefix, household.uuid.uuidString, filler,
                                     member.userID.uuid.uuidString, unreadable])
            }
        }
        try fill(from: leslie, unreadable: true, prefix: "hers-")
        try fill(from: robin, unreadable: false, prefix: "waiting-")
        robin.leak.extra = [try future(from: leslie)]
        #expect(try await robin.sync(household).ignored == 1, "her limit is reached")

        robin.leak.extra = [try future(from: robin)]
        let own = try await robin.sync(household)
        #expect(own.deferred == 1 && own.ignored == 0, "his is still set aside: got \(own)")
    }

    // MARK: - Who starts an epoch, keyless adds, refused answers

    /// Registering a device needs only View, and its entry could name any
    /// epoch. Mallory's named the next one, and the server took it for the
    /// entry that started that epoch, so it refused the budget keys Robin's
    /// "from now on" invite carried. His sync stopped at the group on every
    /// round until the link expired, and the server refused the key of every
    /// budget he added later, so nobody else could read those budgets.
    @Test func aViewMemberCannotBlockFromNowInvites() async throws {
        let robin = try Member(server: server), mallory = try Member(server: server)
        let jamie = try Member(server: server)
        let groceries = groceries()
        try await robin.found(household, name: "Household", budgets: [groceries])
        try await robin.sync(household)
        try await mallory.join(household, from: robin, level: .read)

        let (log, state) = try await mallory.membership(of: household)
        let laptop = DeviceKeyPair()
        let ahead = try MembershipLogEntry.signed(
            scope: .group(household), sequence: UInt64(log.count), previousHash: state.head,
            action: .addDevice, subjectUserID: mallory.userID, subjectKeys: nil, level: .read,
            epochAfter: state.epoch.next, deviceID: laptop.id, devicePublicKey: laptop.publicKey,
            author: mallory.identity, authorUserID: mallory.userID)
        await #expect(throws: ServerRefused.self) {
            try await mallory.session.appendMembership(ahead, group: household, wrappedKeys: [])
        }

        try await jamie.join(household, from: robin, level: .read, history: .fromNow)
        #expect(try jamie.store.pendingJoins().isEmpty, "the join finished")
        let his = try robin.spend("Hilltop", in: groceries)
        let rent = Budget(groupID: household, name: "Rent", limit: Money(minorUnits: 200_000))
        try robin.store.save(rent)
        try await robin.sync(household)
        try await jamie.sync(household)
        #expect(try jamie.store.transaction(his.id)?.merchant == "Hilltop")
        #expect(try jamie.store.budget(rent.id)?.name == "Rent", "a budget added later reaches him")
    }

    /// Both servers compare the keys an add carries with the person's sign-up
    /// keys, and an add with none got round that. Mallory added Jamie with no
    /// keys and a junk group key for him, then removed him. When Robin later
    /// added him with "Everything so far", the server kept her key in Jamie's
    /// slot and dropped Robin's, so Jamie read nothing.
    @Test func aKeylessAddCannotPlantAKeyForLater() async throws {
        let robin = try Member(server: server), mallory = try Member(server: server)
        let jamie = try Member(server: server)
        let groceries = groceries()
        try await robin.found(household, name: "Household", budgets: [groceries])
        let his = try robin.spend("Hilltop", in: groceries)
        try await robin.sync(household)
        try await mallory.join(household, from: robin, level: .manage)

        var (log, state) = try await mallory.membership(of: household)
        let madeUp = IdentityKeyPair.generate()
        let junk = try KeyWrap.wrapToIdentity(
            ScopedKey.generate(scope: .group(household), epoch: state.epoch), recipient: madeUp.publicKeys,
            recipientUserID: jamie.userID, sender: mallory.identity, senderUserID: mallory.userID)
        let keyless = try MembershipLogEntry.signed(
            scope: .group(household), sequence: UInt64(log.count), previousHash: state.head,
            action: .add, subjectUserID: jamie.userID, subjectKeys: nil, level: .read,
            epochAfter: state.epoch, author: mallory.identity, authorUserID: mallory.userID)
        await #expect(throws: ServerRefused.self) {
            try await mallory.session.appendMembership(keyless, group: household, wrappedKeys: [junk])
        }
        (log, state) = try await mallory.membership(of: household)
        if state.level(of: jamie.userID) > .none {
            try await mallory.session.appendMembership(try MembershipLogEntry.signed(
                scope: .group(household), sequence: UInt64(log.count), previousHash: state.head,
                action: .remove, subjectUserID: jamie.userID, subjectKeys: nil, level: .none,
                epochAfter: state.epoch, author: mallory.identity, authorUserID: mallory.userID),
                group: household, wrappedKeys: [])
        }

        try await jamie.join(household, from: robin, level: .read)
        #expect(try jamie.store.transaction(his.id)?.merchant == "Hilltop", "he reads everything so far")
    }

    /// An answer is bound to the link's secret, not to an account, so whoever
    /// holds the link can answer with keys that are not their sign-up keys,
    /// someone else's ID, an ID with no account, or keys that do not parse.
    /// The server refused the add, or sealing to the keys failed, and Robin's
    /// sync stopped at the group on every round until the link expired. The
    /// invite is dropped now, and the sync goes on.
    @Test func anAnswerTheServerWillNotAddSpoilsOnlyItsInvite() async throws {
        let robin = try Member(server: server), mallory = try Member(server: server)
        let jamie = try Member(server: server)
        try await robin.found(household, name: "Household", budgets: [groceries()])
        try await robin.sync(household)

        let made = IdentityKeyPair.generate().publicKeys
        let unparseable = try JSONDecoder().decode(IdentityPublicKeys.self, from: Data(
            #"{"signing":"AAEC","kem":"AAEC"}"#.utf8))
        let answers: [(String, UserID, IdentityPublicKeys)] = [
            ("keys that are not hers", mallory.userID, made),
            ("someone else's ID", jamie.userID, made),
            ("an ID with no account", UserID(), made),
            ("keys that do not parse", mallory.userID, unparseable),
        ]
        for (label, user, keys) in answers {
            let link = try await robin.sharing.createInvite(
                group: household, groupName: "Household", level: .read, historyAccess: .all,
                inviterName: "Robin")
            let secret = try InviteSecret(bytes: link.secret)
            let lookup = try await mallory.session.lookupInvite(id: secret.id)
            let sealed = try InviteCrypto.sealAcceptance(
                InviteAcceptance(accepterUserID: user, accepterKeys: keys, displayName: "Mallory"),
                invite: lookup.invite(id: secret.id), secret: secret)
            try await mallory.session.acceptInvite(id: secret.id, sealed: sealed)

            await #expect(throws: Never.self, "\(label)") { try await robin.sync(household) }
            #expect(server.inviteCount == 0, "\(label): the invite was dropped")
        }
        try await jamie.join(household, from: robin, level: .read)
        #expect(try jamie.store.pendingJoins().isEmpty, "a real answer still gets in")
    }

    /// The fake server took whatever keys a test opened a session with as the
    /// person's sign-up keys, so a test could pass that the real server, which
    /// keeps the keys someone signed up with, would fail. The first keys stay.
    @Test func theFakeServerKeepsTheKeysSomeoneSignedUpWith() {
        let user = UserID()
        let signedUp = IdentityKeyPair.generate().publicKeys
        _ = server.session(for: user, keys: signedUp)
        _ = server.session(for: user, keys: IdentityKeyPair.generate().publicKeys)
        #expect(server.identityKeys(of: user) == signedUp)
    }

    /// A refusal that came because another entry reached the log first is
    /// not the answer's fault. That invite stays, and the next sync adds them.
    @Test func anAddRefusedBecauseTheLogMovedIsTriedAgain() async throws {
        let robin = try Member(server: server), leslie = try Member(server: server)
        let jamie = try Member(server: server)
        try await robin.found(household, name: "Household")
        try await robin.sync(household)
        try await leslie.join(household, from: robin, level: .write)

        let link = try await robin.sharing.createInvite(
            group: household, groupName: "Household", level: .read, historyAccess: .all,
            inviterName: "Robin")
        try await jamie.sharing.join(link, displayName: "Jamie")
        let racing = Racing(robin.session)
        racing.first = {
            let (log, state) = try await leslie.membership(of: household)
            let laptop = DeviceKeyPair()
            try await leslie.session.appendMembership(try MembershipLogEntry.signed(
                scope: .group(household), sequence: UInt64(log.count), previousHash: state.head,
                action: .addDevice, subjectUserID: leslie.userID, subjectKeys: nil, level: .write,
                epochAfter: state.epoch, deviceID: laptop.id, devicePublicKey: laptop.publicKey,
                author: leslie.identity, authorUserID: leslie.userID), group: household, wrappedKeys: [])
        }
        let sharing = Sharing(store: robin.store, keyRing: robin.keyRing, transport: racing,
                              identity: robin.identity, device: robin.device, userID: robin.userID)
        #expect(try await sharing.finishInvites(group: household).isEmpty)
        #expect(server.inviteCount == 1, "the invite stays")
        #expect(try await sharing.finishInvites(group: household).map(\.accepterUserID) == [jamie.userID])
    }

    // MARK: - Versions from before v7, and set-aside records held back

    /// Versions stored before migration v7 have no author on file. On a tie
    /// in Lamport value and device, Robin's Mac kept its own, while both
    /// servers, which compare the real authors, took the other person's.
    /// Mallory registered his device ID as hers and pushed her copy of his
    /// record at his value: everyone else took hers, and his Mac kept his
    /// until someone next edited it. A version with no author on this Mac's
    /// own device ID is taken as this person's, since this Mac sent it in
    /// nearly every case.
    @Test func aVersionStoredBeforeV7IsThisMacsOwn() async throws {
        let groceries = groceries()
        let record = Transaction(budgetID: groceries.id, groupID: household, date: Date(),
                                 merchant: "Hilltop", amount: Money(minorUnits: -1000))
        let device = DeviceKeyPair()

        // His database, made by a build before v7, holding his version.
        var configuration = Configuration()
        configuration.foreignKeysEnabled = true
        let queue = try DatabaseQueue(configuration: configuration)
        try WellSpentDatabase.migrator.migrate(queue, upTo: "v6-outbox-edit-lamport")
        try await queue.write { db in
            try db.execute(sql: """
                INSERT INTO recordVersion (recordId, lamport, authorDeviceId, serverSeq)
                VALUES (?, 7, ?, 0)
                """, arguments: [record.id.uuid.uuidString, device.id.uuid.uuidString])
        }
        let robin = try Member(server: server, userID: UserID(UUID(uuidString: "00000000-0000-0000-0000-00000000000A")!),
                               device: device, database: try WellSpentDatabase(writer: queue))
        let mallory = try Member(server: server,
                                 userID: UserID(UUID(uuidString: "FFFFFFFF-0000-0000-0000-00000000000A")!))
        #expect(try robin.store.recordVersion(record.id)?.author == nil, "v7 kept no author for it")

        try await robin.found(household, name: "Household", budgets: [groceries])
        try robin.store.save(record, queue: false)
        try await robin.sync(household)
        let his = try robin.forge(record, id: record.id, type: .transaction, group: household,
                                  budget: groceries.id, lamport: 7)
        #expect(try await server.push([his], group: household).accepted == [record.id])
        try await mallory.join(household, from: robin, level: .manage)

        let borrowed = DeviceKeyPair(id: device.id)
        let (log, state) = try await mallory.membership(of: household)
        try await mallory.session.appendMembership(try MembershipLogEntry.signed(
            scope: .group(household), sequence: UInt64(log.count), previousHash: state.head,
            action: .addDevice, subjectUserID: mallory.userID, subjectKeys: nil, level: .manage,
            epochAfter: state.epoch, deviceID: borrowed.id, devicePublicKey: borrowed.publicKey,
            author: mallory.identity, authorUserID: mallory.userID), group: household, wrappedKeys: [])
        var changed = record
        changed.merchant = "Changed"
        let hers = try RecordCodec.seal(
            changed, recordID: record.id, recordType: .transaction, groupID: household,
            budgetID: groceries.id, scopeKey: try mallory.keyRing.key(for: .budget(groceries.id), epoch: .initial),
            lamport: 7, author: mallory.userID, device: borrowed, membershipSequence: 0)
        #expect(try await server.push([hers], group: household).accepted == [record.id])
        let stored = try await server.pull(group: household, since: 0, limit: 500).envelopes
        #expect(stored.first { $0.recordID == record.id }?.authorUserID == mallory.userID,
                "the fake server took hers, as the real one does, and did not answer for his")

        try await robin.sync(household)
        #expect(try robin.store.transaction(record.id)?.merchant == "Changed")
    }

    /// A re-seal goes out at a fresh Lamport value with this Mac's content. A
    /// newer version this build cannot read is set aside, so the re-seal never
    /// moved above it, and sent this Mac's older content over it on every Mac.
    /// Its queued row waits now, as long as the version it would overwrite.
    @Test func aReSealWaitsWhileANewerFormatVersionIsSetAside() async throws {
        let robin = try Member(server: server), leslie = try Member(server: server)
        let jamie = try Member(server: server)
        let groceries = groceries()
        try await robin.found(household, name: "Household", budgets: [groceries])
        try await robin.sync(household)
        try await leslie.join(household, from: robin, level: .manage)
        for index in 0 ..< 5 { _ = try robin.spend("Row \(index)", in: groceries) }
        try await robin.sync(household)

        let link = try await robin.sharing.createInvite(
            group: household, groupName: "Household", level: .read, historyAccess: .fromNow,
            inviterName: "Robin")
        try await jamie.sharing.join(link, displayName: "Jamie")
        try await robin.sharing.finishInvites(group: household)
        let budgetID = RecordID(groceries.id.uuid)
        let reseal = try #require(try robin.store.queuedPush(budgetID))

        // Leslie's newer build writes the budget in a format Robin's cannot read.
        let current = try leslie.forge(groceries, id: budgetID, type: .budget, group: household,
                                       budget: nil, lamport: reseal.lamport - 1)
        let unsigned = RecordEnvelope(
            version: RecordEnvelope.currentVersion + 1, recordID: current.recordID,
            recordType: current.recordType, groupID: current.groupID, budgetID: current.budgetID,
            keyEpoch: current.keyEpoch, ciphersuite: current.ciphersuite,
            payloadKind: current.payloadKind, nonce: current.nonce, ciphertext: current.ciphertext,
            lamport: current.lamport, authorUserID: current.authorUserID,
            authorDeviceID: current.authorDeviceID, membershipSequence: current.membershipSequence,
            isDeleted: false, signature: Data())
        let newer = RecordEnvelope(
            version: unsigned.version, recordID: unsigned.recordID, recordType: unsigned.recordType,
            groupID: unsigned.groupID, budgetID: unsigned.budgetID, keyEpoch: unsigned.keyEpoch,
            ciphersuite: unsigned.ciphersuite, payloadKind: unsigned.payloadKind,
            nonce: unsigned.nonce, ciphertext: unsigned.ciphertext, lamport: unsigned.lamport,
            authorUserID: unsigned.authorUserID, authorDeviceID: unsigned.authorDeviceID,
            membershipSequence: unsigned.membershipSequence, isDeleted: false,
            signature: try leslie.device.signing.signature(for: unsigned.signedBytes()))
        #expect(try await server.push([newer], group: household).accepted == [budgetID])

        for _ in 0 ..< 2 {
            let report = try await robin.engine.sync(group: household)
            #expect(report.rejected == 0, "got \(report)")
            let stored = try await server.pull(group: household, since: 0, limit: 500).envelopes
            #expect(stored.first { $0.recordID == budgetID }?.version == RecordEnvelope.currentVersion + 1,
                    "her newer version is still what everyone has")
            #expect(try robin.store.queuedPush(budgetID) != nil, "his re-seal waits")
        }
    }

    /// A set-aside record whose retry fails for a reason that can pass, such
    /// as its key not having arrived, stays for a later pull. A queued
    /// re-seal of it went out meanwhile, with this Mac's older content, over
    /// the version waiting here. It waits with it now. An edit made here
    /// still goes, and the server weighs it as usual.
    @Test func aReSealWaitsWhileItsSetAsideVersionCannotBeRetried() async throws {
        let robin = try Member(server: server), leslie = try Member(server: server)
        let groceries = groceries()
        try await robin.found(household, name: "Household", budgets: [groceries])
        try await robin.sync(household)
        try await leslie.join(household, from: robin, level: .manage)
        let budgetID = RecordID(groceries.id.uuid)
        func stored() async throws -> RecordEnvelope? {
            try await server.pull(group: household, since: 0, limit: 500).envelopes
                .first { $0.recordID == budgetID }
        }
        let before = try #require(try await stored())

        // Hers, set aside by an older build, under a key that has not reached him.
        let later = try RecordCodec.seal(
            groceries, recordID: budgetID, recordType: .budget, groupID: household, budgetID: nil,
            scopeKey: ScopedKey.generate(scope: .group(household), epoch: Epoch(1)), lamport: 50,
            author: leslie.userID, device: leslie.device, membershipSequence: 0)
        try robin.store.deferEnvelope(later, serverSeq: 1)
        try robin.store.queueReseal(of: household, budgets: [groceries.id])

        _ = try await robin.engine.sync(group: household)
        #expect(try await stored()?.lamport == before.lamport, "his re-seal did not go out")
        #expect(try robin.store.queuedPush(budgetID)?.isReseal == true, "and it waits")

        var renamed = groceries
        renamed.name = "Food"
        try robin.store.save(renamed)
        _ = try await robin.engine.sync(group: household)
        #expect(try await stored().map { $0.lamport > before.lamport } == true, "his edit went out")
    }

    /// Holding back every queued row for a record with a version this build
    /// cannot read let Mallory, at Add with a modified app, freeze Robin's
    /// transaction for good: she sent a copy of it in a made-up format, every
    /// Mac set it aside, and nothing Robin did to it went out again. Only a
    /// plain re-seal waits now. His edits and deletes go out, and the server
    /// weighs them by Lamport value.
    @Test func aMadeUpFormatCannotFreezeSomeoneElsesRecord() async throws {
        let robin = try Member(server: server), mallory = try Member(server: server)
        let groceries = groceries()
        try await robin.found(household, name: "Household", budgets: [groceries])
        try await robin.sync(household)
        try await mallory.join(household, from: robin, level: .write)
        let his = try robin.spend("Hilltop", in: groceries)
        try await robin.sync(household)
        func stored() async throws -> RecordEnvelope? {
            try await server.pull(group: household, since: 0, limit: 500).envelopes
                .first { $0.recordID == his.id }
        }
        let held = try #require(try await stored())

        let current = try mallory.forge(his, id: his.id, type: .transaction, group: household,
                                        budget: groceries.id, lamport: held.lamport + 5)
        let unsigned = RecordEnvelope(
            version: 99, recordID: current.recordID,
            recordType: current.recordType, groupID: current.groupID, budgetID: current.budgetID,
            keyEpoch: current.keyEpoch, ciphersuite: current.ciphersuite,
            payloadKind: current.payloadKind, nonce: current.nonce, ciphertext: current.ciphertext,
            lamport: current.lamport, authorUserID: current.authorUserID,
            authorDeviceID: current.authorDeviceID, membershipSequence: current.membershipSequence,
            isDeleted: false, signature: Data())
        let madeUp = RecordEnvelope(
            version: unsigned.version, recordID: unsigned.recordID, recordType: unsigned.recordType,
            groupID: unsigned.groupID, budgetID: unsigned.budgetID, keyEpoch: unsigned.keyEpoch,
            ciphersuite: unsigned.ciphersuite, payloadKind: unsigned.payloadKind,
            nonce: unsigned.nonce, ciphertext: unsigned.ciphertext, lamport: unsigned.lamport,
            authorUserID: unsigned.authorUserID, authorDeviceID: unsigned.authorDeviceID,
            membershipSequence: unsigned.membershipSequence, isDeleted: false,
            signature: try mallory.device.signing.signature(for: unsigned.signedBytes()))
        #expect(try await mallory.session.push([madeUp], group: household).accepted == [his.id])
        #expect(try await robin.sync(household).deferred == 1)

        var changed = try #require(try robin.store.transaction(his.id))
        changed.amount = Money(minorUnits: -2500)
        try robin.store.save(changed)
        #expect(try await robin.sync(household).pushed == 1, "his edit goes out")
        #expect(try await stored()?.authorUserID == robin.userID)
        #expect(try await stored()?.version == RecordEnvelope.currentVersion)

        changed.isDeleted = true
        try robin.store.save(changed)
        #expect(try await robin.sync(household).pushed == 1, "and so does his delete")
        #expect(try await stored()?.isDeleted == true)
    }

    /// A manager who knew Jamie's sign-up keys added him with them, with a
    /// junk group key sealed to him, then removed him without moving the
    /// epoch. The server keeps the first key for each slot, so when Robin
    /// later added him with everything so far, Jamie got the junk key and
    /// read nothing. A removal now takes the group keys stored for him.
    @Test func aRemovalTakesTheGroupKeysStoredForThePerson() async throws {
        let robin = try Member(server: server), mallory = try Member(server: server)
        let jamie = try Member(server: server)
        let groceries = groceries()
        try await robin.found(household, name: "Household", budgets: [groceries])
        let his = try robin.spend("Hilltop", in: groceries)
        try await robin.sync(household)
        try await mallory.join(household, from: robin, level: .manage)

        var (log, state) = try await mallory.membership(of: household)
        let junk = try KeyWrap.wrapToIdentity(
            ScopedKey.generate(scope: .group(household), epoch: state.epoch),
            recipient: jamie.identity.publicKeys, recipientUserID: jamie.userID,
            sender: mallory.identity, senderUserID: mallory.userID)
        try await mallory.session.appendMembership(try MembershipLogEntry.signed(
            scope: .group(household), sequence: UInt64(log.count), previousHash: state.head,
            action: .add, subjectUserID: jamie.userID, subjectKeys: jamie.identity.publicKeys,
            level: .read, epochAfter: state.epoch, author: mallory.identity,
            authorUserID: mallory.userID), group: household, wrappedKeys: [junk])
        (log, state) = try await mallory.membership(of: household)
        try await mallory.session.appendMembership(try MembershipLogEntry.signed(
            scope: .group(household), sequence: UInt64(log.count), previousHash: state.head,
            action: .remove, subjectUserID: jamie.userID, subjectKeys: nil, level: .none,
            epochAfter: state.epoch, author: mallory.identity, authorUserID: mallory.userID),
            group: household, wrappedKeys: [])

        try await jamie.join(household, from: robin, level: .read)
        #expect(try jamie.store.transaction(his.id)?.merchant == "Hilltop", "he reads everything so far")
    }

    /// A group key sealed to a member was taken with any entry from a
    /// manager. Mallory attached junk keys for an epoch Leslie never held,
    /// since she joined "from now on", to an entry registering her own
    /// laptop. Removed and invited back with everything so far, Leslie would
    /// have lost the real older key. A group key goes only to the person an
    /// entry adds, or for the epoch the entry starts.
    @Test func olderGroupKeysTravelOnlyWithTheirOwnEntry() async throws {
        let robin = try Member(server: server), mallory = try Member(server: server)
        let leslie = try Member(server: server)
        try await robin.found(household, name: "Household")
        try await robin.sync(household)
        try await mallory.join(household, from: robin, level: .manage)
        try await leslie.join(household, from: robin, level: .read, history: .fromNow)

        let (log, state) = try await mallory.membership(of: household)
        #expect(state.epoch == Epoch(1))
        let junk = try KeyWrap.wrapToIdentity(
            ScopedKey.generate(scope: .group(household), epoch: .initial),
            recipient: leslie.identity.publicKeys, recipientUserID: leslie.userID,
            sender: mallory.identity, senderUserID: mallory.userID)
        let laptop = DeviceKeyPair()
        let hers = try MembershipLogEntry.signed(
            scope: .group(household), sequence: UInt64(log.count), previousHash: state.head,
            action: .addDevice, subjectUserID: mallory.userID, subjectKeys: nil, level: .manage,
            epochAfter: state.epoch, deviceID: laptop.id, devicePublicKey: laptop.publicKey,
            author: mallory.identity, authorUserID: mallory.userID)
        await #expect(throws: ServerRefused.self) {
            try await mallory.session.appendMembership(hers, group: household, wrappedKeys: [junk])
        }
        try await mallory.session.appendMembership(hers, group: household, wrappedKeys: [])
        let slot = try await server.wrappedKeys(group: household, for: leslie.userID)
            .filter { $0.scope == .group(household) && $0.epoch == .initial }
        #expect(slot.isEmpty, "her empty slot stays empty")
    }

    /// The author's level, the device's registration and, for a format this
    /// build knows, the signature are all checked before a record is set
    /// aside. Set aside first, a record from a device nobody registered, or
    /// one signed with another key, took room on every Mac.
    @Test func anUnreadableRecordIsSetAsideOnlyWhenItsSenderChecksOut() async throws {
        let robin = try Member(server: server), leslie = try Member(server: server)
        try await robin.found(household, name: "Household")
        try await robin.sync(household)
        try await leslie.join(household, from: robin, level: .write)

        struct Future: Codable { let value: Int }
        func future(signedBy device: DeviceKeyPair) throws -> RecordEnvelope {
            try RecordCodec.seal(
                Future(value: 1), recordID: RecordID(), recordType: RecordType(rawValue: "future"),
                groupID: household, budgetID: nil,
                scopeKey: try leslie.keyRing.key(for: .group(household), epoch: .initial),
                lamport: 10_000, author: leslie.userID, device: device, membershipSequence: 0)
        }
        robin.leak.extra = [try future(signedBy: DeviceKeyPair()),
                            try future(signedBy: DeviceKeyPair(id: leslie.device.id))]
        let refused = try await robin.sync(household)
        #expect(refused.ignored == 2 && refused.deferred == 0, "got \(refused)")

        robin.leak.extra = [try future(signedBy: leslie.device)]
        #expect(try await robin.sync(household).deferred == 1)
    }
}
