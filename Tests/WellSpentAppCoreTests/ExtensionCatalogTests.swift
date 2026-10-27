import Foundation
import Testing
import WellSpentAppCore

@Suite("Extension catalog")
struct ExtensionCatalogTests {
    @Test func itemsContainWarTableAndRoadmap() {
        let items = ExtensionCatalog.items(platform: "linux", isWarTableEnabled: true, isRunwayEnabled: true)
        #expect(!items.isEmpty)
        let warTable = items.first { $0.id == "wellspent.wartable" }
        #expect(warTable != nil)
        #expect(warTable?.status == .available)
        #expect(warTable?.isInstalled == true)

        let properties = items.first { $0.id == "wellspent.properties" }
        #expect(properties != nil)
        #expect(properties?.status == .available)
        #expect(properties?.isInstalled == false)

        let disabledRunway = ExtensionCatalog.items(platform: "linux", isWarTableEnabled: true, isRunwayEnabled: false)
        let propertiesDisabled = disabledRunway.first { $0.id == "wellspent.properties" }
        #expect(propertiesDisabled?.status == .comingSoon)
    }

    @Test func warTableExcludedWhenFlagIsOff() {
        let withoutWarTable = ExtensionCatalog.items(platform: "linux", isWarTableEnabled: false, isRunwayEnabled: false)
        #expect(withoutWarTable.first { $0.id == "wellspent.wartable" } == nil)
        #expect(withoutWarTable.contains { $0.id == "wellspent.properties" })

        let flags = FeatureFlags(areExtensionsEnabled: true, isWarTableEnabled: false, isRunwayEnabled: true)
        let fromFlags = ExtensionCatalog.items(platform: "linux", features: flags)
        #expect(fromFlags.first { $0.id == "wellspent.wartable" } == nil)
        #expect(fromFlags.first { $0.id == "wellspent.properties" }?.status == .available)
    }
}

