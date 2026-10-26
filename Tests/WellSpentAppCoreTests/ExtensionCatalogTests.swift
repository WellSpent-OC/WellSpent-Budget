import Foundation
import Testing
import WellSpentAppCore

@Suite("Extension catalog")
struct ExtensionCatalogTests {
    @Test func itemsContainWarTableAndRoadmap() {
        let items = ExtensionCatalog.items(platform: "linux")
        #expect(!items.isEmpty)
        let warTable = items.first { $0.id == "wellspent.wartable" }
        #expect(warTable != nil)
        #expect(warTable?.status == .available)
        #expect(warTable?.isInstalled == true)

        let properties = items.first { $0.id == "wellspent.properties" }
        #expect(properties != nil)
        #expect(properties?.status == .comingSoon)
        #expect(properties?.isInstalled == false)
    }

    @Test func warTableExcludedWhenFlagIsOff() {
        let withoutWarTable = ExtensionCatalog.items(platform: "linux", isWarTableEnabled: false)
        #expect(withoutWarTable.first { $0.id == "wellspent.wartable" } == nil)
        #expect(withoutWarTable.contains { $0.id == "wellspent.properties" })

        let flags = FeatureFlags(areExtensionsEnabled: true, isWarTableEnabled: false)
        let fromFlags = ExtensionCatalog.items(platform: "linux", features: flags)
        #expect(fromFlags.first { $0.id == "wellspent.wartable" } == nil)
    }
}

