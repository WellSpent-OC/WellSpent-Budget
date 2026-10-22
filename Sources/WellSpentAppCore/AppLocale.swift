import Foundation

/// The locale the app reads amounts and writes dates with: the region's, so
/// "12,50" is twelve fifty where a comma marks decimals, and a date reads the
/// way the region writes one.
///
/// On the Mac and the iPhone it's the system's, and follows a change of region
/// at once. On Linux, Foundation answers en_001 whatever the computer's region
/// (swiftlang/swift-foundation#717), so the Linux app's launch sets it from the
/// region its environment names (`posix(_:)`).
///
/// Shared code reads the locale and the calendar from here, never from
/// `Locale.current` or a formatter made without one. A test holds that.
public enum AppLocale {
    /// A test's own locale, for its task only, so tests running side by side
    /// never see each other's: `AppLocale.$override.withValue(germany) { … }`.
    @TaskLocal public static var override: Locale?

    /// The locale the launch set, if it set one. Set once, read from any
    /// thread.
    private static let launch = LaunchLocale()

    public static var current: Locale {
        override ?? launch.locale ?? .autoupdatingCurrent
    }

    /// The calendar dates are counted and written with: the system's, carrying
    /// the app's locale when one is set.
    public static var calendar: Calendar {
        var calendar = Calendar.autoupdatingCurrent
        if let locale = override ?? launch.locale {
            calendar.locale = locale
        }
        return calendar
    }

    /// Sets the app's locale, once, as the app starts. The Linux app calls it
    /// with the region its environment names.
    public static func set(_ locale: Locale) {
        launch.set(locale)
    }

    /// The region a POSIX environment names for numbers, the way the C
    /// library reads it: `LC_ALL`, then `LC_NUMERIC`, then `LANG`, the first
    /// with a value. Dates follow the same one, so numbers and dates never
    /// split two ways. Nil for C or POSIX, which name no region, and for a name
    /// Foundation doesn't know.
    public static func posix(_ environment: [String: String]) -> Locale? {
        for key in ["LC_ALL", "LC_NUMERIC", "LANG"] {
            guard let value = environment[key], !value.isEmpty else { continue }
            return locale(posixName: value)
        }
        return nil
    }

    /// "de_DE.UTF-8" or "de_DE@euro" as Foundation names it: "de_DE".
    static func locale(posixName: String) -> Locale? {
        var name = Substring(posixName)
        if let at = name.firstIndex(of: "@") { name = name[..<at] }
        if let dot = name.firstIndex(of: ".") { name = name[..<dot] }
        let identifier = String(name)
        guard !identifier.isEmpty, identifier != "C", identifier != "POSIX",
              Locale.availableIdentifiers.contains(identifier) else { return nil }
        return Locale(identifier: identifier)
    }
}

/// The launch's locale behind a lock, so any thread may read it.
private final class LaunchLocale: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Locale?

    var locale: Locale? {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func set(_ locale: Locale) {
        lock.lock()
        defer { lock.unlock() }
        value = locale
    }
}
