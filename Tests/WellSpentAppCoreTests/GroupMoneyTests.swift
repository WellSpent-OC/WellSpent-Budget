import Testing
import Foundation
import WellSpentAppCore
import WellSpentCrypto
import WellSpentModel

/// A group's money this month: every budget in it added up, on a desktop's
/// group page and on a phone's Home card.
@Suite("Group money")
struct GroupMoneyTests {
    private let calendar = WheelCalendar.calendar
    private let household = BudgetGroup(name: "Household")
    private let october18 = WheelCalendar.date(2026, 10, 18)

    /// Groceries, $1,000.00 a month with $555.36 spent, and Eating out,
    /// $300.00 with $110.60 spent, on `now`.
    private func householdBudgets(on now: Date) -> [BudgetSummary] {
        [WheelCalendar.summary("Groceries", limit: 100_000, spent: 55_536, on: now, in: household.id),
         WheelCalendar.summary("Eating out", limit: 30_000, spent: 11_060, on: now, in: household.id)]
    }

    private func groupMoney(_ summaries: [BudgetSummary], on now: Date) -> GroupMoney? {
        GroupMoney(group: household, summaries: summaries, now: now, calendar: calendar)
    }

    // Scenario WHEEL-11
    @Test func aGroupsWheelAddsUpItsBudgetsForTheMonth() throws {
        let money = try #require(groupMoney(householdBudgets(on: october18), on: october18))
        #expect(money.groupID == household.id && money.groupName == "Household")
        #expect(money.wheel.scope == .group)
        #expect(money.wheel.budgeted == Money(minorUnits: 130_000))
        #expect(money.wheel.spent == Money(minorUnits: 66_596))
        #expect(money.wheel.middleKey == "Left this month")
        #expect(money.wheel.middleAmount == "$634")
        #expect(money.wheel.middleOf == "of $1,300")
        #expect(money.wheel.figures.map(\.label) == ["Spent", "Left", "Expected left by today"])
        #expect(money.wheel.figures.map(\.amount) == ["$665.96", "$634.04", "$545.16"])
        #expect(money.note == "Day 18 of 31. Every budget in Household, added up.")
        #expect(money.wheel.tick == 13.0 / 31, "the same tick as a budget's wheel")
        #expect(!money.wheel.isWarning && money.wheel.arcColor == PaletteValues.wheelLeft)
        #expect(money.wheel.spokenSummary == "Left this month $634 of $1,300")
    }

    // Scenario WHEEL-11
    /// Rent paid in full on the 2nd puts the group behind the tick. With no
    /// words to say a group's pace, its wheel stays green.
    @Test func aGroupBehindTheTickIsStillNotAWarning() throws {
        let october2 = WheelCalendar.date(2026, 10, 2)
        let money = try #require(groupMoney([
            WheelCalendar.summary("Rent", limit: 150_000, spent: 150_000, on: october2, in: household.id),
            WheelCalendar.summary("Groceries", limit: 100_000, spent: 0, on: october2, in: household.id),
        ], on: october2))
        #expect(money.wheel.arc < money.wheel.tick ?? 0, "behind the tick")
        #expect(!money.wheel.isWarning)
        #expect(money.wheel.arcColor == PaletteValues.wheelLeft)
    }

    // Scenario WHEEL-11
    @Test func aGroupWithNoBudgetsHasNoMoney() {
        #expect(groupMoney([], on: october18) == nil)
    }

    // Scenario WHEEL-12
    @Test func overTheMonthsBudgetsTheGroupsWheelSaysHowFarOver() throws {
        let money = try #require(groupMoney([
            WheelCalendar.summary("Groceries", limit: 100_000, spent: 120_000, on: october18, in: household.id),
            WheelCalendar.summary("Eating out", limit: 30_000, spent: 22_000, on: october18, in: household.id),
        ], on: october18))
        #expect(money.wheel.isOver && money.wheel.isWarning)
        #expect(money.wheel.arc == 1 && money.wheel.tick == nil)
        #expect(money.wheel.middleKey == "Over this month")
        #expect(money.wheel.middleAmount == "$120")
        #expect(money.wheel.middleOf == "of $1,300")
        #expect(money.wheel.compactWord == "over", "Home's card says $120 and over")
        #expect(money.wheel.figures == [
            MoneyWheel.Figure(label: "Spent", amount: "$1420.00"),
            MoneyWheel.Figure(label: "Over", amount: "$120.00", isWarning: true),
        ])
    }

    // Scenario WHEEL-13
    @Test func homesCardSaysTheGroupTheMonthAndWhatIsSpent() throws {
        let money = try #require(groupMoney(householdBudgets(on: october18), on: october18))
        #expect(money.title == "Household · October")
        #expect(money.wheel.day?.shortLine == "Day 18 of 31")
        #expect(money.spentLine == "Spent $666 of $1,300 budgeted")
        #expect(money.wheel.middleAmount == "$634")
        #expect(money.wheel.compactWord == "left")
    }

    /// The day and the tick follow the calendar month, whatever period each
    /// budget's own summary was read in.
    @Test func theGroupsDayIsTheCalendarMonth() throws {
        let week = BudgetPeriod(start: calendar.startOfDay(for: october18),
                                end: calendar.startOfDay(for: WheelCalendar.date(2026, 10, 25)))
        let lunches = Budget(groupID: household.id, name: "Lunches", limit: Money(minorUnits: 5_000),
                             reset: .weekly(weekday: 1))
        let weekly = BudgetSummary(budget: lunches, period: week, spent: Money(minorUnits: 1_000), transactionCount: 1)
        let money = try #require(groupMoney([weekly], on: october18))
        #expect(money.wheel.day?.line == "October · day 18 of 31")
        #expect(money.title == "Household · October")
    }

    /// Money in two currencies cannot be added up, so a group adds up only
    /// the budgets in its first budget's currency.
    @Test func onlyBudgetsInTheFirstBudgetsCurrencyAreAddedUp() throws {
        let money = try #require(groupMoney([
            WheelCalendar.summary("Groceries", limit: 100_000, spent: 10_000, on: october18, in: household.id),
            WheelCalendar.summary("Trip", limit: 50_000, spent: 5_000, on: october18, currency: .eur, in: household.id),
            WheelCalendar.summary("Eating out", limit: 30_000, spent: 3_000, on: october18, in: household.id),
        ], on: october18))
        #expect(money.wheel.budgeted == Money(minorUnits: 130_000))
        #expect(money.wheel.spent == Money(minorUnits: 13_000))
    }

    @Test func theGroupsWordsAreWrittenOnce() {
        #expect(GroupMoney.Words.section == "Money")
        #expect(GroupMoney.Words.card == "This month")
        #expect(GroupMoney.Words.title("Household", "October") == "Household · October")
        #expect(GroupMoney.Words.note("Day 18 of 31", "Household")
                == "Day 18 of 31. Every budget in Household, added up.")
        #expect(GroupMoney.Words.spentLine("$666", "$1,300") == "Spent $666 of $1,300 budgeted")
    }
}
