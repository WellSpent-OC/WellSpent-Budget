import Testing
import Foundation
import WellSpentAppCore
import WellSpentCrypto
import WellSpentModel

/// The wheel's step 2: money in refills a group's wheel toward full, and its
/// middle says money in against money out. Household, day 18 of 31, budgets
/// $4,080.00, the numbers of the step 2 design.
@Suite("Group money in")
struct GroupMoneyInTests {
    private let calendar = WheelCalendar.calendar
    private let household = BudgetGroup(name: "Household")
    private let october18 = WheelCalendar.date(2026, 10, 18)

    /// Rent, $3,000.00 a month with `spent` spent from it and `moneyIn`
    /// come in, and Groceries, $1,080.00 with nothing spent.
    private func household(spent: Int, moneyIn: Int = 0, borrowed: Int = 0, fromSavings: Int = 0) -> GroupMoney? {
        let period = WheelCalendar.month(of: october18)
        func summary(_ name: String, limit: Int, spent: Int, moneyIn: Int = 0, borrowed: Int = 0,
                     fromSavings: Int = 0) -> BudgetSummary {
            BudgetSummary(budget: Budget(groupID: household.id, name: name, limit: Money(minorUnits: limit)),
                          period: period, spent: Money(minorUnits: spent), transactionCount: 1,
                          moneyIn: Money(minorUnits: moneyIn), borrowed: Money(minorUnits: borrowed),
                          fromSavings: Money(minorUnits: fromSavings))
        }
        return GroupMoney(group: household,
                          summaries: [summary("Rent", limit: 300_000, spent: spent, moneyIn: moneyIn,
                                              borrowed: borrowed, fromSavings: fromSavings),
                                      summary("Groceries", limit: 108_000, spent: 0)],
                          now: october18, calendar: calendar)
    }

    // Scenario WHEEL-14
    @Test func moneyInRefillsTheWheelNeverPastFull() throws {
        let a = try #require(household(spent: 277_796, moneyIn: 123_000)).wheel
        #expect(a.left == Money(minorUnits: 253_204))
        #expect(a.arc == 253_204.0 / 408_000)
        #expect(a.tick == 13.0 / 31 && !a.isWarning && a.arcColor == PaletteValues.wheelLeft)

        let b = try #require(household(spent: 277_796, moneyIn: 480_000)).wheel
        #expect(b.left == Money(minorUnits: 610_204), "the sum keeps going")
        #expect(b.arc == 1, "the ring stops at full")
        #expect(b.figures.first { $0.label == "Left" }?.amount == "$4080.00")
        #expect(b.middleAmount == "$4,080")
    }

    // Scenario WHEEL-15
    @Test func theMiddleSaysMoneyInAgainstMoneyOutAndTheCashFlow() throws {
        let money = try #require(household(spent: 277_796, moneyIn: 123_000))
        let wheel = money.wheel
        #expect(wheel.showsCashFlow)
        #expect(wheel.middleIn == "$1,230 in")
        #expect(wheel.middleOut == "$2,778 out")
        #expect(wheel.cashFlowAmount == "\u{2212}$1,548")
        #expect(wheel.cashFlowColor == PaletteValues.warning)
        #expect(MoneyWheel.Words.thisMonth == "this month")
        #expect(wheel.figures == [
            MoneyWheel.Figure(label: "In", amount: "+$1230.00"),
            MoneyWheel.Figure(label: "Spent", amount: "$2777.96"),
            MoneyWheel.Figure(label: "Left", amount: "$2532.04"),
            MoneyWheel.Figure(label: "Expected left by today", amount: "$1710.97"),
        ])
        #expect(money.note == "Day 18 of 31. Every budget in Household, added up, and money in.")
        #expect(wheel.spokenSummary
                == "In $1,230, out $2,778, $1,548 behind this month, 62 percent of the month's budgets left")

        let ahead = try #require(household(spent: 277_796, moneyIn: 480_000)).wheel
        #expect(ahead.cashFlowAmount == "+$2,022")
        #expect(ahead.cashFlowColor == PaletteValues.ink)
        #expect(ahead.spokenSummary == "In $4,800, out $2,778, $2,022 ahead this month, full")
    }

    // Scenario WHEEL-16
    @Test func withNoMoneyInTheWheelIsExactlyAsBefore() throws {
        let money = try #require(household(spent: 277_796))
        let before = MoneyWheel(scope: .group, budgeted: Money(minorUnits: 408_000),
                                spent: Money(minorUnits: 277_796), day: money.wheel.day)
        #expect(money.wheel == before)
        #expect(!money.wheel.showsCashFlow && money.wheel.overBudgetsCoveredLine == nil)
        #expect(money.wheel.middleKey == "Left this month")
        #expect(money.wheel.middleAmount == "$1,302")
        #expect(money.wheel.middleOf == "of $4,080")
        #expect(money.wheel.figures.map(\.label) == ["Spent", "Left", "Expected left by today"])
        #expect(money.wheel.spokenSummary == "Left this month $1,302 of $4,080")
        #expect(money.note == "Day 18 of 31. Every budget in Household, added up.")
        #expect(money.inOutLine == nil)
        #expect(money.spentLine == "Spent $2,778 of $4,080 budgeted")
        #expect(money.otherMoneyLines.isEmpty)
    }

    // Scenario WHEEL-17
    @Test func overTheBudgetsWhileMoneyInCoversItStaysGreenAndSaysSo() throws {
        let wheel = try #require(household(spent: 450_000, moneyIn: 123_000)).wheel
        #expect(!wheel.isOver && wheel.isOverBudgetsCovered)
        #expect(wheel.left == Money(minorUnits: 81_000))
        #expect(wheel.arcColor == PaletteValues.wheelLeft && wheel.tick != nil)
        #expect(wheel.overBudgetsCoveredLine == "Over the month's budgets by $420.00. Money in covers it.")
        #expect(wheel.cashFlowAmount == "\u{2212}$3,270")
        #expect(wheel.spokenSummary == "In $1,230, out $4,500, $3,270 behind this month, "
                + "20 percent of the month's budgets left. Over the month's budgets by $420, money in covers it")
    }

    // Scenario WHEEL-18
    @Test func outPastTheBudgetsAndTheMoneyInTurnsTheWheelOrange() throws {
        let money = try #require(household(spent: 450_000, moneyIn: 20_000))
        let wheel = money.wheel
        #expect(wheel.isOver && wheel.isWarning && wheel.arcColor == PaletteValues.warning)
        #expect(wheel.arc == 1 && wheel.tick == nil)
        #expect(!wheel.isOverBudgetsCovered && wheel.overBudgetsCoveredLine == nil)
        #expect(wheel.middleIn == "$200 in" && wheel.middleOut == "$4,500 out")
        #expect(wheel.cashFlowAmount == "\u{2212}$4,300")
        #expect(wheel.figures == [
            MoneyWheel.Figure(label: "In", amount: "+$200.00"),
            MoneyWheel.Figure(label: "Spent", amount: "$4500.00"),
            MoneyWheel.Figure(label: "Over", amount: "$220.00", isWarning: true),
        ])
        #expect(wheel.spokenSummary == "In $200, out $4,500, $4,300 behind this month. Over budget by $220")
        #expect(money.leftLine == "Over $220 of $4,080")
    }

    // Scenario WHEEL-19
    @Test func borrowedMoneyAndSavingsDrawsNeverRefillTheWheel() throws {
        let money = try #require(household(spent: 277_796, borrowed: 50_000, fromSavings: 30_000))
        #expect(!money.wheel.hasMoneyIn && !money.wheel.showsCashFlow)
        #expect(money.wheel.middleAmount == "$1,302", "the middle reads as with no money in")
        #expect(money.otherMoneyLines == ["$500.00 borrowed this month", "$300.00 from savings this month"])
        let one = try #require(household(spent: 277_796, fromSavings: 30_000))
        #expect(one.otherMoneyLines == ["$300.00 from savings this month"])
    }

    // Scenario WHEEL-20
    @Test func moneyInNeverMovesTheTick() throws {
        let without = try #require(household(spent: 277_796)).wheel
        let with = try #require(household(spent: 277_796, moneyIn: 480_000)).wheel
        #expect(with.tick == without.tick)
        #expect(with.expectedLeft == without.expectedLeft)
    }

    /// The lines for a small wheel's card: the step 2 design's Home card,
    /// waiting on WHEEL-13, which keeps Home free of wheels for now.
    @Test func aSmallWheelsCardShowsMoneyInAndOutBeside() throws {
        let money = try #require(household(spent: 277_796, moneyIn: 123_000))
        #expect(money.wheel.cashFlowAmount == "\u{2212}$1,548")
        #expect(money.inOutLine == "In $1,230 \u{00B7} Out $2,778")
        #expect(money.leftLine == "Left $2,532 of $4,080")
        let full = try #require(household(spent: 277_796, moneyIn: 480_000))
        #expect(full.leftLine == "Left $4,080 of $4,080", "no Full word")
    }

    /// A refund larger than the spending keeps the wheel full, and with no
    /// money in the middle says what it said before.
    @Test func aBudgetsWheelNeverTakesMoneyIn() {
        let wheel = MoneyWheel(scope: .budget, budgeted: Money(minorUnits: 100_000), spent: Money(minorUnits: -5_000),
                               day: nil)
        #expect(wheel.moneyIn == Money(minorUnits: 0) && !wheel.showsCashFlow)
        #expect(wheel.arc == 1 && wheel.middleAmount == "$1,050")
        #expect(wheel.cashFlowAmount == "+$50")
        let even = MoneyWheel(scope: .group, budgeted: Money(minorUnits: 100_000), spent: Money(minorUnits: 5_000),
                              day: nil, moneyIn: Money(minorUnits: 5_000))
        #expect(even.cashFlowAmount == "$0")
        #expect(even.spokenSummary == "In $50, out $50, $0 ahead this month, full")
    }

    @Test func theStepTwoWordsAreWrittenOnce() {
        #expect(MoneyWheel.Words.moneyIn == "In")
        #expect(MoneyWheel.Words.inAmount("$1,230") == "$1,230 in")
        #expect(MoneyWheel.Words.outAmount("$2,778") == "$2,778 out")
        #expect(GroupMoney.Words.borrowed("$500.00") == "$500.00 borrowed this month")
        #expect(GroupMoney.Words.fromSavings("$300.00") == "$300.00 from savings this month")
    }
}
