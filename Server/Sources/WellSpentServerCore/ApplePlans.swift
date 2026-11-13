import Foundation
import Vapor
import Fluent
import JWTKit
import X509
import SwiftASN1

// MARK: - The switch

struct ApplePlansEnabledKey: StorageKey {
    typealias Value = Bool
}

struct AppleVerifierKey: StorageKey {
    typealias Value = any AppleTransactionVerifying
}

extension Application {
    /// `WELLSPENT_APPLE_PLANS=on` lets the apps hand the server an App Store
    /// purchase. It works only while plans are on too. Off, the route answers
    /// 404 and records nothing.
    var applePlansEnabled: Bool {
        get { storage[ApplePlansEnabledKey.self] ?? false }
        set { storage[ApplePlansEnabledKey.self] = newValue }
    }

    /// What checks Apple's signed transactions. Apple's real root, unless a
    /// test sets its own.
    var appleVerifier: any AppleTransactionVerifying {
        get { storage[AppleVerifierKey.self] ?? AppleJWSVerifier.production }
        set { storage[AppleVerifierKey.self] = newValue }
    }
}

// MARK: - Apple's signed transaction

/// The fields of Apple's signed transaction the server uses. Apple's dates are
/// milliseconds since 1970.
struct AppleTransaction: JWTPayload, ValidationTimePayload, Equatable {
    var bundleId: String
    var productId: String
    var originalTransactionId: String
    var transactionId: String
    var appAccountToken: UUID?
    var expiresDate: Date?
    var revocationDate: Date?
    var signedDate: Date
    var environment: String

    enum CodingKeys: String, CodingKey {
        case bundleId, productId, originalTransactionId, transactionId, appAccountToken
        case expiresDate, revocationDate, signedDate, environment
    }

    init(bundleId: String, productId: String, originalTransactionId: String, transactionId: String,
         appAccountToken: UUID?, expiresDate: Date?, revocationDate: Date? = nil, signedDate: Date,
         environment: String) {
        self.bundleId = bundleId
        self.productId = productId
        self.originalTransactionId = originalTransactionId
        self.transactionId = transactionId
        self.appAccountToken = appAccountToken
        self.expiresDate = expiresDate
        self.revocationDate = revocationDate
        self.signedDate = signedDate
        self.environment = environment
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func date(_ key: CodingKeys) throws -> Date? {
            try c.decodeIfPresent(Double.self, forKey: key).map { Date(timeIntervalSince1970: $0 / 1000) }
        }
        bundleId = try c.decode(String.self, forKey: .bundleId)
        productId = try c.decode(String.self, forKey: .productId)
        originalTransactionId = try c.decode(String.self, forKey: .originalTransactionId)
        transactionId = try c.decode(String.self, forKey: .transactionId)
        appAccountToken = try c.decodeIfPresent(UUID.self, forKey: .appAccountToken)
        expiresDate = try date(.expiresDate)
        revocationDate = try date(.revocationDate)
        guard let signed = try date(.signedDate) else {
            throw DecodingError.keyNotFound(CodingKeys.signedDate, .init(codingPath: [], debugDescription: "no signedDate"))
        }
        signedDate = signed
        environment = try c.decode(String.self, forKey: .environment)
    }

    func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        func ms(_ date: Date) -> Double { (date.timeIntervalSince1970 * 1000).rounded() }
        try c.encode(bundleId, forKey: .bundleId)
        try c.encode(productId, forKey: .productId)
        try c.encode(originalTransactionId, forKey: .originalTransactionId)
        try c.encode(transactionId, forKey: .transactionId)
        try c.encodeIfPresent(appAccountToken, forKey: .appAccountToken)
        try c.encodeIfPresent(expiresDate.map(ms), forKey: .expiresDate)
        try c.encodeIfPresent(revocationDate.map(ms), forKey: .revocationDate)
        try c.encode(ms(signedDate), forKey: .signedDate)
        try c.encode(environment, forKey: .environment)
    }

    /// The signature and the chain are checked by the verifier, not here.
    func verify(using algorithm: some JWTAlgorithm) async throws {}
}

protocol AppleTransactionVerifying: Sendable {
    /// The transaction, once its signature and certificate chain check out.
    /// Throws for anything Apple didn't sign.
    func verify(_ signedTransaction: String) async throws -> AppleTransaction
}

/// Checks a signed transaction the way Apple asks: the signature against the
/// leaf certificate in its header, the chain up to a trusted root as of the
/// transaction's own signed date, and Apple's marks on the leaf and the
/// intermediate certificate.
struct AppleJWSVerifier: AppleTransactionVerifying {
    /// Apple's marks: the App Store's receipt-signing leaf, and Apple's
    /// Worldwide Developer Relations intermediate.
    static let leafMark = try! ASN1ObjectIdentifier(dotRepresentation: "1.2.840.113635.100.6.11.1")
    static let intermediateMark = try! ASN1ObjectIdentifier(dotRepresentation: "1.2.840.113635.100.6.2.1")

    let roots: [String]

    /// Apple Root CA - G3, the root every App Store signature chains to.
    static let production = AppleJWSVerifier(roots: [AppleRootCA.g3])

    func verify(_ signedTransaction: String) async throws -> AppleTransaction {
        let transaction: AppleTransaction
        do {
            transaction = try await X5CVerifier(rootCertificates: roots)
                .verifyJWS(signedTransaction, as: AppleTransaction.self, validationTime: .signedDate)
        } catch {
            throw AppleRefusal.notGenuine
        }
        let chain = try Self.chain(of: signedTransaction)
        guard chain.count == 3,
              chain[0].extensions[oid: Self.leafMark] != nil,
              chain[1].extensions[oid: Self.intermediateMark] != nil else {
            throw AppleRefusal.notGenuine
        }
        return transaction
    }

    /// The certificates in the header's x5c, leaf first.
    static func chain(of jws: String) throws -> [Certificate] {
        struct Header: Decodable { let x5c: [String]? }
        guard let first = jws.split(separator: ".").first,
              let data = Data(appleBase64URL: String(first)),
              let x5c = try? JSONDecoder().decode(Header.self, from: data).x5c else {
            throw AppleRefusal.notGenuine
        }
        return try x5c.map { text in
            guard let der = Data(base64Encoded: text), let certificate = try? Certificate(derEncoded: [UInt8](der)) else {
                throw AppleRefusal.notGenuine
            }
            return certificate
        }
    }
}

enum AppleRefusal: Error {
    case notGenuine
}

extension Data {
    init?(appleBase64URL text: String) {
        var base64 = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        self.init(base64Encoded: base64)
    }
}

/// The store that sold a plan, and which of its environments: Apple's
/// Production or Sandbox.
struct AddPlanStoreEnvironment: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema(PlanRow.schema).field("store_environment", .string).update()
    }

    func revert(on database: any Database) async throws {
        try await database.schema(PlanRow.schema).deleteField("store_environment").update()
    }
}

// MARK: - What a purchase buys

/// A store product: `app.wellspent.pro.<tier>.<period>`, the paid tiers only.
struct ApplePlanProduct: Equatable {
    static let prefix = "app.wellspent.pro."

    let tier: Tier
    let period: String

    init?(_ productID: String) {
        guard productID.hasPrefix(Self.prefix) else { return nil }
        let parts = productID.dropFirst(Self.prefix.count).split(separator: ".")
        guard parts.count == 2, let tier = Tier(rawValue: String(parts[0])), tier != .free,
              ["monthly", "yearly"].contains(parts[1]) else { return nil }
        self.tier = tier
        self.period = String(parts[1])
    }
}

/// The app this server sells to: the live app, or the staging build.
enum AppleApp {
    static func bundleID(for environment: ServerEnvironment) -> String {
        environment == .live ? "app.wellspent.mac" : "app.wellspent.mac.staging"
    }
}

// MARK: - The route

struct AppleTransactionRequest: Content {
    let signedTransaction: String
}

func registerApplePlanRoutes(_ routes: any RoutesBuilder) {
    let authed = routes.grouped(SessionAuthenticator(), AuthenticatedUser.guardMiddleware())

    /// `POST /api/v2/plan/apple`: the app hands over Apple's signed transaction
    /// from a purchase or a restore, and gets the plan answer back.
    authed.on(.POST, "plan", "apple", body: .collect(maxSize: "64kb")) { request async throws -> PlanAnswer in
        // The body first, as on the other plan routes: one that isn't JSON is
        // a 400 whether or not the switch is on.
        let body = try request.content.decode(AppleTransactionRequest.self)
        guard request.application.plansEnabled, request.application.applePlansEnabled else {
            throw Abort(.notFound)
        }
        let user = try request.auth.require(AuthenticatedUser.self)
        let transaction: AppleTransaction
        do {
            transaction = try await request.application.appleVerifier.verify(body.signedTransaction)
        } catch {
            throw PlanRefusal.pick("notGenuine", status: 422)
        }
        let environment = request.application.storage[ServerEnvironmentKey.self] ?? .development
        // Live takes Sandbox too: App Review and TestFlight buy there.
        guard transaction.bundleId == AppleApp.bundleID(for: environment),
              ["Production", "Sandbox"].contains(transaction.environment),
              let product = ApplePlanProduct(transaction.productId) else {
            throw PlanRefusal.pick("notGenuine", status: 422)
        }
        try await request.db.transaction { db in
            let plan = try await PlanRow.forUser(user.id, on: db)
            // Bought for another account: Apple tags each purchase with the
            // token this server gave the buyer's account.
            guard transaction.appAccountToken == plan.appleAccountToken else {
                throw PlanRefusal.pick("otherAccount", status: 403)
            }
            if plan.source == "paddle", plan.state != "canceled", plan.state != "free" {
                throw PlanRefusal.pick("paddlePlanLive", status: 409)
            }
            // A refunded or lapsed purchase changes nothing: the answer says
            // what the account has now.
            let now = Date()
            guard transaction.revocationDate == nil, let until = transaction.expiresDate, until > now else { return }
            // A replay of the same purchase, or an older transaction from it,
            // never moves the end date back.
            if plan.source == "apple", plan.storeID == transaction.originalTransactionId,
               let current = plan.paidUntil, current >= until, plan.tier == product.tier.rawValue {
                return
            }
            plan.tier = product.tier.rawValue
            plan.period = product.period
            plan.source = "apple"
            plan.state = "active"
            plan.storeID = transaction.originalTransactionId
            plan.storeEnvironment = transaction.environment
            plan.paidUntil = until
            plan.renews = true
            plan.nextTier = nil
            try await plan.save(on: db)
        }
        return try await PlanAnswer.of(user.id, on: request.db)
    }
}
