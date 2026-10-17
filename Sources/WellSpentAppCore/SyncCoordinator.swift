import Foundation
import Observation
import WellSpentCrypto
import WellSpentKeyStore
import WellSpentModel
import WellSpentStore
import WellSpentSync

/// Connects the app to the readable server.
///
/// One account works on any number of devices, the way a bank's app does.
/// Signing in is an email and a password, and the session renews itself on
/// the server while it is used. There are no keys to make, pair or lose.
///
/// Each round of syncing asks the server which groups this account is in,
/// decides what each one needs (`SyncPlan`), and runs `ReadableSyncEngine`
/// for it.
@MainActor
@Observable
public final class SyncCoordinator {
    public enum State: Equatable, Sendable {
        case signedOut
        case busy(String)
        case signedIn(email: String)
        case failed(String)
    }

    public enum Failure: Error, Equatable, Sendable {
        case notSignedIn
        case server(String)
        /// The other build's server: staging for a live build, live for a staging
        /// one. Refused before a password or a session goes to it.
        case wrongServer(String)
        /// Joining a group needs a confirmed address.
        case emailNotConfirmed
    }

    /// Why this device needs signing in again, for the account screen.
    public struct SignInPrompt: Equatable, Sendable {
        public let email: String?
        public let reason: String
    }

    public private(set) var state: State = .signedOut
    public private(set) var lastReport: SyncReport?
    public private(set) var lastSyncedAt: Date?
    /// Called after every sync, so the screens reload what it brought in.
    public var didSync: (@MainActor () -> Void)?
    /// Set when this device was signed out without being asked to: the
    /// session ended elsewhere, or this is the first launch after the switch.
    public private(set) var signInPrompt: SignInPrompt?
    /// Whether the signed-in account has confirmed its email address.
    public private(set) var emailVerified = false
    /// Groups this account is in whose founder has not updated yet.
    public private(set) var waitingForFounder: Set<GroupID> = []
    /// Groups this account founded that the server no longer lists. Nothing
    /// is hidden or sent for them; the app says so.
    public private(set) var missingOnServer: Set<GroupID> = []

    /// Remembered between launches.
    public var serverAddress: String {
        didSet { defaults.set(serverAddress, forKey: Self.serverAddressKey); defaults.saveNow() }
    }

    static let serverAddressKey = "WellSpentServerAddress"
    /// Which build this is. It decides the server a fresh install starts with, and
    /// the servers this refuses.
    public let environment: AppEnvironment
    /// Where the settings are kept, which differs between live and staging.
    let defaults: UserDefaults
    /// Who is signed in, kept separately from `state` so a sync that runs from
    /// `.busy` knows what to put back when it finishes.
    public private(set) var account: String?

    /// The signed-in account's database, or "This Mac" when nobody is.
    public private(set) var store: Store
    private var keyStore: any KeyStore
    /// Set when each account keeps its own keys and database. Nil keeps one of
    /// each, which the tests of everything else use.
    private let accounts: AccountDirectory?
    /// Called when signing in or out switches to another database, so the
    /// screens can switch with it.
    public var didSwitchStore: (@MainActor (Store) -> Void)?
    private let makeTransport: @Sendable (URL) -> any ReadableAccountTransport

    private var transport: (any ReadableAccountTransport)?
    private var clientID: DeviceID?
    /// Moves on whenever a session starts or ends. A sync round that sees it
    /// change while it waits on the network stops, and leaves the new
    /// session's state alone.
    private var sessionGeneration = 0
    /// Who is signed in, so the app can say "You" on their own transactions.
    public private(set) var userID: UserID?

    /// With no `defaults`, the environment's own: never live's settings for a
    /// staging build.
    public init(store: Store,
                keyStore: any KeyStore,
                defaults: UserDefaults? = nil,
                serverAddress: String? = nil,
                environment: AppEnvironment = .current,
                makeTransport: @escaping @Sendable (URL) -> any ReadableAccountTransport = {
                    ReadableHTTPTransport(baseURL: $0)
                }) {
        self.store = store
        self.keyStore = keyStore
        self.accounts = nil
        let defaults = defaults ?? environment.defaults
        self.environment = environment
        self.defaults = defaults
        self.serverAddress = serverAddress
            ?? defaults.string(forKey: Self.serverAddressKey)
            ?? environment.defaultServerAddress
        self.makeTransport = makeTransport
    }

    /// One Mac login, any number of WellSpent accounts. Opens on whoever was
    /// signed in last, if their session is still saved, and on "This Mac"
    /// otherwise.
    public init(accounts: AccountDirectory,
                defaults: UserDefaults? = nil,
                serverAddress: String? = nil,
                environment: AppEnvironment = .current,
                makeTransport: @escaping @Sendable (URL) -> any ReadableAccountTransport = {
                    ReadableHTTPTransport(baseURL: $0)
                }) throws {
        self.accounts = accounts
        self.store = Store(database: try accounts.database(for: nil))
        self.keyStore = accounts.keyStore(for: nil)
        let defaults = defaults ?? environment.defaults
        self.environment = environment
        self.defaults = defaults
        self.serverAddress = serverAddress
            ?? defaults.string(forKey: Self.serverAddressKey)
            ?? environment.defaultServerAddress
        self.makeTransport = makeTransport
        resumeLastSession()
    }

    /// What is kept between launches, under `.session` in the account's keys.
    /// The session alone is not enough: resuming needs to know whose it is,
    /// and which server issued it, without asking.
    struct SavedSession: Codable {
        let email: String
        let session: ServerSession
        /// The server that issued it, as `Self.normalized` spells it.
        let server: String
    }

    public var isSignedIn: Bool {
        if case .signedIn = state { return true }
        return false
    }

    public var isBusy: Bool {
        if case .busy = state { return true }
        return false
    }

    // MARK: - Resuming

    /// Opens the last account's database with its saved session. The session's
    /// own expiry is not checked here: the server renews a session in use and
    /// never sends the new date, so only the server can say it has ended.
    private func resumeLastSession() {
        guard let accounts, let email = accounts.lastAccount else { return }
        let namespace = AccountDirectory.namespace(for: email)
        let keys = accounts.keyStore(for: namespace)
        guard let data = try? keys.load(.session),
              let saved = try? JSONDecoder().decode(SavedSession.self, from: data) else {
            // Signed in with the sealed app, which saved a different kind of
            // session. Nothing is lost; the account's budgets wait for a sign-in.
            let reason = (try? keys.load(.serverToken)) != nil ? Self.updatedReason : Self.sessionEndedReason
            signInPrompt = SignInPrompt(email: email, reason: reason)
            state = .failed(reason)
            return
        }
        // A session works for the server that issued it, and sending it to any
        // other server hands that server the session. When the server set now
        // is another one, this Mac signs out here without telling any server,
        // and keeps every budget.
        guard let url = try? serverURL(), saved.server == Self.normalized(url) else {
            try? keys.delete(.session)
            accounts.lastAccount = nil
            state = .failed(Self.signedOutReason)
            return
        }
        guard let database = try? accounts.database(for: namespace),
              let clientID = try? keys.loadOrCreateClientID() else { return }
        adopt(transport: makeTransport(url).resuming(with: saved.session), email: saved.email,
              session: saved.session, emailVerified: saved.session.emailVerified, server: url,
              keys: keys, clientID: clientID, into: Store(database: database))
        state = .signedIn(email: saved.email)
    }

    nonisolated static let updatedReason = """
        WellSpent has updated how it syncs. Sign in again to finish. Your budgets are still here.
        """

    nonisolated static let signedOutReason = """
        Please sign in again. The saved sign-in is for a different server than the one set now. \
        Your budgets are still here.
        """

    // MARK: - Account

    /// Creates an account. Whatever was made while signed out becomes the new
    /// account's.
    public func signUp(email typed: String, password: String) async throws {
        state = .busy("Creating your account")
        let email = Self.normalised(email: typed)
        do {
            let url = try serverURL()
            let transport = makeTransport(url)
            // Before any password is sent.
            try await confirmEnvironment(of: transport)
            let session = try await transport.signUp(email: email, password: password,
                                                     deviceLabel: Self.deviceLabel)
            try await finishSigningIn(transport: transport, email: email, session: session, server: url,
                                      takingThisMac: true)
        } catch {
            throw report(error)
        }
    }

    /// Signs in on any device, new or not.
    public func signIn(email typed: String, password: String) async throws {
        state = .busy("Signing in")
        let email = Self.normalised(email: typed)
        do {
            let url = try serverURL()
            let transport = makeTransport(url)
            try await confirmEnvironment(of: transport)
            let session = try await transport.signIn(email: email, password: password,
                                                     deviceLabel: Self.deviceLabel)
            try await finishSigningIn(transport: transport, email: email, session: session, server: url,
                                      takingThisMac: false)
        } catch {
            throw report(error)
        }
    }

    /// Everything after the server said yes, shared by signing up, signing in
    /// and a password reset.
    func finishSigningIn(transport: any ReadableAccountTransport, email: String, session: ServerSession,
                         server: URL, takingThisMac: Bool) async throws {
        var target = store
        var keys = keyStore
        if let accounts {
            let namespace = AccountDirectory.namespace(for: email)
            // Only now, with the password accepted. Before, a mistyped email
            // would take "This Mac"'s budgets, or the keys from before
            // accounts had their own.
            if takingThisMac {
                try accounts.moveThisMacData(into: namespace)
            } else if try accounts.claimOlderKeys(for: namespace) {
                try accounts.moveThisMacData(into: namespace)
            }
            keys = accounts.keyStore(for: namespace)
            target = Store(database: try accounts.database(for: namespace))
        }
        let clientID = try keys.loadOrCreateClientID()
        // The session says whether the address is confirmed as of signing in.
        // Asked again, so a confirmation made on another device shows here.
        let verified = (try? await transport.me().emailVerified) ?? session.emailVerified
        adopt(transport: transport, email: email, session: session, emailVerified: verified, server: server,
              keys: keys, clientID: clientID, into: target)
        try saveSession(SavedSession(email: email, session: Self.session(session, verified: verified),
                                     server: Self.normalized(server)))
        // Invites the sealed app made or answered can never complete now:
        // readable sync makes and answers them on the server.
        try store.clearSealedInvites()
        state = .signedIn(email: email)
    }

    /// Confirms this account's address with the code emailed to it.
    public func verifyEmail(code: String) async throws {
        try await signedIn { try await $0.verifyEmail(code: AccountRules.normalisedCode(code)) }
        noteEmailVerified()
    }

    /// Remembers a confirmed address in the saved session too, so it is still
    /// known after the app is quit and opened again.
    private func noteEmailVerified() {
        emailVerified = true
        guard let data = try? keyStore.load(.session),
              let saved = try? JSONDecoder().decode(SavedSession.self, from: data) else { return }
        try? saveSession(SavedSession(email: saved.email, session: Self.session(saved.session, verified: true),
                                      server: saved.server))
    }

    private static func session(_ session: ServerSession, verified: Bool) -> ServerSession {
        ServerSession(userID: session.userID, token: session.token, expiresAt: session.expiresAt,
                      emailVerified: verified)
    }

    /// Emails a new code. The server waits a minute between codes.
    public func resendVerification() async throws {
        try await signedIn { try await $0.resendVerification() }
    }

    /// Asks for a reset code. Needs no session; the server is checked first,
    /// as before any password goes to it. The server answers the same whether
    /// or not the address has an account, and emails only a confirmed one.
    public func forgotPassword(email typed: String) async throws {
        let transport = makeTransport(try serverURL())
        try await confirmEnvironment(of: transport)
        try await transport.forgotPassword(email: Self.normalised(email: typed))
    }

    /// Sets a new password with an emailed code and signs this device in.
    /// Every other device is signed out.
    public func resetPassword(email typed: String, code: String, newPassword: String) async throws {
        state = .busy("Setting a new password")
        let email = Self.normalised(email: typed)
        do {
            let url = try serverURL()
            let transport = makeTransport(url)
            try await confirmEnvironment(of: transport)
            let session = try await transport.resetPassword(email: email, code: AccountRules.normalisedCode(code),
                                                            newPassword: newPassword,
                                                            deviceLabel: Self.deviceLabel)
            try await finishSigningIn(transport: transport, email: email, session: session, server: url,
                                      takingThisMac: false)
        } catch {
            throw report(error)
        }
    }

    /// Changes the password. This device stays signed in; every other one
    /// is signed out.
    public func changePassword(current: String, new: String) async throws {
        try await signedIn { try await $0.changePassword(current: current, new: new) }
    }

    /// Signs every device out, this one included. When the server cannot be
    /// reached, nothing changes: this device stays signed in, so the person
    /// can try again, and no device is said to be signed out.
    public func signOutEverywhere() async throws {
        try await signedIn { try await $0.signOutEverywhere() }
        forgetSession()
        state = .signedOut
    }

    /// Runs an account call with this device's session. One the server has
    /// ended signs the device out, as a sync would.
    private func signedIn(_ call: (any ReadableAccountTransport) async throws -> Void) async throws {
        do {
            try await call(try requireTransport())
        } catch ReadableTransportError.sessionEnded {
            endSession(reason: Self.sessionEndedReason)
            throw ReadableTransportError.sessionEnded(Self.sessionEndedReason)
        }
    }

    /// Ends this session on the server, then forgets it here. Signing out is
    /// not losing your budgets: the database stays.
    public func signOut() async {
        // If the server refuses or cannot be reached, sign out anyway:
        // refusing to sign someone out because the network is down is wrong.
        try? await transport?.signOut()
        forgetSession()
        state = .signedOut
    }

    /// Signed out by the server: elsewhere, by a password change or reset, or
    /// after a long time unused. Nothing is sent, and nothing local is lost.
    func endSession(reason: String) {
        let email = account
        forgetSession(keepingAccount: true)
        signInPrompt = SignInPrompt(email: email, reason: reason)
        state = .failed(reason)
    }

    /// `keepingAccount` remembers whose budgets these were, so the next
    /// launch asks that person to sign in again, with the reason.
    private func forgetSession(keepingAccount: Bool = false) {
        sessionGeneration += 1
        try? keyStore.delete(.session)
        account = nil
        transport = nil
        userID = nil
        clientID = nil
        emailVerified = false
        waitingForFounder = []
        missingOnServer = []
        if let accounts, let thisMac = try? accounts.database(for: nil) {
            // Each account's budgets are its own. Signed out is "This Mac".
            if !keepingAccount { accounts.lastAccount = nil }
            keyStore = accounts.keyStore(for: nil)
            switchTo(Store(database: thisMac))
        }
    }

    private func switchTo(_ store: Store) {
        self.store = store
        didSwitchStore?(store)
    }

    private func adopt(transport: any ReadableAccountTransport, email: String, session: ServerSession,
                       emailVerified: Bool, server: URL, keys: any KeyStore, clientID: DeviceID,
                       into target: Store) {
        sessionGeneration += 1
        keyStore = keys
        self.transport = transport
        self.userID = session.userID
        self.clientID = clientID
        self.emailVerified = emailVerified
        self.account = email
        signInPrompt = nil
        accounts?.lastAccount = email
        if target.database !== store.database { switchTo(target) }
    }

    private func saveSession(_ saved: SavedSession) throws {
        try keyStore.store(try JSONEncoder().encode(saved), for: .session)
    }

    /// The server set now, unless it is not an address or is the other build's
    /// server. Everything that talks to a server comes through here first.
    private func serverURL() throws -> URL {
        guard let url = URL(string: serverAddress.trimmingCharacters(in: .whitespaces)),
              url.scheme == "http" || url.scheme == "https", url.host != nil else {
            throw Failure.server("\(serverAddress) is not a server address.")
        }
        if let why = environment.refusal(ofServerAt: url) { throw Failure.wrongServer(why) }
        return url
    }

    /// Asks the server which one it is. The address check in `serverURL` only
    /// knows the two servers' names. This also catches another name for one of
    /// them, a bare IP address, or a server on this Mac started as the wrong one.
    private func confirmEnvironment(of transport: any ReadableAccountTransport) async throws {
        let health = try await transport.health()
        if let why = environment.refusal(ofServerSaying: health.environment) {
            throw Failure.wrongServer(why)
        }
    }

    /// One spelling per server, so a saved session still matches when the address
    /// is typed with capitals or a slash at the end.
    static func normalized(_ url: URL) -> String {
        guard var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return url.absoluteString
        }
        parts.scheme = parts.scheme?.lowercased()
        parts.host = parts.host?.lowercased()
        while parts.path.hasSuffix("/") { parts.path.removeLast() }
        return parts.string ?? url.absoluteString
    }

    /// An address in the one form the server keeps, as `AccountRules` on the
    /// server makes it: trimmed, one Unicode form, lower case. A plain
    /// address is unchanged, so an account's files stay where they are.
    static func normalised(email: String) -> String {
        var email = email.trimmingCharacters(in: .whitespacesAndNewlines)
        // An address copied from a link arrives as "mailto:name@example.com".
        // The server drops the prefix the same way, so the account is the
        // plain address, which is the one the person types next time.
        if email.lowercased().hasPrefix("mailto:") { email = String(email.dropFirst("mailto:".count)) }
        return email.trimmingCharacters(in: .whitespacesAndNewlines).precomposedStringWithCanonicalMapping.lowercased()
    }

    /// The name this device shows in the account's list of signed-in devices.
    static var deviceLabel: String {
        let name = ProcessInfo.processInfo.hostName
        return name.isEmpty ? "A computer" : name
    }

    // MARK: - Sync

    /// Syncs every group this account is in. Never throws: this runs from a
    /// button and reports through `state`.
    ///
    /// `quietly` is for the syncs nobody asked for (see `AutoSync`). A quiet one
    /// that fails puts back the state it found, so a server that is briefly down
    /// does not turn the button into an error every two minutes. A session the
    /// server has ended signs the device out even then.
    @discardableResult
    public func syncAll(quietly: Bool = false) async -> SyncReport {
        var combined = SyncReport()
        guard let email = account, let transport else {
            if !quietly { state = .failed("Sign in first.") }
            return combined
        }
        let before = state
        let generation = sessionGeneration
        state = .busy("Syncing")
        do {
            let listed = try await transport.groups()
            // Signed out, or in as someone else, while the list was on its way.
            guard generation == sessionGeneration else { return combined }
            guard let userID else { throw Failure.notSignedIn }
            let actions = try SyncPlan.actions(store: store, listed: listed, me: userID)
            for group in listed {
                try store.saveServerGroup(ServerGroupInfo(group))
            }
            waitingForFounder = []
            missingOnServer = []
            // Confirmed on another device, perhaps: asked while it is not.
            var confirmedElsewhere = false
            if !emailVerified { confirmedElsewhere = try await transport.me().emailVerified }
            guard generation == sessionGeneration else { return combined }
            if confirmedElsewhere { noteEmailVerified() }
            // One group's failure does not stop the others. The first is
            // reported once the round is over.
            var firstFailure: (any Error)?
            for action in actions {
                do {
                    combined.add(try await perform(action))
                } catch let error as ReadableTransportError {
                    if case .sessionEnded = error { throw error }
                    firstFailure = firstFailure ?? error
                } catch {
                    firstFailure = firstFailure ?? error
                }
                guard generation == sessionGeneration else { return combined }
            }
            lastReport = combined
            lastSyncedAt = Date()
            if let firstFailure { throw firstFailure }
            if !missingOnServer.isEmpty { throw Failure.server(Self.missingOnServerReason) }
            state = .signedIn(email: email)
        } catch ReadableTransportError.sessionEnded {
            guard generation == sessionGeneration else { return combined }
            endSession(reason: Self.sessionEndedReason)
        } catch {
            guard generation == sessionGeneration else { return combined }
            state = quietly ? before : .failed(readable(error))
        }
        didSync?()
        return combined
    }

    nonisolated static let sessionEndedReason = """
        You were signed out on this device. Sign in again. Your budgets are still here.
        """

    nonisolated static let missingOnServerReason = """
        A budget group you made is missing from the server. Nothing was changed on this device. \
        Ask for help before changing that group.
        """

    private func perform(_ action: GroupAction) async throws -> SyncReport {
        switch action {
        case .sync(let group, let level):
            // Made here, with the reply to its first send lost: the server has
            // it, so it is on the server from now on.
            if try store.serverGroup(group)?.movedAt == nil, try !store.hasSealedHistory(group) {
                try store.markMoved(group)
            }
            return try await sync(group, level: level)
        case .create(let group):
            // The key this Mac's imports use, made now if there is none yet,
            // so an import before the reply comes back matches the server's.
            let key = try store.oldestGroupKey(group).flatMap { $0.count == 32 ? $0 : nil }
                ?? store.localKey(for: .group(group)).rawBytes
            let made = try await requireTransport().createGroup(id: group, importKey: key)
            try store.saveServerGroup(ServerGroupInfo(made))
            try store.markMoved(group)
            return try await sync(group, level: made.level)
        case .placeholder(let listed):
            try store.placeholderGroup(listed.id, name: "")
            try store.markMoved(listed.id)
            return try await sync(listed.id, level: listed.level)
        case .waitForFounder(let group):
            waitingForFounder.insert(group)
            return SyncReport()
        case .moveAsCreator(let group, let level):
            return try await moveAsCreator(group, level: level)
        case .adopt(let listed):
            return try await adopt(listed)
        case .sendDelete(let group, let level):
            return try await sendDelete(group, level: level)
        case .leave(let group, let level):
            return try await sendThenLeave(group, level: level)
        case .letGo(let group, let level):
            let report = try await engine().pushWithoutPulling(group: group, level: level)
            try store.clearOutbox(in: group)
            return report
        case .dropQueue(let group):
            try store.clearOutbox(in: group)
            return SyncReport()
        case .rejoin(let listed):
            return try await showAgain(listed)
        case .removed(let group):
            try store.hideGroup(group)
            try store.markRemoved(group)
            return SyncReport()
        case .missingOnServer(let group):
            missingOnServer.insert(group)
            return SyncReport()
        }
    }

    /// A group hidden here, listed for this person again: shown, and taken
    /// in from the start. One from before the switch that this Mac has not
    /// sent up yet goes through the move, so this person's own entries from
    /// before still go up once.
    private func showAgain(_ listed: ServerGroup) async throws -> SyncReport {
        // What was saved here before it was hidden goes first, when the
        // group came back before a leave sent it. Sent after the pulls are
        // forgotten, it came back looking like this device's own echo and
        // was skipped, so this device kept its deleted copy of an entry
        // everyone else could see. One not sent up yet goes through the move.
        let sentUp = try store.serverGroup(listed.id)?.movedAt != nil || !store.hasSealedHistory(listed.id)
        if sentUp, try store.outboxCount(in: listed.id) > 0 {
            _ = try await engine().pushWithoutPulling(group: listed.id, level: listed.level)
        }
        try store.forgetPulls(in: listed.id)
        try store.resetPullCursor(in: listed.id)
        if var group = try store.group(listed.id), group.isDeleted {
            group.isDeleted = false
            try store.save(group, queue: false)
        }
        try store.markListedAgain(listed.id)
        if try store.hasSealedHistory(listed.id), try store.serverGroup(listed.id)?.movedAt == nil {
            if listed.founderID == userID { return try await moveAsCreator(listed.id, level: listed.level) }
            if listed.importKey.isEmpty {
                waitingForFounder.insert(listed.id)
                return SyncReport()
            }
            return try await adopt(listed)
        }
        try store.markMoved(listed.id)
        return try await sync(listed.id, level: listed.level)
    }

    /// Takes in, sends, and notes who is in the group now.
    func sync(_ group: GroupID, level: AccessLevel) async throws -> SyncReport {
        let report = try await engine().sync(group: group, level: level)
        try await refreshMembers(of: group)
        return report
    }

    /// A group deleted here. Its founder or an admin deletes it for everyone,
    /// sending without taking in first: a pull would write other members' newer
    /// edits over the delete, and the group would come back here only. Anyone
    /// else leaves it, and it stays hidden here.
    ///
    /// The group's delete and its budget and entry deletes go in one send:
    /// the server refuses anything sent into a group once it is deleted. The
    /// server weighs each record on its own, so someone demoted between the
    /// list and the send has the group's delete refused while the rest goes
    /// through, as far as their new level allows. That is no more than they
    /// could delete at that level anyway.
    private func sendDelete(_ group: GroupID, level: AccessLevel) async throws -> SyncReport {
        guard level.allows(.admin) else { return try await leaveOnServer(group, after: SyncReport()) }
        let report = try await engine().pushWithoutPulling(group: group, level: level)
        // Nothing can be edited in a deleted group, so a row the server did
        // not take now never will be.
        try store.clearOutbox(in: group)
        return report
    }

    /// A member's delete of a shared group: what they saved before it goes
    /// to the other members, then they leave. The delete queued none of its
    /// own budget or transaction deletes, so those stay on this Mac. A push
    /// or leave that fails is tried again next round.
    ///
    /// Checked again first: a join during the round may have brought the
    /// group back since the round was planned.
    private func sendThenLeave(_ group: GroupID, level: AccessLevel) async throws -> SyncReport {
        guard try store.leaveRequested(group), try store.group(group)?.isDeleted == true else { return SyncReport() }
        return try await leaveOnServer(group, after: try await engine().pushWithoutPulling(group: group, level: level))
    }

    /// Takes this person out of `group` on the server, and drops what is
    /// still queued for it, which the server would now refuse.
    private func leaveOnServer(_ group: GroupID, after report: SyncReport) async throws -> SyncReport {
        guard let userID else { throw Failure.notSignedIn }
        try await requireTransport().remove(userID, from: group)
        try store.clearOutbox(in: group)
        try store.markRemoved(group)
        return report
    }

    func engine() throws -> ReadableSyncEngine {
        guard let transport, let clientID, let userID else { throw Failure.notSignedIn }
        return ReadableSyncEngine(store: store, transport: transport, clientID: clientID, userID: userID)
    }

    func requireTransport() throws -> any ReadableAccountTransport {
        guard let transport else { throw Failure.notSignedIn }
        return transport
    }

    // MARK: - Sharing

    /// Makes a link that invites someone to `group`. The group goes to the
    /// server first if it is not there yet, with this person's name in it, so
    /// the person joining sees who asked.
    public func share(group: GroupID, groupName: String, level: AccessLevel,
                      historyAccess: HistoryAccess, myName: String) async throws -> InviteLink {
        do {
            guard let userID else { throw Failure.notSignedIn }
            let name = myName.trimmingCharacters(in: .whitespacesAndNewlines)
            if !name.isEmpty, try displayName(in: group) != name {
                try store.save(MemberProfile(groupID: group, userID: userID, displayName: name))
            }
            let info = try await onServer(group)
            _ = try await sync(group, level: info.level)
            let invite: CreatedInvite
            do {
                invite = try await requireTransport().createInvite(group: group, level: level,
                                                                   history: historyAccess, days: nil)
            } catch ReadableTransportError.http(403, _) {
                throw Failure.server(level >= .manage
                    ? "Only an admin can invite someone as a manager."
                    : "Only a manager or admin can invite people to this group.")
            }
            guard let link = InviteLink(token: invite.token, groupName: groupName, inviterName: name) else {
                throw Failure.server("The server's invite could not be read.")
            }
            didSync?()
            return link
        } catch {
            throw report(error)
        }
    }

    /// The group as the server knows it, sending it there first if it is
    /// not there yet. A group from before the switch must be moved first.
    private func onServer(_ group: GroupID) async throws -> ServerGroupInfo {
        if let info = try store.serverGroup(group), info.movedAt != nil { return info }
        await syncAll()
        guard let info = try store.serverGroup(group), info.movedAt != nil else {
            if case .failed(let why) = state { throw Failure.server(why) }
            throw Failure.server("This group has not reached the server yet. Sync, then try again.")
        }
        return info
    }

    /// Joins the group a link invites to. It needs a confirmed email address.
    /// The group is there at once, filled by the sync that follows.
    @discardableResult
    public func join(_ link: InviteLink, myName: String) async throws -> PendingJoin {
        do {
            guard let userID else { throw Failure.notSignedIn }
            // Confirmed on another device since signing in here, perhaps.
            if !emailVerified, try await requireTransport().me().emailVerified { noteEmailVerified() }
            guard emailVerified else { throw Failure.emailNotConfirmed }
            let joined: ServerGroup
            do {
                joined = try await requireTransport().acceptInvite(token: link.token)
            } catch ReadableTransportError.http(let status, _) where [404, 410].contains(status) {
                throw Failure.server(Self.inviteProblem(status))
            } catch ReadableTransportError.http(409, let reason) {
                // Still in the group on the server, and hidden here: by the
                // sealed app, whose delete hid it on that Mac only, or by a
                // delete whose leave has not gone yet. Shown again; the
                // invite stays unused.
                guard let kept = try await hiddenGroupStillJoined(by: link) else {
                    throw ReadableTransportError.http(status: 409, reason: reason)
                }
                joined = kept
            }
            try store.saveServerGroup(ServerGroupInfo(joined))
            let hidden = try store.group(joined.id)?.isDeleted == true
            try store.placeholderGroup(joined.id, name: link.groupName)
            let name = myName.trimmingCharacters(in: .whitespacesAndNewlines)
            if !name.isEmpty {
                try store.save(MemberProfile(groupID: joined.id, userID: userID, displayName: name))
            }
            if hidden {
                // Hidden here after leaving or being removed.
                _ = try await showAgain(joined)
            } else {
                try store.markListedAgain(joined.id)
                try store.markMoved(joined.id)
                _ = try await sync(joined.id, level: joined.level)
            }
            didSync?()
            return PendingJoin(groupID: joined.id, groupName: link.groupName, inviterName: link.inviterName,
                               displayName: name, level: joined.level)
        } catch {
            throw report(error)
        }
    }

    /// The group `link` invites to, when the server still lists this person
    /// in it and it is hidden here. Nil otherwise, or when the link no longer
    /// says which group it is for, or when this person's delete of it for
    /// everyone is still waiting to go: shown again, the next sync would send
    /// that delete with the group showing here.
    private func hiddenGroupStillJoined(by link: InviteLink) async throws -> ServerGroup? {
        let transport = try requireTransport()
        guard let terms = try? await transport.previewInvite(token: link.token),
              try store.group(terms.groupID)?.isDeleted == true,
              try !store.groupDeleteIsQueued(terms.groupID) else { return nil }
        return try await transport.groups().first { $0.id == terms.groupID && !$0.deleted }
    }

    /// Leaves a group: the server forgets this person in it, and it is
    /// hidden here. Its founder deletes it instead.
    public func leave(_ group: GroupID) async throws {
        do {
            guard let userID else { throw Failure.notSignedIn }
            try await requireTransport().remove(userID, from: group)
            try store.hideGroup(group)
            try store.markRemoved(group)
            didSync?()
        } catch {
            throw report(error)
        }
    }

    /// Changes someone's level in a group.
    public func setLevel(_ level: AccessLevel, of user: UserID, in group: GroupID) async throws {
        do {
            try await requireTransport().setLevel(level, of: user, in: group)
            try await refreshMembers(of: group)
        } catch {
            throw report(error)
        }
    }

    /// Removes someone from a group.
    public func remove(_ user: UserID, from group: GroupID) async throws {
        do {
            try await requireTransport().remove(user, from: group)
            try await refreshMembers(of: group)
        } catch {
            throw report(error)
        }
    }

    /// Invites not yet accepted or expired. Managers see them all.
    public func invites(in group: GroupID) async throws -> [ServerInvite] {
        do {
            return try await requireTransport().invites(in: group)
        } catch {
            throw report(error)
        }
    }

    public func cancelInvite(_ id: UUID, in group: GroupID) async throws {
        do {
            try await requireTransport().cancelInvite(id, in: group)
        } catch {
            throw report(error)
        }
    }

    /// Who is in `group`, as the server last said.
    public func members(of group: GroupID) -> [UserID: AccessLevel] {
        (try? store.members(in: group)) ?? [:]
    }

    /// The name each member gave the group, as last synced.
    public func memberNames(in group: GroupID) -> [UserID: String] {
        let profiles = ((try? store.profiles(in: group)) ?? []).filter { !$0.isDeleted }
        return Dictionary(profiles.map { ($0.userID, $0.displayName) }, uniquingKeysWith: { first, _ in first })
    }

    /// Takes in one group now, with who is in it and their names, for a screen
    /// about that group: someone who just joined shows without waiting for the
    /// next sync. Quiet: if it cannot, things stay as they were, and the next
    /// sync says why.
    public func refresh(_ group: GroupID) async {
        guard account != nil, let info = try? store.serverGroup(group),
              info.movedAt != nil, info.removedAt == nil else { return }
        _ = try? await sync(group, level: info.level)
        didSync?()
    }

    /// Who made `group`, once the server lists it; nil for a group still only
    /// on this device.
    public func founder(of group: GroupID) -> UserID? {
        (try? store.serverGroup(group))?.founderID
    }

    private func refreshMembers(of group: GroupID) async throws {
        let members = try await requireTransport().members(of: group)
        try store.replaceMembers(Dictionary(members.map { ($0.userID, $0.level) }, uniquingKeysWith: max),
                                 in: group)
    }

    /// The invite statuses, in words. Only here: 409 also means "email taken" at
    /// sign-up, so these cannot live in the general error wording.
    static func inviteProblem(_ status: Int) -> String {
        switch status {
        case 404: return "That invite was not found. It may have been cancelled."
        case 409: return "That invite has already been used."
        default: return "That invite has expired or can no longer be used. Ask for a new link."
        }
    }

    // MARK: - Reading what the server said

    /// The name this person shows `group`, if they have set one.
    public func displayName(in group: GroupID) throws -> String? {
        guard let userID else { return nil }
        return try store.profile(MemberProfile.recordID(group: group, user: userID))?.displayName
    }

    /// What deleting `group` does beyond this Mac, for the confirmation: from
    /// who the server said is in it, as of the last sync.
    public func deleteReach(of group: GroupID) -> GroupDeleteReach {
        let members = (try? store.members(in: group)) ?? [:]
        guard !members.isEmpty else { return SealedHistory.deleteReach(of: group, in: store, me: userID) }
        guard members.count > 1 else { return .justYou }
        let level = (try? store.serverGroup(group))?.level ?? AccessLevel.none
        return level.allows(.admin) ? .everyone : .thisMacOnly
    }

    /// Whether this person may add, change or delete budgets in `group`, or
    /// rename it, which takes Manage. A group the server has never listed is
    /// this person's own.
    public func mayManageBudgets(in group: GroupID) -> Bool {
        if let info = try? store.serverGroup(group) { return info.level.allows(.manage) }
        return SealedHistory.mayManageBudgets(in: group, store: store, me: userID)
    }

    /// Whether this person may add entries to `group`, which takes Add. Below
    /// that the server refuses them, and an entry saved anyway would stay on
    /// this device, so nothing offers it. A group the server has never listed
    /// is this person's own.
    public func mayAddEntries(in group: GroupID) -> Bool {
        if let info = try? store.serverGroup(group) { return info.level.allows(.write) }
        return SealedHistory.mayAddEntries(in: group, store: store, me: userID)
    }

    // MARK: - Errors in words

    private func report(_ error: any Error) -> any Error {
        // Any call can find the session ended; it signs the device out, as a
        // sync does.
        if case ReadableTransportError.sessionEnded = error, account != nil {
            endSession(reason: Self.sessionEndedReason)
            return error
        }
        let message = readable(error)
        state = .failed(message)
        return error as? Failure ?? Failure.server(message)
    }

    func readable(_ error: any Error) -> String {
        AccountWording.words(for: error)
    }
}

extension SyncCoordinator: AccountActions {}

extension SyncCoordinator: SharingActions {}

extension ServerGroupInfo {
    /// What the server said about a group, as of now. When this Mac moved
    /// the group is kept by the store, not taken from here.
    init(_ group: ServerGroup) {
        self.init(groupID: group.id, founderID: group.founderID, level: group.level, importKey: group.importKey,
                  historyFloor: group.historyFloor, deletedOnServer: group.deleted)
    }
}

extension SyncReport {
    mutating func add(_ other: SyncReport) {
        pushed += other.pushed
        pulled += other.pulled
        applied += other.applied
        rejected += other.rejected
        conflicts += other.conflicts
        echoes += other.echoes
        ignored += other.ignored
        deferred += other.deferred
        unsaved += other.unsaved
        serverSeq = max(serverSeq, other.serverSeq)
    }
}
