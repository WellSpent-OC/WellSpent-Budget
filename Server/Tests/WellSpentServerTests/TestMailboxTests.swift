import Testing
import Foundation
import Vapor
import VaporTesting
@testable import WellSpentServerCore

/// Staging's test mailbox: UI tests on other machines read the code staging
/// emails to a test address, and nobody reads anyone else's.
@Suite("Server, the test mailbox", .serialized)
struct TestMailboxTests {
    static let token = String(repeating: "t", count: TestMailboxChoice.shortestToken)

    /// Live never has a mailbox, whatever is set. Elsewhere a short token
    /// stops the server, and none means no mailbox.
    @Test func liveNeverHasAMailboxAndAShortTokenStopsTheServer() throws {
        #expect(try TestMailboxChoice.token(server: .live, variable: Self.token) == nil)
        #expect(try TestMailboxChoice.token(server: try ServerEnvironment.resolve(nil, appEnvironment: .production),
                                            variable: Self.token) == nil, "no marker counts as live")
        #expect(try TestMailboxChoice.token(server: .staging, variable: Self.token) == Self.token)
        #expect(try TestMailboxChoice.token(server: .staging, variable: nil) == nil)
        #expect(try TestMailboxChoice.token(server: .staging, variable: "") == nil, "compose passes unset as empty")
        #expect(throws: (any Error).self) { try TestMailboxChoice.token(server: .staging, variable: "short") }
    }

    /// Even called by hand, the mailbox refuses a live server, and the route
    /// stays missing.
    @Test func aLiveServerRefusesTheMailbox() async throws {
        let app = try await Application.make(.testing)
        do {
            try await configure(app)
            app.storage[ServerEnvironmentKey.self] = .live
            #expect(throws: (any Error).self) { try app.enableTestMailbox(token: Self.token) }
            try await app.asyncBoot()
            #expect(try await mailboxStatus(address: "uitest@example.com", token: Self.token, on: app) == .notFound)
        } catch {
            try? await app.asyncShutdown()
            throw error
        }
        try await app.asyncShutdown()
    }

    /// The code a sign-up emails comes back to the token, and confirms the
    /// address as typing it would.
    @Test func theCodeASignUpEmailsComesBackAndConfirmsTheAddress() async throws {
        try await withMailbox { app, mailer in
            let email = "uitest-signup-1@example.com"
            let session = try await v2SignUp(email, on: app)
            let sent = try v2Code(in: await mailer.waitFor(1, to: email).first)

            let kept = try #require(try await mailboxMessage(address: email, token: Self.token, on: app))
            #expect(kept.code == sent)
            #expect(kept.text.contains(sent))
            #expect(try await mailboxMessage(address: email.uppercased(), token: Self.token, on: app)?.code == sent,
                    "an address in any case")
            #expect(try await v2Status(.POST, "api/v2/email/verify", token: session.token,
                                     body: V2CodeBody(code: try #require(kept.code)), on: app) == .noContent)
        }
    }

    /// A second code replaces the first, as a test that asks again needs.
    /// The server holds a resend back for a while, so this is the mailbox's own.
    @Test func theNewestMessageIsTheOneKept() async throws {
        let mailbox = TestMailbox()
        let sent = Date()
        await mailbox.keep(to: "uitest-again@example.com", subject: "Your code", text: "AAAA-1111", at: sent)
        await mailbox.keep(to: "uitest-again@example.com", subject: "Your code", text: "BBBB-2222",
                           at: sent.addingTimeInterval(60))
        #expect(await mailbox.latest(to: "uitest-again@example.com", at: sent.addingTimeInterval(61))?.code
                == "BBBB-2222")
    }

    /// No token, or the wrong one, gets nothing, not even whether a message
    /// is there.
    @Test func withoutTheTokenNothingComesBack() async throws {
        try await withMailbox { app, mailer in
            let email = "uitest-token@example.com"
            _ = try await v2SignUp(email, on: app)
            _ = await mailer.waitFor(1, to: email)
            #expect(try await mailboxStatus(address: email, token: nil, on: app) == .unauthorized)
            #expect(try await mailboxStatus(address: email, token: String(repeating: "x", count: 64), on: app)
                    == .unauthorized)
            #expect(try await mailboxStatus(address: email, token: Self.token, on: app) == .ok)
        }
    }

    /// A real person's address is never kept, so it can never be read.
    @Test func anAddressOutsideExampleDotComIsNeverKept() async throws {
        try await withMailbox { app, mailer in
            let email = "someone@wellspent.space"
            _ = try await v2SignUp(email, on: app)
            #expect(await mailer.waitFor(1, to: email).count == 1, "it is still sent")
            #expect(try await mailboxStatus(address: email, token: Self.token, on: app) == .notFound)
        }
        let mailbox = TestMailbox()
        for address in ["a@example.com.evil.net", "@example.com", "a@notexample.com", "a b@example.com"] {
            await mailbox.keep(to: address, subject: "s", text: "ABCD-1234")
            #expect(await mailbox.latest(to: address) == nil, "\(address)")
        }
    }

    /// A message goes after 15 minutes, longer than a code lasts.
    @Test func aMessageGoesAfterFifteenMinutes() async throws {
        let mailbox = TestMailbox()
        let sent = Date()
        await mailbox.keep(to: "uitest-old@example.com", subject: "Your code", text: "ABCD-1234", at: sent)
        #expect(await mailbox.latest(to: "uitest-old@example.com", at: sent.addingTimeInterval(14 * 60))?.code
                == "ABCD-1234")
        #expect(await mailbox.latest(to: "uitest-old@example.com",
                                     at: sent.addingTimeInterval(TestMailbox.keepFor)) == nil)
    }

    /// With the mailbox, test addresses sign up from one machine past the
    /// usual five an hour, on an allowance of their own, and any other address
    /// still stops at five.
    @Test func testAddressesGetTheTestsAllowanceAndOthersKeepTheUsualOne() async throws {
        try await withMailbox { app, _ async throws in
            let usual = RateLimiter.Limit.signUp.attempts
            for index in 0 ..< usual + 3 {
                #expect(try await signUpStatus("uitest-many-\(index)@example.com", on: app) == .ok)
            }
            for index in 0 ..< usual {
                #expect(try await signUpStatus("person-\(index)@wellspent.space", on: app) == .ok)
            }
            #expect(try await signUpStatus("person-\(usual)@wellspent.space", on: app) == .tooManyRequests)
        }
    }

    /// Without the mailbox, as on live, a test address gets the usual limit.
    @Test func withoutTheMailboxATestAddressGetsTheUsualLimit() async throws {
        try await withV2App { app, _ async throws in
            let usual = RateLimiter.Limit.signUp.attempts
            for index in 0 ..< usual {
                #expect(try await signUpStatus("uitest-few-\(index)@example.com", on: app) == .ok)
            }
            #expect(try await signUpStatus("uitest-few-\(usual)@example.com", on: app) == .tooManyRequests)
        }
    }

    /// Without a token the server has no such route at all.
    @Test func withNoTokenThereIsNoRoute() async throws {
        try await withV2App { app, _ async throws in
            #expect(try await mailboxStatus(address: "uitest@example.com", token: Self.token, on: app) == .notFound)
        }
    }

    // MARK: - Helpers

    private func withMailbox(_ body: (Application, V2RecordingMailer) async throws -> Void) async throws {
        let app = try await Application.make(.testing)
        let mailer = V2RecordingMailer()
        do {
            try await configure(app)
            app.mailer = mailer
            try app.enableTestMailbox(token: Self.token)
            try await app.asyncBoot()
            try await body(app, mailer)
        } catch {
            try? await app.asyncShutdown()
            throw error
        }
        try await app.asyncShutdown()
    }

    private func signUpStatus(_ email: String, on app: Application) async throws -> HTTPStatus {
        try await v2Status(.POST, "api/v2/signup",
                           body: V2SignUp(email: email, password: v2Password, deviceLabel: "Mac"), on: app)
    }

    private func path(_ address: String) -> String {
        "test/mailbox?address=\(address.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? address)"
    }

    private func mailboxStatus(address: String, token: String?, on app: Application) async throws -> HTTPStatus {
        var status = HTTPStatus.internalServerError
        try await app.testing().test(.GET, path(address), headers: token.map(v2Bearer) ?? [:],
                                     afterResponse: { response async throws in status = response.status })
        return status
    }

    private func mailboxMessage(address: String, token: String,
                                on app: Application) async throws -> TestMailbox.Message? {
        var message: TestMailbox.Message?
        try await app.testing().test(.GET, path(address), headers: v2Bearer(token),
                                     afterResponse: { response async throws in
            if response.status == .ok { message = try response.content.decode(TestMailbox.Message.self) }
        })
        return message
    }
}
