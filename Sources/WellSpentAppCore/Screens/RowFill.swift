import Foundation
import WellSpentModel

/// A budget's row in the list, drawn as its own bar: filled from the left as
/// far as the budget is used this period. Over its limit, it fills all the
/// way in the over colour and says how far over, so the colour is never the
/// only sign. What it says lives here, and each app only draws it.
public struct RowFill: Equatable, Sendable {
    /// How far the fill reaches, 0 to 1.
    public let share: Double
    public let isOver: Bool
    /// At the right of the row: "$375.00", or "$15.00 over".
    public let amount: String
    /// The row's value for a screen reader: "25 percent used", or "Over budget".
    public let spokenValue: String

    public init(_ summary: BudgetSummary) {
        isOver = summary.isOverspent
        // A budget with nothing to spend that is spent from is over too, so
        // it fills all the way as well.
        share = isOver ? 1 : summary.fraction
        amount = isOver ? Words.over(summary.remaining.magnitude.display) : summary.remaining.display
        spokenValue = isOver ? Words.overBudget : Words.used(Self.percentUsed(summary))
    }

    /// The fill's colour: rowOver when over, rowUsed otherwise.
    public var fillColor: ColorPair { isOver ? PaletteValues.rowOver : PaletteValues.rowUsed }

    /// Whole percent of the limit spent, rounded down, from 0 to 100. A
    /// limit of nothing has used nothing of it.
    private static func percentUsed(_ summary: BudgetSummary) -> Int {
        let limit = summary.budget.limit.minorUnits
        guard limit > 0 else { return 0 }
        return min(max(summary.spent.minorUnits * 100 / limit, 0), 100)
    }

    public enum Words {
        /// "$15.00 over".
        public static func over(_ amount: String) -> String { "\(amount) over" }
        /// Spoken only: "25 percent used".
        public static func used(_ percent: Int) -> String { "\(percent) percent used" }
        /// Spoken only.
        public static let overBudget = "Over budget"
    }
}
