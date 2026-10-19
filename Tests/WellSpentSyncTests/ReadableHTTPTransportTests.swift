import Testing
import Foundation
@testable import WellSpentSync
import WellSpentCrypto

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// The readable client against a stubbed server: where each call goes, what
/// it sends, and what each refusal means. The server package's own tests
/// prove the server's side.
private final class ReadableStub: URLProtocol, @unchecked Sendable {
    /// Set before each test. Receives the request, returns a status and a body.
    nonisolated(unsafe) static var handler: (@Sendable (URLRequest) throws -> (Int, String))?
    nonisolated(unsafe) static var recorded: [(request: URLRequest, body: Data?)] = []
    private static let lock = NSLock()

    static func reset(_ handler: @escaping @Sendable (URLRequest) throws -> (Int, String)) {
        lock.withLock {
            self.handler = handler
            recorded = []
        }
    }

    static var requests: [(request: URLRequest, body: Data?)] { lock.withLock { recorded } }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let body = request.bodyData
        Self.lock.withLock { Self.recorded.append((request, body)) }
        guard let handler = Self.lock.withLock({ Self.handler }) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        do {
            let (status, text) = try handler(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1",
                                           headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(text.utf8))
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

private extension URLRequest {
    /// URLProtocol may hand the body over as a stream, so read whichever is set.
    var bodyData: Data? {
        if let httpBody { return httpBody }
        guard let stream = httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: buffer.count)
            if read <= 0 { break }
            data.append(buffer, count: read)
        }
        return data
    }
}

private func transport(base: String = "https://example.test",
                       session: ServerSession? = nil) -> ReadableHTTPTransport {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [ReadableStub.self]
    return ReadableHTTPTransport(baseURL: URL(string: base)!, urlSession: URLSession(configuration: configuration),
                                 session: session)
}

private let signedIn = ServerSession(userID: UserID(), token: "session-token",
                                     expiresAt: Date(timeIntervalSince1970: 1_800_000_000), emailVerified: true)

private func object(_ body: Data?) throws -> [String: Any] {
    let data = try #require(body)
    return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
}

private func refusal(_ reason: String) -> String { #"{"error":true,"reason":"\#(reason)"}"# }

@Suite("Readable HTTP transport", .serialized)
struct ReadableHTTPTransportTests {
    /// Calls go under /api/v2 whatever base URL the app holds, and the
    /// health check stays at the server's root.
    @Test func callsGoUnderAPIV2AndHealthStaysAtTheRoot() async throws {
        for base in ["https://example.test", "https://example.test/api/v1", "https://example.test/api/v2"] {
            ReadableStub.reset { request in
                request.url?.path == "/health" ? (200, #"{"status":"ok","environment":"staging"}"#)
                                               : (200, #"{"userID":"\#(signedIn.userID)","email":"a@b.co","emailVerified":true}"#)
            }
            let client = transport(base: base, session: signedIn)
            #expect(try await client.health() == HTTPTransport.Health(status: "ok", environment: "staging"))
            #expect(try await client.me().email == "a@b.co")
            #expect(ReadableStub.requests.map { $0.request.url?.path } == ["/health", "/api/v2/me"], "from \(base)")
        }
    }

    /// Signing in sends no token, keeps the session it gets, and the next
    /// call carries it.
    @Test func signingInKeepsTheSessionForTheNextCall() async throws {
        let user = UserID()
        ReadableStub.reset { request in
            if request.url?.path == "/api/v2/signin" {
                return (200, #"{"userID":"\#(user)","token":"fresh","expiresAt":"2027-01-01T00:00:00Z","emailVerified":false}"#)
            }
            return (200, #"{"userID":"\#(user)","email":"a@b.co","emailVerified":false}"#)
        }
        let client = transport()
        let session = try await client.signIn(email: "a@b.co", password: "long enough pass", deviceLabel: "Desk")
        #expect(session == ServerSession(userID: user, token: "fresh",
                                         expiresAt: Date(timeIntervalSince1970: 1_798_761_600), emailVerified: false))
        _ = try await client.me()

        let (signIn, sent) = ReadableStub.requests[0]
        #expect(signIn.httpMethod == "POST")
        #expect(signIn.value(forHTTPHeaderField: "Authorization") == nil)
        let body = try object(sent)
        #expect(body["email"] as? String == "a@b.co")
        #expect(body["password"] as? String == "long enough pass")
        #expect(body["deviceLabel"] as? String == "Desk")
        #expect(ReadableStub.requests[1].request.value(forHTTPHeaderField: "Authorization") == "Bearer fresh")
        #expect(await client.currentSession == session)
    }

    /// A 401 means the password is wrong when signing in, and the session is
    /// over everywhere else. Only the second signs the device out.
    @Test func a401MeansWhatTheCallMakesItMean() async throws {
        ReadableStub.reset { _ in (401, refusal("email or password is wrong")) }
        await #expect(throws: ReadableTransportError.badCredentials) {
            try await transport().signIn(email: "a@b.co", password: "wrong password", deviceLabel: nil)
        }
        ReadableStub.reset { _ in (401, refusal("Unauthorized")) }
        await #expect(throws: ReadableTransportError.sessionEnded("Unauthorized")) {
            try await transport(session: signedIn).groups()
        }
    }

    /// With no session, a signed-in call fails before anything is sent.
    @Test func withNoSessionNothingIsSent() async throws {
        ReadableStub.reset { _ in (200, "[]") }
        await #expect(throws: ReadableTransportError.sessionEnded("not signed in")) {
            try await transport().groups()
        }
        #expect(ReadableStub.requests.isEmpty)
    }

    /// Changing the password: a wrong current one leaves the session alone; a
    /// session ended, or the password changed somewhere else first, does not.
    @Test func changingThePasswordTellsAWrongPasswordFromAnEndedSession() async throws {
        let client = transport(session: signedIn)
        ReadableStub.reset { _ in (403, refusal("the current password is wrong")) }
        await #expect(throws: ReadableTransportError.wrongCurrentPassword) {
            try await client.changePassword(current: "not it at all", new: "a new long password")
        }
        ReadableStub.reset { _ in (409, refusal("the password was just changed somewhere else. Sign in again.")) }
        await #expect(throws: ReadableTransportError.sessionEnded("the password was just changed somewhere else. Sign in again.")) {
            try await client.changePassword(current: "the right one ok", new: "a new long password")
        }
        ReadableStub.reset { _ in (401, refusal("Unauthorized")) }
        await #expect(throws: ReadableTransportError.sessionEnded("Unauthorized")) {
            try await client.changePassword(current: "the right one ok", new: "a new long password")
        }
        ReadableStub.reset { _ in (204, "") }
        try await client.changePassword(current: "the right one ok", new: "a new long password")
        let body = try object(ReadableStub.requests[0].body)
        #expect(body["currentPassword"] as? String == "the right one ok")
        #expect(body["newPassword"] as? String == "a new long password")
    }

    /// A route every readable server has, answered 404, is a server from
    /// before readable sync. A 404 elsewhere is just a 404.
    @Test func a404OnACoreRouteMeansTheServerIsNotUpdated() async throws {
        ReadableStub.reset { _ in (404, refusal("Not Found")) }
        let client = transport(session: signedIn)
        await #expect(throws: ReadableTransportError.serverNotUpdated) { try await client.groups() }
        await #expect(throws: ReadableTransportError.serverNotUpdated) {
            try await transport().signIn(email: "a@b.co", password: "long enough pass", deviceLabel: nil)
        }
        ReadableStub.reset { _ in (404, refusal("no such invite")) }
        await #expect(throws: ReadableTransportError.http(status: 404, reason: "no such invite")) {
            try await client.cancelInvite(UUID(), in: GroupID())
        }
        // An updated server's own 404 on a route every server has: a used
        // or mistyped invite, not an old server.
        await #expect(throws: ReadableTransportError.http(status: 404, reason: "no such invite")) {
            try await client.previewInvite(token: "used-token")
        }
    }

    /// Records go out with the field names the server reads, and each comes
    /// back accepted or refused with its reason.
    @Test func pushSendsRecordsAndReadsEachAnswer() async throws {
        let group = GroupID(), budget = BudgetID(), device = DeviceID()
        let kept = RecordID(), refused = RecordID()
        ReadableStub.reset { _ in
            (200, #"{"accepted":["\#(kept)"],"rejected":{"\#(refused)":"\#(RecordEnvelope.olderVersionRefusal)"},"serverSeq":12}"#)
        }
        let records = [
            WireRecord(id: kept, type: .transaction, budgetID: budget, lamport: 7, clientID: device,
                       isDeleted: false, body: #"{"merchant":"Market"}"#),
            WireRecord(id: refused, type: .budget, budgetID: budget, lamport: 3, clientID: device,
                       isDeleted: true, body: "{}"),
        ]
        let result = try await transport(session: signedIn).push(records, group: group)
        #expect(result == PushResult(accepted: [kept], rejected: [refused: RecordEnvelope.olderVersionRefusal],
                                     serverSeq: 12))

        let (request, sent) = ReadableStub.requests[0]
        #expect(request.url?.path == "/api/v2/groups/\(group.uuid.uuidString)/push")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer session-token")
        let first = try #require((try object(sent)["records"] as? [[String: Any]])?.first)
        #expect(first["id"] as? String == kept.uuid.uuidString)
        #expect(first["type"] as? String == "transaction")
        #expect(first["budgetID"] as? String == budget.uuid.uuidString)
        #expect(first["lamport"] as? Int == 7)
        #expect(first["clientID"] as? String == device.uuid.uuidString)
        #expect(first["isDeleted"] as? Bool == false)
        #expect(first["body"] as? String == #"{"merchant":"Market"}"#)

        ReadableStub.reset { _ in (200, #"{"accepted":[],"rejected":{"not-an-id":"no"},"serverSeq":12}"#) }
        await #expect(throws: ReadableTransportError.self) {
            try await transport(session: signedIn).push(records, group: group)
        }
    }

    @Test func pullAsksFromWhereItLeftOffAndReadsWhatTheServerAdds() async throws {
        let group = GroupID(), id = RecordID(), device = DeviceID(), author = UserID(), editor = UserID()
        ReadableStub.reset { _ in
            (200, """
            {"records":[{"id":"\(id)","type":"futureThing","lamport":4,"clientID":"\(device)","isDeleted":false,
              "body":"{}","createdBy":"\(author)","updatedBy":"\(editor)","serverSeq":9}],
             "serverSeq":9,"hasMore":true}
            """)
        }
        let page = try await transport(session: signedIn).pull(group: group, since: 5, limit: 200)
        #expect(page == ReadablePull(records: [WireRecord(id: id, type: RecordType(rawValue: "futureThing"),
                                                          budgetID: nil, lamport: 4, clientID: device,
                                                          isDeleted: false, body: "{}", createdBy: author,
                                                          updatedBy: editor, serverSeq: 9)],
                                     serverSeq: 9, hasMore: true))
        let url = try #require(ReadableStub.requests[0].request.url)
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        #expect(url.path == "/api/v2/groups/\(group.uuid.uuidString)/pull")
        #expect(Set(query.map { "\($0.name)=\($0.value ?? "")" }) == ["since=5", "limit=200"])
    }

    /// A rung this build does not know is taken as the one below it, never above.
    @Test func groupsReadLevelsKeysAndFloors() async throws {
        let group = GroupID(), founder = UserID()
        let key = Data(repeating: 5, count: 32)
        ReadableStub.reset { _ in
            (200, """
            [{"id":"\(group)","founderID":"\(founder)","level":9,"importKey":"\(key.base64EncodedString())",
              "historyFloor":41,"deleted":false},
             {"id":"\(group)","founderID":"\(founder)","level":13,"importKey":"","historyFloor":0,"deleted":true}]
            """)
        }
        let groups = try await transport(session: signedIn).groups()
        #expect(groups == [
            ServerGroup(id: group, founderID: founder, level: .manage, importKey: key, historyFloor: 41, deleted: false),
            ServerGroup(id: group, founderID: founder, level: .superadmin, importKey: Data(), historyFloor: 0,
                        deleted: true),
        ])
        #expect(AccessLevel(serverValue: 12) == .admin)
        #expect(AccessLevel(serverValue: 99) == .admin, "never superadmin unless it says so")
        #expect(AccessLevel(serverValue: 2) == AccessLevel.none)
        #expect(HistoryAccess(serverValue: "someday") == .fromNow)
    }

    /// The invite token goes in a body, never a URL, so it stays out of logs.
    @Test func anInviteTokenNeverRidesInTheURL() async throws {
        let group = GroupID()
        ReadableStub.reset { _ in
            (200, #"{"groupID":"\#(group)","level":5,"historyAccess":"all","expiresAt":"2027-01-01T00:00:00Z"}"#)
        }
        let terms = try await transport(session: signedIn).previewInvite(token: "secret-invite-token")
        #expect(terms == InviteTerms(groupID: group, level: .write, history: .all,
                                     expiresAt: Date(timeIntervalSince1970: 1_798_761_600)))
        let (request, sent) = ReadableStub.requests[0]
        #expect(request.url?.absoluteString.contains("secret-invite-token") == false)
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil, "a preview needs no session")
        #expect(try object(sent)["token"] as? String == "secret-invite-token")
    }

    @Test func invitesAndMembersGoWhereTheServerExpects() async throws {
        let group = GroupID(), user = UserID(), invite = UUID()
        ReadableStub.reset { request in
            switch (request.httpMethod, request.url?.path) {
            case ("POST", "/api/v2/groups/\(group.uuid.uuidString)/invites"):
                return (201, #"{"id":"\#(invite)","token":"t","expiresAt":"2027-01-01T00:00:00Z"}"#)
            case ("GET", "/api/v2/groups/\(group.uuid.uuidString)/members"):
                return (200, #"[{"userID":"\#(user)","level":5}]"#)
            default:
                return (204, "")
            }
        }
        let client = transport(session: signedIn)
        let made = try await client.createInvite(group: group, level: .write, history: .fromNow, days: 7)
        #expect(made == CreatedInvite(id: invite, token: "t", expiresAt: Date(timeIntervalSince1970: 1_798_761_600)))
        #expect(try await client.members(of: group) == [ServerMember(userID: user, level: .write)])
        try await client.setLevel(.read, of: user, in: group)
        try await client.remove(user, from: group)
        try await client.cancelInvite(invite, in: group)

        let calls = ReadableStub.requests.map { "\($0.request.httpMethod ?? "") \($0.request.url?.path ?? "")" }
        let g = group.uuid.uuidString, u = user.uuid.uuidString
        #expect(calls == ["POST /api/v2/groups/\(g)/invites", "GET /api/v2/groups/\(g)/members",
                          "PATCH /api/v2/groups/\(g)/members/\(u)", "DELETE /api/v2/groups/\(g)/members/\(u)",
                          "DELETE /api/v2/groups/\(g)/invites/\(invite.uuidString)"])
        let made0 = try object(ReadableStub.requests[0].body)
        #expect(made0["level"] as? Int == 5 && made0["historyAccess"] as? String == "fromNow"
                && made0["expiresInDays"] as? Int == 7)
        #expect(try object(ReadableStub.requests[2].body)["level"] as? Int == 3)
    }

    /// A group made before the switch brings its import key; a new one may not.
    @Test func creatingAGroupSendsItsKeyOnlyWhenThereIsOne() async throws {
        let group = GroupID(), founder = UserID()
        let key = Data(repeating: 1, count: 32)
        ReadableStub.reset { _ in
            (201, """
            {"id":"\(group)","founderID":"\(founder)","level":13,"importKey":"\(key.base64EncodedString())",
             "historyFloor":0,"deleted":false}
            """)
        }
        let client = transport(session: signedIn)
        #expect(try await client.createGroup(id: group, importKey: key).importKey == key)
        _ = try await client.createGroup(id: group, importKey: nil)
        let withKey = try object(ReadableStub.requests[0].body)
        let withoutKey = try object(ReadableStub.requests[1].body)
        #expect(withKey["importKey"] as? String == key.base64EncodedString())
        #expect(withoutKey["importKey"] == nil)
    }

    /// Signing out forgets the session here even when the server cannot be told.
    @Test func signingOutForgetsTheSessionEvenWhenTheServerFails() async throws {
        ReadableStub.reset { _ in (500, refusal("down")) }
        let client = transport(session: signedIn)
        await #expect(throws: ReadableTransportError.self) { try await client.signOut() }
        #expect(await client.currentSession == nil)
    }

    /// Signing out everywhere keeps the session when the server was not
    /// reached, so the device can try again.
    @Test func aFailedSignOutEverywhereKeepsTheSession() async throws {
        let client = transport(session: signedIn)
        ReadableStub.reset { _ in throw URLError(.notConnectedToInternet) }
        await #expect(throws: URLError.self) { try await client.signOutEverywhere() }
        #expect(await client.currentSession == signedIn)
        ReadableStub.reset { _ in (204, "") }
        try await client.signOutEverywhere()
        #expect(await client.currentSession == nil)
    }

    /// A reply that is not the server's JSON gives no reason text, and a
    /// reply that cannot be read keeps its body out of the error.
    @Test func aProxysPageNeverBecomesAReason() async throws {
        ReadableStub.reset { _ in (530, "<!DOCTYPE html><title>Error 1033</title>") }
        await #expect(throws: ReadableTransportError.http(status: 530, reason: "")) {
            _ = try await transport(session: signedIn).groups()
        }
        ReadableStub.reset { _ in (200, #"{"userID":"x","token":"secret-token-123"}"#) }
        do {
            _ = try await transport().signIn(email: "a@b.co", password: "long enough pass", deviceLabel: nil)
            Issue.record("expected a malformed reply")
        } catch ReadableTransportError.malformed(let detail) {
            #expect(!detail.contains("secret-token-123"))
        }
    }

    /// A saved session carries over to a fresh client for the same server.
    @Test func resumingUsesTheSavedSession() async throws {
        ReadableStub.reset { _ in (200, "[]") }
        let resumed = transport().resuming(with: signedIn)
        _ = try await resumed.groups()
        #expect(ReadableStub.requests[0].request.value(forHTTPHeaderField: "Authorization") == "Bearer session-token")
        #expect(ReadableStub.requests[0].request.url?.host == "example.test")
    }

    /// Forgot and reset need no session, and reset signs this device in.
    @Test func aResetSignsThisDeviceIn() async throws {
        let user = UserID()
        ReadableStub.reset { request in
            request.url?.path == "/api/v2/password/forgot"
                ? (204, "")
                : (200, #"{"userID":"\#(user)","token":"after-reset","expiresAt":"2027-01-01T00:00:00Z","emailVerified":true}"#)
        }
        let client = transport()
        try await client.forgotPassword(email: "a@b.co")
        let session = try await client.resetPassword(email: "a@b.co", code: "ABCD-EFGH",
                                                     newPassword: "a new long password", deviceLabel: "Desk")
        #expect(session.token == "after-reset")
        #expect(await client.currentSession == session)
        #expect(ReadableStub.requests.allSatisfy { $0.request.value(forHTTPHeaderField: "Authorization") == nil })
        let reset = try object(ReadableStub.requests[1].body)
        #expect(reset["code"] as? String == "ABCD-EFGH" && reset["newPassword"] as? String == "a new long password")
    }

    /// A network that takes the request and never answers, as a Wi-Fi with no
    /// internet behind it does. The request gives up at the deadline, as
    /// "could not reach the server". Without a deadline of its own, the Linux
    /// app showed "Syncing" for minutes.
    @Test func aRequestNobodyAnswersGivesUpAtTheDeadline() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SilentStub.self]
        let client = ReadableHTTPTransport(baseURL: URL(string: "https://example.test")!,
                                           urlSession: URLSession(configuration: configuration),
                                           requestDeadline: .milliseconds(300))
        let clock = ContinuousClock()
        let start = clock.now
        do {
            _ = try await client.health()
            Issue.record("a request nobody answered succeeded")
        } catch let error as URLError {
            #expect(error.code == .timedOut)
        }
        #expect(clock.now - start < .seconds(10))
        #expect(ReadableHTTPTransport.defaultRequestDeadline == .seconds(30))
    }
}

/// Takes every request and never answers.
private final class SilentStub: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {}
    override func stopLoading() {}
}
