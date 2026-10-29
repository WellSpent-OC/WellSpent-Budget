import Testing
import WellSpentAppCore

/// A month as one bar (BAR-1): filled to today, dark green to the day the
/// costs were covered with a tick there, light green after, or the over
/// colour with no tick when not covered yet. Used by the Booked tile and
/// Runway (PROP-04, PROP-12).
@Suite("Month bar")
struct MonthBarTests {
    @Test func coveredOnTheFourteenthOfThirtyOne() {
        let bar = MonthBar(day: 20, days: 31, coveredDay: 14)
        #expect(bar.isCovered)
        #expect(bar.coveredShare == 14.0 / 31)
        #expect(bar.todayShare == 20.0 / 31)
        #expect(bar.firstFillColor == PaletteValues.monthDeep)
        #expect(MonthBar.secondFillColor == PaletteValues.wheelLeft)
        #expect(bar.spokenValue == "Day 20 of 31, covered on day 14")
    }

    @Test func notCoveredYetIsTheOverColourWithNoTick() {
        let bar = MonthBar(day: 20, days: 31, coveredDay: nil)
        #expect(!bar.isCovered)
        #expect(bar.coveredShare == nil)
        #expect(bar.todayShare == 20.0 / 31)
        #expect(bar.firstFillColor == PaletteValues.rowOver)
        #expect(bar.spokenValue == "Day 20 of 31, not covered yet")
    }

    @Test func coveredTodayPutsTheTickAtTheFillsEnd() {
        let bar = MonthBar(day: 14, days: 31, coveredDay: 14)
        #expect(bar.coveredShare == bar.todayShare)
    }

    @Test func aCoveredDayAfterTodayOrBelowOneIsNotYet() {
        #expect(MonthBar(day: 10, days: 31, coveredDay: 14).coveredDay == 10, "a day ahead of today is clamped to today")
        #expect(MonthBar(day: 10, days: 31, coveredDay: 0).coveredDay == nil)
        #expect(MonthBar(day: 10, days: 31, coveredDay: -3).coveredDay == nil)
    }

    @Test func daysAndTodayStayInRange() {
        let bar = MonthBar(day: 40, days: 0, coveredDay: 2)
        #expect(bar.days == 1)
        #expect(bar.day == 1)
        #expect(bar.coveredDay == 1)
        #expect(bar.todayShare == 1)
    }
}
