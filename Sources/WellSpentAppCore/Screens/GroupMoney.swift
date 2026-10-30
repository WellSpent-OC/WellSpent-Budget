import Foundation
import WellSpentCrypto
import WellSpentModel

/// A group's money this month: the MONEY section of its page on every platform. Its wheel adds up every budget in the group,
/// hidden or not, each one's spending in its own current period, and income
/// refills it toward full. Borrowed money and savings draws never refill it:
/// each is named on a line of its own.
public struct GroupMoney: Equatable, Sendable {
    public let groupID: GroupID
    public let groupName: String
    public let wheel: MoneyWheel
    /// Borrowed across the group's budgets this month.
    public let borrowed: Money
    /// Taken from savings across the group's budgets this month.
    public let fromSavings: Money
    /// Income across the group's budgets this month.
    public var moneyIn: Money { wheel.moneyIn }
    /// Money in less money spent. For a house, its cash flow this month.
    public var cashFlow: Money { wheel.cashFlow }
    /// The wheel's day in the calendar month, which a group always has.
    private let day: PeriodDay

    /// Nil when the group holds no budgets.
    ///
    /// Only budgets in the first budget's currency are added up, since money
    /// in two currencies cannot be. The day and the tick follow the calendar
    /// month: every budget the apps make resets on the 1st, so each budget's
    /// period agrees with it.
    public init?(group: BudgetGroup, summaries: [BudgetSummary], now: Date = Date(),
                 calendar: Calendar = AppLocale.calendar) {
        let month = ResetSchedule.firstOfMonth.period(containing: now, calendar: calendar)
        guard let currency = summaries.first?.budget.limit.currency,
              let day = PeriodDay(period: month, now: now, calendar: calendar) else { return nil }
        let counted = summaries.filter { $0.budget.limit.currency == currency }
        groupID = group.id
        groupName = group.name
        wheel = MoneyWheel(scope: .group, budgeted: Money.total(counted.map(\.budget.limit), currency: currency),
                           spent: Money.total(counted.map(\.spent), currency: currency), day: day,
                           moneyIn: Money.total(counted.map(\.moneyIn), currency: currency))
        borrowed = Money.total(counted.map(\.borrowed), currency: currency)
        fromSavings = Money.total(counted.map(\.fromSavings), currency: currency)
        self.day = day
    }

    /// "Household · October".
    public var title: String { Words.title(groupName, day.month) }
    /// Under the figures: "Day 18 of 31. Every budget in Household, added
    /// up.", ending "added up, and money in." once there is money in.
    public var note: String {
        wheel.hasMoneyIn ? Words.noteWithMoneyIn(day.shortLine, groupName) : Words.note(day.shortLine, groupName)
    }
    /// Under the figures, money that came in without refilling the wheel:
    /// "$500.00 borrowed this month", then "$300.00 from savings this month".
    public var otherMoneyLines: [String] {
        var lines: [String] = []
        if borrowed.minorUnits > 0 { lines.append(Words.borrowed(borrowed.display)) }
        if fromSavings.minorUnits > 0 { lines.append(Words.fromSavings(fromSavings.display)) }
        return lines
    }
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
        /// "Day 18 of 31. Every budget in Household, added up, and money in."
        public static func noteWithMoneyIn(_ day: String, _ group: String) -> String {
            "\(day). Every budget in \(group), added up, and money in."
        }
        /// "$500.00 borrowed this month".
        public static func borrowed(_ amount: String) -> String { "\(amount) borrowed this month" }
        /// "$300.00 from savings this month".
        public static func fromSavings(_ amount: String) -> String { "\(amount) from savings this month" }
        /// "Spent $666 of $1,300 budgeted".
        public static func spentLine(_ spent: String, _ budgeted: String) -> String {
            "Spent \(spent) of \(budgeted) budgeted"
        }
    }
}
