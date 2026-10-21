import Foundation
import Crypto
import Vapor

/// Staging only: the last message sent to each test address, for UI tests
/// that make an account and type the code it emails.
///
/// Staging writes its email to the log, and a test running on another machine
/// cannot read the log. So staging also keeps the newest message to each
/// address at `example.com`, a domain set aside for examples that no person can
/// own, and gives it back to a request that carries the test mailbox token.
/// Any other address is never kept. A message is kept for 15 minutes, longer
/// than any code lasts, and only in memory, so a restart empties it.
///
/// Live never has one: `enableTestMailbox` refuses to run there, and without
/// it the route does not exist.
actor TestMailbox {
    struct Message: Content, Equatable {
        let subject: String
        let text: String
        let sentAt: Date
        /// The XXXX-XXXX code in the text, when there is one.
        let code: String?
    }

    static let domain = "@example.com"
    static let keepFor: TimeInterval = 15 * 60
    /// A bound on memory: the oldest goes first past this many addresses.
    static let mostAddresses = 1000

    private var newest: [String: Message] = [:]

    static func isTestAddress(_ address: String) -> Bool {
        let address = address.lowercased()
        return address.hasSuffix(domain) && address.count > domain.count && !address.contains(" ")
    }

    func keep(to address: String, subject: String, text: String, at now: Date = Date()) {
        guard Self.isTestAddress(address) else { return }
        newest = newest.filter { now.timeIntervalSince($0.value.sentAt) < Self.keepFor }
        newest[address.lowercased()] = Message(subject: subject, text: text, sentAt: now, code: Self.code(in: text))
        if newest.count > Self.mostAddresses,
           let oldest = newest.min(by: { $0.value.sentAt < $1.value.sentAt }) {
            newest[oldest.key] = nil
        }
    }

    func latest(to address: String, at now: Date = Date()) -> Message? {
        guard Self.isTestAddress(address), let message = newest[address.lowercased()],
              now.timeIntervalSince(message.sentAt) < Self.keepFor else { return nil }
        return message
    }

    static func code(in text: String) -> String? {
        guard let match = text.firstMatch(of: /[A-Z0-9]{4}-[A-Z0-9]{4}/) else { return nil }
        return String(match.output)
    }
}

/// Keeps a copy of each message to a test address, then sends it as before.
struct KeepingMailer: Mailer {
    let mailbox: TestMailbox
    let next: any Mailer

    func send(to address: String, subject: String, text: String) async throws {
        await mailbox.keep(to: address, subject: subject, text: text)
        try await next.send(to: address, subject: subject, text: text)
    }
}

/// Whether this server has a test mailbox, decided once at start from
/// `TEST_MAILBOX_TOKEN`.
enum TestMailboxChoice {
    /// Long enough that it cannot be guessed. `openssl rand -hex 32` makes one.
    static let shortestToken = 32

    /// The token, or nil for no mailbox. Live never has one, whatever is set.
    /// Elsewhere a token that is set but short stops the server, rather than
    /// run a guessable door.
    static func token(server: ServerEnvironment, variable: String?) throws -> String? {
        guard server != .live, let variable else { return nil }
        let token = variable.trimmingCharacters(in: .whitespacesAndNewlines)
        // Compose passes an unset variable as empty, so empty means unset.
        guard !token.isEmpty else { return nil }
        guard token.count >= shortestToken else {
            throw Abort(.internalServerError, reason: """
                TEST_MAILBOX_TOKEN must be at least \(shortestToken) characters. \
                openssl rand -hex 32 makes one.
                """)
        }
        return token
    }
}

extension Application {
    /// Gives this server the test mailbox: every message from here on to a
    /// test address is kept, and `GET /test/mailbox?address=` gives back the
    /// newest one to a request bearing `token`. Throws on live, where it must
    /// never exist. Call it after the mailer is set.
    func enableTestMailbox(token: String) throws {
        let server = storage[ServerEnvironmentKey.self] ?? .live
        guard server != .live else {
            throw Abort(.internalServerError, reason: "a live server never has a test mailbox")
        }
        let mailbox = TestMailbox()
        mailer = KeepingMailer(mailbox: mailbox, next: mailer)
        storage[TestMailboxOnKey.self] = true
        // The token is compared by its hash, so the time a wrong guess takes
        // says nothing about how much of it was right.
        let expected = SHA256.hash(data: Data(token.utf8))
        get("test", "mailbox") { request async throws -> TestMailbox.Message in
            guard let given = request.headers.bearerAuthorization?.token,
                  SHA256.hash(data: Data(given.utf8)) == expected else {
                throw Abort(.unauthorized)
            }
            guard let address = request.query[String.self, at: "address"],
                  let message = await mailbox.latest(to: address) else {
                throw Abort(.notFound)
            }
            return message
        }
        logger.notice("test mailbox: on, for \(TestMailbox.domain) addresses only")
    }

    /// Whether `enableTestMailbox` ran. Never on live.
    var hasTestMailbox: Bool { storage[TestMailboxOnKey.self] ?? false }
}

private struct TestMailboxOnKey: StorageKey {
    typealias Value = Bool
}

extension RateLimiter.Limit {
    /// A test address's allowance on a server with the test mailbox: sixty
    /// times as many tries in the same window, 300 sign-ups an hour. UI tests
    /// make a fresh account for each scenario, and every run on one machine
    /// shares its address: twelve times ran out with two engineers' suites
    /// running at once on one box.
    var forTests: RateLimiter.Limit { .init(attempts: attempts * 60, window: window) }
}

extension Request {
    /// The caller's limit, as `enforceRateLimit(_:scope:)`. On a server with
    /// the test mailbox, a request for a test address draws on a separate,
    /// larger allowance instead, so UI tests neither run out nor use up what
    /// anyone else has. Every other address, and every request to live, gets
    /// the usual limit.
    func enforceRateLimit(_ limit: RateLimiter.Limit, scope: String, email: String) async throws {
        if application.hasTestMailbox, TestMailbox.isTestAddress(email) {
            try await enforceRateLimit(limit.forTests, scope: "test-\(scope)")
        } else {
            try await enforceRateLimit(limit, scope: scope)
        }
    }
}
