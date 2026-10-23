import Testing
import Foundation
// Fluent, because these tests read rows back directly to check what the server
// actually stored. Without it the query builder's API is not in scope, and the
// failure reads as "cannot infer key path type from context".
import Fluent
import Vapor
import VaporTesting
import Crypto
@testable import WellSpentServerCore
import WellSpentCrypto

private func withConfiguredApp(_ body: (Application) async throws -> Void) async throws {
    let app = try await Application.make(.testing)
    do {
        try await configure(app)
        // Boot explicitly. Without this the first request through the in-memory
        // responder can arrive before the router is built, which shows up as a
        // 404 on a route that is plainly registered.
        try await app.asyncBoot()
        try await body(app)
    } catch {
        try? await app.asyncShutdown()
        throw error
    }
    try await app.asyncShutdown()
}

@Suite("Server, health")
struct HealthTests {
    /// A health check that answers 200 with no database tells a restart policy
    /// and every uptime monitor that all is well.
    @Test func healthFailsWhenTheDatabaseIsUnreachable() async throws {
        let app = try await Application.make(.testing)
        do {
            // A path that cannot be opened, so every query fails at connect time.
            // Built by hand rather than through configure(), which reads
            // DATABASE_URL from the environment and would point at Postgres in CI.
            app.databases.use(.sqlite(.file("/nonexistent-directory/nope.sqlite"),
                                      connectionPoolTimeout: .seconds(2)), as: .sqlite)
            app.databases.default(to: .sqlite)
            try registerRoutes(app)
            try await app.asyncBoot()

            try await app.testing().test(.GET, "health") { response async throws in
                #expect(response.status == .serviceUnavailable)
            }
        } catch {
            try? await app.asyncShutdown()
            throw error
        }
        try await app.asyncShutdown()
    }
    @Test func healthCheck() async throws {
        try await withConfiguredApp { app in
            try await app.testing().test(.GET, "health") { response async throws in
                #expect(response.status == .ok)
                let body = try response.content.decode([String: String].self)
                #expect(body["status"] == "ok")
                #expect(body["environment"] == "development",
                        "a test server is neither live nor staging")
            }
        }
    }

    /// The app checks this before sign-in, so a staging build cannot sign in to the
    /// live server, and the reverse. The live server must keep answering "live"
    /// with no new setting, and a misspelt name must stop a server, not start one
    /// that calls itself something it is not.
    @Test func theServerSaysWhichEnvironmentItIs() throws {
        #expect(try ServerEnvironment.resolve(nil, appEnvironment: .production) == .live)
        #expect(try ServerEnvironment.resolve("", appEnvironment: .production) == .live)
        #expect(try ServerEnvironment.resolve(nil, appEnvironment: .development) == .development)
        #expect(try ServerEnvironment.resolve(nil, appEnvironment: .testing) == .development)
        #expect(try ServerEnvironment.resolve("staging", appEnvironment: .production) == .staging)
        #expect(try ServerEnvironment.resolve("live", appEnvironment: .development) == .live)
        #expect(throws: (any Error).self) {
            try ServerEnvironment.resolve("Staging", appEnvironment: .production)
        }
        #expect(throws: (any Error).self) {
            try ServerEnvironment.resolve("prod", appEnvironment: .production)
        }
    }
}

@Suite("Server, abuse protection", .serialized)
struct AbuseProtectionTests {

    /// "Runs once at boot and then hourly" was half true: there was no
    /// scheduler, so a long-lived process purged once and never again, and the
    /// rate limiter's dictionary grew for the life of the process.
    ///
    /// Built by hand rather than with withConfiguredApp, because the handler
    /// needs an interval a test can wait for.
    @Test func housekeepingRunsAfterBoot() async throws {
        let app = try await Application.make(.testing)
        do {
            try await configure(app)
            app.lifecycle.use(Housekeeping(every: .milliseconds(50), sweepWindow: 0))
            try await app.asyncBoot()

            let user = UserRow(id: UUID(), email: "housekeeping@example.com",
                               passwordHash: "x", identitySigning: Data([1]),
                               identityKEM: Data([2]))
            try await user.save(on: app.db)
            let userID = try user.requireID()
            // Already expired, and inserted after configure() purged at boot, so
            // only a scheduled tick can remove it.
            try await TokenRow(userID: userID, valueHash: "expired-digest",
                               expiresOn: Date().addingTimeInterval(-60)).save(on: app.db)
            _ = await app.rateLimiter.allow("housekeeping-key", limit: .signIn)

            // One tick purges the tokens, then sweeps the limiter, so both are
            // waited for: reading the limiter as soon as the tokens were gone
            // sometimes landed between the two.
            var tokens = 1
            var remaining = 1
            for _ in 0 ..< 40 {
                try await Task.sleep(for: .milliseconds(50))
                tokens = try await TokenRow.query(on: app.db)
                    .filter(\.$userID == userID).count()
                remaining = await app.rateLimiter.count(for: "housekeeping-key")
                if tokens == 0, remaining == 0 { break }
            }
            #expect(tokens == 0, "the scheduled token purge never ran")
            #expect(remaining == 0, "the limiter's dictionary is never swept, so it grows forever")
        } catch {
            try? await app.asyncShutdown()
            throw error
        }
        // A shutdown that returns proves the timer task was cancelled rather
        // than left running.
        try await app.asyncShutdown()
    }

    /// Reading the first X-Forwarded-For hop made the limiter forgeable: both
    /// Cloudflare and fly-proxy append the address they saw, so the first entry
    /// is whatever the client typed and the last is the truth.
    @Test func theCallerAddressIsTheProxysViewNotTheClientsClaim() async throws {
        setenv("TRUSTED_PROXY", "1", 1)
        defer { unsetenv("TRUSTED_PROXY") }

        try await withConfiguredApp { app in
            func address(_ headers: HTTPHeaders) -> String {
                Request(application: app, method: .POST, url: URI(string: "/"),
                        headers: headers, on: app.eventLoopGroup.next()).callerAddress
            }

            var forged = HTTPHeaders()
            forged.add(name: .xForwardedFor, value: "203.0.113.9, 198.51.100.7")
            #expect(address(forged) == "198.51.100.7", "the last hop, not the first")

            var connecting = HTTPHeaders()
            connecting.add(name: .xForwardedFor, value: "203.0.113.9, 198.51.100.7")
            connecting.add(name: "CF-Connecting-IP", value: "198.51.100.42")
            #expect(address(connecting) == "198.51.100.42",
                    "a header the client cannot set wins over one it can")
        }
    }

    /// The same thing end to end: rotating the part of the header a caller
    /// controls must not hand them a fresh allowance.
    @Test func aForgedForwardedHeaderDoesNotBuyMoreAttempts() async throws {
        setenv("TRUSTED_PROXY", "1", 1)
        defer { unsetenv("TRUSTED_PROXY") }

        try await withConfiguredApp { app in
            struct SignInBody: Content { let email: String; let password: String }
            var statuses: [HTTPResponseStatus] = []

            for attempt in 0 ..< (RateLimiter.Limit.signIn.attempts + 1) {
                var headers = HTTPHeaders()
                // A different claimed origin every time, same real one.
                headers.add(name: .xForwardedFor, value: "203.0.113.\(attempt), 198.51.100.7")
                try await app.testing().test(.POST, "api/v2/signin", headers: headers,
                                             beforeRequest: { request in
                    try request.content.encode(SignInBody(email: "nobody@example.com",
                                                          password: "a-long-enough-password"))
                }, afterResponse: { response async throws in
                    statuses.append(response.status)
                })
            }

            #expect(statuses.last == .tooManyRequests, "got \(statuses)")
        }
    }

    /// Sign-in had nothing in front of it, so a password could be guessed as fast
    /// as the network allowed, and each guess costs the server a bcrypt.
    @Test func repeatedSignInAttemptsAreThrottled() async throws {
        try await withConfiguredApp { app in
            _ = try await v2SignUp("throttled@example.com", on: app)

            struct SignIn: Content { let email: String; let password: String }
            var statuses: [HTTPResponseStatus] = []

            for _ in 0 ..< (RateLimiter.Limit.signIn.attempts + 3) {
                try await app.testing().test(.POST, "api/v2/signin", beforeRequest: { request in
                    try request.content.encode(SignIn(email: "throttled@example.com",
                                                      password: "wrong-password"))
                }, afterResponse: { response async throws in
                    statuses.append(response.status)
                })
            }

            #expect(statuses.contains(.tooManyRequests), "it should start refusing, got \(statuses)")
            #expect(statuses.last == .tooManyRequests)
        }
    }

    @Test func theLimiterExpiresOldAttempts() async throws {
        // A clock we control, so this does not depend on wall time.
        nonisolated(unsafe) var now = Date(timeIntervalSince1970: 1_000_000)
        let limiter = RateLimiter(clock: { now })
        let limit = RateLimiter.Limit(attempts: 2, window: 60)

        #expect(await limiter.allow("k", limit: limit))
        #expect(await limiter.allow("k", limit: limit))
        #expect(!(await limiter.allow("k", limit: limit)), "third attempt inside the window")

        now = now.addingTimeInterval(61)
        #expect(await limiter.allow("k", limit: limit), "the window has rolled")
    }

    @Test func theLimiterSweepsKeysItNoLongerNeeds() async throws {
        nonisolated(unsafe) var now = Date(timeIntervalSince1970: 1_000_000)
        let limiter = RateLimiter(clock: { now })
        _ = await limiter.allow("k", limit: .signIn)
        #expect(await limiter.count(for: "k") == 1)

        now = now.addingTimeInterval(7200)
        await limiter.sweep()
        #expect(await limiter.count(for: "k") == 0)
    }

    @Test func differentCallersHaveSeparateAllowances() async throws {
        let limiter = RateLimiter()
        let limit = RateLimiter.Limit(attempts: 1, window: 600)

        #expect(await limiter.allow("signin:1.1.1.1", limit: limit))
        #expect(!(await limiter.allow("signin:1.1.1.1", limit: limit)))
        #expect(await limiter.allow("signin:2.2.2.2", limit: limit),
                "one caller being throttled must not lock out everyone else")
    }
}
