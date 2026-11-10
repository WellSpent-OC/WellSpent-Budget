#if canImport(SwiftUI)
import Foundation
import WellSpentPlans

/// The names UI tests find the plan screens' controls by, on the Mac and iPhone.
public extension AccessibilityID {
    static let planCard = "plan.card"
    static let planCardTitle = "plan.card.title"
    static let planCardAction = "plan.card.action"
    static let planChangeWhatStaysOpen = "plan.changeWhatStaysOpen"
    static let planRestore = "plan.restore"
    static let planChoices = "plan.choices"
    static let planMonthly = "plan.period.monthly"
    static let planYearly = "plan.period.yearly"
    static func planRow(_ tier: PaidTier) -> String { "plan.row.\(tier.rawValue)" }
    static let planBuy = "plan.buy"
    static let planNotNow = "plan.notNow"
    static let planEmailUs = "plan.emailUs"
    static let planStatus = "plan.status"

    // MARK: Pick what stays open
    static let pickSheet = "pick.sheet"
    static func pickGroup(_ id: UUID) -> String { "pick.group.\(id.uuidString)" }
    static func pickPerson(_ id: UUID) -> String { "pick.person.\(id.uuidString)" }
    static func pickProperty(_ id: UUID) -> String { "pick.property.\(id.uuidString)" }
    static let pickKeep = "pick.keep"
    static let pickSkip = "pick.skip"

    // MARK: Locked
    static let lockedCard = "locked.card"
    static let lockedTitle = "locked.title"
    static func lockedAction(_ action: LockedScreen.Action) -> String { "locked.action.\(action)" }
    /// The "Locked" mark beside a locked group, person or property in a list.
    static func lockedMark(_ id: UUID) -> String { "locked.mark.\(id.uuidString)" }
}
#endif
