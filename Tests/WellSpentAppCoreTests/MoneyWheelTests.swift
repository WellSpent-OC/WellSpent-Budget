import Testing
import Foundation
import WellSpentAppCore
import WellSpentCrypto
import WellSpentModel

private let calendar = WheelCalendar.calendar

/// Whether two numbers agree to well under a millionth of a point.
private func near(_ a: Double, _ b: Double) -> Bool { abs(a - b) < 1e-9 }

private func near(_ point: WheelGeometry.Point, _ x: Double, _ y: Double) -> Bool {
    near(point.x, x) && near(point.y, y)
}

/// A budget's wheel on `now`, `limit` a month with `spent` spent. Cents.
private func wheel(limit: Int, spent: Int, on now: Date) -> MoneyWheel {
    MoneyWheel(budget: WheelCalendar.summary(limit: limit, spent: spent, on: now), now: now, calendar: calendar)
}

/// How far through its period a budget is today. Today counts as spent
/// through, so day 18 of 31 leaves 13 days to come.
@Suite("Period day")
struct PeriodDayTests {
    private func day(_ now: Date) throws -> PeriodDay {
        try #require(PeriodDay(period: WheelCalendar.month(of: now), now: now, calendar: calendar))
    }

    // Scenario WHEEL-05
    @Test func october18IsDay18Of31() throws {
        let today = try day(WheelCalendar.date(2026, 10, 18))
        #expect(today.day == 18 && today.days == 31)
        #expect(today.month == "October")
        #expect(today.line == "October · day 18 of 31")
        #expect(today.shortLine == "Day 18 of 31")
        #expect(today.daysToCome == 13)
        #expect(today.shareToCome == 13.0 / 31)
        #expect(today.start == calendar.startOfDay(for: WheelCalendar.date(2026, 10, 1)))
    }

    @Test func februaryHas28Days() throws {
        let today = try day(WheelCalendar.date(2027, 2, 10))
        #expect(today.day == 10 && today.days == 28)
        #expect(today.line == "February · day 10 of 28")
    }

    /// The clocks change on March 14, 2027 and November 1, 2026. Days are
    /// counted on the calendar, so neither change moves them.
    @Test func theClocksChangingMovesNoDay() throws {
        let march = try day(WheelCalendar.date(2027, 3, 20))
        #expect(march.day == 20 && march.days == 31)
        let november = try day(WheelCalendar.date(2026, 11, 20))
        #expect(november.day == 20 && november.days == 30)
    }

    @Test func theLastWeekIsThePeriodsLast7Days() throws {
        #expect(try day(WheelCalendar.date(2026, 10, 25)).isLastWeek, "day 25 of 31")
        #expect(try !day(WheelCalendar.date(2026, 10, 24)).isLastWeek, "day 24 of 31")
        #expect(try day(WheelCalendar.date(2026, 10, 31)).isLastWeek)
        #expect(try !day(WheelCalendar.date(2026, 10, 1)).isLastWeek)
    }

    @Test func thePeriodsFirstAndLastDays() throws {
        let first = try day(WheelCalendar.date(2026, 10, 1))
        #expect(first.day == 1 && first.daysToCome == 30)
        let last = try day(WheelCalendar.date(2026, 10, 31))
        #expect(last.day == 31 && last.daysToCome == 0 && last.shareToCome == 0)
    }

    /// A day read outside its period stays within it: the summary read
    /// before midnight on the last day stays on that day until the app reads
    /// its budgets again.
    @Test func aDayOutsideItsPeriodStaysWithinIt() throws {
        let october = WheelCalendar.month(of: WheelCalendar.date(2026, 10, 18))
        let after = try #require(PeriodDay(period: october, now: WheelCalendar.date(2026, 11, 2), calendar: calendar))
        #expect(after.day == 31 && after.days == 31)
        let before = try #require(PeriodDay(period: october, now: WheelCalendar.date(2026, 9, 28), calendar: calendar))
        #expect(before.day == 1)
    }

    /// A period of a week, from Sunday October 18 to the next Sunday.
    @Test func aWeeklyBudgetCountsTheDaysOfItsWeek() throws {
        let wednesday = WheelCalendar.date(2026, 10, 21)
        let week = BudgetPeriod(start: calendar.startOfDay(for: WheelCalendar.date(2026, 10, 18)),
                                end: calendar.startOfDay(for: WheelCalendar.date(2026, 10, 25)))
        let today = try #require(PeriodDay(period: week, now: wednesday, calendar: calendar))
        #expect(today.day == 4 && today.days == 7)
        #expect(today.isLastWeek)
    }

    /// A budget that never resets has no period to be partway through.
    @Test func aBudgetThatNeverResetsHasNoDay() {
        let never = ResetSchedule.never.period(containing: WheelCalendar.date(2026, 10, 18), calendar: calendar)
        #expect(PeriodDay(period: never, now: WheelCalendar.date(2026, 10, 18), calendar: calendar) == nil)
        let start = WheelCalendar.date(2026, 10, 1)
        #expect(PeriodDay(period: BudgetPeriod(start: start, end: start), now: start, calendar: calendar) == nil,
                "a period of no days")
    }
}

/// What is left of a budget, or of a group's budgets added up: the wheel's
/// shape, its colours and its words.
@Suite("Money wheel")
struct MoneyWheelTests {
    private let october18 = WheelCalendar.date(2026, 10, 18)

    // Scenario WHEEL-05
    @Test func groceriesOnOctober18SaysWhatIsSpentLeftAndExpected() {
        let groceries = wheel(limit: 100_000, spent: 55_536, on: october18)
        #expect(groceries.scope == .budget)
        #expect(groceries.arc == 0.44464)
        #expect(groceries.middleKey == "Left")
        #expect(groceries.middleAmount == "$445")
        #expect(groceries.middleOf == "of $1,000")
        #expect(groceries.figures == [
            MoneyWheel.Figure(label: "Spent", amount: "$555.36"),
            MoneyWheel.Figure(label: "Left", amount: "$444.64"),
            MoneyWheel.Figure(label: "Expected left by today", amount: "$419.35"),
        ])
        #expect(groceries.figures.map(\.id) == ["Spent", "Left", "Expected left by today"])
        #expect(groceries.spokenSummary == "Left $445 of $1,000")
        #expect(!groceries.isOver && !groceries.isOverPace && !groceries.isWarning)
        #expect(groceries.arcColor == PaletteValues.wheelLeft)
        #expect(groceries.amountColor == PaletteValues.ink)
        #expect(groceries.figures.map(\.amountColor) == [PaletteValues.ink, PaletteValues.ink, PaletteValues.ink])
        #expect(groceries.compactWord == "left")
    }

    /// A budget's wheel is the one its summary and its own period give.
    @Test func aBudgetsWheelComesFromItsSummary() {
        let summary = WheelCalendar.summary(limit: 100_000, spent: 55_536, on: october18)
        let groceries = MoneyWheel(budget: summary, now: october18, calendar: calendar)
        #expect(groceries == MoneyWheel(scope: .budget, budgeted: Money(minorUnits: 100_000),
                                        spent: Money(minorUnits: 55_536),
                                        day: PeriodDay(period: summary.period, now: october18, calendar: calendar)))
        #expect(groceries.budgeted == Money(minorUnits: 100_000))
        #expect(groceries.spent == Money(minorUnits: 55_536))
        #expect(groceries.left == Money(minorUnits: 44_464))
        #expect(groceries.day?.line == "October · day 18 of 31")
    }

    // Scenario WHEEL-06
    @Test func theWheelIsFullBeforeAnythingIsSpentAndEmptiesAsMoneyGoesOut() {
        let october10 = WheelCalendar.date(2026, 10, 10)
        let untouched = wheel(limit: 100_000, spent: 0, on: october10)
        #expect(untouched.arc == 1)
        #expect(untouched.middleAmount == "$1,000")
        #expect(!untouched.isWarning)

        let quarterSpent = wheel(limit: 100_000, spent: 25_000, on: october10)
        #expect(quarterSpent.arc == 0.75)
        #expect(quarterSpent.middleAmount == "$750")
        #expect(quarterSpent.spokenSummary == "Left $750 of $1,000")
        #expect(!quarterSpent.isWarning)
    }

    // Scenario WHEEL-07
    @Test func theTickMarksWhereAnEvenPaceWouldBeToday() {
        let groceries = wheel(limit: 100_000, spent: 55_536, on: october18)
        #expect(groceries.tick == 13.0 / 31)
        #expect(groceries.expectedLeft == Money(minorUnits: 41_935), "100000 × 13 ÷ 31 is 41935.48")
        #expect(groceries.arc > groceries.tick ?? 1, "more is left than expected, so the green reaches past the tick")

        #expect(wheel(limit: 100_000, spent: 0, on: WheelCalendar.date(2026, 10, 1)).tick == 30.0 / 31)
        #expect(wheel(limit: 100_000, spent: 0, on: WheelCalendar.date(2026, 10, 31)).tick == 0)
    }

    // Scenario WHEEL-07
    @Test func whatIsExpectedLeftIsRoundedHalfUpToTheCent() {
        // September has 30 days, so on the 15th half the month is to come.
        let september15 = WheelCalendar.date(2026, 9, 15)
        #expect(wheel(limit: 10_001, spent: 0, on: september15).expectedLeft == Money(minorUnits: 5_001),
                "half of 10001 is 5000.5")
        #expect(wheel(limit: 9_999, spent: 0, on: september15).expectedLeft == Money(minorUnits: 5_000),
                "half of 9999 is 4999.5")
        let october31 = WheelCalendar.date(2026, 10, 31)
        #expect(wheel(limit: 100_000, spent: 0, on: october31).expectedLeft == Money(minorUnits: 0),
                "nothing is expected to be left on the last day")
    }

    // Scenario WHEEL-08
    @Test func spendingFasterThanAnEvenPaceTurnsTheWheelOrange() {
        let gas = wheel(limit: 18_000, spent: 12_200, on: october18)
        #expect(gas.left == Money(minorUnits: 5_800))
        #expect(gas.expectedLeft == Money(minorUnits: 7_548))
        #expect(gas.isOverPace && gas.isWarning && !gas.isOver)
        #expect(gas.arcColor == PaletteValues.warning)
        #expect(gas.amountColor == PaletteValues.ink, "over pace keeps the amount in ink")
        #expect(gas.arc < gas.tick ?? 0, "the green stops short of the tick")
        #expect(gas.middleKey == "Left" && gas.middleAmount == "$58" && gas.middleOf == "of $180")
    }

    // Scenario WHEEL-10
    @Test func overItsLimitTheWheelIsOrangeAllTheWayRoundAndSaysHowFarOver() {
        let groceries = wheel(limit: 10_000, spent: 11_500, on: october18)
        #expect(groceries.isOver && groceries.isWarning)
        #expect(groceries.arc == 1)
        #expect(groceries.tick == nil)
        #expect(groceries.expectedLeft == nil)
        #expect(!groceries.isOverPace, "over is not a pace")
        #expect(groceries.left == Money(minorUnits: -1_500))
        #expect(groceries.middleKey == "Over")
        #expect(groceries.middleAmount == "$15")
        #expect(groceries.middleOf == "of $100")
        #expect(groceries.figures == [
            MoneyWheel.Figure(label: "Spent", amount: "$115.00"),
            MoneyWheel.Figure(label: "Over", amount: "$15.00", isWarning: true),
        ])
        #expect(groceries.figures.map(\.amountColor) == [PaletteValues.ink, PaletteValues.warning],
                "the Over figure's amount is in the warning colour")
        #expect(groceries.arcColor == PaletteValues.warning)
        #expect(groceries.amountColor == PaletteValues.warning)
        #expect(groceries.compactWord == "over")
        #expect(groceries.spokenSummary == "Over $15 of $100")
    }

    // Scenario WHEEL-10
    /// Over by a few cents, the orange wheel still says how far over: at least
    /// a whole dollar, never "Over $0". Past that it rounds half up, as every
    /// whole amount in the middle does.
    @Test func overByLessThanADollarTheMiddleSaysOneDollar() {
        let cents = wheel(limit: 10_000, spent: 10_020, on: october18)
        #expect(cents.isOver)
        #expect(cents.middleKey == "Over" && cents.middleAmount == "$1" && cents.middleOf == "of $100")
        #expect(cents.spokenSummary == "Over $1 of $100")
        #expect(cents.figures.last == MoneyWheel.Figure(label: "Over", amount: "$0.20", isWarning: true),
                "the figure keeps the cents")
        #expect(wheel(limit: 10_000, spent: 10_001, on: october18).middleAmount == "$1", "one cent over")
        #expect(wheel(limit: 10_000, spent: 10_050, on: october18).middleAmount == "$1")
        #expect(wheel(limit: 10_000, spent: 10_149, on: october18).middleAmount == "$1")
        #expect(wheel(limit: 10_000, spent: 10_150, on: october18).middleAmount == "$2")
    }

    // Scenario WHEEL-12
    @Test func overByLessThanADollarAGroupsMiddleSaysOneDollar() {
        let household = MoneyWheel(scope: .group, budgeted: Money(minorUnits: 130_000),
                                   spent: Money(minorUnits: 130_020),
                                   day: PeriodDay(period: WheelCalendar.month(of: october18), now: october18,
                                                  calendar: calendar))
        #expect(household.spokenSummary == "Over this month $1 of $1,300")
        #expect(household.middleAmount == "$1" && household.compactWord == "over", "Home's card says $1 over")
    }

    // Scenario WHEEL-12
    @Test func overItsMonthsBudgetsAGroupsWheelSaysHowFarOver() {
        let household = MoneyWheel(scope: .group, budgeted: Money(minorUnits: 130_000),
                                   spent: Money(minorUnits: 142_000),
                                   day: PeriodDay(period: WheelCalendar.month(of: october18), now: october18,
                                                  calendar: calendar))
        #expect(household.middleKey == "Over this month")
        #expect(household.middleAmount == "$120")
        #expect(household.middleOf == "of $1,300")
        #expect(household.compactWord == "over")
        #expect(household.isWarning && household.tick == nil)
        #expect(household.arc == 1 && household.arcColor == PaletteValues.warning)
    }

    // Scenario WHEEL-11
    /// No words say a group's pace, so its colour does not either: behind the
    /// tick, a group's wheel stays green until the group is over.
    @Test func aGroupsWheelTurnsOrangeOnlyWhenOver() {
        let october2 = WheelCalendar.date(2026, 10, 2)
        let household = MoneyWheel(scope: .group, budgeted: Money(minorUnits: 250_000),
                                   spent: Money(minorUnits: 150_000),
                                   day: PeriodDay(period: WheelCalendar.month(of: october2), now: october2,
                                                  calendar: calendar))
        #expect(household.isOverPace, "rent is paid on the 2nd")
        #expect(!household.isWarning)
        #expect(household.arcColor == PaletteValues.wheelLeft)
        #expect(household.middleKey == "Left this month")
        #expect(household.tick == 29.0 / 31)
    }

    /// A budget that never resets has no period to pace, so its wheel has no
    /// tick and no expected figure.
    @Test func aBudgetThatNeverResetsHasNoTickAndOnlyTwoFigures() {
        let period = ResetSchedule.never.period(containing: october18, calendar: calendar)
        let savings = MoneyWheel(budget: BudgetSummary(
            budget: Budget(groupID: GroupID(), name: "Savings", limit: Money(minorUnits: 50_000), reset: .never),
            period: period, spent: Money(minorUnits: 10_000), transactionCount: 1), now: october18, calendar: calendar)
        #expect(savings.day == nil)
        #expect(savings.tick == nil && savings.expectedLeft == nil && !savings.isOverPace)
        #expect(savings.figures.map(\.label) == ["Spent", "Left"])
        #expect(savings.arc == 0.8)
    }

    @Test func aRefundLargerThanTheSpendingKeepsTheWheelFull() {
        let refunded = wheel(limit: 10_000, spent: -1_000, on: october18)
        #expect(refunded.arc == 1)
        #expect(refunded.middleAmount == "$110")
        #expect(!refunded.isWarning)
    }

    @Test func aBudgetOfNothingHasNoGreenAndNoExpectedFigure() {
        let nothing = wheel(limit: 0, spent: 0, on: october18)
        #expect(nothing.arc == 0)
        #expect(nothing.expectedLeft == nil && !nothing.isOverPace)
        #expect(nothing.middleAmount == "$0" && nothing.middleOf == "of $0")
    }

    @Test func theWheelsWordsAreWrittenOnce() {
        #expect(MoneyWheel.Words.left == "Left")
        #expect(MoneyWheel.Words.over == "Over")
        #expect(MoneyWheel.Words.leftThisMonth == "Left this month")
        #expect(MoneyWheel.Words.overThisMonth == "Over this month")
        #expect(MoneyWheel.Words.spent == "Spent")
        #expect(MoneyWheel.Words.expectedLeft == "Expected left by today")
        #expect(MoneyWheel.Words.compactLeft == "left" && MoneyWheel.Words.compactOver == "over")
        #expect(MoneyWheel.Words.of("$1,000") == "of $1,000")
    }
}

/// Where every part of a wheel goes, in points, y down, from the top left of
/// its square.
@Suite("Wheel geometry")
struct WheelGeometryTests {
    @Test func aBudgetsWheelOnADesktopHasTheDesignsRadii() {
        let wheel = WheelGeometry.budgetDesktop
        #expect(wheel.size == 210 && wheel.band == 26)
        #expect(wheel.center == 105)
        #expect(wheel.radius == 89)
        #expect(wheel.outerEdge == 102 && wheel.innerEdge == 76)
        #expect(wheel.tickInner == 70 && wheel.tickOuter == 105)
        #expect(WheelGeometry.edgeWidth == 3 && WheelGeometry.tickWidth == 5)
    }

    @Test func eachWheelHasItsOwnSizeAndBand() {
        #expect(WheelGeometry.groupDesktop == WheelGeometry(size: 170, band: 22))
        #expect(WheelGeometry.budgetPhone == WheelGeometry(size: 190, band: 24))
        #expect(WheelGeometry.homeCard == WheelGeometry(size: 96, band: 12))
        let home = WheelGeometry.homeCard
        #expect(home.radius == 39 && home.outerEdge == 45 && home.innerEdge == 33)
        #expect(home.tickInner == 27 && home.tickOuter == 48)
        for wheel in [WheelGeometry.budgetDesktop, .groupDesktop, .budgetPhone, .homeCard] {
            #expect(wheel.outerEdge + WheelGeometry.edgeWidth / 2 <= wheel.size / 2, "the outer edge stays inside")
            #expect(wheel.tickInner > 0)
        }
    }

    // Scenario WHEEL-07
    @Test func theTickWithNothingToComeCrossesTheBandAtTheTop() {
        let tick = WheelGeometry.budgetDesktop.tick(at: 0)
        #expect(near(tick.from, 105, 35))
        #expect(near(tick.to, 105, 0))
    }

    // Scenario WHEEL-07
    @Test func theTickAQuarterOfTheWayRoundLiesRightOfTheCentre() {
        let tick = WheelGeometry.budgetDesktop.tick(at: 0.25)
        #expect(near(tick.from, 175, 105))
        #expect(near(tick.to, 210, 105))
        let half = WheelGeometry.budgetDesktop.tick(at: 0.5)
        #expect(near(half.from, 105, 175) && near(half.to, 105, 210), "half way round is the bottom")
    }

    // Scenario WHEEL-06
    @Test func theArcRunsClockwiseFromTheTopSplitAtThreeOClock() {
        let wheel = WheelGeometry.budgetDesktop
        let turn = 2 * Double.pi
        #expect(wheel.spans(for: 0).isEmpty)
        #expect(wheel.spans(for: -0.5).isEmpty)
        #expect(wheel.spans(for: 1) == [WheelGeometry.Span(start: 0, end: turn)])
        #expect(wheel.spans(for: 1.5) == [WheelGeometry.Span(start: 0, end: turn)])

        let fifth = wheel.spans(for: 0.2)
        #expect(fifth.count == 1)
        #expect(near(fifth[0].start, Double.pi * 1.5) && near(fifth[0].end, Double.pi * 1.9))

        let quarter = wheel.spans(for: 0.25)
        #expect(quarter.count == 1 && near(quarter[0].end, turn), "a quarter ends at 3 o'clock")

        let half = wheel.spans(for: 0.5)
        #expect(half.count == 2)
        #expect(near(half[0].start, Double.pi * 1.5) && half[0].end == turn)
        #expect(half[1].start == 0 && near(half[1].end, Double.pi / 2))

        for step in 1 ..< 100 {
            for span in wheel.spans(for: Double(step) / 100) {
                #expect(span.start >= 0 && span.end <= turn && span.start < span.end, "share \(step) of 100")
            }
        }
    }
}

/// The wheel's middle shows whole units, rounded half up, with commas.
@Suite("Whole amounts")
struct WholeDisplayTests {
    @Test func wholeUnitsAreRoundedHalfUpWithACommaEveryThreeDigits() {
        #expect(Money(minorUnits: 44_464).wholeDisplay == "$445")
        #expect(Money(minorUnits: 130_204).wholeDisplay == "$1,302")
        #expect(Money(minorUnits: 99_950).wholeDisplay == "$1,000")
        #expect(Money(minorUnits: 49).wholeDisplay == "$0")
        #expect(Money(minorUnits: 50).wholeDisplay == "$1")
        #expect(Money(minorUnits: 0).wholeDisplay == "$0")
        #expect(Money(minorUnits: 99_999).wholeDisplay == "$1,000")
        #expect(Money(minorUnits: 123_456_789).wholeDisplay == "$1,234,568")
        #expect(Money(minorUnits: 100_000_000).wholeDisplay == "$1,000,000")
    }

    @Test func belowZeroItKeepsItsSignUnlessItRoundsToNothing() {
        #expect(Money(minorUnits: -150).wholeDisplay == "-$2")
        #expect(Money(minorUnits: -49).wholeDisplay == "$0")
        #expect(Money(minorUnits: -12_345_678).wholeDisplay == "-$123,457")
    }

    @Test func eachCurrencyKeepsItsOwnSymbol() {
        #expect(Money(minorUnits: 130_204, currency: .eur).wholeDisplay == "\u{20AC}1,302")
        #expect(Money(minorUnits: 130_204, currency: .gbp).wholeDisplay == "\u{A3}1,302")
    }
}
