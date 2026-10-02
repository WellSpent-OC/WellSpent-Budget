import Testing
import Foundation
import Crypto
@testable import WellSpentAppCore
import WellSpentCrypto
import WellSpentKeyStore
import WellSpentModel
import WellSpentStore
import WellSpentSync

/// Tests for the wire between the app and a server.
///
/// The transport here is `InMemoryTransport` wrapped in the account calls, not a
/// hand-written yes-man. That matters: it verifies signatures, replays the
/// membership log and refuses records from a device the log does not know about.
/// A stub that accepted everything would have passed while the device was never
/// enrolled, which is exactly the bug this layer is capable of having.
final class StubAccountTransport: AccountTransport, @unchecked Sendable {
    let inner: InMemoryTransport
    private var _userID: UserID
    var userID: UserID { lock.withLock { _userID } }
    /// When set, each email gets its own fixed account ID, the way the real
    /// server keeps one per email. For several accounts on one Mac.
    var idsFromEmail = false
    /// When set, sign-in fails the way a wrong password does.
    var refuseSignIn: HTTPTransport.Failure?
    /// Set at sign-up, so the invite calls know whose keys to hand out.
    private var keys: IdentityPublicKeys?

    /// Two of these over one `inner` are two people on one server.
    init(inner: InMemoryTransport = InMemoryTransport(), userID: UserID = UserID()) {
        self.inner = inner
        self._userID = userID
    }

    private func account(for email: String) {
        guard idsFromEmail else { return }
        let id = UUID(uuid: (Array(Data(email.lowercased().utf8).sha256Prefix(16)) + [UInt8](repeating: 0, count: 16))
                        .prefix(16).tuple16)
        lock.withLock { _userID = UserID(id) }
    }

    private var session: InMemorySession {
        get throws {
            guard let keys = lock.withLock({ keys }) else { throw HTTPTransport.Failure.notAuthenticated }
            return inner.session(for: userID, keys: keys)
        }
    }

    func createInvite(_ invite: NewInvite) async throws { try await session.createInvite(invite) }
    func lookupInvite(id: Data) async throws -> InviteLookup { try await session.lookupInvite(id: id) }
    func acceptInvite(id: Data, sealed: SealedAcceptance) async throws {
        try await session.acceptInvite(id: id, sealed: sealed)
    }
    func invites(in group: GroupID) async throws -> [PendingInvite] {
        if let action = takeHook(&_beforeInvitesRead, for: group) { await action() }
        return try await session.invites(in: group)
    }
    func deleteInvite(id: Data) async throws { try await session.deleteInvite(id: id) }
    func uploadKeys(_ keys: [WrappedKey], group: GroupID) async throws {
        try await session.uploadKeys(keys, group: group)
    }

    private let lock = NSLock()
    private var _appended: [MembershipLogEntry] = []
    private var _signUps = 0
    private var _signIns = 0

    /// When set, sign-up fails the way the real server fails.
    var refuseSignUp: HTTPTransport.Failure?

    var appended: [MembershipLogEntry] { lock.withLock { _appended } }
    var signUps: Int { lock.withLock { _signUps } }
    var signIns: Int { lock.withLock { _signIns } }

    private func credentials() -> HTTPTransport.Credentials {
        HTTPTransport.Credentials(userID: userID, token: "token-\(UUID().uuidString)",
                                  expiresOn: Date().addingTimeInterval(3600))
    }

    func signUp(email: String, password: String, identity: IdentityPublicKeys,
                escrow: RecoveryEscrow?) async throws -> HTTPTransport.Credentials {
        if let refuseSignUp { throw refuseSignUp }
        account(for: email)
        lock.withLock {
            _signUps += 1
            keys = identity
        }
        return credentials()
    }

    private var _resumed: HTTPTransport.Credentials?
    var resumed: HTTPTransport.Credentials? { lock.withLock { _resumed } }
    func resuming(with credentials: HTTPTransport.Credentials) -> any AccountTransport {
        lock.withLock { _resumed = credentials }
        return self
    }

    func signIn(email: String, password: String) async throws -> HTTPTransport.Credentials {
        if let refuseSignIn { throw refuseSignIn }
        account(for: email)
        lock.withLock { _signIns += 1 }
        return credentials()
    }

    /// Counts revocations, so a sign-out that never reaches the server is a
    /// test failure rather than something nobody notices.
    private var _signOuts = 0
    var signOuts: Int { lock.withLock { _signOuts } }

    func signOut() async throws {
        lock.withLock { _signOuts += 1 }
    }

    func appendMembership(_ entry: MembershipLogEntry, group: GroupID,
                          wrappedKeys: [WrappedKey]) async throws {
        lock.withLock { _appended.append(entry) }
        inner.append(entry, to: group)
        if !wrappedKeys.isEmpty { inner.seed(keys: wrappedKeys, for: group) }
        if let action = takeHook(&_whileAppending, for: group) { await action() }
    }

    private var _whileAppending: (group: GroupID, action: Hook)?

    /// Runs `action` once, the next time an entry goes into this group's
    /// log, after the server has taken it and before the answer comes back.
    func whileNextAppend(to group: GroupID, _ action: @escaping Hook) {
        lock.withLock { _whileAppending = (group, action) }
    }

    /// When set, every push is refused with this reason. The in-memory server
    /// refuses less than the real one, so this stands in for it.
    var refuseEverything: String?
    /// Records refused whenever they are pushed, each with its reason.
    var refusing: [RecordID: String] = [:]

    func push(_ envelopes: [RecordEnvelope], group: GroupID) async throws -> PushResult {
        if let failEveryPush, failEveryPush.group == group { throw failEveryPush.failure }
        if let reason = refuseEverything {
            let refused = envelopes.map { ($0.recordID, reason) }
            return PushResult(accepted: [], rejected: Dictionary(uniqueKeysWithValues: refused),
                              serverSeq: 0)
        }
        let passed = try await inner.push(envelopes.filter { refusing[$0.recordID] == nil }, group: group)
        var rejected = passed.rejected
        for envelope in envelopes {
            if let reason = refusing[envelope.recordID] { rejected[envelope.recordID] = reason }
        }
        return PushResult(accepted: passed.accepted, rejected: rejected, serverSeq: passed.serverSeq)
    }

    func pull(group: GroupID, since: UInt64, limit: Int) async throws -> PullResult {
        if let action = takeHook(&_beforePull, for: group) { await action() }
        let failure: HTTPTransport.Failure? = lock.withLock {
            guard let set = failNextPull, set.group == group else { return nil }
            failNextPull = nil
            return set.failure
        }
        if let failure { throw failure }
        if let failEveryPull, failEveryPull.group == group { throw failEveryPull.failure }
        return try await inner.pull(group: group, since: since, limit: limit)
    }

    /// When set, the next pull of this group fails this way, once.
    var failNextPull: (group: GroupID, failure: HTTPTransport.Failure)?
    /// When set, every pull of this group fails this way, as a page this
    /// build cannot read would.
    var failEveryPull: (group: GroupID, failure: HTTPTransport.Failure)?
    /// The same for every push to this group.
    var failEveryPush: (group: GroupID, failure: HTTPTransport.Failure)?

    typealias Hook = @MainActor @Sendable () async -> Void
    private var _beforePull: (group: GroupID, action: Hook)?
    private var _beforeLogRead: (group: GroupID, action: Hook)?

    /// Runs `action` once, the next time this group's records are pulled, while
    /// the sync round waits on this server. For something a person does in
    /// the middle of a round.
    func beforeNextPull(of group: GroupID, _ action: @escaping Hook) {
        lock.withLock { _beforePull = (group, action) }
    }

    /// The same, the next time this group's log is read.
    func beforeNextLogRead(of group: GroupID, _ action: @escaping Hook) {
        lock.withLock { _beforeLogRead = (group, action) }
    }

    private var _beforeInvitesRead: (group: GroupID, action: Hook)?

    /// The same, the next time this group's open invites are read, which is
    /// after the log read in `finishInvites` and before anyone is added.
    func beforeNextInvitesRead(of group: GroupID, _ action: @escaping Hook) {
        lock.withLock { _beforeInvitesRead = (group, action) }
    }

    private func takeHook(_ hook: inout (group: GroupID, action: Hook)?, for group: GroupID) -> Hook? {
        lock.withLock {
            guard let set = hook, set.group == group else { return nil }
            hook = nil
            return set.action
        }
    }

    /// When set, a read of this group's whole log gets this one instead, the
    /// way a dishonest server could answer. Reads that extend a log already
    /// held still get the real entries.
    var madeUpLog: (group: GroupID, log: [MembershipLogEntry])?

    /// When set, reading any log fails this way, for errors that are not a 403.
    var failLogRead: HTTPTransport.Failure?
    /// The same, for one group's log only.
    var failLogReadOf: (group: GroupID, failure: HTTPTransport.Failure)?

    /// Log reads per group, so a test can tell a group was left alone.
    private var _logReads: [GroupID: Int] = [:]
    func logReads(of group: GroupID) -> Int { lock.withLock { _logReads[group] ?? 0 } }

    /// The real server answers 403 for a group it has never seen, the same as
    /// for a group you are not in. This answered with an empty log instead, the
    /// way an older server did, and so passed while the app could not found a
    /// group on the live one. It also answered anyone who was not yet a member,
    /// which the real server never does.
    func membershipLog(group: GroupID, since: UInt64) async throws -> [MembershipLogEntry] {
        lock.withLock { _logReads[group, default: 0] += 1 }
        if let action = takeHook(&_beforeLogRead, for: group) { await action() }
        if let failLogRead { throw failLogRead }
        if let madeUpLog, madeUpLog.group == group, since == 0 { return madeUpLog.log }
        if let failLogReadOf, failLogReadOf.group == group { throw failLogReadOf.failure }
        let log = try await inner.membershipLog(group: group, since: 0)
        guard !log.isEmpty,
              (try? MembershipLog.replay(log, scope: .group(group)))?.allows(userID, .read) != false
        else {
            throw HTTPTransport.Failure.http(status: 403,
                                             reason: "you are not a member of that group")
        }
        return log.filter { $0.sequence >= since }
    }

    func wrappedKeys(group: GroupID, for user: UserID) async throws -> [WrappedKey] {
        try await inner.wrappedKeys(group: group, for: user)
    }
}

/// A key store that refuses, the way the data protection keychain refuses an
/// unsigned build.
final class RefusingKeyStore: KeyStore, @unchecked Sendable {
    func store(_ data: Data, for item: KeyStoreItem) throws {
        throw KeyStoreError.backendFailure("SecItemAdd -34018 for \(item.rawValue)")
    }
    func load(_ item: KeyStoreItem) throws -> Data? { nil }
    func delete(_ item: KeyStoreItem) throws {}
    func removeAll() throws {}
}

/// Keeps everything except the server token, so a sign-in gets all the way past
/// the server and then fails on this Mac.
final class TokenRefusingKeyStore: KeyStore, @unchecked Sendable {
    private let inner = InMemoryKeyStore()
    func store(_ data: Data, for item: KeyStoreItem) throws {
        if item == .serverToken { throw KeyStoreError.backendFailure("no token today") }
        try inner.store(data, for: item)
    }
    func load(_ item: KeyStoreItem) throws -> Data? { try inner.load(item) }
    func delete(_ item: KeyStoreItem) throws { try inner.delete(item) }
    func removeAll() throws { try inner.removeAll() }
}

/// Defaults the tests own, cleared on creation.
///
/// `UserDefaults.standard` is shared with everything else this process has ever
/// run, so one test setting a deliberately bad server address made every later
/// test read it back. Found by exactly that failure.
@MainActor
func isolatedDefaults() -> UserDefaults {
    let name = "app.wellspent.tests"
    let defaults = UserDefaults(suiteName: name)!
    defaults.removePersistentDomain(forName: name)
    return defaults
}

@MainActor
private struct Fixture {
    let model: AppModel
    let keyStore: InMemoryKeyStore
    let transport: StubAccountTransport
    let sync: SyncCoordinator
    let group: BudgetGroup
    let budget: Budget

    init(keyStore: InMemoryKeyStore = InMemoryKeyStore(),
         transport: StubAccountTransport = StubAccountTransport()) throws {
        let store = Store(database: try WellSpentDatabase.inMemory())
        model = AppModel(store: store)
        self.keyStore = keyStore
        self.transport = transport
        let captured = transport
        sync = SyncCoordinator(store: store, keyStore: keyStore,
                               defaults: isolatedDefaults(),
                               makeTransport: { _ in captured })

        model.addGroup(named: "Household")
        group = try #require(model.groups.first)
        model.addBudget(named: "Groceries", limit: Money(minorUnits: 100_000), in: group.id)
        budget = try #require(model.summaries[group.id]?.first?.budget)
        model.selectedBudget = budget.id
    }
}

@Suite("Sync coordinator", .serialized)
@MainActor
struct SyncCoordinatorTests {

    // MARK: - Accounts

    @Test func signingUpReturnsTwelveWordsAndSignsIn() async throws {
        let f = try Fixture()
        let enrolment = try await f.sync.signUp(email: "robin@example.com", password: "a-long-password")

        #expect(enrolment.recoveryWords.count == 12)
        #expect(enrolment.email == "robin@example.com")
        #expect(f.sync.state == .signedIn(email: "robin@example.com"))
        #expect(f.sync.account == "robin@example.com")
        #expect(f.transport.signUps == 1)
    }

    /// The words are the only copy. Holding them for the screen to show is part of
    /// signing up, not an afterthought that can be skipped.
    @Test func theRecoveryCodeWaitsToBeShown() async throws {
        let f = try Fixture()
        let enrolment = try await f.sync.signUp(email: "robin@example.com", password: "a-long-password")

        #expect(f.sync.pendingEnrolment?.recoveryWords == enrolment.recoveryWords)
        f.sync.recoveryWordsWereWrittenDown()
        #expect(f.sync.pendingEnrolment == nil)
        #expect(try f.keyStore.load(.recoveryConfirmedAt) != nil)
    }

    @Test func signingUpKeepsTheIdentityAndTheTokenOnThisDevice() async throws {
        let f = try Fixture()
        try await f.sync.signUp(email: "robin@example.com", password: "a-long-password")

        #expect(try f.keyStore.load(.identity) != nil)
        #expect(try f.keyStore.load(.deviceSigning) != nil)
        #expect(try f.keyStore.load(.serverToken) != nil)
        #expect(f.sync.hasIdentity)
    }

    /// The identity never goes to the server in the clear, so a second device
    /// cannot get it by signing in. Saying that plainly beats signing in and then
    /// failing to open anything.
    @Test func signingInOnADeviceWithNoIdentityIsRefusedWithAReason() async throws {
        let f = try Fixture()
        #expect(!f.sync.hasIdentity)

        await #expect(throws: SyncCoordinator.Failure.noIdentityOnThisDevice) {
            try await f.sync.signIn(email: "robin@example.com", password: "a-long-password")
        }
        guard case .failed(let why) = f.sync.state else {
            Issue.record("expected a failed state, got \(f.sync.state)")
            return
        }
        #expect(why.contains("Pairing a second device"))
        #expect(f.transport.signIns == 0, "nothing should reach the server")
    }

    @Test func signingInWorksWhenTheIdentityIsAlreadyHere() async throws {
        let keyStore = InMemoryKeyStore()
        let first = try Fixture(keyStore: keyStore)
        try await first.sync.signUp(email: "robin@example.com", password: "a-long-password")

        // Same device, next launch: a new coordinator over the same key store.
        let next = try Fixture(keyStore: keyStore)
        try await next.sync.signIn(email: "robin@example.com", password: "a-long-password")
        #expect(next.sync.isSignedIn)
        #expect(next.transport.signIns == 1)
    }

    @Test func signingOutForgetsTheTokenAndKeepsTheIdentity() async throws {
        let f = try Fixture()
        try await f.sync.signUp(email: "robin@example.com", password: "a-long-password")
        await f.sync.signOut()

        #expect(f.sync.state == .signedOut)
        #expect(f.sync.account == nil)
        #expect(try f.keyStore.load(.serverToken) == nil)
        #expect(try f.keyStore.load(.identity) != nil, "signing out is not losing your budgets")
        #expect(f.transport.signOuts == 1,
                "clearing the token here leaves the session live on the server for 30 days")
    }

    @Test func aServerAddressThatIsNotAnAddressIsRefusedBeforeAnyNetworkCall() async throws {
        let f = try Fixture()
        f.sync.serverAddress = "wellspent"

        await #expect(throws: (any Error).self) {
            try await f.sync.signUp(email: "robin@example.com", password: "a-long-password")
        }
        #expect(f.transport.signUps == 0)
        guard case .failed(let why) = f.sync.state else {
            Issue.record("expected a failed state, got \(f.sync.state)")
            return
        }
        #expect(why.contains("not a server address"))
    }

    @Test func aRefusedSignUpReadsAsTheServerPutIt() async throws {
        let transport = StubAccountTransport()
        transport.refuseSignUp = .http(status: 400, reason: "That email is already in use.")
        let f = try Fixture(transport: transport)

        await #expect(throws: (any Error).self) {
            try await f.sync.signUp(email: "robin@example.com", password: "a-long-password")
        }
        #expect(f.sync.state == .failed("That email is already in use."))
    }

    /// A five hundred is not the person's fault and should not read like it is.
    @Test func aServerErrorSaysWhichOne() async throws {
        let transport = StubAccountTransport()
        transport.refuseSignUp = .http(status: 503, reason: "upstream unavailable")
        let f = try Fixture(transport: transport)

        _ = try? await f.sync.signUp(email: "robin@example.com", password: "a-long-password")
        #expect(f.sync.state == .failed("The server said 503: upstream unavailable"))
    }

    @Test func aKeyStoreThatRefusesSaysSoInWords() async throws {
        let store = Store(database: try WellSpentDatabase.inMemory())
        let transport = StubAccountTransport()
        let sync = SyncCoordinator(store: store, keyStore: RefusingKeyStore(),
                                   defaults: isolatedDefaults(),
                                   makeTransport: { _ in transport })

        await #expect(throws: (any Error).self) {
            try await sync.signUp(email: "robin@example.com", password: "a-long-password")
        }
        guard case .failed(let why) = sync.state else {
            Issue.record("expected a failed state, got \(sync.state)")
            return
        }
        #expect(why.contains("would not store the key"))
        #expect(why.contains("-34018"), "the actual reason, not a shrug")
    }

    /// A failed sign-in must leave no account behind, because the account is what
    /// puts Sign out in the toolbar.
    @Test func aFailedSignUpLeavesNoAccount() async throws {
        let transport = StubAccountTransport()
        transport.refuseSignUp = .http(status: 400, reason: "That email is already in use.")
        let f = try Fixture(transport: transport)

        _ = try? await f.sync.signUp(email: "robin@example.com", password: "a-long-password")
        #expect(f.sync.account == nil)
    }

    /// The server said yes, but this Mac could not keep the token. Still not signed in.
    @Test func aTokenThatCannotBeSavedLeavesNoAccount() async throws {
        let store = Store(database: try WellSpentDatabase.inMemory())
        let transport = StubAccountTransport()
        let sync = SyncCoordinator(store: store, keyStore: TokenRefusingKeyStore(),
                                   defaults: isolatedDefaults(),
                                   makeTransport: { _ in transport })

        await #expect(throws: (any Error).self) {
            try await sync.signUp(email: "robin@example.com", password: "a-long-password")
        }
        #expect(transport.signUps == 1, "the failure has to come after the server said yes")
        #expect(sync.account == nil)
        #expect(!sync.isSignedIn)
    }

    // MARK: - Syncing

    @Test func syncingWithoutSigningInSaysSoRatherThanThrowing() async throws {
        let f = try Fixture()
        let report = await f.sync.syncAll()

        #expect(report.pushed == 0)
        #expect(f.sync.state == .failed("Sign in first."))
    }

    @Test func theFirstSyncFoundsTheGroupAndEnrolsThisDevice() async throws {
        let f = try Fixture()
        f.model.addTransaction(merchant: "Hilltop", amount: Money(minorUnits: 14208),
                              date: Date(), note: "")
        try await f.sync.signUp(email: "robin@example.com", password: "a-long-password")

        let report = await f.sync.syncAll()

        let founding = try #require(f.transport.appended.first)
        #expect(f.transport.appended.count == 1)
        #expect(founding.action == .found)
        #expect(founding.sequence == 0)
        #expect(founding.deviceID != nil, "without this the server refuses every push")
        #expect(founding.devicePublicKey != nil)

        // The group, the budget and the transaction, sealed and accepted.
        #expect(report.pushed == 3, "got \(report), state \(f.sync.state)")
        #expect(report.rejected == 0)
        #expect(f.sync.lastSyncedAt != nil)
        #expect(f.sync.state == .signedIn(email: "robin@example.com"))
    }

    /// Only a 403 means "not founded yet". Anything else, such as a server that
    /// is down, must stop the sync rather than found a group that may exist.
    @Test func aServerErrorOnTheFirstReadIsNotMistakenForANewGroup() async throws {
        let f = try Fixture()
        try await f.sync.signUp(email: "robin@example.com", password: "a-long-password")
        f.transport.failLogRead = .http(status: 503, reason: "database unreachable")

        let report = await f.sync.syncAll()

        #expect(f.transport.appended.isEmpty)
        #expect(report.pushed == 0)
        guard case .failed = f.sync.state else {
            Issue.record("expected a failure, got \(f.sync.state)")
            return
        }
    }

    @Test func thePushedRecordsAreCiphertextTheServerCannotRead() async throws {
        let f = try Fixture()
        f.model.addTransaction(merchant: "Riverside Grill", amount: Money(minorUnits: 6810),
                              date: Date(), note: "birthday")
        try await f.sync.signUp(email: "robin@example.com", password: "a-long-password")
        await f.sync.syncAll()

        let blobs = f.transport.inner.ciphertexts(in: f.group.id)
        #expect(!blobs.isEmpty)
        for blob in blobs {
            let text = String(decoding: blob, as: UTF8.self)
            #expect(!text.contains("Riverside Grill"))
            #expect(!text.contains("birthday"))
        }
    }

    @Test func aSecondSyncDoesNotFoundTheGroupAgain() async throws {
        let f = try Fixture()
        try await f.sync.signUp(email: "robin@example.com", password: "a-long-password")

        await f.sync.syncAll()
        await f.sync.syncAll()

        #expect(f.transport.appended.count == 1)
        #expect(f.sync.state == .signedIn(email: "robin@example.com"))
    }

    /// The bug this stops: a budget made after the first sync has no key, and the
    /// engine skips what it cannot seal, so those rows sit in the outbox in
    /// silence.
    @Test func aBudgetAddedAfterTheFirstSyncStillPushes() async throws {
        let f = try Fixture()
        try await f.sync.signUp(email: "robin@example.com", password: "a-long-password")
        await f.sync.syncAll()

        f.model.addBudget(named: "Fuel", limit: Money(minorUnits: 20_000), in: f.group.id)
        let fuel = try #require(f.model.summaries[f.group.id]?
            .first { $0.budget.name == "Fuel" }?.budget)
        f.model.selectedBudget = fuel.id
        f.model.addTransaction(merchant: "Chevron", amount: Money(minorUnits: 5500),
                              date: Date(), note: "")

        let report = await f.sync.syncAll()
        #expect(report.pushed == 2, "the new budget and its transaction, got \(report)")
        #expect(try f.model.store.outboxCount(in: f.group.id) == 0)
    }

    /// The bug this stops: the sync loop skipped deleted groups, so a group that
    /// had already reached the server was deleted on the Mac and never anywhere
    /// else. Found on the live server as a fourth group nobody could see.
    @Test func deletingASyncedGroupSendsTheDelete() async throws {
        let f = try Fixture()
        try await f.sync.signUp(email: "robin@example.com", password: "a-long-password")
        await f.sync.syncAll()

        f.model.deleteGroup(f.group.id, reach: .justYou)
        let report = await f.sync.syncAll()

        #expect(report.pushed == 2, "the group and its budget, got \(report)")
        #expect(try f.model.store.outboxCount(in: f.group.id) == 0)
        let pulled = try await f.transport.inner.pull(group: f.group.id, since: 0, limit: 100)
        let meta = try #require(pulled.envelopes.first { $0.recordType == .groupMeta })
        #expect(meta.isDeleted)

        // Done once. The next sync leaves the group alone, down to not reading
        // its log. Counting pushes alone could not tell, because a second pass
        // with nothing left to send also pushes nothing.
        let reads = f.transport.logReads(of: f.group.id)
        let again = await f.sync.syncAll()
        #expect(again.pushed == 0)
        #expect(f.transport.logReads(of: f.group.id) == reads)
        #expect(f.sync.state == .signedIn(email: "robin@example.com"))
    }

    /// A budget made since the last sync has no key yet, and the engine skips
    /// what it cannot seal. Deleting the group used to leave that budget's rows
    /// queued for good, and the hidden group came back into every sync after.
    @Test func aDeletedGroupFinishesWithABudgetThatNeverSynced() async throws {
        let f = try Fixture()
        try await f.sync.signUp(email: "robin@example.com", password: "a-long-password")
        await f.sync.syncAll()

        f.model.addBudget(named: "Travel", limit: Money(minorUnits: 50_000), in: f.group.id)
        f.model.deleteGroup(f.group.id, reach: .justYou)
        let report = await f.sync.syncAll()

        #expect(try f.model.store.outboxCount(in: f.group.id) == 0, "got \(report)")
        let reads = f.transport.logReads(of: f.group.id)
        await f.sync.syncAll()
        #expect(f.transport.logReads(of: f.group.id) == reads, "the group is finished with")
        #expect(f.sync.state == .signedIn(email: "robin@example.com"))
    }

    /// The server refuses a deleted group's rows for a reason no later sync
    /// can change. Nothing in a deleted group can be edited again, so a
    /// refused row could never be taken. Keeping it meant sending it on every
    /// sync, for good. The reason here is not "older": the engine drops a row
    /// refused as older by itself, and this pins the drop after the push.
    @Test func whatTheServerRefusesForADeletedGroupIsDropped() async throws {
        let f = try Fixture()
        try await f.sync.signUp(email: "robin@example.com", password: "a-long-password")
        await f.sync.syncAll()

        f.model.deleteGroup(f.group.id, reach: .justYou)
        f.transport.refuseEverything = "another record already has this ID"
        let report = await f.sync.syncAll()

        #expect(report.rejected == 2, "the group and its budget, got \(report)")
        #expect(try f.model.store.outboxCount(in: f.group.id) == 0)
        let reads = f.transport.logReads(of: f.group.id)
        await f.sync.syncAll()
        #expect(f.transport.logReads(of: f.group.id) == reads)
    }

    /// Letting go keeps a deleted group's queue through failures that clear
    /// up by themselves, and gives up only on the others.
    @Test func onlyFailuresThatClearUpKeepAQueueForLater() {
        #expect(SyncCoordinator.mayClearUp(URLError(.notConnectedToInternet)))
        #expect(SyncCoordinator.mayClearUp(CancellationError()))
        #expect(SyncCoordinator.mayClearUp(HTTPTransport.Failure.notAuthenticated))
        for status in [401, 408, 429, 500, 503] {
            #expect(SyncCoordinator.mayClearUp(HTTPTransport.Failure.http(status: status, reason: "")),
                    "\(status)")
        }
        #expect(!SyncCoordinator.mayClearUp(HTTPTransport.Failure.http(status: 400, reason: "")))
        #expect(!SyncCoordinator.mayClearUp(HTTPTransport.Failure.malformedResponse("unreadable")))
    }

    /// A deleted group with more than a page queued. The push sends every
    /// page, so the rows dropped after it must come from every page too. A
    /// refused row past the first page stayed queued, and the hidden group
    /// took another round to finish.
    @Test func aDeletedGroupWithMoreThanAPageFinishesInOnePass() async throws {
        let f = try Fixture()
        try await f.sync.signUp(email: "robin@example.com", password: "a-long-password")
        await f.sync.syncAll()

        for index in 0 ..< 220 {
            try f.model.store.save(Transaction(
                budgetID: f.budget.id, groupID: f.group.id, date: Date(),
                merchant: "Hilltop \(index)", amount: Money(minorUnits: -100)))
        }
        f.model.deleteGroup(f.group.id, reach: .justYou)
        let queued = try f.model.store.pendingPushes(in: f.group.id, limit: 1_000)
        #expect(queued.count > 210)
        f.transport.refusing[queued[210].recordID] = "another record already has this ID"
        let report = await f.sync.syncAll()

        #expect(report.rejected == 1, "got \(report)")
        #expect(try f.model.store.outboxCount(in: f.group.id) == 0)
        let reads = f.transport.logReads(of: f.group.id)
        await f.sync.syncAll()
        #expect(f.transport.logReads(of: f.group.id) == reads, "the group is finished with")
    }

    /// The same with more than a page still queued after the push. Every row
    /// left is checked, not only the first page of them, or the refused rows
    /// past it stay queued and the hidden group takes another round.
    @Test func aDeletedGroupWithMoreThanAPageRefusedFinishesInOnePass() async throws {
        let f = try Fixture()
        try await f.sync.signUp(email: "robin@example.com", password: "a-long-password")
        await f.sync.syncAll()

        for index in 0 ..< 220 {
            try f.model.store.save(Transaction(
                budgetID: f.budget.id, groupID: f.group.id, date: Date(),
                merchant: "Hilltop \(index)", amount: Money(minorUnits: -100)))
        }
        f.model.deleteGroup(f.group.id, reach: .justYou)
        let queued = try f.model.store.pendingPushes(in: f.group.id, limit: 1_000)
        for item in queued.prefix(210) {
            f.transport.refusing[item.recordID] = "another record already has this ID"
        }
        let report = await f.sync.syncAll()

        #expect(report.rejected == 210, "got \(report)")
        #expect(try f.model.store.outboxCount(in: f.group.id) == 0)
    }

    /// A group deleted while the round is still on an earlier group is read
    /// again when the round reaches it, so its delete goes out in this round
    /// rather than waiting for the next.
    @Test func aGroupDeletedMidRoundTakesTheDeletedPath() async throws {
        let f = try Fixture()
        let alpha = try #require(f.model.addGroup(named: "Alpha"))
        try await f.sync.signUp(email: "robin@example.com", password: "a-long-password")
        await f.sync.syncAll()

        let model = f.model, household = f.group.id
        f.transport.beforeNextPull(of: alpha) { model.deleteGroup(household, reach: .justYou) }
        await f.sync.syncAll()

        #expect(try f.model.store.outboxCount(in: household) == 0, "its delete went out in this round")
        let pulled = try await f.transport.inner.pull(group: household, since: 0, limit: 100)
        #expect(pulled.envelopes.first { $0.recordType == .groupMeta }?.isDeleted == true)
    }

    /// A deleted group that fails every time used to end the round, so every
    /// live group named after it stopped syncing too, with the error pinned
    /// to a group nobody could see.
    @Test func aFailingDeletedGroupDoesNotStopTheLiveOnes() async throws {
        let f = try Fixture()
        let archive = try #require(f.model.addGroup(named: "Archive"))
        try await f.sync.signUp(email: "robin@example.com", password: "a-long-password")
        await f.sync.syncAll()

        f.model.deleteGroup(archive, reach: .justYou)
        f.transport.failLogReadOf = (archive, .http(status: 503, reason: "database unreachable"))
        f.model.addTransaction(merchant: "Hilltop", amount: Money(minorUnits: 14208),
                              date: Date(), note: "")
        await f.sync.syncAll()

        #expect(try f.model.store.outboxCount(in: f.group.id) == 0, "Household, after Archive, still syncs")
        #expect(try f.model.store.outboxCount(in: archive) > 0, "Archive tries again next time")
        #expect(f.sync.state == .failed("The server said 503: database unreachable"))
    }

    /// A group deleted before it ever synced is not founded on the server just
    /// to carry its own tombstone.
    @Test func deletingAGroupTheServerNeverSawDropsItQuietly() async throws {
        let f = try Fixture()
        try await f.sync.signUp(email: "robin@example.com", password: "a-long-password")

        f.model.deleteGroup(f.group.id, reach: .justYou)
        let report = await f.sync.syncAll()

        #expect(f.transport.appended.isEmpty, "nothing founded")
        #expect(report.pushed == 0)
        #expect(try f.model.store.outboxCount(in: f.group.id) == 0)
        #expect(f.sync.state == .signedIn(email: "robin@example.com"))
    }

    /// Founding must not replace a key this device already used, because the
    /// statement fingerprints were computed with it.
    @Test func foundingKeepsTheKeyThisDeviceAlreadyMinted() async throws {
        let f = try Fixture()
        let before = try f.model.store.localKey(for: .group(f.group.id)).rawBytes

        try await f.sync.signUp(email: "robin@example.com", password: "a-long-password")
        await f.sync.syncAll()

        let after = try f.model.store.localKey(for: .group(f.group.id)).rawBytes
        #expect(before == after)
    }

    /// Without this the field resets to localhost on every launch, so the
    /// address of the server you actually use gets retyped every time.
    @Test func theServerAddressSurvivesARelaunch() throws {
        let defaults = isolatedDefaults()
        let store = Store(database: try WellSpentDatabase.inMemory())

        let first = SyncCoordinator(store: store, keyStore: InMemoryKeyStore(),
                                    defaults: defaults)
        #expect(first.serverAddress == "https://sync.wellspent.space", "the hosted default")
        first.serverAddress = "http://127.0.0.1:8080"

        let next = SyncCoordinator(store: store, keyStore: InMemoryKeyStore(),
                                   defaults: defaults)
        #expect(next.serverAddress == "http://127.0.0.1:8080")
    }

    @Test func syncingOneGroupWhileSignedOutThrows() async throws {
        let f = try Fixture()
        await #expect(throws: SyncCoordinator.Failure.notSignedIn) {
            _ = try await f.sync.sync(group: f.group.id)
        }
    }
}

extension Data {
    func sha256Prefix(_ count: Int) -> Data { Data(SHA256.hash(data: self).prefix(count)) }
}

extension ArraySlice where Element == UInt8 {
    var tuple16: uuid_t {
        let b = Array(self)
        return (b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7],
                b[8], b[9], b[10], b[11], b[12], b[13], b[14], b[15])
    }
}
