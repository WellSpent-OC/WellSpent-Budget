import Foundation

/// A day of this month that a staging build can be asked to count as today,
/// so a UI test of the money wheel sees the same thing on any day it runs:
/// the over-pace words in the middle of a month, and the hint in its last
/// week. Only the wheel's day moves. Entries keep their real dates, and every
/// budget its real period. A live build never reads it.
public enum PinnedDay {
    /// The environment variable that names the day of the month, such as
    /// "15". Like `StartingScreen.variable`, only a staging build reads it.
    public static let variable = "WELLSPENT_TODAY_IS_DAY"

    /// Noon on the asked day of the month holding `now`. Nil in a live
    /// build, when nothing is asked, and for anything that is not a day of
    /// that month.
    public static func requested(in processEnvironment: [String: String] = ProcessInfo.processInfo.environment,
                                 environment: AppEnvironment = .current, now: Date = Date(),
                                 calendar: Calendar = .autoupdatingCurrent) -> Date? {
        guard environment == .staging, let text = processEnvironment[variable], let day = Int(text),
              let month = calendar.range(of: .day, in: .month, for: now), month.contains(day) else { return nil }
        var parts = calendar.dateComponents([.era, .year, .month], from: now)
        parts.day = day
        parts.hour = 12
        return calendar.date(from: parts)
    }
}
