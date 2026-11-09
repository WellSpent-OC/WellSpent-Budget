import Foundation

/// A product as the store sells it here, with its price in the person's own
/// currency, worded by the store.
public struct StoreOffer: Equatable, Sendable {
    public let product: PlanProduct
    public let displayPrice: String

    public init(product: PlanProduct, displayPrice: String) {
        self.product = product
        self.displayPrice = displayPrice
    }
}

/// A purchase the store reports. `signed` is the store's signed record of it,
/// which only the server checks.
public struct StoreTransaction: Equatable, Sendable {
    public let id: UInt64
    public let productID: String
    public let signed: String

    public init(id: UInt64, productID: String, signed: String) {
        self.id = id
        self.productID = productID
        self.signed = signed
    }
}

/// How a purchase ended on the store's side.
public enum PurchaseResult: Equatable, Sendable {
    case purchased(StoreTransaction)
    /// Waiting for someone else's approval, as under Ask to Buy.
    case pending
    /// The person closed the store's sheet.
    case cancelled
}

/// The app's store: Apple on the Mac and iPhone. Linux has none and sends
/// people to the website.
public protocol PlanStore: Sendable {
    /// The products this storefront sells, with their prices.
    func offers() async throws -> [StoreOffer]
    /// Shows the store's purchase sheet, tagged with the account's token.
    func purchase(_ product: PlanProduct, accountToken: UUID) async throws -> PurchaseResult
    /// The subscriptions this store account holds now.
    func current() async -> [StoreTransaction]
    /// Asks the store to bring its records up to date, for Restore Purchases.
    func sync() async throws
    /// Tells the store the app is done with a purchase. Only after the server
    /// has accepted it.
    func finish(_ transactionID: UInt64) async
    /// Purchases that arrive while the app runs: a renewal, an approval under
    /// Ask to Buy, a purchase on another device.
    func updates() -> AsyncStream<StoreTransaction>
    /// The storefront's country, "USA". Nil when the store can't say.
    func storefrontCountry() async -> String?
}

/// The two things the server does for purchases.
public protocol PlanService: Sendable {
    /// What plan this account has.
    func plan() async throws -> PlanAnswer
    /// Hands the server Apple's signed record of a purchase. The server checks
    /// it and answers with the account's plan as it now stands.
    func submitApple(signedTransaction: String) async throws -> PlanAnswer
}

/// Why the server refused a purchase, or couldn't be asked.
public enum PlanServiceError: Error, Equatable, Sendable {
    /// The account already pays through the website.
    case paddlePlanLive
    /// The signed record didn't check out.
    case notGenuine
    /// No answer from the server.
    case unreachable
}

/// Keeps the last answer, so the right screens show with no connection.
public protocol PlanCache: Sendable {
    func load() -> PlanAnswer?
    func save(_ answer: PlanAnswer)
}
