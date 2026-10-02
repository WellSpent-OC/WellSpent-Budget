import Foundation
import WellSpentCrypto

#if canImport(FoundationNetworking)
import FoundationNetworking      // URLSession lives here on Linux
#endif

/// Talks to the real server.
///
/// Until this existed, `SyncTransport` had exactly one implementation and it was
/// the in-memory fake. Both sides enforced the same rules and neither had ever
/// spoken to the other, which is the most likely place for a disagreement to be
/// hiding.
///
/// Dates are pinned to ISO 8601 in both directions, matching the server's
/// `ContentConfiguration`. That is not cosmetic: `MembershipLogEntry.at` is
/// covered by the author's signature, so if the two sides disagree about how a
/// `Date` encodes, every signature fails to verify and nothing says why.
public actor HTTPTransport: SyncTransport {
    public struct Credentials: Sendable, Codable, Equatable {
        public let userID: UserID
        public let token: String
        public let expiresOn: Date

        public init(userID: UserID, token: String, expiresOn: Date) {
            self.userID = userID
            self.token = token
            self.expiresOn = expiresOn
        }
    }

    public enum Failure: Error, Sendable {
        case notAuthenticated
        case http(status: Int, reason: String)
        case malformedResponse(String)
    }

    private let baseURL: URL
    private let session: URLSession
    private var credentials: Credentials?

    public init(baseURL: URL, session: URLSession = .shared, credentials: Credentials? = nil) {
        // Everything hangs off /api/v1, so accept either form of base URL.
        self.baseURL = baseURL.lastPathComponent == "v1" ? baseURL
                                                         : baseURL.appendingPathComponent("api/v1")
        self.session = session
        self.credentials = credentials
    }

    public var currentCredentials: Credentials? { credentials }

    public func use(_ credentials: Credentials?) {
        self.credentials = credentials
    }

    /// Revokes this session on the server, then forgets it here.
    ///
    /// Clearing the token locally is not signing out: the server honours it for
    /// another thirty days. The local half happens either way, because a person
    /// who pressed sign out while offline should still be signed out.
    public func signOut() async throws {
        defer { credentials = nil }
        guard credentials != nil else { return }
        var request = try request(.post, "signout", query: [], authenticated: true)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        _ = try await perform(request)
    }

    // MARK: - Coding

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

    // MARK: - Accounts

    private struct SignUpBody: Encodable {
        let email: String
        let password: String
        let identitySigning: Data
        let identityKEM: Data
        let escrowNonce: Data?
        let escrowCiphertext: Data?
    }

    private struct SignInBody: Encodable {
        let email: String
        let password: String
    }

    private struct AuthBody: Decodable {
        let userID: UUID
        let token: String
        let expiresOn: Date
    }

    /// Creates an account and keeps the token for subsequent calls.
    ///
    /// The escrow blob is optional on the wire but not in practice: without it,
    /// losing every device means losing the data with no way back.
    @discardableResult
    public func signUp(email: String, password: String,
                       identity: IdentityPublicKeys,
                       escrow: RecoveryEscrow? = nil) async throws -> Credentials {
        let body = SignUpBody(
            email: email, password: password,
            identitySigning: identity.signing, identityKEM: identity.kem,
            escrowNonce: escrow?.nonce, escrowCiphertext: escrow?.ciphertext
        )
        let auth: AuthBody = try await send(.post, "signup", body: body, authenticated: false)
        return adopt(auth)
    }

    @discardableResult
    public func signIn(email: String, password: String) async throws -> Credentials {
        let auth: AuthBody = try await send(.post, "signin",
                                            body: SignInBody(email: email, password: password),
                                            authenticated: false)
        return adopt(auth)
    }

    /// The same server, already signed in with a session saved from an earlier
    /// launch. No network call: if the token has been revoked since, the next
    /// call says so.
    public nonisolated func resuming(with credentials: Credentials) -> HTTPTransport {
        HTTPTransport(baseURL: baseURL, session: session, credentials: credentials)
    }

    private func adopt(_ auth: AuthBody) -> Credentials {
        let credentials = Credentials(userID: UserID(auth.userID), token: auth.token,
                                      expiresOn: auth.expiresOn)
        self.credentials = credentials
        return credentials
    }

    // MARK: - Membership

    private struct AppendLogBody: Encodable {
        let entry: MembershipLogEntry
        let wrappedKeys: [WrappedKey]
    }

    /// Appends to a group's access history.
    ///
    /// The entry and any keys the change requires go in one request, because the
    /// server applies them in a single transaction. A rotation that half applies
    /// leaves records nobody can open.
    public func appendMembership(_ entry: MembershipLogEntry, group: GroupID,
                                 wrappedKeys: [WrappedKey] = []) async throws {
        try await sendIgnoringBody(.post, "groups/\(group.uuid.uuidString)/log",
                                   body: AppendLogBody(entry: entry, wrappedKeys: wrappedKeys))
    }

    // MARK: - SyncTransport

    private struct PushBody: Encodable {
        let envelopes: [RecordEnvelope]
    }

    private struct PushBodyResponse: Decodable {
        let accepted: [UUID]
        let rejected: [String: String]
        let serverSeq: Int
    }

    private struct PullBodyResponse: Decodable {
        let envelopes: [RecordEnvelope]
        let serverSeq: Int
        let hasMore: Bool
    }

    public func push(_ envelopes: [RecordEnvelope], group: GroupID) async throws -> PushResult {
        let response: PushBodyResponse = try await send(
            .post, "groups/\(group.uuid.uuidString)/push", body: PushBody(envelopes: envelopes))

        var rejected: [RecordID: String] = [:]
        for (key, reason) in response.rejected {
            guard let uuid = UUID(uuidString: key) else { continue }
            rejected[RecordID(uuid)] = reason
        }
        return PushResult(accepted: response.accepted.map { RecordID($0) },
                          rejected: rejected,
                          serverSeq: UInt64(max(0, response.serverSeq)))
    }

    public func pull(group: GroupID, since: UInt64, limit: Int) async throws -> PullResult {
        let response: PullBodyResponse = try await send(
            .get, "groups/\(group.uuid.uuidString)/pull",
            query: [URLQueryItem(name: "since", value: String(since)),
                    URLQueryItem(name: "limit", value: String(limit))])

        return PullResult(envelopes: response.envelopes,
                          serverSeq: UInt64(max(0, response.serverSeq)),
                          hasMore: response.hasMore)
    }

    public func membershipLog(group: GroupID, since: UInt64) async throws -> [MembershipLogEntry] {
        try await send(.get, "groups/\(group.uuid.uuidString)/log",
                       query: [URLQueryItem(name: "since", value: String(since))])
    }

    public func wrappedKeys(group: GroupID, for user: UserID) async throws -> [WrappedKey] {
        try await send(.get, "groups/\(group.uuid.uuidString)/keys")
    }

    // MARK: - Plumbing

    private enum Method: String {
        case get = "GET"
        case post = "POST"
        case delete = "DELETE"
    }

    private func request(_ method: Method, _ path: String,
                         query: [URLQueryItem], authenticated: Bool) throws -> URLRequest {
        var components = URLComponents(
            url: baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false)
        if !query.isEmpty { components?.queryItems = query }
        guard let url = components?.url else {
            throw Failure.malformedResponse("could not build a url for \(path)")
        }

        var request = URLRequest(url: url)
        request.httpMethod = method.rawValue
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        if authenticated {
            guard let credentials else { throw Failure.notAuthenticated }
            request.setValue("Bearer \(credentials.token)", forHTTPHeaderField: "Authorization")
        }
        return request
    }

    private func perform(_ request: URLRequest) async throws -> Data {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw Failure.malformedResponse("no http response")
        }
        guard (200 ..< 300).contains(http.statusCode) else {
            // Vapor's AbortError renders as {"error": true, "reason": "..."}.
            struct ServerError: Decodable { let reason: String? }
            let reason = (try? JSONDecoder().decode(ServerError.self, from: data))?.reason
                ?? String(decoding: data, as: UTF8.self)
            throw Failure.http(status: http.statusCode, reason: reason)
        }
        return data
    }

    /// No body: a GET.
    private func send<Response: Decodable>(
        _ method: Method, _ path: String,
        query: [URLQueryItem] = [], authenticated: Bool = true
    ) async throws -> Response {
        let request = try request(method, path, query: query, authenticated: authenticated)
        return try decode(try await perform(request))
    }

    /// With a body: a POST.
    private func send<Response: Decodable>(
        _ method: Method, _ path: String,
        query: [URLQueryItem] = [], body: some Encodable, authenticated: Bool = true
    ) async throws -> Response {
        var request = try request(method, path, query: query, authenticated: authenticated)
        request.httpBody = try Self.encoder.encode(body)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        return try decode(try await perform(request))
    }

    private func decode<Response: Decodable>(_ data: Data) throws -> Response {
        do {
            return try Self.decoder.decode(Response.self, from: data)
        } catch {
            throw Failure.malformedResponse(
                "\(error) while decoding \(Response.self) from: \(String(decoding: data.prefix(400), as: UTF8.self))")
        }
    }

    private func sendIgnoringBody(
        _ method: Method, _ path: String, body: some Encodable, authenticated: Bool = true
    ) async throws {
        var request = try request(method, path, query: [], authenticated: authenticated)
        request.httpBody = try Self.encoder.encode(body)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        _ = try await perform(request)
    }
}

// MARK: - Invites

extension HTTPTransport: InviteTransport {
    private struct CreateInviteBody: Encodable {
        let inviteHash: Data
        let groupID: UUID
        let level: Int
        let historyAccess: String
        let expiresAt: Date
    }

    private struct LookupBody: Decodable {
        let groupID: UUID
        let level: Int
        let historyAccess: String
        let inviterUserID: UUID
        let inviterSigning: Data
        let inviterKEM: Data
        let expiresAt: Date
    }

    private struct AcceptBody: Encodable {
        let inviteHash: Data
        let acceptance: Data
    }

    private struct PendingBody: Decodable {
        let inviteHash: Data
        let level: Int
        let historyAccess: String
        let expiresAt: Date
        let acceptance: Data?
    }

    private struct UploadKeysBody: Encodable {
        let wrappedKeys: [WrappedKey]
    }

    public func createInvite(_ invite: NewInvite) async throws {
        try await sendIgnoringBody(.post, "invites", body: CreateInviteBody(
            inviteHash: invite.id, groupID: invite.group.uuid, level: invite.level.rawValue,
            historyAccess: invite.historyAccess.rawValue, expiresAt: invite.expiresAt))
    }

    /// Unauthenticated on purpose: the hash is the credential, and it can only
    /// have come from the link.
    public func lookupInvite(id: Data) async throws -> InviteLookup {
        let body: LookupBody = try await send(.get, "invites/\(id.hexString)", authenticated: false)
        guard let level = AccessLevel(rawValue: body.level),
              let history = HistoryAccess(rawValue: body.historyAccess) else {
            throw Failure.malformedResponse("unknown level or history in an invite")
        }
        return InviteLookup(
            group: GroupID(body.groupID), level: level, historyAccess: history,
            inviterUserID: UserID(body.inviterUserID),
            inviterKeys: try IdentityPublicKeys(signing: body.inviterSigning, kem: body.inviterKEM),
            expiresAt: body.expiresAt)
    }

    public func acceptInvite(id: Data, sealed: SealedAcceptance) async throws {
        try await sendIgnoringBody(.post, "invites/accept", body: AcceptBody(
            inviteHash: id, acceptance: try JSONEncoder().encode(sealed)), authenticated: false)
    }

    public func invites(in group: GroupID) async throws -> [PendingInvite] {
        let bodies: [PendingBody] = try await send(.get, "groups/\(group.uuid.uuidString)/invites")
        return bodies.compactMap { body in
            guard let level = AccessLevel(rawValue: body.level),
                  let history = HistoryAccess(rawValue: body.historyAccess) else { return nil }
            return PendingInvite(
                id: body.inviteHash, level: level, historyAccess: history, expiresAt: body.expiresAt,
                acceptance: body.acceptance.flatMap { try? JSONDecoder().decode(SealedAcceptance.self, from: $0) })
        }
    }

    public func deleteInvite(id: Data) async throws {
        let request = try request(.delete, "invites/\(id.hexString)", query: [], authenticated: true)
        _ = try await perform(request)
    }

    public func uploadKeys(_ keys: [WrappedKey], group: GroupID) async throws {
        try await sendIgnoringBody(.post, "groups/\(group.uuid.uuidString)/keys",
                                   body: UploadKeysBody(wrappedKeys: keys))
    }
}
