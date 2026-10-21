import Foundation
import WellSpentCrypto
import WellSpentModel

/// A group's money this month: the MONEY section of its page on a desktop,
/// and Home's card on a phone. Its wheel adds up every budget in the group,
/// hidden or not, each one's spending in its own current period. It counts
/// budgets and what is spent from them, nothing else.
public struct GroupMoney: Equatable, Sendable {
    public let groupID: GroupID
    public let groupName: String
    public let wheel: MoneyWheel
    /// The wheel's day in the calendar month, which a group always has.
    private let day: PeriodDay

    /// Nil when the group holds no budgets.
    ///
    /// Only budgets in the first budget's currency are added up, since money
    /// in two currencies cannot be. The day and the tick follow the calendar
    /// month: every budget the apps make resets on the 1st, so each budget's
    /// period agrees with it.
    public init?(group: BudgetGroup, summaries: [BudgetSummary], now: Date = Date(),
                 calendar: Calendar = .autoupdatingCurrent) {
        let month = ResetSchedule.firstOfMonth.period(containing: now, calendar: calendar)
        guard let currency = summaries.first?.budget.limit.currency,
              let day = PeriodDay(period: month, now: now, calendar: calendar) else { return nil }
        let counted = summaries.filter { $0.budget.limit.currency == currency }
        groupID = group.id
        groupName = group.name
        wheel = MoneyWheel(scope: .group, budgeted: Money.total(counted.map(\.budget.limit), currency: currency),
                           spent: Money.total(counted.map(\.spent), currency: currency), day: day)
        self.day = day
    }

    /// "Household · October".
    public var title: String { Words.title(groupName, day.month) }
    /// Under the figures: "Day 18 of 31. Every budget in Household, added up."
    public var note: String { Words.note(day.shortLine, groupName) }
    /// On Home's card: "Spent $666 of $1,300 budgeted".
    public var spentLine: String { Words.spentLine(wheel.spent.wholeDisplay, wheel.budgeted.wholeDisplay) }

    public enum Words {
        /// The section's heading, drawn in capitals as "MONEY", like "People".
        public static let section = "Money"
        /// Above the figures in the section.
        public static let card = "This month"
        /// "Household · October".
        public static func title(_ group: String, _ month: String) -> String { "\(group) \u{00B7} \(month)" }
        /// "Day 18 of 31. Every budget in Household, added up."
        public static func note(_ day: String, _ group: String) -> String {
            "\(day). Every budget in \(group), added up."
        }
        /// "Spent $666 of $1,300 budgeted".
        public static func spentLine(_ spent: String, _ budgeted: String) -> String {
            "Spent \(spent) of \(budgeted) budgeted"
        }
    }
}
