import Foundation
@testable import WellSpentAppCore
import WellSpentCrypto
import WellSpentSync

/// The readable server in memory, with the knobs the app tests turn: what it
/// says it is, refusals, failures, and counts of what was asked. Two of these
/// over one `server` are two devices or two people on one server.
final class StubReadableTransport: ReadableAccountTransport, @unchecked Sendable {
    let server: InMemoryReadableServer
    private let lock = NSLock()
    private var inner: InMemoryReadableSession

    /// What `/health` says. A test build is a staging build, which signs in
    /// only to a staging or development server. Nil is a server from before
    /// the field, which only the live build accepts.
    var serverEnvironment: String? {
        get { lock.withLock { _serverEnvironment } }
        set { lock.withLock { _serverEnvironment = newValue } }
    }
    private var _serverEnvironment: String? = "staging"
    var healthError: (any Error)?
    var refuseSignIn: ReadableTransportError?
    var refuseSignUp: ReadableTransportError?
    /// Makes listing groups fail, which fails a whole sync round.
    var failSync: ReadableTransportError?
    /// Groups left out of the next listing only, as a server restored from an
    /// older backup would.
    var leaveOutOfNextListing: Set<GroupID> = []
    /// The next group made is made on the server, and its reply is lost.
    var loseNextCreateReply = false
    /// Runs once a listing has been read, before it is handed back.
    var whileListing: (@Sendable () async -> Void)?
    /// Runs while the server is asked what an invite offers, before it
    /// answers.
    var whilePreviewing: (@Sendable () async -> Void)?
    /// Runs once the server has taken an invite, before the group is handed
    /// back.
    var whileAccepting: (@Sendable () async -> Void)?
    /// Makes signing out everywhere fail before it reaches the server.
    var failSignOutEverywhere: URLError?
    /// The saved session a resume used, if one did.
    private(set) var resumed: ServerSession?
    private(set) var healthChecks = 0
    private(set) var signUps = 0
    private(set) var signIns = 0
    private(set) var syncRounds = 0
    private(set) var previews = 0

    init(server: InMemoryReadableServer = InMemoryReadableServer()) {
        self.server = server
        self.inner = server.client()
    }

    private var client: InMemoryReadableSession { lock.withLock { inner } }

    func resuming(with session: ServerSession) -> any ReadableAccountTransport {
        lock.withLock {
            resumed = session
            inner = server.client(session: session)
        }
        return self
    }

    func health() async throws -> HTTPTransport.Health {
        lock.withLock { healthChecks += 1 }
        if let healthError { throw healthError }
        return HTTPTransport.Health(status: "ok", environment: serverEnvironment)
    }

    func signUp(email: String, password: String, deviceLabel: String?) async throws -> ServerSession {
        lock.withLock { signUps += 1 }
        if let refuseSignUp { throw refuseSignUp }
        let fresh = server.client()
        let session = try await fresh.signUp(email: email, password: password, deviceLabel: deviceLabel)
        lock.withLock { inner = fresh }
        return session
    }

    func signIn(email: String, password: String, deviceLabel: String?) async throws -> ServerSession {
        lock.withLock { signIns += 1 }
        if let refuseSignIn { throw refuseSignIn }
        let fresh = server.client()
        let session = try await fresh.signIn(email: email, password: password, deviceLabel: deviceLabel)
        lock.withLock { inner = fresh }
        return session
    }

    func resetPassword(email: String, code: String, newPassword: String,
                       deviceLabel: String?) async throws -> ServerSession {
        let fresh = server.client()
        let session = try await fresh.resetPassword(email: email, code: code, newPassword: newPassword,
                                                    deviceLabel: deviceLabel)
        lock.withLock { inner = fresh }
        return session
    }

    func forgotPassword(email: String) async throws { try await client.forgotPassword(email: email) }
    func signOut() async throws { try await client.signOut() }
    func signOutEverywhere() async throws {
        if let failSignOutEverywhere { throw failSignOutEverywhere }
        try await client.signOutEverywhere()
    }
    func me() async throws -> Me { try await client.me() }
    func sessions() async throws -> [DeviceSession] { try await client.sessions() }
    func endSession(_ id: UUID) async throws { try await client.endSession(id) }
    func verifyEmail(code: String) async throws { try await client.verifyEmail(code: code) }
    func resendVerification() async throws { try await client.resendVerification() }
    func changePassword(current: String, new: String) async throws {
        try await client.changePassword(current: current, new: new)
    }

    func groups() async throws -> [ServerGroup] {
        lock.withLock { syncRounds += 1 }
        if let failSync { throw failSync }
        let left = lock.withLock { () -> Set<GroupID> in
            defer { leaveOutOfNextListing = [] }
            return leaveOutOfNextListing
        }
        let listed = try await client.groups().filter { !left.contains($0.id) }
        if let whileListing { await whileListing() }
        return listed
    }

    func createGroup(id: GroupID, importKey: Data?) async throws -> ServerGroup {
        let made = try await client.createGroup(id: id, importKey: importKey)
        let lose = lock.withLock { () -> Bool in
            defer { loseNextCreateReply = false }
            return loseNextCreateReply
        }
        if lose { throw URLError(.networkConnectionLost) }
        return made
    }
    func members(of group: GroupID) async throws -> [ServerMember] { try await client.members(of: group) }
    func setLevel(_ level: AccessLevel, of user: UserID, in group: GroupID) async throws {
        try await client.setLevel(level, of: user, in: group)
    }
    func remove(_ user: UserID, from group: GroupID) async throws { try await client.remove(user, from: group) }
    func createInvite(group: GroupID, level: AccessLevel, history: HistoryAccess,
                      days: Int?) async throws -> CreatedInvite {
        try await client.createInvite(group: group, level: level, history: history, days: days)
    }
    func invites(in group: GroupID) async throws -> [ServerInvite] { try await client.invites(in: group) }
    func cancelInvite(_ id: UUID, in group: GroupID) async throws { try await client.cancelInvite(id, in: group) }
    func previewInvite(token: String) async throws -> InviteTerms {
        lock.withLock { previews += 1 }
        if let whilePreviewing { await whilePreviewing() }
        return try await client.previewInvite(token: token)
    }
    func acceptInvite(token: String) async throws -> ServerGroup {
        let group = try await client.acceptInvite(token: token)
        if let whileAccepting { await whileAccepting() }
        return group
    }
    func push(_ records: [WireRecord], group: GroupID) async throws -> PushResult {
        try await client.push(records, group: group)
    }
    func pull(group: GroupID, since: UInt64, limit: Int) async throws -> ReadablePull {
        try await client.pull(group: group, since: since, limit: limit)
    }
}
