import Foundation
import Testing
import WellSpentExtensions
@testable import WellSpentAppCore

@Suite("Properties registration")
struct PropertiesRegistrationTests {
    @Test func manifestMatchesTheCatalogCard() {
        let card = ExtensionCatalog.items(platform: "linux", isWarTableEnabled: true, isPropertiesEnabled: true)
            .first { $0.id == PropertiesRegistration.id }
        #expect(card != nil)
        #expect(PropertiesRegistration.manifest.id == PropertiesRegistration.id)
        #expect(PropertiesRegistration.manifest.name == card?.name)
        #expect(PropertiesRegistration.manifest.ownedData == ["houses", "bookings"])
        #expect(PropertiesRegistration.manifest.actions.map(\.name) == ["read_bookings", "write_income", "connect_pricelabs"])
    }

    @Test func registryOffersPropertiesOnlyWhenThePackageIsLinked() {
        let registry = PropertiesRegistration.registry
        #expect(registry.manifest(id: WarTableRegistration.manifest.id) != nil)
        let offered = registry.manifest(id: PropertiesRegistration.id) != nil
        #expect(offered == PropertiesRegistration.isPackageLinked)
        // The build with the package can say so to a test through the
        // environment; without that word, the test only checks the two agree.
        if let expected = ProcessInfo.processInfo.environment["WELLSPENT_PROPERTIES_LINKED"] {
            #expect(PropertiesRegistration.isPackageLinked == FeatureFlags.isTruthy(expected))
        }
    }
}
