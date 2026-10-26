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

    /// The user defaults key for App Extensions.
    public static let extensionsDefaultsKey = "feature.extensions"

    /// The user defaults key for WarTable.
    public static let warTableDefaultsKey = "feature.wartable"

    /// Whether App Extensions, including the activity rail and catalog, are on.
    public let areExtensionsEnabled: Bool

    /// Whether WarTable is on. If extensions are off, WarTable is always off.
    public let isWarTableEnabled: Bool

    public init(
        areExtensionsEnabled: Bool = false,
        isWarTableEnabled: Bool = false
    ) {
        self.areExtensionsEnabled = areExtensionsEnabled
        self.isWarTableEnabled = areExtensionsEnabled && isWarTableEnabled
    }

    /// Resolves the flags for a build environment.
    ///
    /// Live builds turn unreleased features off unless an explicit preference
    /// says otherwise. Staging builds turn them on by default.
    public static func resolve(
        for environment: AppEnvironment,
        defaults: UserDefaults? = nil,
        processEnvironment: [String: String] = ProcessInfo.processInfo.environment
    ) -> FeatureFlags {
        let extensionsEnabled: Bool
        let warTableEnabled: Bool

        switch environment {
        case .live:
            extensionsEnabled = defaults?.bool(forKey: extensionsDefaultsKey) ?? false
            warTableEnabled = defaults?.bool(forKey: warTableDefaultsKey) ?? false
        case .staging:
            if let envText = processEnvironment[extensionsVariable] {
                extensionsEnabled = isTruthy(envText)
            } else if let defValue = defaults?.object(forKey: extensionsDefaultsKey) as? Bool {
                extensionsEnabled = defValue
            } else {
                extensionsEnabled = true
            }

            if let envText = processEnvironment[warTableVariable] {
                warTableEnabled = isTruthy(envText)
            } else if let defValue = defaults?.object(forKey: warTableDefaultsKey) as? Bool {
                warTableEnabled = defValue
            } else {
                warTableEnabled = true
            }
        }

        return FeatureFlags(
            areExtensionsEnabled: extensionsEnabled,
            isWarTableEnabled: warTableEnabled
        )
    }

    /// Checks whether a configuration text means true or false.
    public static func isTruthy(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return trimmed == "1" || trimmed == "true" || trimmed == "yes" || trimmed == "on"
    }
}
