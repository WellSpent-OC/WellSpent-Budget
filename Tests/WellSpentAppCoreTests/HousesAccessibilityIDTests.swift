import Testing
import WellSpentAppCore

/// The names the Mac's and the iPhone's Houses tests find things by: one
/// scheme, so both platforms' tests read alike.
@Suite("Houses names")
struct HousesAccessibilityIDTests {
    @Test func eachPartOfHousesHasItsName() {
        #expect(AccessibilityID.housesTile("Booked") == "houses.tile.Booked")
        #expect(AccessibilityID.housesNeedsYou("Check-in tomorrow") == "houses.needsYou.Check-in tomorrow")
        #expect(AccessibilityID.housesRow("Pool House") == "houses.row.Pool House")
        #expect(AccessibilityID.housesRowWheel("Pool House") == "houses.row.Pool House.wheel")
        #expect(AccessibilityID.keySheetListing("City Loft") == "keySheet.listing.City Loft")
        #expect(AccessibilityID.housesNothingNeedsYou.hasPrefix("houses.needsYou."))
    }
}
