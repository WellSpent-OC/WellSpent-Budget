import Testing
import Foundation
import WellSpentAppCore

/// The day of this month a staging build counts as today when a UI test asks
/// it to, so the money wheel's pace words are the same on any day the test
/// runs.
@Suite("Pinned day")
struct PinnedDayTests {
    private let calendar = WheelCalendar.calendar
    private let october21 = WheelCalendar.date(2026, 10, 21)

    private func asked(_ text: String, environment: AppEnvironment = .staging,
                       on now: Date? = nil) -> Date? {
        PinnedDay.requested(in: [PinnedDay.variable: text], environment: environment,
                            now: now ?? october21, calendar: calendar)
    }

    @Test func aStagingBuildCountsTheAskedDayOfThisMonthAsToday() {
        #expect(asked("15") == WheelCalendar.date(2026, 10, 15), "noon on October 15")
        #expect(asked("28") == WheelCalendar.date(2026, 10, 28))
        #expect(asked("1") == WheelCalendar.date(2026, 10, 1))
        #expect(asked("31") == WheelCalendar.date(2026, 10, 31))
        #expect(PinnedDay.variable == "WELLSPENT_TODAY_IS_DAY")
    }

    @Test func aLiveBuildNeverDoes() {
        #expect(asked("15", environment: .live) == nil)
    }

    @Test func onlyADayOfThisMonthCounts() {
        #expect(PinnedDay.requested(in: [:], environment: .staging, now: october21, calendar: calendar) == nil,
                "nothing asked")
        #expect(asked("0") == nil)
        #expect(asked("32") == nil)
        #expect(asked("fifteen") == nil)
        #expect(asked("31", on: WheelCalendar.date(2026, 11, 2)) == nil, "November has 30 days")
        #expect(asked("28", on: WheelCalendar.date(2027, 2, 3)) == WheelCalendar.date(2027, 2, 28))
    }
}
