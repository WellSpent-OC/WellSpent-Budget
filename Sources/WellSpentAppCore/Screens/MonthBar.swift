import Foundation

/// A month as one bar, day 1 at the left and the last day at the right,
/// filled to today. A dark fill runs to the day the month's costs were
/// covered, a light fill from there to today, and a tick stands on the
/// covered day. Not covered yet, the fill to today is the over colour with
/// no tick. The Booked tile and Runway draw it (BAR-1); its shares, colours
/// and words live here, and each app only draws them.
public struct MonthBar: Equatable, Sendable {
    /// Today, counted from 1, and the days in the month.
    public let day: Int
    public let days: Int
    /// The day the costs were covered, 1 to `day`. Nil when not yet.
    public let coveredDay: Int?

    public init(day: Int, days: Int, coveredDay: Int?) {
        self.days = max(days, 1)
        self.day = min(max(day, 1), self.days)
        if let coveredDay, coveredDay >= 1 {
            self.coveredDay = min(coveredDay, self.day)
        } else {
            self.coveredDay = nil
        }
    }

    public var isCovered: Bool { coveredDay != nil }

    /// Where today's fill ends, 0 to 1 along the bar.
    public var todayShare: Double { Double(day) / Double(days) }

    /// Where the dark fill ends and the tick stands, 0 to 1. Nil when not
    /// covered: then there is no tick.
    public var coveredShare: Double? { coveredDay.map { Double($0) / Double(days) } }

    /// The fill from the left: the dark green to the covered day, or the
    /// over colour to today when not covered.
    public var firstFillColor: ColorPair { isCovered ? PaletteValues.monthDeep : PaletteValues.rowOver }
    /// The fill from the covered day to today, the budget bar's green.
    public static let secondFillColor = PaletteValues.wheelLeft

    /// For a screen reader: "Day 20 of 31, covered on day 14" or
    /// "Day 20 of 31, not covered yet".
    public var spokenValue: String {
        if let coveredDay { return Words.covered(day: day, of: days, on: coveredDay) }
        return Words.notCovered(day: day, of: days)
    }

    public enum Words {
        public static func covered(day: Int, of days: Int, on covered: Int) -> String {
            "Day \(day) of \(days), covered on day \(covered)"
        }
        public static func notCovered(day: Int, of days: Int) -> String {
            "Day \(day) of \(days), not covered yet"
        }
    }
}
