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
/// the app draws without typing a word or an amount in.
///
/// With `pinnedDay`, today is that day of this month, as the app reads it
/// when the test launches it with `Workspace.pinnedDayVariable` set.
struct TodaysBudget {
    let summary: BudgetSummary
    /// Today, as the app under test reads it for its wheels.
    let today: Date

    init(_ name: String = "", limit: Int, spent: Int, pinnedDay: Int? = nil) {
        let budget = Budget(groupID: GroupID(), name: name, limit: Money(minorUnits: limit))
        summary = BudgetSummary(budget: budget, period: budget.reset.period(containing: Date()),
                                spent: Money(minorUnits: spent), transactionCount: spent == 0 ? 0 : 1)
        today = Workspace.today(pinnedTo: pinnedDay)
    }

    var wheel: MoneyWheel { MoneyWheel(budget: summary, now: today) }
    var row: RowFill { RowFill(summary) }

    /// The pace words under the figures, for someone who may change budgets.
    var pace: BudgetPace? { BudgetPace(wheel: wheel, budgetName: summary.budget.name, mayEdit: true) }

    /// The money of a group holding these budgets, as its page shows it.
    static func group(_ name: String, _ budgets: [TodaysBudget]) -> GroupMoney? {
        GroupMoney(group: BudgetGroup(name: name), summaries: budgets.map(\.summary),
                   now: budgets.first?.today ?? Date())
    }
}
