import Foundation

/// Whether the app sells plans yet. Build A of 0.4.0 shows the plans with
/// "Coming soon" in place of Subscribe and Restore Purchases, because the
/// server can't take an App Store purchase until build B. Build B sets
/// `opensInThisBuild` to true.
public enum PlanBuying {
    /// The one switch build B turns on.
    public static let opensInThisBuild = false

    #if DEBUG
    /// Test builds only: `WELLSPENT_PLAN_BUYING=open` lets a UI test reach
    /// Subscribe before build B. A release build is compiled without it, and
    /// the release check fails the build if this name is in the app.
    public static let variable = "WELLSPENT_PLAN_BUYING"
    #endif

    /// What stands in place of Subscribe while buying is closed.
    public static let comingSoon = "Coming soon"

    public static func isOpen(in environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        #if DEBUG
        if environment[variable]?.lowercased() == "open" { return true }
        #endif
        return opensInThisBuild
    }
}
