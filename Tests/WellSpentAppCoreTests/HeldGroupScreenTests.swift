import Testing
@testable import WellSpentAppCore

/// Scenario PLAN-18: a group past the free plan says it's only on this device.
@Suite("A group kept on this device only")
struct HeldGroupScreenTests {
    @Test func beforeTheStoreSellsPlansItDoesNotAskForOne() {
        let screen = HeldGroupScreen(group: "Beach", synced: "Home", device: .mac, platform: .appleStore,
                                     buyingIsOpen: false)
        #expect(screen.marker == "Only on this Mac")
        #expect(screen.notice == "Beach is only on this Mac. Your free plan syncs 1 group, and Home is that group. "
            + "Nothing in Beach is deleted. Paid plans are coming soon.")
        #expect(screen.action == "See Plans")
    }

    @Test func withPlansOnSaleItSaysChooseAPlan() {
        let screen = HeldGroupScreen(group: "Beach", synced: "Home", device: .iPhone, platform: .appleStore,
                                     buyingIsOpen: true)
        #expect(screen.marker == "Only on this iPhone")
        #expect(screen.notice == "Beach is only on this iPhone. Your free plan syncs 1 group, and Home is that group. "
            + "Nothing in Beach is deleted. Choose a plan to sync it too.")
    }

    /// The website always sells plans, so Linux always says Choose a plan.
    @Test func onTheWebsiteItAlwaysSaysChooseAPlan() {
        let screen = HeldGroupScreen(group: "Beach", synced: "Home", device: .computer, platform: .website,
                                     buyingIsOpen: false)
        #expect(screen.marker == "Only on this computer")
        #expect(screen.notice.hasSuffix("Choose a plan to sync it too."))
    }

    /// With no synced group to name, it leaves the name out.
    @Test func withNoSyncedGroupItNamesNone() {
        let screen = HeldGroupScreen(group: "Beach", synced: nil, device: .mac, platform: .appleStore,
                                     buyingIsOpen: false)
        #expect(screen.notice == "Beach is only on this Mac. Your free plan syncs 1 group. "
            + "Nothing in Beach is deleted. Paid plans are coming soon.")
    }
}
