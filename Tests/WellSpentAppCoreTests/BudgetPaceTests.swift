import Testing
import Foundation
import WellSpentAppCore
import WellSpentCrypto
import WellSpentModel

/// The pace words under a budget's wheel. Spending faster than an even pace
/// says when the money runs out, to everyone. In the month's last week, more
/// left than expected asks whether to lower the budget, and only of someone
/// who may change it.
@Suite("Budget pace")
struct BudgetPaceTests {
    private let calendar = WheelCalendar.calendar

    /// The pace words for `name`, `limit` a month with `spent` spent, on the
    /// given day of October 2026. Cents.
    private func pace(_ name: String = "Groceries", limit: Int, spent: Int, october day: Int,
                      mayEdit: Bool = true) -> BudgetPace? {
        let now = WheelCalendar.date(2026, 10, day)
        let wheel = MoneyWheel(budget: WheelCalendar.summary(name, limit: limit, spent: spent, on: now),
                               now: now, calendar: calendar)
        return BudgetPace(wheel: wheel, budgetName: name, mayEdit: mayEdit, calendar: calendar)
    }

    // Scenario WHEEL-08
    @Test func spendingFasterThanAnEvenPaceSaysWhenTheMoneyRunsOut() throws {
        let gas = try #require(pace("Gas", limit: 18_000, spent: 12_200, october: 18))
        #expect(gas.kind == .overPace)
        #expect(gas.text == "At this pace, Gas runs out around Oct 26, five days early.")
        #expect(gas.offersEdit, "Robin may change budgets")

        let atAdd = try #require(pace("Gas", limit: 18_000, spent: 12_200, october: 18, mayEdit: false))
        #expect(atAdd.text == gas.text, "Leslie, at Add, sees the same words")
        #expect(!atAdd.offersEdit, "with no button")
    }

    // Scenario WHEEL-08
    @Test func theDaysEarlyAreTheDaysLeftAfterTheMoneyRunsOut() throws {
        let oneDay = try #require(pace("Gas", limit: 31_000, spent: 15_500, october: 15))
        #expect(oneDay.text == "At this pace, Gas runs out around Oct 30, one day early.")
        let fifteenDays = try #require(pace("Gas", limit: 31_000, spent: 19_000, october: 10))
        #expect(fifteenDays.text == "At this pace, Gas runs out around Oct 16, 15 days early.")
    }

    @Test func oneToNineDaysAreWrittenInWords() {
        #expect(BudgetPace.Words.days(1) == "one day")
        #expect(BudgetPace.Words.days(2) == "two days")
        #expect(BudgetPace.Words.days(5) == "five days")
        #expect(BudgetPace.Words.days(9) == "nine days")
        #expect(BudgetPace.Words.days(10) == "10 days")
        #expect(BudgetPace.Words.days(12) == "12 days")
        #expect(BudgetPace.Words.runsOut("Gas", around: "Oct 26", daysEarly: 5)
                == "At this pace, Gas runs out around Oct 26, five days early.")
    }

    // Scenario WHEEL-09
    @Test func inTheLastWeekMoreLeftThanExpectedOffersToLowerTheBudget() throws {
        let groceries = try #require(pace(limit: 100_000, spent: 50_000, october: 26))
        #expect(groceries.kind == .underPace)
        #expect(groceries.text
                == "$339 more left than expected by today. Keep this budget, or lower it for next month?")
        #expect(groceries.offersEdit)
    }

    // Scenario WHEEL-09
    @Test func beforeTheLastWeekOrToSomeoneWhoMayNotChangeItNothingIsAsked() {
        #expect(pace(limit: 100_000, spent: 50_000, october: 24) == nil, "October 24 is before the last week")
        #expect(pace(limit: 100_000, spent: 50_000, october: 26, mayEdit: false) == nil, "Leslie, at Add, is not asked")
    }

    // Scenario WHEEL-09
    /// On October 26, $161.29 is expected to be left of $1,000.00. Less than
    /// a dollar more, once rounded to whole dollars, is not worth asking about.
    @Test func lessThanADollarMoreThanExpectedSaysNothing() throws {
        #expect(pace(limit: 100_000, spent: 83_822, october: 26) == nil, "49 cents more")
        let fiftyCents = try #require(pace(limit: 100_000, spent: 83_821, october: 26))
        #expect(fiftyCents.text.hasPrefix("$1 more left than expected by today."))
    }

    @Test func onAnEvenPaceThereAreNoWords() {
        #expect(pace(limit: 3_100, spent: 100, october: 1) == nil, "$30.00 left, and $30.00 expected")
    }

    // Scenario WHEEL-10
    @Test func overItsLimitThereAreNoPaceWords() {
        #expect(pace(limit: 10_000, spent: 11_500, october: 18) == nil)
        #expect(pace(limit: 10_000, spent: 11_500, october: 28) == nil, "nor in the last week")
    }

    @Test func aBudgetThatNeverResetsHasNoPaceWords() {
        let now = WheelCalendar.date(2026, 10, 28)
        let wheel = MoneyWheel(scope: .budget, budgeted: Money(minorUnits: 100_000),
                               spent: Money(minorUnits: 90_000), day: nil)
        #expect(wheel.day == nil)
        #expect(BudgetPace(wheel: wheel, budgetName: "Savings", mayEdit: true, calendar: calendar) == nil)
        #expect(MoneyWheel(budget: BudgetSummary(
            budget: Budget(groupID: GroupID(), name: "Savings", limit: Money(minorUnits: 100_000), reset: .never),
            period: ResetSchedule.never.period(containing: now, calendar: calendar),
            spent: Money(minorUnits: 90_000), transactionCount: 1), now: now, calendar: calendar) == wheel)
    }

    /// No words say a group's pace: its wheel has the tick alone.
    @Test func aGroupsWheelHasNoPaceWords() {
        let now = WheelCalendar.date(2026, 10, 18)
        let household = MoneyWheel(scope: .group, budgeted: Money(minorUnits: 18_000),
                                   spent: Money(minorUnits: 12_200),
                                   day: PeriodDay(period: WheelCalendar.month(of: now), now: now, calendar: calendar))
        #expect(household.isOverPace)
        #expect(BudgetPace(wheel: household, budgetName: "Household", mayEdit: true, calendar: calendar) == nil)
    }

    @Test func editBudgetEndsInAnEllipsisOnlyOnADesktop() {
        #expect(BudgetPace.Words.editBudget(onPhone: false) == "Edit Budget…")
        #expect(BudgetPace.Words.editBudget(onPhone: true) == "Edit Budget")
        #expect(BudgetPace.Words.moreLeft("$25")
                == "$25 more left than expected by today. Keep this budget, or lower it for next month?")
    }
}
