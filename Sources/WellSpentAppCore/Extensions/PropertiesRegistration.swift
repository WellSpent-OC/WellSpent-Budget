import Foundation
import WellSpentExtensions
#if canImport(WellSpentProperties)
import WellSpentProperties
#endif

/// The Properties extension's seat in the core: its manifest, and whether the
/// private package (`WellSpent-OC/WellSpent-Properties`) is linked into this
/// build. The public app builds with or without it. Houses, bookings and the
/// PriceLabs importer live in that package; the core keeps only the flag, the
/// catalog card, the rail slot and the claim field on a group.
public enum PropertiesRegistration {
    /// The id the catalog, the registry and `BudgetGroup.claimedBy` use.
    public static let id = "wellspent.properties"

    public static let manifest = ExtensionManifest(
        id: id, name: "Properties", version: "0.1.0", license: "Proprietary",
        platforms: ["macos", "ios", "linux"], ownedData: ["houses", "bookings"],
        actions: [
            .init(name: "read_bookings", access: .read),
            .init(name: "write_income", access: .write),
            .init(name: "connect_pricelabs", access: .sensitive)
        ])

    /// True when the private package was linked at build time. A public CI
    /// build has it false; the release build and the job with the deploy key
    /// have it true. Nothing of Properties shows unless this is true and the
    /// feature flag is on.
    public static var isPackageLinked: Bool {
        #if canImport(WellSpentProperties)
        return WellSpentProperties.extensionID == id
        #else
        return false
        #endif
    }

    /// The manifests this build can offer: WarTable always, Properties only
    /// when its package is linked.
    public static var registry: ExtensionRegistry {
        var manifests = [WarTableRegistration.manifest]
        if isPackageLinked { manifests.append(manifest) }
        return try! ExtensionRegistry(manifests)
    }
}
