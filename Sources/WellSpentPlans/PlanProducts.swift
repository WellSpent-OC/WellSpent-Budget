import Foundation

/// A plan an account can be on. Free needs no purchase.
public enum PlanTier: String, Codable, Sendable, CaseIterable {
    case free, starter, growth, portfolio
}

/// A plan that costs money, and so has products in the stores.
public enum PaidTier: String, Codable, Sendable, CaseIterable {
    case starter, growth, portfolio

    public var tier: PlanTier {
        switch self {
        case .starter: .starter
        case .growth: .growth
        case .portfolio: .portfolio
        }
    }
}

/// How often a paid plan renews.
public enum BillingPeriod: String, Codable, Sendable, CaseIterable {
    case monthly, yearly
}

/// One of the six products in the App Store's "WellSpent Pro" subscription
/// group. The ids are fixed for good: Apple never lets a product id be used
/// twice, even after the product is deleted.
public struct PlanProduct: Hashable, Sendable {
    public let tier: PaidTier
    public let period: BillingPeriod

    public init(_ tier: PaidTier, _ period: BillingPeriod) {
        self.tier = tier
        self.period = period
    }

    /// Every product, smallest plan first, monthly before yearly.
    public static let all: [PlanProduct] = PaidTier.allCases.flatMap { tier in
        BillingPeriod.allCases.map { PlanProduct(tier, $0) }
    }

    static let prefix = "app.wellspent.pro."

    /// The App Store's product id, "app.wellspent.pro.starter.monthly".
    public var id: String { "\(Self.prefix)\(tier.rawValue).\(period.rawValue)" }

    /// The product with this App Store id. Nil for any id that isn't one of ours.
    public init?(id: String) {
        guard let found = Self.all.first(where: { $0.id == id }) else { return nil }
        self = found
    }
}
