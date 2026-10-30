#if canImport(WellSpentProperties)
import Foundation
import XCTest
import WellSpentAppCore
import WellSpentProperties

/// The Houses screen on a phone (card PROP-B, with PROP-A's key sheet), on
/// the mock PriceLabs: its three example houses with stays placed around
/// today, so the words come true whatever day the test runs. Built only when
/// the private Properties package is linked. No account, so it runs in light
/// and in dark.
final class PhoneHousesTests: XCTestCase {
    nonisolated(unsafe) private static var dataRootPath: String?

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    override func tearDown() {
        let app = XCUIApplication()
        if app.state != .notRunning { app.terminate() }
        if let path = Self.dataRootPath { try? FileManager.default.removeItem(atPath: path) }
        Self.dataRootPath = nil
        super.tearDown()
    }

    @MainActor
    func testConnectPriceLabsAndSeeTheHouses() throws {
        let pool = PriceLabsMockService.poolHouse.name
        let cabin = PriceLabsMockService.mountainCabin.name
        let loft = PriceLabsMockService.cityLoft.name
        typealias Sheet = PriceLabsKeySheet.Words

        let run = PhoneTestApp()
        Self.dataRootPath = run.dataRoot.path
        run.app.launchEnvironment[FeatureFlags.extensionsVariable] = "1"
        run.app.launchEnvironment[FeatureFlags.propertiesVariable] = "1"
        run.app.launchEnvironment[PriceLabsServiceChoice.variable] = PriceLabsServiceChoice.mockValue
        run.launch()

        // Properties is turned on from the catalog, and Houses opens with no
        // houses yet.
        run.openAddMenu()
        let addExtension = run.app.buttons["Add an extension…"].firstMatch
        XCTAssertTrue(addExtension.waitForExistence(timeout: 15), "no Add an extension…. On screen: \(run.visibleButtons())")
        addExtension.tap()
        let turnOn = run.app.buttons["Turn on"].firstMatch
        XCTAssertTrue(turnOn.waitForExistence(timeout: 10), "no Turn on for Properties. On screen: \(run.visibleButtons())")
        turnOn.tap()
        XCTAssertTrue(run.has(AccessibilityID.housesEmpty), "Houses does not open empty. On screen: \(run.visibleTexts())")
        XCTAssertTrue(run.shows(HousesScreen.Words.noHousesYet))

        // Scenario PROP-14
        // 1. A key pasted with spaces around it is taken. The sheet says
        // where the key is, what PriceLabs charges, that WellSpent only
        // reads, and that the key stays on the device.
        run.app.buttons[HousesScreen.Words.connectPriceLabs].firstMatch.tap()
        for line in [Sheet.whereToFind, Sheet.cost, Sheet.onlyReads, Sheet.staysYours] {
            XCTAssertTrue(run.shows(line), "the key sheet does not say \(line). On screen: \(run.visibleTexts())")
        }
        XCTAssertFalse(run.button(AccessibilityID.keySheetConnect).isEnabled, "Connect is offered with no key")
        run.paste("  mock-key-for-tests  ", into: AccessibilityID.keySheetField)
        run.tap(AccessibilityID.keySheetConnect)

        // 2. The listings are offered as houses, every one chosen. A
        // listing left out makes nothing.
        XCTAssertTrue(run.shows(Sheet.chooseTitle, timeout: 15), "no listings offered. On screen: \(run.visibleTexts())")
        let loftSwitch = run.element(AccessibilityID.keySheetListing(loft))
        XCTAssertTrue(loftSwitch.waitForExistence(timeout: 5), "\(loft) is not offered")
        loftSwitch.switches.firstMatch.exists ? loftSwitch.switches.firstMatch.tap() : loftSwitch.tap()
        run.tap(AccessibilityID.keySheetAddHouses)
        XCTAssertTrue(run.has(AccessibilityID.housesRow(pool), timeout: 15), "no \(pool). On screen: \(run.visibleTexts())")
        XCTAssertTrue(run.has(AccessibilityID.housesRow(cabin)))
        XCTAssertTrue(run.lacks(AccessibilityID.housesRow(loft)), "\(loft) was left out and still became a house")

        // 3. Connecting again offers only the listing not yet a house.
        run.tap(AccessibilityID.housesAdd)
        run.app.buttons[HousesScreen.Words.connectPriceLabs].firstMatch.tap()
        run.paste("mock-key-for-tests", into: AccessibilityID.keySheetField)
        run.tap(AccessibilityID.keySheetConnect)
        XCTAssertTrue(run.has(AccessibilityID.keySheetListing(loft), timeout: 15), "\(loft) is not offered again")
        XCTAssertTrue(run.lacks(AccessibilityID.keySheetListing(pool)), "\(pool) is offered though it is a house")
        run.tap(AccessibilityID.keySheetAddHouses)

        // 4. The screen says when PriceLabs last brought bookings in.
        let broughtIn = run.element(AccessibilityID.housesBroughtIn)
        XCTAssertTrue(run.wait(for: broughtIn, until: "label BEGINSWITH 'PriceLabs brought in'", timeout: 15),
                      "no line saying when bookings came in: \(broughtIn.label)")

        // Scenario PROP-04
        // 5. Three tiles across the top, and a row per house with its wheel.
        for title in [HousesScreen.Words.cashFlowThisMonth, HousesScreen.Words.bookedTitle,
                      HousesScreen.Words.nextThirtyTitle] {
            XCTAssertTrue(run.has(AccessibilityID.housesTile(title)), "no \(title) tile. On screen: \(run.visibleTexts())")
        }
        for house in [pool, cabin, loft] {
            XCTAssertTrue(run.has(AccessibilityID.housesRow(house)), "no row for \(house)")
        }

        // Scenario PROP-06
        // 6. Needs you has today's turnover at Pool House with both times,
        // and tomorrow's check-in at City Loft.
        let times = House(id: "times", name: pool)
        let turnover = NeedsYou.Words.turnover(pool, out: times.checkOutTime.words, in: times.checkInTime.words)
        XCTAssertTrue(run.has(AccessibilityID.housesNeedsYou(turnover)), "Needs you does not say \(turnover). "
                          + "On screen: \(run.visibleTexts())")
        let checkIn = NeedsYou.Words.checkInTomorrow(loft)
        XCTAssertTrue(run.has(AccessibilityID.housesNeedsYou(checkIn)), "Needs you does not say \(checkIn)")

        // Scenario PROP-07
        // 7. Needs you names the one empty night between Mountain Cabin's
        // two stays.
        let emptyNight = run.app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@",
                                  AccessibilityID.housesNeedsYou(NeedsYou.Words.emptyNight(cabin, on: ""))))
            .firstMatch
        XCTAssertTrue(emptyNight.waitForExistence(timeout: 10),
                      "Needs you names no empty night at \(cabin). On screen: \(run.visibleTexts())")

        // Scenario PROP-04
        // 8. Every house's row carries its wheel, a house with no money in
        // yet included.
        for house in [pool, cabin, loft] {
            XCTAssertTrue(run.has(AccessibilityID.housesRowWheel(house)), "no wheel on \(house)'s row")
        }
    }
}
#endif
