import Testing
import Foundation
import Crypto
import Fluent
import Vapor
import VaporTesting
@testable import WellSpentServerCore

@Suite("Server, accounts for readable sync", .serialized)
struct AccountsV2Tests {
    @Test func signUpGivesASessionAndEmailsACodeThatConfirmsTheAddress() async throws {
        try await withV2App { app, mailer in
            let email = "v2-signup@example.com"
            let session = try await v2SignUp(email, on: app)
            #expect(session.emailVerified == false)
            #expect(try await v2Me(session.token, on: app)?.emailVerified == false)

            let sent = try v2Code(in: await mailer.waitFor(1, to: email).first)
            #expect(try await v2Status(.POST, "api/v2/email/verify", token: session.token,
                                     body: V2CodeBody(code: sent.lowercased()), on: app) == .noContent,
                    "a code is accepted in any case")
            #expect(try await v2Me(session.token, on: app)?.emailVerified == true)
        }
    }

    /// Five tries per code, and then even the right code is refused.
    @Test func aWrongCodeIsRefusedAndFiveWrongTriesSpendTheCode() async throws {
        try await withV2App { app, mailer in
            let email = "v2-wrong-code@example.com"
            let session = try await v2SignUp(email, on: app)
            let sent = try v2Code(in: await mailer.waitFor(1, to: email).first)
            for _ in 0 ..< EmailCode.maxAttempts {
                #expect(try await v2Status(.POST, "api/v2/email/verify", token: session.token,
                                         body: V2CodeBody(code: "AAAA-AAAA"), on: app) == .badRequest)
            }
            #expect(try await v2Status(.POST, "api/v2/email/verify", token: session.token,
                                     body: V2CodeBody(code: sent), on: app) == .badRequest)
            #expect(try await v2Me(session.token, on: app)?.emailVerified == false)
        }
    }

    /// The database holds a keyed hash, never the code, and not a plain hash a
    /// leaked copy could be checked against.
    @Test func aStoredCodeIsAKeyedHash() async throws {
        try await withV2App { app, mailer in
            let email = "v2-code-hash@example.com"
            let session = try await v2SignUp(email, on: app)
            let sent = EmailCode.normalise(try v2Code(in: await mailer.waitFor(1, to: email).first))
            let row = try #require(try await EmailCodeRow.query(on: app.db)
                .filter(\.$userID == session.userID).first())
            #expect(row.codeHMAC != sent)
            #expect(row.codeHMAC != Data(SHA256.hash(data: Data(sent.utf8))).hexString)
            #expect(row.codeHMAC == EmailCode.digest(sent, key: app.emailCodeKey))
        }
    }

    @Test func signInWorksOnAnyDeviceAndRefusesAWrongPasswordTheSameAsAnUnknownAddress() async throws {
        try await withV2App { app, _ in
            let email = "v2-signin@example.com"
            let first = try await v2SignUp(email, on: app)
            let (ok, second) = try await v2SignIn("  V2-SignIn@Example.com ", v2Password, label: "Family desktop", on: app)
            #expect(ok == .ok, "the address is trimmed and lower-cased")
            #expect(second?.userID == first.userID && second?.token != first.token)

            let (wrong, _) = try await v2SignIn(email, "not-the-password", on: app)
            let (unknown, _) = try await v2SignIn("v2-nobody@example.com", v2Password, on: app)
            #expect(wrong == .unauthorized && unknown == .unauthorized)
        }
    }

    /// A session used now and then stays alive; an idle one runs out.
    @Test func aSessionRenewsWhileUsedAndAnIdleOneRunsOut() async throws {
        try await withV2App { app, _ in
            let session = try await v2SignUp("v2-renew@example.com", on: app)
            let row = try #require(try await SessionRow.query(on: app.db)
                .filter(\.$tokenHash == tokenDigest(session.token)).first())
            let twoDaysAgo = Date().addingTimeInterval(-2 * 86_400)
            row.lastUsedAt = twoDaysAgo
            row.expiresAt = Date().addingTimeInterval(86_400)
            try await row.save(on: app.db)

            #expect(try await v2Me(session.token, on: app) != nil)
            let renewed = try #require(try await SessionRow.find(row.id, on: app.db))
            #expect(renewed.lastUsedAt > twoDaysAgo)
            #expect(renewed.expiresAt > Date().addingTimeInterval(SessionRules.idleLifetime - 60))

            renewed.expiresAt = Date().addingTimeInterval(-1)
            try await renewed.save(on: app.db)
            #expect(try await v2Status(.GET, "api/v2/me", token: session.token, on: app) == .unauthorized)
            #expect(try await SessionRow.find(row.id, on: app.db) == nil, "an expired session is deleted")
        }
    }

    @Test func signingOutEndsOneSessionAndEverywhereEndsThemAll() async throws {
        try await withV2App { app, _ in
            let email = "v2-signout@example.com"
            let mac = try await v2SignUp(email, on: app)
            let desktop = try #require(try await v2SignIn(email, v2Password, on: app).1)
            let laptop = try #require(try await v2SignIn(email, v2Password, on: app).1)

            #expect(try await v2Status(.POST, "api/v2/signout", token: mac.token, on: app) == .noContent)
            #expect(try await v2Me(mac.token, on: app) == nil)
            #expect(try await v2Me(desktop.token, on: app) != nil)

            #expect(try await v2Status(.POST, "api/v2/signout/everywhere", token: desktop.token, on: app) == .noContent)
            #expect(try await v2Me(desktop.token, on: app) == nil)
            #expect(try await v2Me(laptop.token, on: app) == nil)
        }
    }

    @Test func aPersonSeesTheirSessionsAndCanEndOneButNotSomeoneElses() async throws {
        try await withV2App { app, _ in
            let robin = try await v2SignUp("v2-sessions@example.com", label: "Mac", on: app)
            let desktop = try #require(try await v2SignIn("v2-sessions@example.com", v2Password,
                                                        label: "Family desktop", on: app).1)
            let stranger = try await v2SignUp("v2-sessions-other@example.com", on: app)

            var listed: [V2SessionInfo] = []
            try await app.testing().test(.GET, "api/v2/sessions", headers: v2Bearer(robin.token),
                                         afterResponse: { response async throws in
                listed = try response.content.decode([V2SessionInfo].self)
            })
            #expect(listed.count == 2)
            #expect(listed.filter(\.current).map(\.deviceLabel) == ["Mac"])
            let other = try #require(listed.first { !$0.current })
            #expect(other.deviceLabel == "Family desktop")

            #expect(try await v2Status(.DELETE, "api/v2/sessions/\(other.id)", token: stranger.token, on: app) == .notFound)
            #expect(try await v2Me(desktop.token, on: app) != nil)
            #expect(try await v2Status(.DELETE, "api/v2/sessions/\(other.id)", token: robin.token, on: app) == .noContent)
            #expect(try await v2Me(desktop.token, on: app) == nil)
        }
    }

    /// The same answer for every address. A code goes only to a confirmed one.
    @Test func forgotPasswordSaysNothingAndEmailsOnlyAConfirmedAddress() async throws {
        try await withV2App { app, mailer in
            let confirmed = "v2-forgot@example.com"
            _ = try await v2VerifiedAccount(confirmed, on: app, mailer: mailer)
            let unconfirmed = "v2-forgot-unconfirmed@example.com"
            _ = try await v2SignUp(unconfirmed, on: app)
            _ = await mailer.waitFor(1, to: unconfirmed)

            for email in [confirmed, unconfirmed, "v2-forgot-nobody@example.com"] {
                #expect(try await v2Status(.POST, "api/v2/password/forgot", body: V2Forgot(email: email), on: app) == .noContent)
            }
            let resets = await mailer.waitFor(2, to: confirmed)
            #expect(resets.count == 2 && resets[1].subject.hasPrefix("Reset your WellSpent password"))
            try await Task.sleep(for: .milliseconds(200))
            #expect(await mailer.count(to: unconfirmed) == 1, "only the sign-up code")
            #expect(await mailer.count(to: "v2-forgot-nobody@example.com") == 0)
        }
    }

    /// The reset sets the new v2Password, signs every device out, signs this one
    /// in, works once, and tells the person.
    @Test func aResetChangesThePasswordSignsEveryDeviceOutAndWorksOnce() async throws {
        try await withV2App { app, mailer in
            let email = "v2-reset@example.com"
            let old = try await v2VerifiedAccount(email, on: app, mailer: mailer)
            #expect(try await v2Status(.POST, "api/v2/password/forgot", body: V2Forgot(email: email), on: app) == .noContent)
            let resetCode = try v2Code(in: await mailer.waitFor(2, to: email).last)

            var fresh: V2Session?
            try await app.testing().test(.POST, "api/v2/password/reset", beforeRequest: { request in
                try request.content.encode(V2Reset(email: email, code: resetCode,
                                                 newPassword: "another-long-password", deviceLabel: "Laptop"))
            }, afterResponse: { response async throws in
                #expect(response.status == .ok)
                fresh = try response.content.decode(V2Session.self)
            })
            #expect(try await v2Me(old.token, on: app) == nil, "the old device is signed out")
            #expect(try await v2Me(try #require(fresh).token, on: app) != nil)
            #expect(try await v2SignIn(email, v2Password, on: app).0 == .unauthorized)
            #expect(try await v2SignIn(email, "another-long-password", on: app).0 == .ok)

            #expect(try await v2Status(.POST, "api/v2/password/reset",
                                     body: V2Reset(email: email, code: resetCode, newPassword: "a-third-long-password",
                                                 deviceLabel: nil), on: app) == .badRequest, "a code works once")
            let last = await mailer.waitFor(3, to: email).last
            #expect(last?.subject == AccountEmail.passwordChanged.subject)
        }
    }

    /// A wrong code and an unknown address get the same answer.
    @Test func aResetWithAWrongCodeOrUnknownAddressIsRefusedTheSame() async throws {
        try await withV2App { app, mailer in
            let email = "v2-reset-wrong@example.com"
            _ = try await v2VerifiedAccount(email, on: app, mailer: mailer)
            let wrong = try await v2Status(.POST, "api/v2/password/reset",
                                         body: V2Reset(email: email, code: "AAAA-AAAA",
                                                     newPassword: "another-long-password", deviceLabel: nil), on: app)
            let unknown = try await v2Status(.POST, "api/v2/password/reset",
                                           body: V2Reset(email: "v2-reset-nobody@example.com", code: "AAAA-AAAA",
                                                       newPassword: "another-long-password", deviceLabel: nil), on: app)
            #expect(wrong == .badRequest && unknown == .badRequest)
            #expect(try await v2SignIn(email, v2Password, on: app).0 == .ok, "the password did not change")
        }
    }

    @Test func changingThePasswordNeedsTheCurrentOneAndSignsOtherDevicesOut() async throws {
        try await withV2App { app, mailer in
            let email = "v2-change@example.com"
            let mac = try await v2SignUp(email, on: app)
            let desktop = try #require(try await v2SignIn(email, v2Password, on: app).1)

            #expect(try await v2Status(.POST, "api/v2/password/change", token: mac.token,
                                     body: V2Change(currentPassword: "not-the-password",
                                                  newPassword: "another-long-password"), on: app) == .forbidden,
                    "a wrong current password is not a dead session")
            #expect(try await v2Status(.POST, "api/v2/password/change", token: mac.token,
                                     body: V2Change(currentPassword: v2Password,
                                                  newPassword: "another-long-password"), on: app) == .noContent)
            #expect(try await v2Me(mac.token, on: app) != nil, "this device stays signed in")
            #expect(try await v2Me(desktop.token, on: app) == nil)
            #expect(try await v2SignIn(email, "another-long-password", on: app).0 == .ok)
            let last = await mailer.waitFor(2, to: email).last
            #expect(last?.subject == AccountEmail.passwordChanged.subject)
        }
    }

    /// Each case gets its own server, because sign-up allows five tries an hour
    /// from one address.
    @Test func passwordsAndAddressesAreChecked() async throws {
        let cases: [(String, String)] = [
            ("v2-short@example.com", "short"),
            ("v2-long@example.com", String(repeating: "x", count: 129)),
            ("not-an-address", v2Password), ("@example.com", v2Password), ("v2@", v2Password),
            ("v2 space@example.com", v2Password), (String(repeating: "a", count: 250) + "@example.com", v2Password),
            ("v2@two@example.com", v2Password), ("v2@localhost", v2Password), ("v2@.example.com", v2Password),
            ("v2@example..com", v2Password),
        ]
        for (email, attempt) in cases {
            try await withV2App { app, _ in
                let answer = try await v2Status(.POST, "api/v2/signup",
                                              body: V2SignUp(email: email, password: attempt, deviceLabel: nil),
                                              on: app)
                #expect(answer == .badRequest, "\(email.prefix(20))")
            }
        }
    }

    /// Requests that need no session are small, and a big one is refused before
    /// anything is read. Through a real server: the in-memory tester skips the
    /// body limit.
    @Test func anOversizedRequestIsRefused() async throws {
        try await withV2App { app, _ in
            var answer = HTTPStatus.ok
            try await app.testing(method: .running(port: 0)).test(.POST, "api/v2/password/forgot",
                                                                  beforeRequest: { request in
                try request.content.encode(V2Forgot(email: String(repeating: "a", count: 8_000) + "@example.com"))
            }, afterResponse: { response async throws in
                answer = response.status
            })
            #expect(answer == .payloadTooLarge)
        }
    }

    /// A session counts only while its stamp matches the password. One made
    /// with the old stamp after a change, as a sign-in racing a reset would be,
    /// is refused; the device that made the change stays signed in.
    @Test func aSessionFromBeforeAPasswordChangeEndsEvenIfMadeAfterIt() async throws {
        try await withV2App { app, _ in
            let email = "v2-stamp@example.com"
            let mac = try await v2SignUp(email, on: app)
            #expect(try await v2Status(.POST, "api/v2/password/change", token: mac.token,
                                     body: V2Change(currentPassword: v2Password, newPassword: "another-long-password"),
                                     on: app) == .noContent)
            let now = Date()
            try await SessionRow(userID: mac.userID, tokenHash: tokenDigest("raced-sign-in"), deviceLabel: nil,
                                 lastUsedAt: now, expiresAt: now.addingTimeInterval(86_400),
                                 credentialStamp: nil).create(on: app.db)
            #expect(try await v2Me("raced-sign-in", on: app) == nil)
            #expect(try await v2Me(mac.token, on: app) != nil)
        }
    }

    /// A reset that lands while a password change is on its way wins: the
    /// change finds the password changed since its session began, and does
    /// nothing, so whoever reset it keeps it.
    @Test func aPasswordChangeLosesToAResetThatLandedFirst() async throws {
        try await withV2App { app, _ in
            let mac = try await v2SignUp("v2-change-race@example.com", on: app)
            let session = try #require(try await SessionRow.query(on: app.db)
                .filter(\.$tokenHash == tokenDigest(mac.token)).first())
            let user = try #require(try await UserRow.find(mac.userID, on: app.db))
            user.passwordHash = try Bcrypt.hash("the-reset-password")
            user.passwordChangedAt = Date()
            try await user.save(on: app.db)

            let changed = try await changePassword(of: mac.userID, session: try session.requireID(),
                                                   to: try Bcrypt.hash("the-attackers-password"), on: app.db)
            #expect(changed == false)
            #expect(try await v2SignIn("v2-change-race@example.com", "the-reset-password", on: app).0 == .ok)
        }
    }

    /// Guesses at one account slow down wherever they come from.
    @Test func signInSlowsDownForOneAccount() async throws {
        try await withV2App { app, _ in
            let email = "v2-account-limit@example.com"
            _ = try await v2SignUp(email, on: app)
            let key = "v2-signin-address:\(Data(SHA256.hash(data: Data(email.utf8))).hexString)"
            for _ in 0 ..< RateLimiter.Limit.signInPerAccount.attempts {
                _ = await app.rateLimiter.allow(key, limit: .signInPerAccount)
            }
            #expect(try await v2SignIn(email, v2Password, on: app).0 == .tooManyRequests)
        }
    }

    /// A second code within a minute is not sent; the one on its way still works.
    @Test func aSecondCodeWithinAMinuteIsNotSent() async throws {
        try await withV2App { app, mailer in
            let email = "v2-resend-gap@example.com"
            let session = try await v2SignUp(email, on: app)
            _ = await mailer.waitFor(1, to: email)
            #expect(try await v2Status(.POST, "api/v2/email/verify/resend", token: session.token, on: app) == .noContent)
            try await Task.sleep(for: .milliseconds(200))
            #expect(await mailer.count(to: email) == 1)

            let row = try #require(try await EmailCodeRow.query(on: app.db).filter(\.$userID == session.userID).first())
            row.lastSentAt = Date().addingTimeInterval(-2 * 60)
            try await row.save(on: app.db)
            #expect(try await v2Status(.POST, "api/v2/email/verify/resend", token: session.token, on: app) == .noContent)
            #expect(await mailer.waitFor(2, to: email).count == 2)
        }
    }

    /// The same address typed two ways is one account.
    @Test func anAddressIsOneAccountHoweverItIsTyped() async throws {
        try await withV2App { app, _ in
            _ = try await v2SignUp("jose\u{301}@example.com", on: app)
            #expect(try await v2SignIn("JOS\u{C9}@example.com", v2Password, on: app).0 == .ok)
        }
    }

    /// The public development key only in development and tests.
    @Test func theDevelopmentCodeKeyIsOnlyForDevelopmentAndTests() throws {
        #expect(throws: (any Error).self) {
            try EmailCode.chooseKey(environment: Environment(name: "preview"), configured: nil)
        }
        _ = try EmailCode.chooseKey(environment: .development, configured: nil)
        _ = try EmailCode.chooseKey(environment: .testing, configured: nil)
    }

    /// A forgot-password request just before the server stops must not take it
    /// down: the work after answering holds everything it needs from the start.
    @Test func aForgotPasswordJustBeforeShutdownIsHarmless() async throws {
        let app = try await Application.make(.testing)
        try await configure(app)
        app.mailer = V2RecordingMailer()
        try await app.asyncBoot()
        let answer = try await v2Status(.POST, "api/v2/password/forgot",
                                      body: V2Forgot(email: "v2-shutdown@example.com"), on: app)
        try await app.asyncShutdown()
        try await Task.sleep(for: .milliseconds(300))
        #expect(answer == .noContent)
    }

    /// A live server with no email service or code key refuses to start;
    /// staging and development write codes to the log.
    @Test func aLiveServerNeedsAnEmailServiceAndACodeKey() throws {
        #expect(throws: (any Error).self) {
            try MailerChoice.choose(server: .live, resendAPIKey: nil, from: nil)
        }
        #expect(throws: (any Error).self, "no marker counts as live") {
            try MailerChoice.choose(server: try ServerEnvironment.resolve(nil, appEnvironment: .production),
                                    resendAPIKey: "", from: nil)
        }
        #expect(try MailerChoice.choose(server: try ServerEnvironment.resolve("staging", appEnvironment: .production),
                                        resendAPIKey: nil, from: nil) == .log)
        #expect(try MailerChoice.choose(server: .live, resendAPIKey: "re_x", from: nil)
                == .resend(apiKey: "re_x", from: MailerChoice.defaultFrom))
        #expect(try MailerChoice.choose(server: try ServerEnvironment.resolve(nil, appEnvironment: .development),
                                        resendAPIKey: nil, from: nil) == .log)
        #expect(try MailerChoice.choose(server: .live, resendAPIKey: "re_x", from: "")
                == .resend(apiKey: "re_x", from: MailerChoice.defaultFrom), "compose passes unset as empty")

        #expect(throws: (any Error).self) { try EmailCode.chooseKey(environment: .production, configured: nil) }
        #expect(throws: (any Error).self) { try EmailCode.chooseKey(environment: .production, configured: "c2hvcnQ=") }
        _ = try EmailCode.chooseKey(environment: .production,
                                    configured: Data(repeating: 7, count: 32).base64EncodedString())
    }
}
