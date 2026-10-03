import Foundation
import Observation
import Crypto
import WellSpentCrypto
import WellSpentKeyStore
import WellSpentModel
import WellSpentStore
import WellSpentSync

/// What the app needs from a server, beyond syncing.
///
/// `SyncTransport` already covers push, pull, the membership log and key
/// delivery. Creating an account and appending to a log are account operations,
/// and keeping them in their own protocol is what lets a test replace the whole
/// server without one running.
public protocol AccountTransport: InviteTransport {
    @discardableResult
    func signUp(email: String, password: String, identity: IdentityPublicKeys,
                escrow: RecoveryEscrow?) async throws -> HTTPTransport.Credentials
    @discardableResult
    func signIn(email: String, password: String) async throws -> HTTPTransport.Credentials
    func signOut() async throws
    /// The same server, signed in with a session saved from an earlier launch.
    func resuming(with credentials: HTTPTransport.Credentials) -> any AccountTransport
}

extension HTTPTransport: AccountTransport {
    public nonisolated func resuming(with credentials: Credentials) -> any AccountTransport {
        let resumed: HTTPTransport = resuming(with: credentials)
        return resumed
    }
}

/// Connects the app to a server.
///
/// Every piece of this existed and was tested before this file: the key
/// hierarchy, the sync engine, the HTTP client, the server itself. None of it was
/// attached to the app, which read and wrote a local database and stopped there.
/// This is the attachment.
///
/// It owns the three things the engine needs and the app had nowhere to keep: the
/// identity key pair, this device's signing key, and the key ring.
@MainActor
@Observable
public final class SyncCoordinator {
    public enum State: Equatable, Sendable {
        case signedOut
        case busy(String)
        case signedIn(email: String)
        case failed(String)
    }

    /// What signing up hands back, once.
    ///
    /// The twelve words are shown to the person and never stored. Losing them and
    /// every device means losing the data, which is the price of a server that
    /// cannot read it.
    public struct Enrolment: Sendable, Equatable {
        public let email: String
        public let recoveryWords: [String]
    }

    public enum Failure: Error, Equatable, Sendable {
        /// Signing in on a device that has never held this account's identity key.
        ///
        /// Pairing a second device and recovering from the twelve words are both
        /// unbuilt. Until they exist this is a wall, and it says so rather than
        /// signing in and then failing to open anything.
        case noIdentityOnThisDevice
        case notSignedIn
        case server(String)
    }

    public private(set) var state: State = .signedOut
    public private(set) var lastReport: SyncReport?
    public private(set) var lastSyncedAt: Date?
    /// Groups this person asked to join, until the inviter's app adds them.
    public private(set) var pendingJoins: [PendingJoin] = []
    /// Called after every sync, so the screens reload what it brought in.
    public var didSync: (@MainActor () -> Void)?
    /// Set once by `signUp`, cleared when the person says they have written the
    /// words down. The only copy is on screen.
    public var pendingEnrolment: Enrolment?

    /// Remembered between launches. Without this the field resets to localhost
    /// every time the app opens, and the address of the server you actually use
    /// has to be retyped.
    public var serverAddress: String {
        didSet { defaults.set(serverAddress, forKey: Self.serverAddressKey) }
    }

    static let serverAddressKey = "WellSpentServerAddress"
    /// The hosted server. `make serve` runs one locally at `http://127.0.0.1:8080`
    /// for development; type that into the field to use it.
    public static let defaultServerAddress = "https://sync.wellspent.space"
    /// Who is signed in, kept separately from `state` so a sync that runs from
    /// `.busy` knows what to put back when it finishes.
    public private(set) var account: String?

    /// The signed-in account's database, or "This Mac" when nobody is.
    public private(set) var store: Store
    private var keyStore: any KeyStore
    /// Set when each account keeps its own keys and database. Nil keeps the older
    /// arrangement of one of each, which the tests of everything else still use.
    private let accounts: AccountDirectory?
    /// Called when signing in or out switches to another database, so the
    /// screens can switch with it.
    public var didSwitchStore: (@MainActor (Store) -> Void)?
    private let defaults: UserDefaults
    private let makeTransport: @Sendable (URL) -> any AccountTransport

    private var transport: (any AccountTransport)?
    private var identity: IdentityKeyPair?
    private var device: DeviceKeyPair?
    private var keyRing: KeyRing?
    /// Who is signed in, so the app can say "You" on their own transactions.
    public private(set) var userID: UserID?

    public init(store: Store,
                keyStore: any KeyStore,
                defaults: UserDefaults = .standard,
                serverAddress: String? = nil,
                makeTransport: @escaping @Sendable (URL) -> any AccountTransport = {
                    HTTPTransport(baseURL: $0)
                }) {
        self.store = store
        self.keyStore = keyStore
        self.accounts = nil
        self.defaults = defaults
        self.serverAddress = serverAddress
            ?? defaults.string(forKey: Self.serverAddressKey)
            ?? Self.defaultServerAddress
        self.makeTransport = makeTransport
        pendingJoins = (try? store.pendingJoins()) ?? []
    }

    /// One Mac login, any number of WellSpent accounts. Opens on whoever was
    /// signed in last, if their session is still good, and on "This Mac"
    /// otherwise.
    public init(accounts: AccountDirectory,
                defaults: UserDefaults = .standard,
                serverAddress: String? = nil,
                makeTransport: @escaping @Sendable (URL) -> any AccountTransport = {
                    HTTPTransport(baseURL: $0)
                }) throws {
        self.accounts = accounts
        self.store = Store(database: try accounts.database(for: nil))
        self.keyStore = accounts.keyStore(for: nil)
        self.defaults = defaults
        self.serverAddress = serverAddress
            ?? defaults.string(forKey: Self.serverAddressKey)
            ?? Self.defaultServerAddress
        self.makeTransport = makeTransport
        resumeLastSession()
        pendingJoins = (try? store.pendingJoins()) ?? []
    }

    /// What is kept between launches. The token alone is not enough: resuming
    /// needs to know whose it is without asking the server.
    struct SavedSession: Codable {
        let email: String
        let credentials: HTTPTransport.Credentials
    }

    private func resumeLastSession() {
        guard let accounts, let email = accounts.lastAccount else { return }
        let namespace = AccountDirectory.namespace(for: email)
        let keys = accounts.keyStore(for: namespace)
        guard let data = try? keys.load(.serverToken),
              let saved = try? JSONDecoder().decode(SavedSession.self, from: data),
              saved.credentials.expiresOn > Date(),
              let url = try? serverURL(),
              let database = try? accounts.database(for: namespace) else { return }
        keyStore = keys
        identity = nil
        device = nil
        let transport = makeTransport(url).resuming(with: saved.credentials)
        do {
            try adopt(transport: transport, email: saved.email, credentials: saved.credentials,
                      into: Store(database: database))
            state = .signedIn(email: saved.email)
        } catch {
            keyStore = accounts.keyStore(for: nil)
        }
    }

    /// Points the key lookups at one account's keychain items.
    private func useKeys(of email: String?) {
        guard let accounts else { return }
        keyStore = accounts.keyStore(for: email.map(AccountDirectory.namespace(for:)))
        identity = nil
        device = nil
    }

    public var isSignedIn: Bool {
        if case .signedIn = state { return true }
        return false
    }

    public var isBusy: Bool {
        if case .busy = state { return true }
        return false
    }

    /// Whether this device holds an identity at all, which decides whether the
    /// account screen offers signing in or only creating an account.
    public var hasIdentity: Bool {
        // `try?` flattens, so nil covers both "no identity" and "the keychain
        // would not answer". Either way there is no identity to sign in with.
        (try? keyStore.load(.identity)) != nil
    }

    /// Whether this Mac can sign in to `email`: it holds that account's keys, or
    /// the keys from before accounts had their own, which the first account to
    /// sign in takes over.
    /// With no address typed yet there is nothing to look up, so that counts as
    /// yes rather than warning about a key before anyone has said whose.
    public func hasIdentity(for email: String) -> Bool {
        guard let accounts else { return hasIdentity }
        guard email.contains("@") else { return true }
        let own = accounts.keyStore(for: AccountDirectory.namespace(for: email))
        return (try? own.load(.identity)) != nil
            || (try? accounts.keyStore(for: nil).load(.identity)) != nil
    }

    // MARK: - Keys on this device

    /// The identity, creating one on first use.
    ///
    /// Generated here and never sent anywhere in the clear. The server sees the
    /// public halves and a blob sealed under the recovery code, and nothing else.
    private func loadOrCreateIdentity() throws -> IdentityKeyPair {
        if let identity { return identity }
        if let existing = try? keyStore.loadIdentity() {
            identity = existing
            return existing
        }
        let fresh = IdentityKeyPair.generate()
        try keyStore.storeIdentity(fresh)
        identity = fresh
        return fresh
    }

    private func loadOrCreateDevice() throws -> DeviceKeyPair {
        if let device { return device }
        if let existing = try? keyStore.loadDevice() {
            device = existing
            return existing
        }
        let fresh = DeviceKeyPair()
        try keyStore.storeDevice(fresh)
        device = fresh
        return fresh
    }

    private func existingIdentity() throws -> IdentityKeyPair {
        if let identity { return identity }
        guard let existing = try? keyStore.loadIdentity() else {
            throw Failure.noIdentityOnThisDevice
        }
        identity = existing
        return existing
    }

    // MARK: - Account

    /// Creates an account. The returned words are the only copy of the recovery
    /// code, and are also left in `pendingEnrolment` for the screen to show.
    @discardableResult
    public func signUp(email: String, password: String) async throws -> Enrolment {
        state = .busy("Creating your account")
        useKeys(of: email)
        let hadKeys = hasIdentity
        do {
            let url = try serverURL()
            let identity = try loadOrCreateIdentity()
            _ = try loadOrCreateDevice()

            // The escrow blob is what makes recovery possible at all, so it is
            // written at sign-up rather than offered later and skipped.
            let entropy = RecoveryCode.generateEntropy()
            let words = try RecoveryCode.encode(entropy: entropy)
            let escrow = try RecoveryEscrow.seal(identity: identity, entropy: entropy)

            let transport = makeTransport(url)
            let credentials = try await transport.signUp(email: email, password: password,
                                                         identity: identity.publicKeys,
                                                         escrow: escrow)
            // Whatever was built while signed out becomes the new account's.
            var target = store
            if let accounts {
                let namespace = AccountDirectory.namespace(for: email)
                try accounts.moveThisMacData(into: namespace)
                target = Store(database: try accounts.database(for: namespace))
            }
            try adopt(transport: transport, email: email, credentials: credentials, into: target)
            let enrolment = Enrolment(email: email, recoveryWords: words)
            pendingEnrolment = enrolment
            state = .signedIn(email: email)
            return enrolment
        } catch {
            // Keys made for an account the server refused belong to nobody, and
            // left behind they would sit under an email someone may sign in
            // with later.
            if !hadKeys, accounts != nil { try? keyStore.removeAll() }
            useKeys(of: account)
            throw report(error)
        }
    }

    /// Signs in on a device that already holds the identity.
    public func signIn(email: String, password: String) async throws {
        state = .busy("Signing in")
        useKeys(of: email)
        do {
            let url = try serverURL()
            guard hasIdentity(for: email) else { throw Failure.noIdentityOnThisDevice }

            let transport = makeTransport(url)
            let credentials = try await transport.signIn(email: email, password: password)

            // Only now, with the password accepted, can older keys be handed to
            // this account. Before, a mistyped email would take them.
            var target = store
            if let accounts {
                let namespace = AccountDirectory.namespace(for: email)
                if try accounts.claimOlderKeys(for: namespace) {
                    try accounts.moveThisMacData(into: namespace)
                }
                useKeys(of: email)
                target = Store(database: try accounts.database(for: namespace))
            }
            _ = try existingIdentity()
            _ = try loadOrCreateDevice()
            try adopt(transport: transport, email: email, credentials: credentials, into: target)
            state = .signedIn(email: email)
        } catch {
            useKeys(of: account)
            throw report(error)
        }
    }

    /// Forgets the session, and nothing else. Signing out is not losing your
    /// budgets: the identity and the local database both stay.
    public func signOut() async {
        // Ask the server to revoke the token first. If it refuses or cannot be
        // reached, sign out anyway: refusing to sign someone out because the
        // network is down is the wrong answer, and the token expires in thirty
        // days regardless.
        try? await transport?.signOut()
        try? keyStore.delete(.serverToken)
        account = nil
        transport = nil
        userID = nil
        keyRing = nil
        state = .signedOut
        if let accounts, let thisMac = try? accounts.database(for: nil) {
            // Each account's budgets are its own. Signed out is "This Mac".
            accounts.lastAccount = nil
            useKeys(of: nil)
            switchTo(Store(database: thisMac))
        }
    }

    private func switchTo(_ store: Store) {
        self.store = store
        pendingJoins = (try? store.pendingJoins()) ?? []
        didSwitchStore?(store)
    }

    public func recoveryWordsWereWrittenDown() {
        pendingEnrolment = nil
        let stamp = ISO8601DateFormatter().string(from: Date())
        try? keyStore.store(Data(stamp.utf8), for: .recoveryConfirmedAt)
    }

    private func adopt(transport: any AccountTransport, email: String,
                       credentials: HTTPTransport.Credentials, into target: Store) throws {
        // Every step that can fail goes first. `account` is what puts Sign out in
        // the toolbar, so it is set only once the sign-in has fully succeeded.
        let keyRing = KeyRing(store: target,
                              identity: try existingIdentity(),
                              userID: credentials.userID)
        try keyStore.store(try JSONEncoder().encode(SavedSession(email: email, credentials: credentials)),
                           for: .serverToken)
        self.transport = transport
        self.userID = credentials.userID
        self.keyRing = keyRing
        self.account = email
        accounts?.lastAccount = email
        if target.database !== store.database { switchTo(target) }
    }

    private func serverURL() throws -> URL {
        guard let url = URL(string: serverAddress.trimmingCharacters(in: .whitespaces)),
              url.scheme == "http" || url.scheme == "https", url.host != nil else {
            throw Failure.server("\(serverAddress) is not a server address.")
        }
        return url
    }

    // MARK: - Sync

    /// Syncs every group on this device. Never throws: this runs from a button and
    /// reports through `state`.
    ///
    /// `quietly` is for the syncs nobody asked for (see `AutoSync`). A quiet one
    /// that fails puts back the state it found, so a server that is briefly down
    /// does not turn the button into an error every two minutes. The next sync
    /// tries again, and a click still shows the reason.
    @discardableResult
    public func syncAll(quietly: Bool = false) async -> SyncReport {
        var combined = SyncReport()
        guard let email = account, transport != nil else {
            if !quietly { state = .failed("Sign in first.") }
            return combined
        }
        let before = state
        state = .busy("Syncing")
        do {
            // A deleted group is out of sight, so its failure must not stop the
            // live groups named after it from syncing. The first one is still
            // reported, once the round is over.
            var deletedGroupFailure: (any Error)?
            // Deleted groups are included only while their delete is still queued.
            // Leaving them out entirely meant a deleted group's tombstone never
            // left this Mac, and the server kept the group as if it were live.
            //
            // Each group is read again as the round reaches it. A delete
            // confirmed while the round is running must take the deleted path,
            // not the live one the group was on when the round began.
            for id in try store.groups(includeDeleted: true).map(\.id) {
                guard let group = try store.group(id) else { continue }
                let report: SyncReport
                if group.isDeleted {
                    guard try store.outboxCount(in: group.id) > 0
                            || !store.sentInvites(in: group.id).isEmpty else { continue }
                    do {
                        report = try await sendDelete(of: group.id)
                    } catch {
                        deletedGroupFailure = deletedGroupFailure ?? error
                        continue
                    }
                } else {
                    report = try await sync(group: group.id)
                }
                combined.pushed += report.pushed
                combined.pulled += report.pulled
                combined.applied += report.applied
                combined.rejected += report.rejected
                combined.conflicts += report.conflicts
                combined.undecryptable += report.undecryptable
                combined.echoes += report.echoes
                combined.ignored += report.ignored
            }
            lastReport = combined
            lastSyncedAt = Date()
            if let deletedGroupFailure { throw deletedGroupFailure }
            state = .signedIn(email: email)
        } catch {
            state = quietly ? before : .failed(readable(error))
        }
        pendingJoins = (try? store.pendingJoins()) ?? []
        didSync?()
        return combined
    }

    /// Syncs one group, founding it on the server the first time.
    public func sync(group: GroupID) async throws -> SyncReport {
        guard let transport, let keyRing, let userID else { throw Failure.notSignedIn }
        let identity = try existingIdentity()
        let device = try loadOrCreateDevice()
        // A deleted group goes through sendDelete, never through here. This is
        // checked again before the engine runs, because a delete can be
        // confirmed during the waits on the network in between.
        guard try !isDeleted(group) else { return SyncReport() }

        let waiting = try store.pendingJoin(group) != nil
        var log: [MembershipLogEntry]
        do {
            log = try await transport.membershipLog(group: group, since: 0)
        } catch HTTPTransport.Failure.http(status: 403, _) {
            // Asked to join and not added yet: nothing to do until the inviter's
            // app finishes it.
            if waiting { return SyncReport() }
            // The server answers 403 for a group it has never seen, the same as
            // for a group you are not in, so a guessed ID learns nothing. Either
            // way, try to found it. If the group is someone else's, the server
            // refuses the founding entry, so this cannot take one over.
            log = []
        }
        if waiting {
            let state = try MembershipLog.replay(log, scope: .group(group))
            guard state.allows(userID, .read) else { return SyncReport() }
        } else if log.isEmpty {
            log = [try await found(group: group, transport: transport,
                                   identity: identity, device: device, userID: userID)]
        }
        let engine = SyncEngine(store: store, keyRing: keyRing, transport: transport,
                                identity: identity, device: device, userID: userID)
        // Judged on the history this Mac has verified, as sendDelete does:
        // what it holds plus what extends it. The whole log the server sent
        // above can be made up.
        try mintKeysIfSoleMember(group: group, state: try await engine.membership(of: group),
                                 userID: userID)

        // Checked again after each wait, so that nobody is added to a group
        // this Mac let go of while the round waited on the server. Its
        // invites stay open, and letting go of it cancels them.
        guard try !isDeleted(group) else { return SyncReport() }
        let sharing = Sharing(store: store, keyRing: keyRing, transport: transport,
                              identity: identity, device: device, userID: userID)
        try await sharing.prepare(group: group)
        guard try !isDeleted(group) else { return SyncReport() }
        try await sharing.finishInvites(group: group)
        guard try !isDeleted(group) else { return SyncReport() }

        var report = try await engine.sync(group: group)
        if try await sharing.completeJoin(group: group) {
            // No longer waiting, so a delete dialog opened from now on must
            // not offer to turn the invite down.
            pendingJoins = (try? store.pendingJoins()) ?? []
            // Turned down while that was out, so their name stays here.
            guard try !isDeleted(group) else { return report }
            // Their name for the group, written now they are in. Send it.
            report = try await engine.sync(group: group)
        }
        return report
    }

    /// Sends what is left in the outbox for a group deleted on this Mac, then
    /// leaves it alone.
    ///
    /// A pass that finishes leaves the group's outbox empty, or holding only
    /// rows a later sync can still send. Anything else would bring the hidden
    /// group back through here on every sync, for good.
    ///
    /// A group the server has never seen is not founded just to carry its own
    /// tombstone. Its queued rows are dropped here instead, since nobody else can
    /// have a copy of it.
    func sendDelete(of group: GroupID) async throws -> SyncReport {
        guard let transport, let keyRing, let userID else { throw Failure.notSignedIn }

        // Deleting a group that is still waiting to join turns the invite down
        // here. The delete was made on a placeholder, before this Mac ever saw
        // the real group. Sent once the inviter adds them, it would delete the
        // inviter's group for everyone.
        if try store.pendingJoin(group) != nil {
            try store.clearOutbox(in: group)
            try store.deletePendingJoin(group)
            return SyncReport()
        }
        let engine = SyncEngine(store: store, keyRing: keyRing, transport: transport,
                                identity: try existingIdentity(), device: try loadOrCreateDevice(),
                                userID: userID)
        guard try store.groupDeleteIsQueued(group) else {
            return try await letGo(of: group, engine: engine)
        }

        // Decided from the access history this Mac has already verified, plus
        // what extends it. A log fetched whole and replayed on its own could be
        // one the server made up, naming this person as the founder.
        let membership: MembershipState
        do {
            membership = try await engine.membership(of: group)
        } catch HTTPTransport.Failure.http(status: 403, _) {
            try store.clearOutbox(in: group)
            return SyncReport()
        } catch SyncError.notAMember {
            try store.clearOutbox(in: group)
            return SyncReport()
        }
        // Only the founder or an admin deletes a shared group for everyone. For
        // anyone else, Delete hides it on this Mac and sends nothing, the way it
        // always did before deletes were sent.
        guard membership.mayDeleteGroup(userID) else {
            try store.clearOutbox(in: group)
            return SyncReport()
        }
        try mintKeysIfSoleMember(group: group, state: membership, userID: userID)

        // Push without pulling. A pull would write other members' newer edits
        // over the delete here, and the group would come back on this Mac only.
        // The engine asks the same question again, of the history it seals with.
        // Every queued row, not one page: the push sends every page.
        let attempted = try store.pendingPushes(in: group, limit: .max)
        guard let report = try await engine.pushDelete(group: group) else {
            try store.clearOutbox(in: group)
            return SyncReport()
        }
        try dropWhatCannotGo(attempted, in: group, keyRing: keyRing)
        return report
    }

    /// Lets go of a deleted group with no delete of ours waiting: one removed
    /// from this Mac only, one deleted by another member, or one whose delete
    /// already went out.
    ///
    /// What is still queued was saved before that, and some of it may be owed
    /// to other people. A Manage member who just added someone "from now on"
    /// owes them the group and its budgets, sealed under the new key. So it
    /// goes out once, and whatever did not go is dropped. Removing a group
    /// from this Mac only queues nothing, so what goes out is only what the
    /// person saved before that. This device's open invites to the group are
    /// cancelled too, because nobody else holds their secrets to finish them.
    ///
    /// It pulls first, like any sync. Pushing alone sent this Mac's old copies
    /// over other members' newer edits it had not seen, whenever a queued row
    /// had the higher Lamport value. The pull cannot bring the group back
    /// here, because a group deleted on this Mac stays deleted (see `settle`).
    ///
    /// A failure that may clear up by itself, such as no network, keeps
    /// everything for the next round. Any other failure would come back on
    /// every round, for a group this person can no longer see, so after
    /// `letGoAttempts` rounds in a row the queue and invites are dropped.
    private func letGo(of group: GroupID, engine: SyncEngine) async throws -> SyncReport {
        var report = SyncReport()
        do {
            report = try await sendWhatIsQueued(for: group, engine: engine)
            failedLetGoes[group] = nil
        } catch let error where !Self.mayClearUp(error) {
            let failures = failedLetGoes[group, default: 0] + 1
            guard failures >= Self.letGoAttempts else {
                failedLetGoes[group] = failures
                throw error
            }
            failedLetGoes[group] = nil
        }
        // A new link brought the group back while this was out. The join
        // started its pulls again from the beginning, and this round's pull
        // then wrote its own place back over that, so the pulls are forgotten
        // again. Nothing queued or sent for it now belongs to this round.
        guard try isDeleted(group) else {
            try store.forgetPulls(in: group)
            return report
        }
        try store.clearOutbox(in: group)
        let sharing = try sharing()
        for invite in try store.sentInvites(in: group) { try await sharing.cancelInvite(invite.id) }
        return report
    }

    /// Sends what is queued for a group being let go of, pulling first. When
    /// the pull fails in a way no later round would change, such as a record
    /// this build cannot read, the queue goes out without it, as it did before
    /// letting go pulled. Otherwise the group could never be let go of.
    private func sendWhatIsQueued(for group: GroupID, engine: SyncEngine) async throws -> SyncReport {
        do {
            return try await engine.sync(group: group)
        } catch let error where Self.nobodyToTell(error) {
            return SyncReport()
        } catch let error where !Self.mayClearUp(error) {
            do {
                return try await engine.pushWithoutPulling(group: group)
            } catch let error where Self.nobodyToTell(error) {
                return SyncReport()
            }
        }
    }

    /// Rounds in a row that could not let go of a deleted group, for a reason
    /// that does not clear up by itself. Kept for as long as the app runs.
    private var failedLetGoes: [GroupID: Int] = [:]
    /// How many such rounds a deleted group gets before its queue and
    /// invites are dropped anyway.
    static let letGoAttempts = 3

    /// Removed from the group, or it never reached the server, or its
    /// history no longer checks out. Either way nothing can be sent to it,
    /// now or later.
    private static func nobodyToTell(_ error: any Error) -> Bool {
        switch error {
        case HTTPTransport.Failure.http(status: 403, _), SyncError.notAMember, SyncError.membershipRefused:
            return true
        default:
            return false
        }
    }

    /// Whether an error may clear up by itself: no network, a server that is
    /// down or busy, or a session to sign in to again.
    static func mayClearUp(_ error: any Error) -> Bool {
        switch error {
        case is URLError, is CancellationError, HTTPTransport.Failure.notAuthenticated:
            return true
        case HTTPTransport.Failure.http(let status, _):
            return status >= 500 || [401, 408, 429].contains(status)
        default:
            return false
        }
    }

    private func isDeleted(_ group: GroupID) throws -> Bool {
        try store.group(group)?.isDeleted == true
    }

    /// After a deleted group's push, drops the rows no later sync could send
    /// either.
    ///
    /// Nothing in a deleted group can be edited again. So a row the server
    /// refused can never become newer and win, and a row with no key, for a
    /// record the server never saw, has nobody to tell. What stays is a row
    /// saved after the push read the queue, and a record the server holds
    /// that is still waiting on its key.
    private func dropWhatCannotGo(_ attempted: [PendingPush], in group: GroupID,
                                  keyRing: KeyRing) throws {
        let epoch = try MembershipLog.replay(try store.membershipLog(for: group),
                                             scope: .group(group)).epoch
        let left = try store.pendingPushes(in: group, limit: .max)
        var drop: [PendingPush] = []
        for item in attempted where left.contains(item) {
            let scope: KeyScope = item.budgetID.map { .budget($0) } ?? .group(item.groupID)
            if try keyRing.has(scope: scope, epoch: epoch) || store.recordVersion(item.recordID) == nil {
                drop.append(item)
            }
        }
        try store.clearOutbox(drop)
    }

    // MARK: - Sharing

    /// Makes a link that invites someone to `group`. Syncs the group first, so it
    /// exists on the server with keys to hand out, and records the inviter's own
    /// name in it so the person joining sees who asked.
    public func share(group: GroupID, groupName: String, level: AccessLevel,
                      historyAccess: HistoryAccess, myName: String) async throws -> InviteLink {
        do {
            guard let userID else { throw Failure.notSignedIn }
            let name = myName.trimmingCharacters(in: .whitespacesAndNewlines)
            if !name.isEmpty, try displayName(in: group) != name {
                try store.save(MemberProfile(groupID: group, userID: userID, displayName: name))
            }
            _ = try await sync(group: group)
            let link = try await sharing().createInvite(
                group: group, groupName: groupName, level: level, historyAccess: historyAccess,
                inviterName: name)
            didSync?()
            return link
        } catch {
            throw report(error)
        }
    }

    /// Answers an invite. The group appears straight away, marked as waiting.
    @discardableResult
    public func join(_ link: InviteLink, myName: String) async throws -> PendingJoin {
        do {
            let join = try await sharing().join(
                link, displayName: myName.trimmingCharacters(in: .whitespacesAndNewlines),
                beforeComingBack: { group in try await self.finishLettingGo(of: group) })
            pendingJoins = try store.pendingJoins()
            didSync?()
            return join
        } catch HTTPTransport.Failure.http(let status, _) where [404, 409, 410].contains(status) {
            throw report(Failure.server(Self.inviteProblem(status)))
        } catch {
            throw report(error)
        }
    }

    /// A group removed from this Mac, coming back with a new link before any
    /// sync let go of it. What is still queued for it goes out first, as that
    /// sync would have sent it. Dropped at the join instead, an edit or a
    /// transaction never sent was lost for everyone, and a re-seal owed to
    /// someone just added never reached them.
    private func finishLettingGo(of group: GroupID) async throws {
        guard try store.outboxCount(in: group) > 0 || !store.sentInvites(in: group).isEmpty else {
            return
        }
        do {
            _ = try await sendDelete(of: group)
        } catch let error where !Self.mayClearUp(error) {
            // The link is answered anyway, and the join drops what could not
            // go, as it did before it let go first. A group whose sync keeps
            // failing must not also keep its new link from working. A failure
            // that clears up by itself, such as a server error, fails the join
            // instead, so the queue is kept for the next try.
        }
    }

    /// The invite statuses, in words. Only here: 409 also means "email taken" at
    /// sign-up, so these cannot live in the general error wording.
    static func inviteProblem(_ status: Int) -> String {
        switch status {
        case 404: return "That invite was not found. It may have been cancelled."
        case 409: return "That invite has already been used."
        default: return "That invite has expired. Ask for a new link."
        }
    }

    /// The name this person shows `group`, if they have set one.
    public func displayName(in group: GroupID) throws -> String? {
        guard let userID else { return nil }
        return try store.profile(MemberProfile.recordID(group: group, user: userID))?.displayName
    }

    public func isWaitingToJoin(_ group: GroupID) -> Bool {
        pendingJoins.contains { $0.groupID == group }
    }

    /// What deleting `group` does beyond this Mac, for the confirmation. Read
    /// from the membership log as of the last sync, the same rule `sendDelete`
    /// applies to the log it fetches.
    func deleteReach(of group: GroupID) -> GroupDeleteReach {
        if isWaitingToJoin(group) { return .declinesInvite }
        guard let log = try? store.membershipLog(for: group), !log.isEmpty,
              let state = try? MembershipLog.replay(log, scope: .group(group)),
              state.members.count > 1 else { return .justYou }
        guard let userID, state.mayDeleteGroup(userID) else { return .thisMacOnly }
        return .everyone
    }

    /// Whether this person may add, change or delete budgets in `group`, or
    /// rename the group, which takes Manage. Read from the membership log as
    /// of the last sync, the rule every other member's app and the server
    /// apply. A group with no log has never been synced, so it is this
    /// person's own. A group still waiting to join has nothing in it to
    /// change yet.
    func mayManageBudgets(in group: GroupID) -> Bool {
        if isWaitingToJoin(group) { return false }
        guard let log = try? store.membershipLog(for: group), !log.isEmpty else { return true }
        guard let userID, let state = try? MembershipLog.replay(log, scope: .group(group)) else {
            return false
        }
        return state.allows(userID, .manage)
    }

    private func sharing() throws -> Sharing {
        guard let transport, let keyRing, let userID else { throw Failure.notSignedIn }
        return Sharing(store: store, keyRing: keyRing, transport: transport,
                       identity: try existingIdentity(), device: try loadOrCreateDevice(),
                       userID: userID)
    }

    /// A group made on this Mac has no history on the server until someone writes
    /// its founding entry. Doing that lazily here is what lets the app be used
    /// offline for a week and then sync.
    ///
    /// The founding entry carries this device's public key, which enrols the
    /// device. Without that, every record it pushes is refused as signed by a
    /// device nobody has heard of.
    private func found(group: GroupID, transport: any AccountTransport,
                       identity: IdentityKeyPair, device: DeviceKeyPair,
                       userID: UserID) async throws -> MembershipLogEntry {
        let founding = try MembershipLogEntry.signed(
            scope: .group(group), sequence: 0, previousHash: MembershipLogEntry.rootHash,
            action: .found, subjectUserID: userID, subjectKeys: identity.publicKeys,
            level: .superadmin, epochAfter: .initial,
            deviceID: device.id, devicePublicKey: device.publicKey,
            author: identity, authorUserID: userID
        )
        try await transport.appendMembership(founding, group: group, wrappedKeys: [])
        try store.append(founding, in: group)
        return founding
    }

    /// Makes sure a group only this person belongs to has a key for everything in
    /// it, minting what is missing.
    ///
    /// Two reasons it is every sync and not only the founding one. A budget added
    /// after the first sync has no key, and the engine skips records it cannot
    /// seal, so those rows would sit in the outbox forever without a word. And a
    /// key this device already minted offline is kept rather than replaced,
    /// because the statement fingerprints are computed with it.
    ///
    /// The sole-member check is what makes this safe. In a shared group the real
    /// keys arrive sealed from whoever shared it, and minting a local one instead
    /// would seal records that nobody else can open.
    ///
    /// Deleted budgets count too. A budget added and deleted between two syncs
    /// still has its delete queued, and with no key that row would never go.
    ///
    /// Only for a group this person founded with their own key, judged on the
    /// log this Mac has verified. A server can make up a log naming someone
    /// its only member, and can even put their public keys in it, since those
    /// are not secret. It cannot sign a founding entry with their key. Minting
    /// on a made-up log at some later epoch kept keys nobody else had, because
    /// a key this Mac holds is never replaced.
    private func mintKeysIfSoleMember(group: GroupID, state: MembershipState,
                                      userID: UserID) throws {
        guard state.members == [userID],
              let founding = try store.membershipLog(for: group).first,
              founding.subjectUserID == userID,
              founding.subjectKeys == (try existingIdentity()).publicKeys else { return }

        _ = try store.localKey(for: .group(group), epoch: state.epoch)
        for budget in try store.budgets(in: group, includeDeleted: true) {
            _ = try store.localKey(for: .budget(budget.id), epoch: state.epoch)
        }
    }

    private func report(_ error: any Error) -> any Error {
        let message = readable(error)
        state = .failed(message)
        return error as? Failure ?? Failure.server(message)
    }

    private func readable(_ error: any Error) -> String {
        if let failure = error as? Failure {
            switch failure {
            case .noIdentityOnThisDevice:
                return """
                       This Mac has no key for that account. Pairing a second \
                       device is not built yet, so sign in on the Mac that made \
                       the account.
                       """
            case .notSignedIn: return "Sign in first."
            case .server(let message): return message
            }
        }
        if let failure = error as? KeyStoreError {
            switch failure {
            case .notFound: return "This Mac has no key for that account."
            case .locked: return "Unlock the key store first."
            case .wrongPassphrase: return "That passphrase is wrong."
            case .backendFailure(let detail):
                // Most often an unsigned build being refused the data protection
                // keychain. Say what happened rather than "sync failed".
                return "This Mac would not store the key: \(detail)"
            }
        }
        if let failure = error as? SharingError {
            switch failure {
            case .notAllowed(let needed):
                return needed == .admin
                    ? "Only an admin can invite someone as a manager."
                    : "Only a manager or admin can invite people to this group."
            case .badLink: return "That is not a WellSpent invite link."
            case .alreadyAMember: return "That is your own invite."
            }
        }
        if let failure = error as? HTTPTransport.Failure {
            switch failure {
            case .http(let status, let reason):
                return status == 400 || status == 401 || status == 429
                     ? reason : "The server said \(status): \(reason)"
            case .notAuthenticated: return "Sign in first."
            case .malformedResponse(let detail): return "Unexpected reply from the server: \(detail)"
            }
        }
        return String(describing: error)
    }
}

extension Store {
    /// The key for a scope on this device, minting and caching one the first time.
    ///
    /// This is what the statement importer keys its fingerprints with. It used to
    /// use a key generated at launch, which meant the same statement imported
    /// after a restart produced different fingerprints and duplicated every row.
    ///
    /// Always epoch zero, deliberately. Every epoch is kept forever, so asking for
    /// the first one means a key rotation does not change any fingerprint either.
    func localKey(for scope: KeyScope, epoch: Epoch = .initial) throws -> ScopedKey {
        if let existing = try cachedKey(scope: scope, epoch: epoch) { return existing }
        let fresh = ScopedKey.generate(scope: scope, epoch: epoch)
        try cache(fresh)
        return fresh
    }
}
