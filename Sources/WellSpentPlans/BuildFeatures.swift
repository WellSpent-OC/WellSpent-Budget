import Foundation

/// The flags a build carries on: on the Mac and iPhone the Info.plist list
/// (`WellSpentFeatures`), on Linux the features file the packaging step
/// writes. One string of names separated by commas, such as
/// "extensions,purchases". Here, below the app's core, so PlanBuying reads the
/// same list FeatureFlags does.
public enum BuildFeatures {
    /// The Info.plist key. The build scripts write it from WELLSPENT_FEATURES.
    public static let infoPlistKey = "WellSpentFeatures"

    /// The names in a bundle's Info.plist list. A bare executable (`swift run`)
    /// has none.
    public static func list(in bundle: Bundle = .main) -> Set<String> {
        parse(bundle.object(forInfoDictionaryKey: infoPlistKey))
    }

    /// Names separated by commas, spaces and case ignored. Missing, empty or
    /// anything but a string is none.
    public static func parse(_ value: Any?) -> Set<String> {
        guard let text = value as? String else { return [] }
        return Set(text.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty })
    }
}
