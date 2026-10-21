import Foundation
import WellSpentModel

/// The pace words under a budget's wheel, when there are any.
///
/// Spending faster than an even pace says when the money runs out, to
/// everyone. In the period's last week, more left than expected asks whether
/// to keep the budget or lower it, and only of someone who may change it. A
/// budget on pace, over its limit, with nothing left, or with no period says
/// nothing, and so does a group's wheel.
public struct BudgetPace: Equatable, Sendable {
    public enum Kind: Equatable, Sendable { case overPace, underPace }

    public let kind: Kind
    public let text: String
    /// Whether Edit Budget shows beside the words.
    public let offersEdit: Bool

    /// `mayEdit`: whether this person may change budgets in the group.
    ///
    /// With nothing left, the money has run out already, so there is no day
    /// ahead for it to run out on. Rent paid in full on the 1st would
    /// otherwise run out "around" today, on every day of the month.
    public init?(wheel: MoneyWheel, budgetName: String, mayEdit: Bool, calendar: Calendar = AppLocale.calendar) {
        guard wheel.scope == .budget, !wheel.isOver, wheel.left.minorUnits > 0, let day = wheel.day,
              let expected = wheel.expectedLeft else { return nil }
        let left = wheel.left
        if left < expected {
            // The day the money runs out at today's pace, counted from the
            // period's first day. Less is left than expected only once
            // something is spent, so this never divides by nothing.
            let runsOut = wheel.budgeted.minorUnits * day.day / wheel.spent.minorUnits
            let date = calendar.date(byAdding: .day, value: runsOut - 1, to: day.start) ?? day.start
            let style = Date.FormatStyle(locale: calendar.locale ?? AppLocale.current, calendar: calendar,
                                         timeZone: calendar.timeZone)
            kind = .overPace
            text = Words.runsOut(budgetName, around: date.formatted(style.month(.abbreviated).day()),
                                 daysEarly: max(day.days - runsOut, 1))
            offersEdit = mayEdit
        } else if left > expected, day.isLastWeek, mayEdit, (left - expected).wholeUnits >= 1 {
            kind = .underPace
            text = Words.moreLeft((left - expected).wholeDisplay)
            offersEdit = true
        } else {
            return nil
        }
    }

    public enum Words {
        /// "At this pace, Gas runs out around Oct 26, five days early."
        public static func runsOut(_ budget: String, around date: String, daysEarly: Int) -> String {
            "At this pace, \(budget) runs out around \(date), \(days(daysEarly)) early."
        }

        /// "one day", "five days" or "12 days": one to nine in words.
        public static func days(_ count: Int) -> String {
            let words = ["one", "two", "three", "four", "five", "six", "seven", "eight", "nine"]
            guard (1 ... 9).contains(count) else { return "\(count) days" }
            return count == 1 ? "one day" : "\(words[count - 1]) days"
        }

        /// "$25 more left than expected by today. Keep this budget, or lower it for next month?"
        public static func moreLeft(_ amount: String) -> String {
            "\(amount) more left than expected by today. Keep this budget, or lower it for next month?"
        }

        /// Beside the pace words. A phone's buttons never end in "…".
        public static func editBudget(onPhone: Bool) -> String { onPhone ? "Edit Budget" : "Edit Budget…" }
    }
}
