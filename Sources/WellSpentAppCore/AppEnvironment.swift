import Foundation

/// Which WellSpent this build is: the live app, or the staging one.
///
/// Live is the app people keep their real budgets in. It talks only to the live
/// server, and it keeps exactly the folder, keychain names and settings the app
/// has always used, so nobody's data moves when this arrives.
///
/// Staging is for testing, against a server that runs unreviewed code. It differs
/// from live on every one of those points. So a staging build signed in with a
/// real email address still cannot open, change or sync that person's real
/// budgets, and never sends their live session anywhere.
///
/// Only a build that says "live" is live. Anything else counts as staging,
/// including a build that says nothing at all. A test build mistaken for live is
/// the dangerous mistake. A live build mistaken for staging only opens staging's
/// budgets, under an orange banner.
public enum AppEnvironment: String, Sendable, Equatable, CaseIterable {
    case live
    case staging

    /// The Info.plist key `scripts/make-app.sh` writes, and the beta workflow
    /// checks before it publishes anything.
    public static let infoPlistKey = "WellSpentEnvironment"

    /// This running app.
    ///
    /// `make run` and `swift run` start a bare executable with no Info.plist, so
    /// they are staging. Only `make app` with `WELLSPENT_ENV=live` makes a live one.
    public static let current = AppEnvironment(
        infoPlistValue: Bundle.main.object(forInfoDictionaryKey: infoPlistKey))

    /// Exactly "live" is live. A missing value, a misspelling, or "Live" is staging.
    public init(infoPlistValue: Any?) {
        self = (infoPlistValue as? String) == AppEnvironment.live.rawValue ? .live : .staging
    }

    /// The name in the menu bar, the window title and the Finder.
    public var appName: String {
        switch self {
        case .live: "WellSpent"
        case .staging: "WellSpent Staging"
        }
    }

    public var bundleIdentifier: String {
        switch self {
        case .live: "app.wellspent.mac"
        case .staging: "app.wellspent.mac.staging"
        }
    }

    /// The folder in Application Support that holds every database.
    public var dataFolderName: String {
        switch self {
        case .live: "WellSpent"
        case .staging: "WellSpent Staging"
        }
    }

    /// The keychain service for the keys from before accounts had their own. Each
    /// account's service is this, a dot, and its namespace.
    public var keychainService: String {
        switch self {
        case .live: "app.wellspent.keys"
        case .staging: "app.wellspent.staging.keys"
        }
    }

    /// Nil is the keys from before accounts had their own. See `AccountDirectory`.
    public func keychainService(for namespace: String?) -> String {
        namespace.map { "\(keychainService).\($0)" } ?? keychainService
    }

    /// Where the settings live. Nil is the standard defaults, which live has always
    /// used.
    ///
    /// Staging's suite is named apart from both bundle IDs. A bare `make run` has
    /// no bundle ID, so its standard defaults are the ones every earlier
    /// `make run` wrote, including the last account and the live server's
    /// address. And macOS will not use a suite named after the app's own bundle
    /// ID.
    public var defaultsSuiteName: String? {
        switch self {
        case .live: nil
        case .staging: "app.wellspent.staging"
        }
    }

    /// Where a bare `make run` kept its settings: the domain named after its
    /// process, ~/Library/Preferences/WellSpentApp.plist. Today's live app is
    /// that bare executable.
    static let bareRunSuiteName = "WellSpentApp"

    /// The settings a bare run kept that the app reads back.
    @MainActor static let carriedKeys = [AccountDirectory.lastAccountKey, AccountDirectory.samplesSeededKey,
                              SyncCoordinator.serverAddressKey, "sidebar.collapsedGroups"]

    /// Copies a bare run's settings into the live app's own, once. The live app
    /// reads app.wellspent.mac's settings, so without this its first launch
    /// came up signed out, and with "samples seeded" unread it put sample
    /// budgets beside the real ones. It runs only while that setting is unset
    /// here, and never replaces a setting already here.
    /// Returns whether anything was copied.
    @MainActor @discardableResult
    static func carryOver(from bareRun: UserDefaults, into live: UserDefaults) -> Bool {
        guard live.object(forKey: AccountDirectory.samplesSeededKey) == nil else { return false }
        var carried = false
        for key in carriedKeys where live.object(forKey: key) == nil {
            guard let value = bareRun.object(forKey: key) else { continue }
            live.set(value, forKey: key)
            carried = true
        }
        return carried
    }

    public var defaults: UserDefaults {
        guard let name = defaultsSuiteName else { return .standard }
        // Falling back to the standard defaults here would mix staging's settings
        // into live's, so a suite that cannot be opened stops the app instead.
        guard let suite = UserDefaults(suiteName: name) else {
            preconditionFailure("could not open the \(name) defaults")
        }
        return suite
    }

    /// The server this build is for.
    public var serverHost: String {
        switch self {
        case .live: "sync.wellspent.space"
        case .staging: "staging.wellspent.space"
        }
    }

    /// What the Server field starts with on a fresh install. A staging build also
    /// accepts a server on this Mac: `make serve` runs one at
    /// `http://127.0.0.1:8080`, and that address can be typed into the field.
    public var defaultServerAddress: String { "https://\(serverHost)" }

    /// The other build, whose server this one refuses.
    var other: AppEnvironment { self == .live ? .staging : .live }

    /// Why this build will not use the server at `url`, or nil when it may.
    ///
    /// This catches the other build's server by name, before anything is sent.
    /// Any other name for that same server is caught by `refusal(ofServerSaying:)`
    /// instead, once the server says what it is.
    public func refusal(ofServerAt url: URL) -> String? {
        var host = (url.host ?? "").lowercased()
        // "sync.wellspent.space." with the final dot is the same server.
        while host.hasSuffix(".") { host.removeLast() }
        guard host == other.serverHost else { return nil }
        switch self {
        case .live:
            return "\(host) is the staging server. This is the live WellSpent app, "
                 + "which uses only the live server. Use WellSpent Staging to test."
        case .staging:
            return "\(host) is the live server, where real budgets are kept. "
                 + "WellSpent Staging is a test build and never connects to it."
        }
    }

    /// Why this build will not sign in to a server whose `/health` names
    /// `environment`, or nil when it may.
    ///
    /// Live accepts "live", and also a server that names nothing. That second rule
    /// is for the changeover: the live server answered `{"status":"ok"}` before it
    /// learned to say which one it is, and live builds must keep working while it
    /// is updated. Once the live server says "live", the rule can go.
    ///
    /// Staging accepts "staging", and "development" for a server on a developer's
    /// own Mac. It never accepts a server that names nothing, because the one
    /// server old enough to say nothing is the live one.
    public func refusal(ofServerSaying environment: String?) -> String? {
        switch self {
        case .live:
            if environment == nil || environment == "live" { return nil }
        case .staging:
            if environment == "staging" || environment == "development" { return nil }
        }
        let what = environment.map { "says it is a \($0) server" }
            ?? "does not say which server it is"
        let allowed = self == .live ? "the live server" : "a staging or development server"
        return "That server \(what). \(appName) signs in only to \(allowed)."
    }
}
