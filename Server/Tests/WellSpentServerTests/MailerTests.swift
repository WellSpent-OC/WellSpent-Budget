import Testing
import Foundation
import NIOConcurrencyHelpers
import NIOCore
import Vapor
@testable import WellSpentServerCore

/// Stands in for Resend's web service: keeps each request, and answers every
/// one with the status it was made with.
private final class RecordingClient: Client, @unchecked Sendable {
    let eventLoop: any EventLoop
    let status: HTTPStatus
    private let lock = NIOLock()
    private var sent: [ClientRequest] = []

    init(eventLoop: any EventLoop, status: HTTPStatus) {
        self.eventLoop = eventLoop
        self.status = status
    }

    func delegating(to eventLoop: any EventLoop) -> any Client { self }

    func send(_ request: ClientRequest) -> EventLoopFuture<ClientResponse> {
        lock.withLock { sent.append(request) }
        // A reply that names the address, as a real one can.
        let body = ByteBuffer(string: #"{"message":"refused for robin@example.com"}"#)
        return eventLoop.makeSucceededFuture(ClientResponse(status: status, body: body))
    }

    var requests: [ClientRequest] { lock.withLock { sent } }
}

private struct SentEmail: Decodable {
    let from: String
    let to: [String]
    let subject: String
    let text: String
}

/// Live's email: the codes that confirm an address and reset a password reach
/// people only through `ResendMailer`, which had no test.
@Suite("Server, live's email through Resend", .serialized)
struct MailerTests {
    @Test func anEmailGoesToResendAsOneMessageWithTheKey() async throws {
        try await withClient(status: .ok) { client in
            let mailer = ResendMailer(apiKey: "re_test_key", from: MailerChoice.defaultFrom, client: client)
            try await mailer.send(to: "robin@example.com", subject: "Your WellSpent code: ABCD-1234",
                                  text: "Your WellSpent code is ABCD-1234.")

            let request = try #require(client.requests.first)
            #expect(client.requests.count == 1)
            #expect(request.method == .POST)
            #expect(request.url.string == "https://api.resend.com/emails")
            #expect(request.headers.bearerAuthorization?.token == "re_test_key")
            let email = try request.content.decode(SentEmail.self)
            #expect(email.from == MailerChoice.defaultFrom)
            #expect(email.to == ["robin@example.com"])
            #expect(email.subject == "Your WellSpent code: ABCD-1234")
            #expect(email.text == "Your WellSpent code is ABCD-1234.")
        }
    }

    /// A send Resend refuses throws, so the caller logs a failure, and says
    /// nothing of the address: neither ours nor the reply's copy of it.
    @Test func aRefusedSendThrowsWithoutTheAddress() async throws {
        for status: HTTPStatus in [.unprocessableEntity, .tooManyRequests, .internalServerError] {
            try await withClient(status: status) { client in
                let mailer = ResendMailer(apiKey: "re_test_key", from: MailerChoice.defaultFrom, client: client)
                do {
                    try await mailer.send(to: "robin@example.com", subject: "s", text: "t")
                    Issue.record("a \(status.code) answer did not throw")
                } catch let error as Abort {
                    #expect(error.status == .badGateway)
                    #expect(error.reason.contains("\(status.code)"))
                    #expect(!error.reason.contains("robin"), "\(error.reason)")
                }
            }
        }
    }

    /// With a key, any server sends through Resend, the way live must.
    @Test func aServerWithAKeySendsThroughResend() async throws {
        setenv("RESEND_API_KEY", "re_test_key", 1)
        defer { unsetenv("RESEND_API_KEY") }
        let app = try await Application.make(.testing)
        do {
            try app.configureMailer()
            #expect(app.mailer is ResendMailer)
        } catch {
            try? await app.asyncShutdown()
            throw error
        }
        try await app.asyncShutdown()
    }

    private func withClient(status: HTTPStatus, _ body: (RecordingClient) async throws -> Void) async throws {
        let app = try await Application.make(.testing)
        do {
            try await body(RecordingClient(eventLoop: app.eventLoopGroup.any(), status: status))
        } catch {
            try? await app.asyncShutdown()
            throw error
        }
        try await app.asyncShutdown()
    }
}
