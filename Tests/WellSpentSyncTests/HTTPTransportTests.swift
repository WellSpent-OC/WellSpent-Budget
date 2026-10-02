import Testing
import Foundation
import Crypto
@testable import WellSpentSync
import WellSpentCrypto

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Unit tests for the HTTP client, with no server.
///
/// The end-to-end tests in the server package prove the two sides agree. These
/// prove the client behaves when the server does something unusual: an error
/// body, an unexpected shape, a rejection list. Those paths are awkward to
/// provoke against a real server and are exactly where a client goes wrong.
private final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    /// Set before each test. Receives the request, returns a status and a body.
    nonisolated(unsafe) static var handler: (@Sendable (URLRequest) throws -> (Int, Data))?
    /// Every request that went through, so tests can assert on paths and headers.
    nonisolated(unsafe) static var recorded: [URLRequest] = []
    private static let lock = NSLock()

    static func reset() {
        lock.withLock {
            handler = nil
            recorded = []
        }
    }

    static func record(_ request: URLRequest) {
        lock.withLock { recorded.append(request) }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.record(request)
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        do {
            let (status, body) = try handler(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: status,
                                           httpVersion: "HTTP/1.1",
                                           headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: body)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

private func stubbedSession() -> URLSession {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [StubURLProtocol.self]
    return URLSession(configuration: configuration)
}

private func makeTransport(credentials: HTTPTransport.Credentials? = nil) -> HTTPTransport {
    HTTPTransport(baseURL: URL(string: "https://example.test")!,
                  session: stubbedSession(), credentials: credentials)
}

private let anyCredentials = HTTPTransport.Credentials(
    userID: UserID(), token: "a-token", expiresOn: Date().addingTimeInterval(3600))

private func json(_ value: some Encodable) -> Data {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    return try! encoder.encode(value)
}

@Suite("HTTP transport", .serialized)
struct HTTPTransportTests {

    @Test func signUpPostsToTheRightPlaceAndKeepsTheToken() async throws {
        StubURLProtocol.reset()
        struct Auth: Encodable { let userID: UUID; let token: String; let expiresOn: Date }
        let userID = UUID()
        StubURLProtocol.handler = { _ in
            (200, json(Auth(userID: userID, token: "tok", expiresOn: Date().addingTimeInterval(60))))
        }

        let transport = makeTransport()
        let identity = IdentityKeyPair.generate()
        let credentials = try await transport.signUp(email: "a@b.com", password: "pw",
                                                     identity: identity.publicKeys)

        #expect(credentials.userID.uuid == userID)
        #expect(credentials.token == "tok")
        // Kept, so the next call is authenticated without being told again.
        #expect(await transport.currentCredentials?.token == "tok")

        let request = try #require(StubURLProtocol.recorded.first)
        #expect(request.url?.path == "/api/v1/signup")
        #expect(request.httpMethod == "POST")
    }

    /// The base URL may or may not already carry the api prefix.
    @Test func baseURLIsNormalised() async throws {
        StubURLProtocol.reset()
        StubURLProtocol.handler = { _ in (200, Data("[]".utf8)) }

        let withPrefix = HTTPTransport(baseURL: URL(string: "https://example.test/api/v1")!,
                                       session: stubbedSession(), credentials: anyCredentials)
        _ = try await withPrefix.membershipLog(group: GroupID(), since: 0)
        #expect(StubURLProtocol.recorded.first?.url?.path.hasPrefix("/api/v1/groups") == true)
        #expect(StubURLProtocol.recorded.first?.url?.path.contains("v1/api") == false)
    }

    @Test func authenticatedCallsSendABearerToken() async throws {
        StubURLProtocol.reset()
        StubURLProtocol.handler = { _ in (200, Data("[]".utf8)) }

        let transport = makeTransport(credentials: anyCredentials)
        _ = try await transport.membershipLog(group: GroupID(), since: 0)

        let request = try #require(StubURLProtocol.recorded.first)
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer a-token")
    }

    @Test func callingAnAuthenticatedRouteWithNoTokenFailsBeforeTheNetwork() async throws {
        StubURLProtocol.reset()
        StubURLProtocol.handler = { _ in (200, Data("[]".utf8)) }

        let transport = makeTransport()      // no credentials
        await #expect(throws: HTTPTransport.Failure.self) {
            _ = try await transport.pull(group: GroupID(), since: 0, limit: 10)
        }
        #expect(StubURLProtocol.recorded.isEmpty, "it should not have hit the network at all")
    }

    @Test func pushMapsAcceptedAndRejected() async throws {
        StubURLProtocol.reset()
        let accepted = RecordID(), rejected = RecordID()
        struct Reply: Encodable {
            let accepted: [UUID]
            let rejected: [String: String]
            let serverSeq: Int
        }
        StubURLProtocol.handler = { _ in
            (200, json(Reply(accepted: [accepted.uuid],
                             rejected: [rejected.uuid.uuidString: "author holds read, needs write"],
                             serverSeq: 42)))
        }

        let transport = makeTransport(credentials: anyCredentials)
        let result = try await transport.push([], group: GroupID())

        #expect(result.accepted == [accepted])
        #expect(result.rejected[rejected] == "author holds read, needs write")
        #expect(result.serverSeq == 42)
    }

    @Test func pullPassesItsCursorAndLimit() async throws {
        StubURLProtocol.reset()
        struct Reply: Encodable { let envelopes: [Int]; let serverSeq: Int; let hasMore: Bool }
        StubURLProtocol.handler = { _ in
            (200, Data(#"{"envelopes":[],"serverSeq":7,"hasMore":true}"#.utf8))
        }

        let transport = makeTransport(credentials: anyCredentials)
        let page = try await transport.pull(group: GroupID(), since: 3, limit: 50)

        #expect(page.serverSeq == 7)
        #expect(page.hasMore)
        let query = try #require(StubURLProtocol.recorded.first?.url?.query)
        #expect(query.contains("since=3"))
        #expect(query.contains("limit=50"))
    }

    /// A negative sequence would underflow UInt64. The server should never send
    /// one, which is exactly why the client should not assume it.
    @Test func aNegativeServerSequenceIsClampedRatherThanCrashing() async throws {
        StubURLProtocol.reset()
        StubURLProtocol.handler = { _ in
            (200, Data(#"{"envelopes":[],"serverSeq":-1,"hasMore":false}"#.utf8))
        }

        let transport = makeTransport(credentials: anyCredentials)
        let page = try await transport.pull(group: GroupID(), since: 0, limit: 10)
        #expect(page.serverSeq == 0)
    }

    @Test func anErrorBodySurfacesItsReason() async throws {
        StubURLProtocol.reset()
        StubURLProtocol.handler = { _ in
            (403, Data(#"{"error":true,"reason":"you are not a member of that group"}"#.utf8))
        }

        let transport = makeTransport(credentials: anyCredentials)
        do {
            _ = try await transport.pull(group: GroupID(), since: 0, limit: 10)
            Issue.record("should have thrown")
        } catch let failure as HTTPTransport.Failure {
            guard case .http(let status, let reason) = failure else {
                Issue.record("wrong case: \(failure)")
                return
            }
            #expect(status == 403)
            #expect(reason.contains("not a member"))
        }
    }

    @Test func anUnparseableBodySaysWhatItGotRatherThanThrowingBlind() async throws {
        StubURLProtocol.reset()
        StubURLProtocol.handler = { _ in (200, Data("this is not json".utf8)) }

        let transport = makeTransport(credentials: anyCredentials)
        do {
            _ = try await transport.pull(group: GroupID(), since: 0, limit: 10)
            Issue.record("should have thrown")
        } catch let failure as HTTPTransport.Failure {
            guard case .malformedResponse(let detail) = failure else {
                Issue.record("wrong case: \(failure)")
                return
            }
            #expect(detail.contains("not json"), "the message should quote what arrived")
        }
    }

    /// Dates are pinned to ISO 8601 on both sides because a signed membership
    /// entry carries one. This checks the client half of that agreement.
    @Test func datesAreSentAndReadAsISO8601() async throws {
        StubURLProtocol.reset()
        StubURLProtocol.handler = { _ in (201, Data()) }

        let person = IdentityKeyPair.generate()
        let device = DeviceKeyPair()
        let userID = UserID()
        let group = GroupID()
        let entry = try MembershipLogEntry.signed(
            scope: .group(group), sequence: 0, previousHash: MembershipLogEntry.rootHash,
            action: .found, subjectUserID: userID, subjectKeys: person.publicKeys,
            level: .superadmin, epochAfter: .initial,
            deviceID: device.id, devicePublicKey: device.publicKey,
            author: person, authorUserID: userID)

        let transport = makeTransport(credentials: anyCredentials)
        try await transport.appendMembership(entry, group: group)

        let body = try #require(StubURLProtocol.recorded.first?.httpBodyData)
        let text = String(decoding: body, as: UTF8.self)
        #expect(text.contains("T"), "an ISO 8601 date, not a number")
        #expect(text.contains("Z") || text.contains("+"))

        // And it survives a round trip through the same coders.
        struct Body: Decodable { let entry: MembershipLogEntry }
        let decoded = try HTTPTransport.decoder.decode(Body.self, from: body)
        #expect(decoded.entry.at == entry.at)
        #expect(decoded.entry.verifySignature(by: person.publicKeys),
                "the signature must still verify after the wire")
    }

    @Test func signInAdoptsTheNewToken() async throws {
        StubURLProtocol.reset()
        struct Auth: Encodable { let userID: UUID; let token: String; let expiresOn: Date }
        StubURLProtocol.handler = { _ in
            (200, json(Auth(userID: UUID(), token: "second", expiresOn: Date())))
        }

        let transport = makeTransport(credentials: anyCredentials)
        _ = try await transport.signIn(email: "a@b.com", password: "pw")
        #expect(await transport.currentCredentials?.token == "second")
    }

    @Test func credentialsCanBeClearedForSignOut() async throws {
        let transport = makeTransport(credentials: anyCredentials)
        #expect(await transport.currentCredentials != nil)
        await transport.use(nil)
        #expect(await transport.currentCredentials == nil)
    }

    @Test func wrappedKeysDecodeFromTheServerShape() async throws {
        StubURLProtocol.reset()
        let robin = IdentityKeyPair.generate()
        let leslie = IdentityKeyPair.generate()
        let key = ScopedKey.generate(scope: .group(GroupID()))
        let wrapped = try KeyWrap.wrapToIdentity(key, recipient: leslie.publicKeys,
                                                 recipientUserID: UserID(),
                                                 sender: robin, senderUserID: UserID())
        StubURLProtocol.handler = { _ in (200, json([wrapped])) }

        let transport = makeTransport(credentials: anyCredentials)
        let keys = try await transport.wrappedKeys(group: GroupID(), for: UserID())

        #expect(keys.count == 1)
        let reopened = try KeyWrap.unwrapToIdentity(keys[0], recipient: leslie,
                                                    sender: robin.publicKeys)
        #expect(reopened.rawBytes == key.rawBytes)
    }
}

private extension URLRequest {
    /// URLProtocol hands the body over as a stream when it is set via httpBody,
    /// so read whichever one is populated.
    var httpBodyData: Data? {
        if let httpBody { return httpBody }
        guard let stream = httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        let size = 4096
        var buffer = [UInt8](repeating: 0, count: size)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: size)
            if read <= 0 { break }
            data.append(buffer, count: read)
        }
        return data
    }
}
