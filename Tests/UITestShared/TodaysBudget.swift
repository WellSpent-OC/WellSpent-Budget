// What the Mac's and the iPhone's UI tests share for the money wheel: what
// the shared code says a budget, or a group of them, shows today. Each
// platform's project compiles this folder into its own UI test bundle.
import Foundation
import WellSpentAppCore
import WellSpentCrypto
import WellSpentModel

/// What the shared code says a budget shows today, `limit` a month with
/// `spent` spent from it, in cents. The app reads its budgets for today in
/// this device's calendar, and so does this, so a test expects exactly what
/// the app draws without typing a word or an amount in. `now` is today,
/// unless the test asked the app to count another day of this month as today
/// (`PinnedDay`).
struct TodaysBudget {
    let summary: BudgetSummary
    /// The day the app counts as today.
    let now: Date

    init(_ name: String = "", limit: Int, spent: Int, on now: Date = Date()) {
        let budget = Budget(groupID: GroupID(), name: name, limit: Money(minorUnits: limit))
        summary = BudgetSummary(budget: budget, period: budget.reset.period(containing: now),
                                spent: Money(minorUnits: spent), transactionCount: spent == 0 ? 0 : 1)
        self.now = now
    }

    var wheel: MoneyWheel { MoneyWheel(budget: summary, now: now) }
    var row: RowFill { RowFill(summary) }

    /// The pace words under the figures, for someone who may change budgets.
    var pace: BudgetPace? { BudgetPace(wheel: wheel, budgetName: summary.budget.name, mayEdit: true) }

    /// The money of a group holding these budgets, as its page shows it, on
    /// the day they count as today.
    static func group(_ name: String, _ budgets: [TodaysBudget]) -> GroupMoney? {
        GroupMoney(group: BudgetGroup(name: name), summaries: budgets.map(\.summary),
                   now: budgets.first?.now ?? Date())
    }
}
