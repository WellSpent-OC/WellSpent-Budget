import Foundation

/// Flags that turn experimental or in-progress features on and off.
///
/// In a live build, unreleased features are off by default so unfinished work
/// never shows up in production. In a staging build, they are on by default
/// so developers and automated tests can exercise them. A test can turn any flag
/// on or off through process environment variables or user defaults.
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

    /// Resolves the flags for a build environment.
    ///
    /// Unreleased features are off by default across both live and staging so
    /// in-development features are never shipped or shown by accident.
    /// A developer or test can turn any flag on through process environment
    /// variables or user defaults.
    public static func resolve(
        for environment: AppEnvironment,
        defaults: UserDefaults? = nil,
        processEnvironment: [String: String] = ProcessInfo.processInfo.environment
    ) -> FeatureFlags {
        let extensionsEnabled: Bool
        let warTableEnabled: Bool
        let propertiesEnabled: Bool

        if let envText = processEnvironment[extensionsVariable] {
            extensionsEnabled = isTruthy(envText)
        } else if let defValue = defaults?.object(forKey: extensionsDefaultsKey) as? Bool {
            extensionsEnabled = defValue
        } else {
            extensionsEnabled = false
        }

        if let envText = processEnvironment[warTableVariable] {
            warTableEnabled = isTruthy(envText)
        } else if let defValue = defaults?.object(forKey: warTableDefaultsKey) as? Bool {
            warTableEnabled = defValue
        } else {
            warTableEnabled = false
        }

        if let envText = processEnvironment[propertiesVariable] {
            propertiesEnabled = isTruthy(envText)
        } else if let defValue = defaults?.object(forKey: propertiesDefaultsKey) as? Bool {
            propertiesEnabled = defValue
        } else {
            propertiesEnabled = false
        }

        return FeatureFlags(
            areExtensionsEnabled: extensionsEnabled,
            isWarTableEnabled: warTableEnabled,
            isPropertiesEnabled: propertiesEnabled
        )
    }

    /// Checks whether a configuration text means true or false.
    public static func isTruthy(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return trimmed == "1" || trimmed == "true" || trimmed == "yes" || trimmed == "on"
    }
}
