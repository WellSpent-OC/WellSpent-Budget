import Foundation
import WellSpentExtensions

/// An item displayed in the Extensions Catalog.
public struct ExtensionCatalogItem: Identifiable, Sendable, Equatable {
    public enum Status: String, Sendable, Equatable {
        case available = "Available"
        case comingSoon = "Coming later"
        case idea = "Idea"
    }

    public let id: String
    public let name: String
    public let summary: String
    public let pricing: String
    public let status: Status
    public let platforms: [String]
    public let isInstalled: Bool

    public init(
        id: String,
        name: String,
        summary: String,
        pricing: String,
        status: Status,
        platforms: [String],
        isInstalled: Bool
    ) {
        self.id = id
        self.name = name
        self.summary = summary
        self.pricing = pricing
        self.status = status
        self.platforms = platforms
        self.isInstalled = isInstalled
    }
}

/// Catalog of extensions available or planned for WellSpent.
public enum ExtensionCatalog {
    public static func items(
        platform: String = "linux",
        isWarTableEnabled: Bool = true,
        isRunwayEnabled: Bool = true
    ) -> [ExtensionCatalogItem] {
        var items: [ExtensionCatalogItem] = []
        if isWarTableEnabled {
            items.append(
                ExtensionCatalogItem(
                    id: "wellspent.wartable",
                    name: "WarTable",
                    summary: "AI agent chat and workroom: connect agents, collaborate in rooms, and review tasks.",
                    pricing: "Free, MIT license",
                    status: .available,
                    platforms: ["linux"],
                    isInstalled: true
                )
            )
        }
        items.append(
            ExtensionCatalogItem(
                id: "wellspent.properties",
                name: "Runway (Properties)",
                summary: "For rental houses: cash flow, PriceLabs bookings, break-even runway, and proforma scenarios.",
                pricing: "$5 a house a month, billed yearly",
                status: isRunwayEnabled ? .available : .comingSoon,
                platforms: ["macos", "ios", "linux"],
                isInstalled: false
            )
        )
        items.append(contentsOf: [
            ExtensionCatalogItem(
                id: "wellspent.settle",
                name: "Settle",
                summary: "Match logged spending with bank lines as they clear.",
                pricing: "Price to come",
                status: .comingSoon,
                platforms: ["macos", "ios", "linux"],
                isInstalled: false
            ),
            ExtensionCatalogItem(
                id: "wellspent.debt",
                name: "Debt in one place",
                summary: "Every debt with its interest rate, monthly cost, and payoff order.",
                pricing: "Price to come",
                status: .comingSoon,
                platforms: ["macos", "ios", "linux"],
                isInstalled: false
            ),
            ExtensionCatalogItem(
                id: "wellspent.business",
                name: "Business tools",
                summary: "Invoicing and expense tracking for business owners.",
                pricing: "Idea",
                status: .idea,
                platforms: ["macos", "ios", "linux"],
                isInstalled: false
            ),
            ExtensionCatalogItem(
                id: "wellspent.tasks",
                name: "Tasks",
                summary: "To-dos tied to budget lines and recurring bills.",
                pricing: "Idea",
                status: .idea,
                platforms: ["macos", "ios", "linux"],
                isInstalled: false
            )
        ])
        return items
    }

    public static func items(platform: String = "linux", features: FeatureFlags) -> [ExtensionCatalogItem] {
        items(
            platform: platform,
            isWarTableEnabled: features.isWarTableEnabled,
            isRunwayEnabled: features.isRunwayEnabled
        )
    }
}

