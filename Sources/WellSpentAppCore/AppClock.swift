import Foundation

/// Where the app reads today's date and time. A real build reads the
/// system's clock. A staging test build can read a file instead, so a UI test
/// can move the whole date, day, month and year, while the app runs
/// (`Workspace.clockFileVariable`).
///
/// Only the calendar reads it: what today is, which period a budget is in,
/// and when a new day begins. The times records are stamped with
/// (`updatedAt`) stay on the system's clock, since sync orders changes by them.
public struct AppClock: Sendable {
    private let read: @Sendable () -> Date
    /// Whether a test moved the clock. A desktop that checks for a new day on
    /// a timer can then check more often, so a test need not wait long.
    public let isPinned: Bool

    public init(isPinned: Bool = false, read: @escaping @Sendable () -> Date) {
        self.isPinned = isPinned
        self.read = read
    }

    /// The system's clock.
    public static let system = AppClock { Date() }

    public func now() -> Date { read() }

    #if DEBUG
    /// A clock reading `path` each time it's asked: one local date and time,
    /// such as `2026-12-14T09:00:00`, in `calendar`'s time zone. It stays at
    /// that moment until the file changes. A missing or unreadable file reads
    /// as the system's clock, so a test that hasn't written it yet still runs.
    public static func file(_ path: String, calendar: Calendar = AppLocale.calendar) -> AppClock {
        AppClock(isPinned: true) {
            guard let text = try? String(contentsOfFile: path, encoding: .utf8),
                  let date = parse(text.trimmingCharacters(in: .whitespacesAndNewlines), calendar: calendar) else {
                return Date()
            }
            return date
        }
    }

    /// `2026-12-14T09:00:00` as a moment in `calendar`'s time zone.
    static func parse(_ text: String, calendar: Calendar) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        return formatter.date(from: text)
    }

    /// The same written out, for a test that sets the clock.
    public static func text(for date: Date, calendar: Calendar = AppLocale.calendar) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        return formatter.string(from: date)
    }
    #endif
}
