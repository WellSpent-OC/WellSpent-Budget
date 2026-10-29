import Foundation

/// Flags that turn experimental or in-progress features on and off.
///
/// Unreleased features are off by default in every build, so unfinished work
/// never shows up by accident. A flag is turned on one of three ways, in this
/// order: a process environment variable (tests and `make run`), a stored
/// default, or the build's own Info.plist list (`WellSpentFeatures`), which is
/// how a TestFlight build carries extensions on for its testers.
public struct FeatureFlags: Sendable, Equatable {
    /// The environment variable to control App Extensions in staging.
    nonisolated public static let extensionsVariable = "WELLSPENT_FEATURE_EXTENSIONS"

    /// The environment variable to control WarTable in staging.
    nonisolated public static let warTableVariable = "WELLSPENT_FEATURE_WARTABLE"

    /// The environment variable to control Properties in staging.
    nonisolated public static let propertiesVariable = "WELLSPENT_FEATURE_PROPERTIES"

    /// The user defaults key for App Extensions.
    public static let extensionsDefaultsKey = "feature.extensions"

    /// The user defaults key for WarTable.
    public static let warTableDefaultsKey = "feature.wartable"

    /// The user defaults key for Properties.
    public static let propertiesDefaultsKey = "feature.properties"

    /// The Info.plist key: the flags a build carries on, as one string of
    /// names separated by commas, such as "extensions,properties". The build
    /// scripts write it from WELLSPENT_FEATURES. Missing or empty is none.
    public static let bundleFeaturesKey = "WellSpentFeatures"

    /// The names in the Info.plist list, one per flag.
    public static let extensionsBundleName = "extensions"
    public static let warTableBundleName = "wartable"
    public static let propertiesBundleName = "properties"

    /// Whether App Extensions, including the activity rail and catalog, are on.
    public let areExtensionsEnabled: Bool

    /// Whether WarTable is on. If extensions are off, WarTable is always off.
    public let isWarTableEnabled: Bool

    /// Whether Properties is on. If extensions are off, Properties is always off.
    public let isPropertiesEnabled: Bool

    public init(
        areExtensionsEnabled: Bool = false,
        isWarTableEnabled: Bool = false,
        isPropertiesEnabled: Bool = false
    ) {
        self.areExtensionsEnabled = areExtensionsEnabled
        self.isWarTableEnabled = areExtensionsEnabled && isWarTableEnabled
        self.isPropertiesEnabled = areExtensionsEnabled && isPropertiesEnabled
    }

    /// The flags a build carries on, read from its Info.plist. A bare
    /// executable (`swift run`) has none.
    public static func bundleFeatures(in bundle: Bundle = .main) -> Set<String> {
        bundleFeatures(from: bundle.object(forInfoDictionaryKey: bundleFeaturesKey))
    }

    /// Parses the Info.plist value: names separated by commas, spaces and case
    /// ignored. Anything but a string is none.
    public static func bundleFeatures(from value: Any?) -> Set<String> {
        guard let text = value as? String else { return [] }
        return Set(text.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty })
    }

    /// Resolves the flags for a build environment.
    ///
    /// Unreleased features are off by default across both live and staging so
    /// in-development features are never shipped or shown by accident. Each
    /// flag is read in this order, and the first source that speaks wins: the
    /// process environment variable, the stored default, then the build's own
    /// Info.plist list. The environment is read for its name only, so a live
    /// TestFlight build can carry extensions on for testers while an App
    /// Store build of the same code, built without the list, has none.
    public static func resolve(
        for environment: AppEnvironment,
        defaults: UserDefaults? = nil,
        processEnvironment: [String: String] = ProcessInfo.processInfo.environment,
        bundleFeatures: Set<String> = bundleFeatures()
    ) -> FeatureFlags {
        func flag(_ variable: String, _ defaultsKey: String, _ bundleName: String) -> Bool {
            if let envText = processEnvironment[variable] { return isTruthy(envText) }
            if let stored = defaults?.object(forKey: defaultsKey) as? Bool { return stored }
            return bundleFeatures.contains(bundleName)
        }
        return FeatureFlags(
            areExtensionsEnabled: flag(extensionsVariable, extensionsDefaultsKey, extensionsBundleName),
            isWarTableEnabled: flag(warTableVariable, warTableDefaultsKey, warTableBundleName),
            isPropertiesEnabled: flag(propertiesVariable, propertiesDefaultsKey, propertiesBundleName)
        )
    }

    /// Checks whether a configuration text means true or false.
    public static func isTruthy(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return trimmed == "1" || trimmed == "true" || trimmed == "yes" || trimmed == "on"
    }
}
