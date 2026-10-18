import Foundation
import WellSpentCrypto

#if canImport(FoundationNetworking)
import FoundationNetworking      // URLSession lives here on Linux
#endif

/// Talks to the readable server, under /api/v2.
///
/// It carries its own request plumbing rather than sharing `HTTPTransport`'s,
/// because that one goes when the sealed API does.
///
/// Dates are ISO 8601 and bytes are base64 in both directions, as the server
/// encodes them.
public actor ReadableHTTPTransport: ReadableAccountTransport {
    /// /api/v2 on the server.
    private let apiURL: URL
    /// The server itself, where `/health` lives.
    private let rootURL: URL
    private let urlSession: URLSession
    private var session: ServerSession?
    private let requestDeadline: Duration

    /// How long one request may take, start to finish, before it counts as
    /// unanswered. On a network that answers nothing, such as a Wi-Fi with no
    /// internet behind it, Linux's network library waited a minute for each
    /// address it tried, and the app showed "Syncing" for minutes.
    public static let defaultRequestDeadline: Duration = .seconds(30)

    /// `baseURL` may be the server itself or any /api/vN under it.
    public init(baseURL: URL, urlSession: URLSession = .shared, session: ServerSession? = nil,
                requestDeadline: Duration = defaultRequestDeadline) {
        var root = baseURL
        if root.lastPathComponent.hasPrefix("v"), root.deletingLastPathComponent().lastPathComponent == "api" {
            root = root.deletingLastPathComponent().deletingLastPathComponent()
        }
        self.rootURL = root
        self.apiURL = root.appendingPathComponent("api/v2")
        self.urlSession = urlSession
        self.session = session
        self.requestDeadline = requestDeadline
    }

    public var currentSession: ServerSession? { session }

    public nonisolated func resuming(with session: ServerSession) -> any ReadableAccountTransport {
        ReadableHTTPTransport(baseURL: rootURL, urlSession: urlSession, session: session,
                              requestDeadline: requestDeadline)
    }

    public func health() async throws -> HTTPTransport.Health {
        var request = URLRequest(url: rootURL.appendingPathComponent("health"))
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return try decode(try await perform(request, as: .anonymous))
    }

    // MARK: - Accounts

    private struct Credentials: Encodable {
        let email: String
        let password: String
        let deviceLabel: String?
    }

    private struct Reset: Encodable {
        let email: String
        let code: String
        let newPassword: String
        let deviceLabel: String?
    }

    private struct Email: Encodable { let email: String }
    private struct Code: Encodable { let code: String }
    private struct PasswordChange: Encodable {
        let currentPassword: String
        let newPassword: String
    }

    public func signUp(email: String, password: String, deviceLabel: String?) async throws -> ServerSession {
        adopt(try await send(.post, "signup", body: Credentials(email: email, password: password,
                                                               deviceLabel: deviceLabel),
                             as: .anonymous, oldServerIfMissing: true))
    }

    public func signIn(email: String, password: String, deviceLabel: String?) async throws -> ServerSession {
        adopt(try await send(.post, "signin", body: Credentials(email: email, password: password,
                                                               deviceLabel: deviceLabel),
                             as: .signingIn, oldServerIfMissing: true))
    }

    public func resetPassword(email: String, code: String, newPassword: String,
                              deviceLabel: String?) async throws -> ServerSession {
        adopt(try await send(.post, "password/reset",
                             body: Reset(email: email, code: code, newPassword: newPassword,
                                         deviceLabel: deviceLabel),
                             as: .anonymous, oldServerIfMissing: true))
    }

    public func forgotPassword(email: String) async throws {
        try await sendIgnoringReply(.post, "password/forgot", body: Email(email: email),
                                    as: .anonymous, oldServerIfMissing: true)
    }

    private func adopt(_ new: ServerSession) -> ServerSession {
        session = new
        return new
    }

    /// Ends this session on the server, then forgets it here. The local half
    /// happens either way, so pressing sign out while offline still signs out.
    public func signOut() async throws {
        defer { session = nil }
        guard session != nil else { return }
        try await sendIgnoringReply(.post, "signout", as: .signedIn)
    }

    /// Forgets the session only once the server has ended it, or says it
    /// already had. A call that fails leaves this device signed in, so it
    /// can try again, and never looks as if every device was signed out.
    public func signOutEverywhere() async throws {
        do {
            try await sendIgnoringReply(.post, "signout/everywhere", as: .signedIn)
        } catch ReadableTransportError.sessionEnded(let reason) {
            session = nil
            throw ReadableTransportError.sessionEnded(reason)
        }
        session = nil
    }

    public func me() async throws -> Me {
        try await send(.get, "me", as: .signedIn, oldServerIfMissing: true)
    }

    public func sessions() async throws -> [DeviceSession] {
        try await send(.get, "sessions", as: .signedIn)
    }

    public func endSession(_ id: UUID) async throws {
        try await sendIgnoringReply(.delete, "sessions/\(id.uuidString)", as: .signedIn)
    }

    public func verifyEmail(code: String) async throws {
        try await sendIgnoringReply(.post, "email/verify", body: Code(code: code), as: .signedIn)
    }

    public func resendVerification() async throws {
        try await sendIgnoringReply(.post, "email/verify/resend", as: .signedIn)
    }

    public func changePassword(current: String, new: String) async throws {
        try await sendIgnoringReply(.post, "password/change",
                                    body: PasswordChange(currentPassword: current, newPassword: new),
                                    as: .changingPassword)
    }

    // MARK: - Groups, members and invites

    private struct GroupBody: Codable {
        let id: UUID
        let founderID: UUID
        let level: Int
        let importKey: Data
        let historyFloor: Int
        let deleted: Bool

        var model: ServerGroup {
            ServerGroup(id: GroupID(id), founderID: UserID(founderID), level: AccessLevel(serverValue: level),
                        importKey: importKey, historyFloor: UInt64(max(0, historyFloor)), deleted: deleted)
        }
    }

    private struct NewGroup: Encodable {
        let id: UUID
        let importKey: Data?
    }

    private struct MemberBody: Decodable {
        let userID: UUID
        let level: Int
    }

    private struct Level: Encodable { let level: Int }

    private struct NewInvite: Encodable {
        let level: Int
        let historyAccess: String
        let expiresInDays: Int?
    }

    private struct CreatedInviteBody: Decodable {
        let id: UUID
        let token: String
        let expiresAt: Date
    }

    private struct InviteBody: Decodable {
        let id: UUID
        let level: Int
        let historyAccess: String
        let expiresAt: Date
        let inviterUserID: UUID
    }

    private struct PreviewBody: Decodable {
        let groupID: UUID
        let level: Int
        let historyAccess: String
        let expiresAt: Date
    }

    private struct Token: Encodable { let token: String }

    public func groups() async throws -> [ServerGroup] {
        let groups: [GroupBody] = try await send(.get, "groups", as: .signedIn, oldServerIfMissing: true)
        return groups.map(\.model)
    }

    public func createGroup(id: GroupID, importKey: Data?) async throws -> ServerGroup {
        let group: GroupBody = try await send(.post, "groups", body: NewGroup(id: id.uuid, importKey: importKey),
                                              as: .signedIn, oldServerIfMissing: true)
        return group.model
    }

    public func members(of group: GroupID) async throws -> [ServerMember] {
        let members: [MemberBody] = try await send(.get, "groups/\(group.uuid.uuidString)/members", as: .signedIn)
        return members.map { ServerMember(userID: UserID($0.userID), level: AccessLevel(serverValue: $0.level)) }
    }

    public func setLevel(_ level: AccessLevel, of user: UserID, in group: GroupID) async throws {
        try await sendIgnoringReply(.patch, "groups/\(group.uuid.uuidString)/members/\(user.uuid.uuidString)",
                                    body: Level(level: level.rawValue), as: .signedIn)
    }

    public func remove(_ user: UserID, from group: GroupID) async throws {
        try await sendIgnoringReply(.delete, "groups/\(group.uuid.uuidString)/members/\(user.uuid.uuidString)",
                                    as: .signedIn)
    }

    public func createInvite(group: GroupID, level: AccessLevel, history: HistoryAccess,
                             days: Int?) async throws -> CreatedInvite {
        let made: CreatedInviteBody = try await send(
            .post, "groups/\(group.uuid.uuidString)/invites",
            body: NewInvite(level: level.rawValue, historyAccess: history.rawValue, expiresInDays: days),
            as: .signedIn)
        return CreatedInvite(id: made.id, token: made.token, expiresAt: made.expiresAt)
    }

    public func invites(in group: GroupID) async throws -> [ServerInvite] {
        let invites: [InviteBody] = try await send(.get, "groups/\(group.uuid.uuidString)/invites", as: .signedIn)
        return invites.map {
            ServerInvite(id: $0.id, level: AccessLevel(serverValue: $0.level),
                         history: HistoryAccess(serverValue: $0.historyAccess),
                         expiresAt: $0.expiresAt, inviterID: UserID($0.inviterUserID))
        }
    }

    public func cancelInvite(_ id: UUID, in group: GroupID) async throws {
        try await sendIgnoringReply(.delete, "groups/\(group.uuid.uuidString)/invites/\(id.uuidString)",
                                    as: .signedIn)
    }

    /// The token goes in the body, never the path, so it stays out of logs.
    public func previewInvite(token: String) async throws -> InviteTerms {
        let terms: PreviewBody = try await send(.post, "invites/preview", body: Token(token: token),
                                                as: .anonymous, oldServerIfMissing: true)
        return InviteTerms(groupID: GroupID(terms.groupID), level: AccessLevel(serverValue: terms.level),
                           history: HistoryAccess(serverValue: terms.historyAccess), expiresAt: terms.expiresAt)
    }

    public func acceptInvite(token: String) async throws -> ServerGroup {
        let group: GroupBody = try await send(.post, "invites/accept", body: Token(token: token), as: .signedIn)
        return group.model
    }

    // MARK: - Sync

    private struct PushBody: Encodable { let records: [WireRecord] }

    private struct PushReply: Decodable {
        let accepted: [UUID]
        let rejected: [String: String]
        let serverSeq: Int
    }

    private struct PullReply: Decodable {
        let records: [WireRecord]
        let serverSeq: Int
        let hasMore: Bool
    }

    public func push(_ records: [WireRecord], group: GroupID) async throws -> PushResult {
        let reply: PushReply = try await send(.post, "groups/\(group.uuid.uuidString)/push",
                                              body: PushBody(records: records),
                                              as: .signedIn, oldServerIfMissing: true)
        var rejected: [RecordID: String] = [:]
        for (key, reason) in reply.rejected {
            guard let uuid = UUID(uuidString: key) else {
                throw ReadableTransportError.malformed("a refusal names '\(key)', which is not a record ID")
            }
            rejected[RecordID(uuid)] = reason
        }
        return PushResult(accepted: reply.accepted.map { RecordID($0) }, rejected: rejected,
                          serverSeq: UInt64(max(0, reply.serverSeq)))
    }

    public func pull(group: GroupID, since: UInt64, limit: Int) async throws -> ReadablePull {
        let reply: PullReply = try await send(
            .get, "groups/\(group.uuid.uuidString)/pull",
            query: [URLQueryItem(name: "since", value: String(since)),
                    URLQueryItem(name: "limit", value: String(limit))],
            as: .signedIn, oldServerIfMissing: true)
        return ReadablePull(records: reply.records, serverSeq: UInt64(max(0, reply.serverSeq)),
                            hasMore: reply.hasMore)
    }

    // MARK: - Plumbing

    private enum Method: String {
        case get = "GET", post = "POST", patch = "PATCH", delete = "DELETE"
    }

    /// Who a call is made as, which decides what a refusal means.
    private enum Caller {
        /// No session: sign-up, a reset, an invite preview, the health check.
        case anonymous
        /// A 401 means the email or password is wrong.
        case signingIn
        /// A 401 means the session is over.
        case signedIn
        /// A 403 means the current password is wrong; a 401 or a 409, that
        /// the session is over.
        case changingPassword
    }

    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    private func request(_ method: Method, _ path: String, query: [URLQueryItem],
                         as caller: Caller) throws -> URLRequest {
        var components = URLComponents(url: apiURL.appendingPathComponent(path), resolvingAgainstBaseURL: false)
        if !query.isEmpty { components?.queryItems = query }
        guard let url = components?.url else {
            throw ReadableTransportError.malformed("could not build a URL for \(path)")
        }
        var request = URLRequest(url: url)
        request.httpMethod = method.rawValue
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        switch caller {
        case .signedIn, .changingPassword:
            guard let session else { throw ReadableTransportError.sessionEnded("not signed in") }
            request.setValue("Bearer \(session.token)", forHTTPHeaderField: "Authorization")
        case .anonymous, .signingIn:
            break
        }
        return request
    }

    /// `oldServerIfMissing`: the route exists on every readable server, so a
    /// 404 for a missing route means the server predates readable sync.
    private func perform(_ request: URLRequest, as caller: Caller, oldServerIfMissing: Bool = false) async throws -> Data {
        let (data, response) = try await answer(to: request)
        guard let http = response as? HTTPURLResponse else {
            throw ReadableTransportError.malformed("no HTTP response")
        }
        let status = http.statusCode
        guard !(200 ..< 300).contains(status) else { return data }

        // Vapor's errors read {"error": true, "reason": "..."}. Anything else,
        // such as a proxy's HTML page, gives no reason: its text is never
        // shown to anyone.
        struct ServerError: Decodable { let reason: String? }
        let reason = (try? JSONDecoder().decode(ServerError.self, from: data))?.reason ?? ""
        switch (caller, status) {
        case (.signingIn, 401):
            throw ReadableTransportError.badCredentials
        case (.signedIn, 401), (.changingPassword, 401), (.changingPassword, 409):
            throw ReadableTransportError.sessionEnded(reason)
        case (.changingPassword, 403):
            throw ReadableTransportError.wrongCurrentPassword
        // A route the server does not have answers Vapor's plain "Not
        // Found". A route it has can answer 404 too, with its own reason,
        // such as an invite that is gone.
        case (_, 404) where oldServerIfMissing && reason == "Not Found":
            throw ReadableTransportError.serverNotUpdated
        default:
            throw ReadableTransportError.http(status: status, reason: reason)
        }
    }

    /// The server's reply, or `URLError(.timedOut)` once `requestDeadline`
    /// passes, which the app shows as "could not reach the server". The
    /// request is cancelled then, so nothing is left waiting on it.
    private func answer(to request: URLRequest) async throws -> (Data, URLResponse) {
        let urlSession = urlSession, deadline = requestDeadline
        return try await withThrowingTaskGroup(of: (Data, URLResponse)?.self) { group in
            group.addTask { try await urlSession.data(for: request) }
            group.addTask {
                try await Task.sleep(for: deadline)
                return nil
            }
            defer { group.cancelAll() }
            guard let first = try await group.next(), let reply = first else { throw URLError(.timedOut) }
            return reply
        }
    }

    private func send<Reply: Decodable>(_ method: Method, _ path: String, query: [URLQueryItem] = [],
                                        as caller: Caller, oldServerIfMissing: Bool = false) async throws -> Reply {
        let request = try request(method, path, query: query, as: caller)
        return try decode(try await perform(request, as: caller, oldServerIfMissing: oldServerIfMissing))
    }

    private func send<Reply: Decodable>(_ method: Method, _ path: String, body: some Encodable,
                                        as caller: Caller, oldServerIfMissing: Bool = false) async throws -> Reply {
        let request = try withBody(try request(method, path, query: [], as: caller), body)
        return try decode(try await perform(request, as: caller, oldServerIfMissing: oldServerIfMissing))
    }

    private func sendIgnoringReply(_ method: Method, _ path: String, as caller: Caller,
                                   oldServerIfMissing: Bool = false) async throws {
        let request = try request(method, path, query: [], as: caller)
        _ = try await perform(request, as: caller, oldServerIfMissing: oldServerIfMissing)
    }

    private func sendIgnoringReply(_ method: Method, _ path: String, body: some Encodable, as caller: Caller,
                                   oldServerIfMissing: Bool = false) async throws {
        let request = try withBody(try request(method, path, query: [], as: caller), body)
        _ = try await perform(request, as: caller, oldServerIfMissing: oldServerIfMissing)
    }

    private func withBody(_ request: URLRequest, _ body: some Encodable) throws -> URLRequest {
        var request = request
        request.httpBody = try Self.encoder.encode(body)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        return request
    }

    private func decode<Reply: Decodable>(_ data: Data) throws -> Reply {
        do {
            return try Self.decoder.decode(Reply.self, from: data)
        } catch {
            // The reply itself stays out of the error: a sign-in reply holds
            // the session's token.
            throw ReadableTransportError.malformed("\(Reply.self): \(error)")
        }
    }
}
