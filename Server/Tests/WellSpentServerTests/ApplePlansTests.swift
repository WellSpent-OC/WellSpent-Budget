import Testing
import Foundation
import Fluent
import Vapor
import VaporTesting
import Crypto
import X509
import SwiftASN1
@testable import WellSpentServerCore

/// A chain of certificates shaped like Apple's, to sign test purchases with:
/// a root, an intermediate with Apple's intermediate mark, and a leaf with
/// Apple's receipt-signing mark.
private struct TestChain {
    let root: Certificate
    let intermediate: Certificate
    let leaf: Certificate
    let leafKey: P256.Signing.PrivateKey

    init(marked: Bool = true) throws {
        let rootKey = P256.Signing.PrivateKey()
        let intermediateKey = P256.Signing.PrivateKey()
        leafKey = P256.Signing.PrivateKey()
        let now = Date()
        let from = now.addingTimeInterval(-86_400)
        let until = now.addingTimeInterval(86_400 * 365)
        func name(_ text: String) throws -> DistinguishedName { try DistinguishedName { CommonName(text) } }
        func mark(_ oid: ASN1ObjectIdentifier) -> Certificate.Extension {
            Certificate.Extension(oid: oid, critical: false, value: [0x05, 0x00])
        }
        root = try Certificate(
            version: .v3, serialNumber: .init(), publicKey: .init(rootKey.publicKey),
            notValidBefore: from, notValidAfter: until, issuer: try name("Test Root"), subject: try name("Test Root"),
            signatureAlgorithm: .ecdsaWithSHA256,
            extensions: try Certificate.Extensions {
                Critical(BasicConstraints.isCertificateAuthority(maxPathLength: nil))
                KeyUsage(keyCertSign: true)
            },
            issuerPrivateKey: .init(rootKey))
        intermediate = try Certificate(
            version: .v3, serialNumber: .init(), publicKey: .init(intermediateKey.publicKey),
            notValidBefore: from, notValidAfter: until, issuer: root.subject, subject: try name("Test Intermediate"),
            signatureAlgorithm: .ecdsaWithSHA256,
            extensions: try Certificate.Extensions {
                Critical(BasicConstraints.isCertificateAuthority(maxPathLength: 0))
                KeyUsage(keyCertSign: true)
                if marked { mark(AppleJWSVerifier.intermediateMark) }
            },
            issuerPrivateKey: .init(rootKey))
        leaf = try Certificate(
            version: .v3, serialNumber: .init(), publicKey: .init(leafKey.publicKey),
            notValidBefore: from, notValidAfter: until, issuer: intermediate.subject, subject: try name("Test Leaf"),
            signatureAlgorithm: .ecdsaWithSHA256,
            extensions: try Certificate.Extensions {
                Critical(BasicConstraints.notCertificateAuthority)
                KeyUsage(digitalSignature: true)
                if marked { mark(AppleJWSVerifier.leafMark) }
            },
            issuerPrivateKey: .init(intermediateKey))
    }

    var rootPEM: String { get throws { try root.serializeAsPEM().pemString } }

    /// A JWS of `transaction`, signed by the leaf, with the chain in its x5c.
    func sign(_ transaction: AppleTransaction) throws -> String {
        func der(_ certificate: Certificate) throws -> String {
            var serializer = DER.Serializer()
            try serializer.serialize(certificate)
            return Data(serializer.serializedBytes).base64EncodedString()
        }
        func url(_ data: Data) -> String {
            data.base64EncodedString().replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        }
        let header = try JSONSerialization.data(withJSONObject: [
            "alg": "ES256", "x5c": [try der(leaf), try der(intermediate), try der(root)],
        ])
        let input = url(header) + "." + url(try JSONEncoder().encode(transaction))
        let signature = try leafKey.signature(for: Data(input.utf8))
        return input + "." + url(signature.rawRepresentation)
    }
}

private struct Handover: Content { let signedTransaction: String }
private struct Answer: Content { let tier: String; let period: String; let source: String; let state: String }
private struct Refusal: Content { let reason: String }

/// Plans and Apple purchases on, with a verifier that trusts `chain`'s root.
private func withApplePlans(trusting chain: TestChain,
                            _ body: (Application) async throws -> Void) async throws {
    try await withV2App { app, _ in
        app.plansEnabled = true
        app.applePlansEnabled = true
        app.appleVerifier = AppleJWSVerifier(roots: [try chain.rootPEM])
        try await body(app)
    }
}

private func purchase(token: UUID?, product: String = "app.wellspent.pro.growth.yearly",
                      original: String = "2000000000000001", transaction: String = "2000000000000001",
                      expires: Date? = Date().addingTimeInterval(86_400 * 365), revoked: Date? = nil,
                      bundle: String = "app.wellspent.mac.staging", environment: String = "Sandbox") -> AppleTransaction {
    AppleTransaction(bundleId: bundle, productId: product, originalTransactionId: original,
                     transactionId: transaction, appAccountToken: token, expiresDate: expires,
                     revocationDate: revoked, signedDate: Date().addingTimeInterval(-60), environment: environment)
}

private func hand(_ jws: String, _ session: V2Session, on app: Application) async throws -> (HTTPStatus, Answer?, String?) {
    var result: (HTTPStatus, Answer?, String?) = (.internalServerError, nil, nil)
    try await app.testing().test(.POST, "api/v2/plan/apple", headers: v2Bearer(session.token),
                                 beforeRequest: { request in
        try request.content.encode(Handover(signedTransaction: jws))
    }, afterResponse: { response async throws in
        result = (response.status, try? response.content.decode(Answer.self),
                  (try? response.content.decode(Refusal.self))?.reason)
    })
    return result
}

private func token(of session: V2Session, on app: Application) async throws -> UUID {
    try await PlanRow.forUser(session.userID, on: app.db).appleAccountToken
}

@Suite("Apple purchases", .serialized) struct ApplePlansTests {
    @Test("While the switch is off, or plans are off, the route isn't there and nothing changes")
    func offIsNotFound() async throws {
        let chain = try TestChain()
        for (plans, apple) in [(true, false), (false, true), (false, false)] {
            try await withV2App { app, _ in
                app.plansEnabled = plans
                app.applePlansEnabled = apple
                app.appleVerifier = AppleJWSVerifier(roots: [try chain.rootPEM])
                let me = try await v2SignUp("apple-off@example.com", on: app)
                let jws = try chain.sign(purchase(token: try await token(of: me, on: app)))
                #expect(try await hand(jws, me, on: app).0 == .notFound)
                #expect(try await PlanRow.forUser(me.userID, on: app.db).tier == "free")
            }
        }
    }

    @Test("A genuine purchase sets the plan, from Apple, until the date Apple gives")
    func aPurchaseSetsThePlan() async throws {
        let chain = try TestChain()
        try await withApplePlans(trusting: chain) { app in
            let me = try await v2SignUp("apple-buys@example.com", on: app)
            let bought = purchase(token: try await token(of: me, on: app))
            let (status, answer, _) = try await hand(try chain.sign(bought), me, on: app)
            #expect(status == .ok)
            #expect(answer?.tier == "growth" && answer?.period == "yearly" && answer?.source == "apple" && answer?.state == "active")
            let plan = try await PlanRow.forUser(me.userID, on: app.db)
            #expect(plan.storeID == bought.originalTransactionId)
            #expect(plan.storeEnvironment == "Sandbox")
            #expect(abs((plan.paidUntil ?? .distantPast).timeIntervalSince(bought.expiresDate!)) < 1)
        }
    }

    @Test("Anything Apple didn't sign is refused with 422 and changes nothing")
    func notGenuineIsRefused() async throws {
        let chain = try TestChain()
        let stranger = try TestChain()
        let unmarked = try TestChain(marked: false)
        try await withApplePlans(trusting: chain) { app in
            let me = try await v2SignUp("apple-fake@example.com", on: app)
            let mine = try await token(of: me, on: app)
            let genuine = try chain.sign(purchase(token: mine))
            var parts = genuine.split(separator: ".").map(String.init)
            parts[1] = try chain.sign(purchase(token: mine, product: "app.wellspent.pro.portfolio.yearly"))
                .split(separator: ".").map(String.init)[1]
            let tampered = parts.joined(separator: ".")
            let cases: [(String, String)] = [
                ("a payload changed after signing", tampered),
                ("a chain to a root this server doesn't trust", try stranger.sign(purchase(token: mine))),
                ("a chain without Apple's marks", try unmarked.sign(purchase(token: mine))),
                ("not a JWS at all", "not.a.jws"),
                ("a product that isn't ours", try chain.sign(purchase(token: mine, product: "com.example.gold"))),
                ("the free tier as a product", try chain.sign(purchase(token: mine, product: "app.wellspent.pro.free.monthly"))),
                ("another app's bundle", try chain.sign(purchase(token: mine, bundle: "com.example.other"))),
                ("Xcode's local store", try chain.sign(purchase(token: mine, environment: "Xcode"))),
            ]
            for (what, jws) in cases {
                let (status, _, reason) = try await hand(jws, me, on: app)
                #expect(status == .unprocessableEntity && reason == "notGenuine", "\(what): \(status)")
            }
            #expect(try await PlanRow.forUser(me.userID, on: app.db).tier == "free")
        }
    }

    @Test("A Production purchase is taken as well as a Sandbox one, and the plan says which")
    func productionAndSandboxAreBothTaken() async throws {
        let chain = try TestChain()
        try await withApplePlans(trusting: chain) { app in
            let me = try await v2SignUp("apple-production@example.com", on: app)
            let bought = purchase(token: try await token(of: me, on: app), environment: "Production")
            #expect(try await hand(try chain.sign(bought), me, on: app).0 == .ok)
            #expect(try await PlanRow.forUser(me.userID, on: app.db).storeEnvironment == "Production")
        }
    }

    @Test("The live server takes only the live app's purchases")
    func liveTakesTheLiveApp() {
        #expect(AppleApp.bundleID(for: .live) == "app.wellspent.mac")
        #expect(AppleApp.bundleID(for: .staging) == "app.wellspent.mac.staging")
    }

    @Test("A purchase made for another account is refused with 403")
    func anotherAccountsPurchaseIsRefused() async throws {
        let chain = try TestChain()
        try await withApplePlans(trusting: chain) { app in
            let buyer = try await v2SignUp("apple-buyer@example.com", on: app)
            let other = try await v2SignUp("apple-other@example.com", on: app)
            let jws = try chain.sign(purchase(token: try await token(of: buyer, on: app)))
            let (status, _, reason) = try await hand(jws, other, on: app)
            #expect(status == .forbidden && reason == "otherAccount")
            #expect(try await hand(try chain.sign(purchase(token: nil)), other, on: app).2 == "otherAccount")
            #expect(try await PlanRow.forUser(other.userID, on: app.db).tier == "free")
        }
    }

    @Test("The same purchase handed over twice gives the same plan, and an older one never moves the date back")
    func aReplayChangesNothing() async throws {
        let chain = try TestChain()
        try await withApplePlans(trusting: chain) { app in
            let me = try await v2SignUp("apple-twice@example.com", on: app)
            let mine = try await token(of: me, on: app)
            let later = Date().addingTimeInterval(86_400 * 365)
            let jws = try chain.sign(purchase(token: mine, expires: later))
            #expect(try await hand(jws, me, on: app).0 == .ok)
            #expect(try await hand(jws, me, on: app).1?.tier == "growth")
            let older = purchase(token: mine, transaction: "2000000000000000", expires: Date().addingTimeInterval(86_400 * 30))
            #expect(try await hand(try chain.sign(older), me, on: app).0 == .ok)
            let plan = try await PlanRow.forUser(me.userID, on: app.db)
            #expect(abs((plan.paidUntil ?? .distantPast).timeIntervalSince(later)) < 1)
        }
    }

    @Test("A lapsed or refunded purchase changes nothing, and the answer says what the account has")
    func lapsedOrRefundedChangesNothing() async throws {
        let chain = try TestChain()
        try await withApplePlans(trusting: chain) { app in
            let me = try await v2SignUp("apple-lapsed@example.com", on: app)
            let mine = try await token(of: me, on: app)
            let lapsed = try chain.sign(purchase(token: mine, expires: Date().addingTimeInterval(-60)))
            let refunded = try chain.sign(purchase(token: mine, revoked: Date().addingTimeInterval(-60)))
            for jws in [lapsed, refunded] {
                let (status, answer, _) = try await hand(jws, me, on: app)
                #expect(status == .ok && answer?.tier == "free")
            }
        }
    }

    @Test("While a website plan is live, an Apple purchase is refused with 409")
    func aLiveWebsitePlanComesFirst() async throws {
        let chain = try TestChain()
        try await withApplePlans(trusting: chain) { app in
            let me = try await v2SignUp("apple-paddle@example.com", on: app)
            let plan = try await PlanRow.forUser(me.userID, on: app.db)
            plan.tier = "starter"; plan.period = "monthly"; plan.source = "paddle"; plan.state = "active"
            try await plan.save(on: app.db)
            let (status, _, reason) = try await hand(try chain.sign(purchase(token: plan.appleAccountToken)), me, on: app)
            #expect(status == .conflict && reason == "paddlePlanLive")
            #expect(try await PlanRow.forUser(me.userID, on: app.db).source == "paddle")
        }
    }

    @Test("The switch is on only when its variable says on, and the real verifier trusts Apple's root")
    func theSwitchAndTheRoot() throws {
        #expect(ServerSwitch.isOn("on") && !ServerSwitch.isOn(nil))
        let root = try Certificate(pemEncoded: AppleRootCA.g3)
        #expect(root.subject.description.contains("Apple Root CA - G3"))
        #expect(AppleJWSVerifier.production.roots == [AppleRootCA.g3])
    }
}
