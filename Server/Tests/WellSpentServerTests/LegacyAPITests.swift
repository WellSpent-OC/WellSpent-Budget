import Testing
import Foundation
import Vapor
import VaporTesting
@testable import WellSpentServerCore

private struct Reason: Content { let reason: String }

@Suite("Server, the old API is gone", .serialized)
struct LegacyAPITests {
    /// Every path under /api/v1, by every method, signed in or not, answers 401
    /// with the update message. The old app shows it as is and treats it as
    /// something that may clear up, so it keeps everything it has queued. The
    /// new API and the health check carry on.
    @Test func everyOldPathAsksTheAppToUpdateAndTheNewOneCarriesOn() async throws {
        try await withV2App { app, _ in
            let group = UUID()
            let paths = ["signup", "signin", "signout", "escrow/someone@example.com",
                         "groups/\(group)/pull?since=0", "groups/\(group)/push", "groups/\(group)/log",
                         "groups/\(group)/keys", "groups/\(group)/invites", "invites", "invites/accept",
                         "invites/abcdef", "a/path/that/never/was"]
            var answered: [String] = []
            for path in paths {
                for method: HTTPMethod in [.GET, .POST, .DELETE] {
                    for token: String? in [nil, "any-old-token"] {
                        var reason = ""
                        var status = HTTPStatus.ok
                        try await app.testing().test(method, "api/v1/\(path)", headers: token.map(v2Bearer) ?? [:],
                                                     beforeRequest: { request in
                            if method == .POST { request.body = ByteBuffer(string: "{\"email\": \"x\"}") }
                        }, afterResponse: { response async throws in
                            status = response.status
                            reason = (try? response.content.decode(Reason.self).reason) ?? ""
                        })
                        if status != .unauthorized || reason != LegacyAPI.refusal {
                            answered.append("\(method.rawValue) \(path): \(status.code)")
                        }
                    }
                }
            }
            #expect(answered.isEmpty, "these did not ask for the update: \(answered)")

            _ = try await v2SignUp("legacy-gone-new@example.com", on: app)
            #expect(try await v2Status(.GET, "health", on: app) == .ok)
        }
    }

    /// The only routes left under /api/v1 are its answer, one for each
    /// method, so nothing of the sealed sync can be reached by any path.
    @Test func noRouteOfTheOldAPIIsLeft() async throws {
        try await withV2App { app, _ in
            let left = app.routes.all.map { route in route.path.map(\.description) }
                .filter { $0.first == "api" && $0.dropFirst().first == "v1" }
            #expect(left.allSatisfy { $0 == ["api", "v1", "**"] }, "\(left)")
            #expect(left.count == 5, "one answer for each method: \(left.count)")
        }
    }
}
