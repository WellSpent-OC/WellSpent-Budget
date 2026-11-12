import Foundation

/// Whether the app sells plans: the purchases flag. Off by default, so a
/// build shows the plans with "Coming soon" in place of Subscribe, or of
/// Continue on wellspent.space on Linux, until a release turns it on.
///
/// A release build reads only its own list of flags (BuildFeatures), so
/// nobody can make it sell early by launching it with a variable or a stored
/// setting (PLAN-17). A test build reads, in order, the variable, a stored
/// default, then the list.
public enum PlanBuying {
    /// The flag's name in a build's list.
    public static let bundleName = "purchases"

    #if DEBUG
    /// Test builds only: `WELLSPENT_PLAN_BUYING=on` lets a UI test reach
    /// Subscribe. A release build is compiled without it, and the release
    /// check fails the build if this name is in the app.
    public static let variable = "WELLSPENT_PLAN_BUYING"

    /// Test builds only: the stored default, read from the suite FeatureFlags
    /// is given.
    public static let defaultsKey = "feature.purchases"
    #endif

    /// What stands in place of Subscribe while buying is closed.
    public static let comingSoon = "Coming soon"

    /// Whether this build sells plans. With no arguments, as the screens ask:
    /// the variable in a test build, then the build's own list. FeatureFlags
    /// passes its stored settings too, and agrees whenever none is stored.
    public static func isOpen(processEnvironment: [String: String] = ProcessInfo.processInfo.environment,
                              defaults: UserDefaults? = nil,
                              bundleFeatures: Set<String> = BuildFeatures.list()) -> Bool {
        #if DEBUG
        if let text = processEnvironment[variable] { return isOn(text) }
        if let stored = defaults?.object(forKey: defaultsKey) as? Bool { return stored }
        #endif
        return bundleFeatures.contains(bundleName)
    }

    #if DEBUG
    /// The words FeatureFlags takes for on, and "open", which UI tests used
    /// before this was a flag.
    static func isOn(_ text: String) -> Bool {
        ["1", "true", "yes", "on", "open"].contains(text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
    }
    #endif
}
