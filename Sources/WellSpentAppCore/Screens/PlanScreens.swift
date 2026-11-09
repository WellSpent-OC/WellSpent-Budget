import Foundation
import WellSpentPlans

/// Where this app takes payment: Apple in the app on the Mac and iPhone, the
/// website on Linux.
public enum PlanPlatform: Equatable, Sendable {
    case appleStore
    case website
}

/// Each paid plan's price as people see it. On the Mac and iPhone the store's
/// own words replace these, so the price is in the person's currency.
public struct PlanPrices: Equatable, Sendable {
    public var monthly: [PaidTier: String]
    public var yearly: [PaidTier: String]

    public static let us = PlanPrices(
        monthly: [.starter: "$19", .growth: "$49", .portfolio: "$99"],
        yearly: [.starter: "$190", .growth: "$490", .portfolio: "$990"])

    public init(monthly: [PaidTier: String], yearly: [PaidTier: String]) {
        self.monthly = monthly
        self.yearly = yearly
    }

    /// The US prices, with each one the store offers in its place.
    public init(offers: [StoreOffer]) {
        self = .us
        for offer in offers {
            switch offer.product.period {
            case .monthly: monthly[offer.product.tier] = offer.displayPrice
            case .yearly: yearly[offer.product.tier] = offer.displayPrice
            }
        }
    }

    public func price(_ tier: PaidTier, _ period: BillingPeriod) -> String {
        (period == .monthly ? monthly[tier] : yearly[tier]) ?? ""
    }
}

/// The words about plans, shared by every app.
public enum PlanWording {
    public static let freeShort = "1 property, sync on every device, and 1 group shared with 1 person."
    public static let freeForever = "Free forever. No card, no end date."
    public static let everyFeature = "Every paid plan has every feature: PriceLabs income sync, the lodging tax "
        + "ledger, Schedule E, the portfolio view, and as many groups and people as you like. Plans differ only "
        + "in how many properties."
    public static let peopleFree = "The people you invite never pay. They sign in with an email code."
    public static let moreThan15 = "More than 15 properties?"
    public static let emailUs = "Email us"
    public static let appleFinePrint = "Billed to your Apple account. It renews until you cancel in your Apple "
        + "account settings."
    public static let websiteFinePrint = "On Linux you pay on our website. The plan works on every device you "
        + "sign in on."
    public static let nothingDeleted = "Nothing was deleted."
    public static let managedOnApple = "Bought through Apple, so it's managed on your Mac or iPhone."
    /// Everything keeps working this long after a renewal fails.
    public static let graceDays = 16

    public static func name(_ tier: PlanTier) -> String {
        switch tier {
        case .free: "Free"
        case .starter: "Starter"
        case .growth: "Growth"
        case .portfolio: "Portfolio"
        }
    }

    public static func properties(_ count: Int) -> String {
        count == 1 ? "1 property" : "\(count) properties"
    }

    /// "A, B and C".
    public static func list(_ items: [String]) -> String {
        guard items.count > 1 else { return items.first ?? "" }
        return items.dropLast().joined(separator: ", ") + " and " + items.last!
    }

    public static func per(_ period: BillingPeriod) -> String {
        period == .monthly ? "a month" : "a year"
    }

    /// "Dec 9", or "Nov 9, 2027" when it isn't this year.
    public static func day(_ date: Date, now: Date, calendar: Calendar) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US")
        formatter.timeZone = calendar.timeZone
        let sameYear = calendar.component(.year, from: date) == calendar.component(.year, from: now)
        formatter.dateFormat = sameYear ? "MMM d" : "MMM d, yyyy"
        return formatter.string(from: date)
    }
}

/// The one plan card on Account, in each state the server can answer.
public struct PlanCardScreen: Equatable, Sendable {
    public enum Tone: Equatable, Sendable {
        case plain
        /// A payment is failing.
        case warning
    }

    public enum Action: Equatable, Sendable {
        case seePlans
        case seePlansOnWebsite
        case changePlan
        case keepPlan
        case openAppleSettings
        case manageOnWebsite

        public var title: String {
            switch self {
            case .seePlans: "See Plans"
            case .seePlansOnWebsite: "See Plans on wellspent.space"
            case .changePlan: "Change Plan"
            case .keepPlan: "Keep My Plan"
            case .openAppleSettings: "Open Apple Settings"
            case .manageOnWebsite: "Manage on wellspent.space"
            }
        }
    }

    public let title: String
    /// The plan's name beside the title, when the title doesn't already say it.
    public let badge: String?
    public let lines: [String]
    /// Nil when this app can't change the plan, as on Linux for an Apple plan.
    public let action: Action?
    /// Whether the action is the card's main button.
    public let actionIsPrimary: Bool
    public let tone: Tone
    /// "Change what stays open", under the card once a paid plan has ended.
    public let showsChangeWhatStaysOpen: Bool

    /// `openNames` are the names of what the answer's `open` keeps open, in
    /// order: the group, the properties, the person. The server sends ids only.
    public init(answer: PlanAnswer, platform: PlanPlatform, prices: PlanPrices = .us, openNames: [String] = [],
                now: Date = Date(), calendar: Calendar = AppLocale.calendar) {
        let day = { (date: Date?) in date.map { PlanWording.day($0, now: now, calendar: calendar) } ?? "" }
        let tierName = PlanWording.name(answer.tier)
        let paid = PaidTier(rawValue: answer.tier.rawValue)
        let period: BillingPeriod = answer.period == .yearly ? .yearly : .monthly
        let apple = answer.source == .apple
        // An Apple plan can only be changed in an app Apple sells through.
        let appleElsewhere = apple && platform == .website
        let store = apple ? "Apple" : "we"
        let storeCap = apple ? "Apple" : "We"
        let fixPayment = apple
            ? "Update your payment in your Apple account settings"
                + (platform == .website ? ", on your Mac or iPhone." : ".")
            : "Update your payment on wellspent.space."
        let payAction: Action? = apple ? (appleElsewhere ? nil : .openAppleSettings) : .manageOnWebsite

        var title = tierName
        var badge: String? = nil
        var lines: [String] = []
        var action: Action?
        var primary = true
        var tone = Tone.plain
        var changeWhatStaysOpen = false
        let locked = Self.locked(answer.locked)

        switch (answer.state, paid) {
        case (.free, _) where answer.lastPlan != nil, (_, nil) where answer.lastPlan != nil:
            let last = answer.lastPlan!
            badge = "Free"
            let until = "\(locked) locked until you pick a plan. \(PlanWording.nothingDeleted)"
            if last.reason == .refunded {
                title = "Refunded"
                lines = ["Your \(day(last.endedOn)) payment was refunded, so you're on the free plan.", until]
            } else {
                title = "Free plan"
                lines = ["Your \(PlanWording.name(last.tier)) plan ended \(day(last.endedOn)).", until]
                if !openNames.isEmpty { lines.append("Open now: \(PlanWording.list(openNames)).") }
                changeWhatStaysOpen = true
            }
            action = platform == .appleStore ? .seePlans : .seePlansOnWebsite
            primary = false
        case (.free, _), (_, nil):
            title = "Free plan"
            badge = "Free"
            lines = [PlanWording.freeShort, PlanWording.freeForever]
            action = platform == .appleStore ? .seePlans : .seePlansOnWebsite
        case (.active, let tier?):
            title = "\(tierName) · \(prices.price(tier, period)) \(PlanWording.per(period))"
            lines = [Self.usage(answer)]
            let renews = "Renews \(day(answer.paidUntil))."
            switch (apple, appleElsewhere) {
            case (true, false):
                lines.append("\(renews) Bought through Apple.")
                action = .changePlan
            case (true, true):
                lines += [renews, PlanWording.managedOnApple]
            default:
                lines.append("\(renews) Bought on wellspent.space.")
                action = .manageOnWebsite
            }
            primary = false
        case (.grace, _):
            title = apple ? "Apple couldn't renew your plan" : "Your payment didn't go through"
            badge = tierName
            // The server sends the store's own grace end; the usual 16 days only if it hasn't.
            let graceEnd = answer.graceUntil ?? answer.paidUntil.flatMap {
                calendar.date(byAdding: .day, value: PlanWording.graceDays, to: $0)
            }
            lines = ["Everything keeps working for \(PlanWording.graceDays) days, until \(day(graceEnd)), "
                        + "while \(store) \(apple ? "tries" : "try") again.", fixPayment]
            action = payAction
            tone = .warning
        case (.billingProblem, _):
            title = "\(tierName) is paused"
            badge = "Free"
            lines = ["\(storeCap) still couldn't take payment, so you're on the free plan for now.",
                     "\(locked) locked until the payment goes through. \(PlanWording.nothingDeleted)"]
            if appleElsewhere { lines.append(PlanWording.managedOnApple) }
            action = payAction
            tone = .warning
        case (.canceled, _):
            let end = day(answer.paidUntil)
            title = "\(tierName) · ends \(end)"
            lines = ["You canceled. Everything works until \(end), then you move to the free plan.",
                     "Nothing is deleted."]
            if appleElsewhere { lines.append(PlanWording.managedOnApple) }
            action = apple ? (appleElsewhere ? nil : .keepPlan) : .manageOnWebsite
        }

        self.title = title
        self.badge = badge
        self.lines = lines
        self.action = action
        actionIsPrimary = action != nil && primary
        self.tone = tone
        showsChangeWhatStaysOpen = changeWhatStaysOpen
    }

    /// "2 properties, 1 group and 2 people are", or "Anything past the free
    /// plan is" when the answer doesn't say what.
    static func locked(_ locked: PlanAnswer.Locked?) -> String {
        guard let locked else { return "Anything past the free plan is" }
        var parts: [String] = []
        if !locked.houseIDs.isEmpty { parts.append(PlanWording.properties(locked.houseIDs.count)) }
        if !locked.groupIDs.isEmpty { parts.append(locked.groupIDs.count == 1 ? "1 group" : "\(locked.groupIDs.count) groups") }
        if !locked.people.isEmpty { parts.append(locked.people.count == 1 ? "1 person" : "\(locked.people.count) people") }
        guard !parts.isEmpty else { return "Anything past the free plan is" }
        let one = parts.count == 1 && (parts[0].hasPrefix("1 ") )
        return "\(PlanWording.list(parts)) \(one ? "is" : "are")"
    }

    /// "Up to 5 properties. You have 3."
    static func usage(_ answer: PlanAnswer) -> String {
        let limit = answer.limits.properties.map { "Up to \(PlanWording.properties($0))." } ?? "Any number of properties."
        return "\(limit) You have \(answer.used.properties ?? 0)."
    }
}

/// Choose a plan: monthly or yearly, and the three sizes.
public struct PlanChoicesScreen: Equatable, Sendable {
    public struct Row: Equatable, Sendable {
        public let tier: PaidTier
        public let name: String
        public let price: String
        /// " a month" or " a year", after the price.
        public let unit: String
        public let detail: String
        public let isCurrent: Bool
    }

    public let intro: String
    public let monthlyLabel = "Monthly"
    public let yearlyLabel = "Yearly"
    public let yearlyNote = "2 months free"
    public let rows: [Row]
    public let selected: PaidTier
    public let everyFeature = PlanWording.everyFeature
    public let peopleFree = PlanWording.peopleFree
    /// "More than 15 properties? Email us." Nil where Apple's rules don't
    /// allow it: in the app, outside the US.
    public let moreThan15: String?
    public let finePrint: String
    public let showsTermsAndPrivacy: Bool
    public let showsRestore: Bool
    public let notNow = "Not Now"
    public let buy: String

    public init(answer: PlanAnswer?, platform: PlanPlatform, period: BillingPeriod, selected: PaidTier? = nil,
                prices: PlanPrices = .us, storefrontIsUS: Bool) {
        let used = answer?.used.properties ?? 0
        let current = answer.flatMap { $0.state == .free ? nil : PaidTier(rawValue: $0.tier.rawValue) }
        let fits = PaidTier.allCases.first { Self.limit($0) >= used } ?? .portfolio
        let chosen = selected ?? current ?? fits

        if let answer, let current {
            intro = "You're on \(PlanWording.name(current.tier)): up to "
                + "\(PlanWording.properties(answer.limits.properties ?? Self.limit(current)))."
        } else {
            intro = "You're on the free plan: \(PlanWording.freeShort)"
        }
        rows = PaidTier.allCases.map { tier in
            let yearly = prices.price(tier, .yearly)
            return Row(tier: tier, name: PlanWording.name(tier.tier), price: prices.price(tier, period),
                       unit: " \(PlanWording.per(period))",
                       detail: "Up to \(PlanWording.properties(Self.limit(tier)))"
                        + (period == .monthly ? " · or \(yearly) a year" : ""),
                       isCurrent: tier == current)
        }
        self.selected = chosen
        let emailAllowed = platform == .website || storefrontIsUS
        moreThan15 = emailAllowed ? "\(PlanWording.moreThan15) \(PlanWording.emailUs)." : nil
        finePrint = platform == .appleStore ? PlanWording.appleFinePrint : PlanWording.websiteFinePrint
        showsTermsAndPrivacy = platform == .appleStore
        showsRestore = platform == .appleStore
        let period = period == .monthly ? "Month" : "Year"
        buy = platform == .appleStore
            ? "Subscribe for \(prices.price(chosen, period == "Month" ? .monthly : .yearly)) a \(period)"
            : "Continue on wellspent.space"
    }

    /// The store product for what's chosen.
    public func product(_ period: BillingPeriod) -> PlanProduct { PlanProduct(selected, period) }

    /// How many properties each paid plan allows. The server's answer is the
    /// judge; this only words the choices.
    static func limit(_ tier: PaidTier) -> Int {
        switch tier {
        case .starter: 2
        case .growth: 5
        case .portfolio: 15
        }
    }
}
