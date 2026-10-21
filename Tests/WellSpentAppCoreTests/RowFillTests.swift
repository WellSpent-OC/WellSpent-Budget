import Testing
import Foundation
import WellSpentAppCore
import WellSpentModel

/// A budget's row in the list fills from the left as far as its money is
/// used this period. Over its limit, it fills all the way in the over colour
/// and says how far over, in words a screen reader says too.
@Suite("Row fill")
struct RowFillTests {
    private let today = WheelCalendar.date(2026, 10, 18)

    private func fill(limit: Int, spent: Int) -> RowFill {
        RowFill(WheelCalendar.summary(limit: limit, spent: spent, on: today))
    }

    // Scenario WHEEL-01
    @Test func aQuarterUsedFillsTheRowAQuarterOfTheWay() {
        let groceries = fill(limit: 50_000, spent: 12_500)
        #expect(groceries.share == 0.25)
        #expect(!groceries.isOver)
        #expect(groceries.amount == "$375.00", "what is left, as the list shows it today")
        #expect(groceries.spokenValue == "25 percent used")
        #expect(groceries.fillColor == PaletteValues.rowUsed)
    }

    // Scenario WHEEL-01
    @Test func nothingSpentShowsOnlyTheEmptyTrack() {
        let eatingOut = fill(limit: 30_000, spent: 0)
        #expect(eatingOut.share == 0 && !eatingOut.isOver)
        #expect(eatingOut.amount == "$300.00")
        #expect(eatingOut.spokenValue == "0 percent used")

        let nothingToSpend = fill(limit: 0, spent: 0)
        #expect(nothingToSpend.share == 0 && !nothingToSpend.isOver)
        #expect(nothingToSpend.amount == "$0.00")
        #expect(nothingToSpend.spokenValue == "0 percent used")
    }

    // Scenario WHEEL-02
    @Test func overItsLimitTheRowFillsAllTheWayAndSaysHowFarOver() {
        let groceries = fill(limit: 10_000, spent: 11_500)
        #expect(groceries.share == 1)
        #expect(groceries.isOver)
        #expect(groceries.amount == "$15.00 over")
        #expect(groceries.spokenValue == "Over budget")
        #expect(groceries.fillColor == PaletteValues.rowOver)
    }

    // Scenario WHEEL-02
    @Test func spentToTheCentFillsTheRowWithoutBeingOver() {
        let groceries = fill(limit: 10_000, spent: 10_000)
        #expect(groceries.share == 1)
        #expect(!groceries.isOver)
        #expect(groceries.amount == "$0.00")
        #expect(groceries.spokenValue == "100 percent used")
        #expect(groceries.fillColor == PaletteValues.rowUsed)
    }

    /// Spending from a budget of nothing is over it, so the row says so and
    /// fills all the way, as any budget over its limit does.
    @Test func spendingFromABudgetOfNothingIsOverIt() {
        let nothing = fill(limit: 0, spent: 500)
        #expect(nothing.isOver && nothing.share == 1)
        #expect(nothing.amount == "$5.00 over")
        #expect(nothing.spokenValue == "Over budget")
    }

    @Test func thePercentUsedIsRoundedDown() {
        #expect(fill(limit: 100_000, spent: 33_399).spokenValue == "33 percent used")
        #expect(fill(limit: 100_000, spent: 99_999).spokenValue == "99 percent used", "not 100 until all is spent")
        #expect(fill(limit: 300, spent: 1).spokenValue == "0 percent used")
    }

    /// A refund larger than the spending leaves more than the budget, and
    /// the row empty.
    @Test func aRefundLargerThanTheSpendingLeavesTheRowEmpty() {
        let refunded = fill(limit: 10_000, spent: -1_000)
        #expect(refunded.share == 0 && !refunded.isOver)
        #expect(refunded.amount == "$110.00")
        #expect(refunded.spokenValue == "0 percent used")
    }

    @Test func theRowsWordsAreWrittenOnce() {
        #expect(RowFill.Words.over("$15.00") == "$15.00 over")
        #expect(RowFill.Words.used(25) == "25 percent used")
        #expect(RowFill.Words.overBudget == "Over budget")
    }
}
