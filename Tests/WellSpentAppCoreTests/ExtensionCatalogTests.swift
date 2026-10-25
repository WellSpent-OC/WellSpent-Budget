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
}

