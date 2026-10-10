import Testing
import Foundation
import Vapor
import VaporTesting
@testable import WellSpentServerCore

private struct OldSignUp: Content {
    let email: String; let password: String; let identitySigning: Data; let identityKEM: Data
    let escrowNonce: Data?; let escrowCiphertext: Data?
}
private struct Reason: Content { let reason: String }

@Suite("Server, closing the old API at the switch", .serialized)
struct LegacyAPITests {
    /// Closed, every old route answers 401 with the update message, which the
    /// old app shows as is and treats as something that may clear up, so it
    /// keeps everything it has queued. The new API and the health check carry on.
    @Test func aClosedOldAPIAsksTheAppToUpdateAndTheNewOneCarriesOn() async throws {
        try await withV2App { app, _ in
            app.legacyAPIOpen = false
            var reason = ""
            try await app.testing().test(.POST, "api/v1/signup", beforeRequest: { request in
                try request.content.encode(OldSignUp(email: "legacy-closed@example.com", password: v2Password,
                                                     identitySigning: Data([1]), identityKEM: Data([2]),
                                                     escrowNonce: nil, escrowCiphertext: nil))
            }, afterResponse: { response async throws in
                #expect(response.status == .unauthorized)
                reason = try response.content.decode(Reason.self).reason
            })
            #expect(reason == LegacyAPIGate.refusal)
            for path in ["api/v1/groups/\(UUID())/pull", "api/v1/groups/\(UUID())/log"] {
                #expect(try await v2Status(.GET, path, token: "any-old-token", on: app) == .unauthorized)
            }
            _ = try await v2SignUp("legacy-closed-new@example.com", on: app)
            #expect(try await v2Status(.GET, "health", on: app) == .ok)
        }
    }

    @Test func theOldAPIIsOpenUntilTheSwitch() async throws {
        try await withV2App { app, _ in
            let answer = try await v2Status(.POST, "api/v1/signup",
                                            body: OldSignUp(email: "legacy-open@example.com", password: v2Password,
                                                            identitySigning: Data([1]), identityKEM: Data([2]),
                                                            escrowNonce: nil, escrowCiphertext: nil), on: app)
            #expect(answer == .ok)
        }
    }

    @Test func theSettingIsOnOrOffAndNothingElse() throws {
        #expect(try LegacyAPIGate.parse(nil) == true)
        #expect(try LegacyAPIGate.parse("") == true)
        #expect(try LegacyAPIGate.parse("on") == true)
        #expect(try LegacyAPIGate.parse(" OFF ") == false)
        #expect(throws: (any Error).self) { try LegacyAPIGate.parse("maybe") }
    }
}
