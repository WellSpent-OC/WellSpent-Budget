#if canImport(WellSpentProperties)
import Foundation
import XCTest
import WellSpentAppCore
import WellSpentProperties

/// The Houses screen on the Mac (card PROP-B, with PROP-A's key sheet), on the
/// mock PriceLabs: its three example houses with stays placed around today, so
/// the words come true whatever day the test runs. The same steps as the
/// iPhone's PhoneHousesTests. Built only when the private Properties package is
/// linked. No account is needed.
final class HousesTests: XCTestCase {
    nonisolated(unsafe) private static var dataRootPath: String?

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    override func tearDown() {
        let app = XCUIApplication()
        if app.state != .notRunning { app.terminate() }
        TestApp.wipeSettings()
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

        let run = try launched(.standard)

        // Scenario PROP-14
        // 1. A key pasted with spaces around it is taken. The sheet says
        // where the key is, what PriceLabs charges, that WellSpent only
        // reads, and that the key stays on the person's devices.
        run.app.buttons[HousesScreen.Words.connectPriceLabs].firstMatch.click()
        for line in [Sheet.whereToFind, Sheet.cost, Sheet.onlyReads, Sheet.staysYours] {
            XCTAssertTrue(run.app.staticTexts[line].firstMatch.waitForExistence(timeout: 10),
                          "the key sheet does not say \(line). On screen: \(run.visibleTexts())")
        }
        run.expect(AccessibilityID.keySheetConnect, enabled: false, "Connect with no key")
        run.paste("  mock-key-for-tests  ", into: AccessibilityID.keySheetField)
        run.click(AccessibilityID.keySheetConnect)

        // 2. The listings are offered as houses, every one chosen. A listing
        // left out makes nothing.
        XCTAssertTrue(run.element(AccessibilityID.keySheetListing(loft)).waitForExistence(timeout: 15),
                      "no listings offered. On screen: \(run.visibleTexts())")
        run.click(AccessibilityID.keySheetListing(loft))
        run.click(AccessibilityID.keySheetAddHouses)
        XCTAssertTrue(has(run, AccessibilityID.housesRow(pool), timeout: 15), "no \(pool). On screen: \(run.visibleTexts())")
        XCTAssertTrue(has(run, AccessibilityID.housesRow(cabin)))
        XCTAssertFalse(run.element(AccessibilityID.housesRow(loft)).exists, "\(loft) was left out and still became a house")

        // 3. Connecting again offers only the listing not yet a house.
        run.click(AccessibilityID.housesAdd)
        run.clickMenuItem(HousesScreen.Words.connectPriceLabs)
        run.paste("mock-key-for-tests", into: AccessibilityID.keySheetField)
        run.click(AccessibilityID.keySheetConnect)
        XCTAssertTrue(has(run, AccessibilityID.keySheetListing(loft), timeout: 15), "\(loft) is not offered again")
        XCTAssertFalse(run.element(AccessibilityID.keySheetListing(pool)).exists, "\(pool) is offered though it is a house")
        run.click(AccessibilityID.keySheetAddHouses)

        // 4. The screen says when PriceLabs last brought bookings in.
        let broughtIn = run.element(AccessibilityID.housesBroughtIn)
        XCTAssertTrue(run.wait(for: broughtIn, until: "value BEGINSWITH 'PriceLabs brought in' OR label BEGINSWITH "
                                   + "'PriceLabs brought in'", timeout: 15),
                      "no line saying when bookings came in. On screen: \(run.visibleTexts())")

        // Scenario PROP-04
        // 5. Three tiles across the top, and a card per house with its wheel,
        // a house with no money in yet included.
        for title in [HousesScreen.Words.cashFlowThisMonth, HousesScreen.Words.bookedTitle,
                      HousesScreen.Words.nextThirtyTitle] {
            XCTAssertTrue(has(run, AccessibilityID.housesTile(title)), "no \(title) tile. On screen: \(run.visibleTexts())")
        }
        for house in [pool, cabin, loft] {
            XCTAssertTrue(has(run, AccessibilityID.housesRow(house)), "no card for \(house)")
            XCTAssertTrue(has(run, AccessibilityID.housesRowWheel(house)), "no wheel on \(house)'s card")
        }

        // Scenario PROP-06
        // 6. Needs you has today's turnover at Pool House with both times,
        // and tomorrow's check-in at City Loft.
        let times = House(id: "times", name: pool)
        let turnover = NeedsYou.Words.turnover(pool, out: times.checkOutTime.words, in: times.checkInTime.words)
        XCTAssertTrue(has(run, AccessibilityID.housesNeedsYou(turnover)),
                      "Needs you does not say \(turnover). On screen: \(run.visibleTexts())")
        let checkIn = NeedsYou.Words.checkInTomorrow(loft)
        XCTAssertTrue(has(run, AccessibilityID.housesNeedsYou(checkIn)), "Needs you does not say \(checkIn)")

        // Scenario PROP-07
        // 7. Needs you names the one empty night between Mountain Cabin's
        // two stays.
        let emptyNight = run.app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@",
                                  AccessibilityID.housesNeedsYou(NeedsYou.Words.emptyNight(cabin, on: ""))))
            .firstMatch
        XCTAssertTrue(emptyNight.waitForExistence(timeout: 10),
                      "Needs you names no empty night at \(cabin). On screen: \(run.visibleTexts())")
    }

    // Scenario PROP-05
    /// City Loft alone, with spending added while Properties is off, which
    /// brings its group back into Budgets (PROP-02): back on, the house is
    /// below break-even, its cash flow carries a minus sign, and Needs you
    /// says so.
    @MainActor
    func testAHouseBelowBreakEven() throws {
        let loft = PriceLabsMockService.cityLoft.name
        let run = try launched(.standard)
        connect(run, keeping: [loft])
        XCTAssertTrue(has(run, AccessibilityID.housesRow(loft), timeout: 15), "no \(loft). On screen: \(run.visibleTexts())")

        setProperties(run, on: false)
        run.openBudget(named: HousesFeed.bookingsBudget)
        run.addEntry(merchant: "Plumber", amount: "500")
        setProperties(run, on: true)

        let below = NeedsYou.Words.belowBreakEven(loft)
        XCTAssertTrue(has(run, AccessibilityID.housesNeedsYou(below), timeout: 15),
                      "Needs you does not say \(below). On screen: \(run.visibleTexts())")
        let minus = MoneyWords.signedAmount(-50_000)
        XCTAssertTrue(run.app.staticTexts[minus].firstMatch.waitForExistence(timeout: 10),
                      "no \(minus) on \(loft)'s card. On screen: \(run.visibleTexts())")
    }

    // Scenario PROP-08
    /// No turnover, no check-in, no gap and no house below break-even: Needs
    /// you says so in one plain sentence.
    @MainActor
    func testNothingNeedsYou() throws {
        let run = try launched(.quiet)
        connect(run)
        XCTAssertTrue(has(run, AccessibilityID.housesNothingNeedsYou, timeout: 15),
                      "Needs you is not empty. On screen: \(run.visibleTexts())")
    }

    // Scenario PROP-17
    /// The key stops working after the listings came: the line says PriceLabs
    /// is paused, the houses stay, and Reconnect opens the key sheet.
    @MainActor
    func testAPausedConnection() throws {
        let pool = PriceLabsMockService.poolHouse.name
        let run = try launched(.paused)
        connect(run)
        let line = run.element(AccessibilityID.housesBroughtIn)
        XCTAssertTrue(run.wait(for: line, until: "value BEGINSWITH 'PriceLabs is paused' OR label BEGINSWITH "
                                   + "'PriceLabs is paused'", timeout: 15),
                      "the line does not say PriceLabs is paused. On screen: \(run.visibleTexts())")
        XCTAssertTrue(has(run, AccessibilityID.housesRow(pool)), "\(pool) was lost when PriceLabs paused")
        run.click(AccessibilityID.housesReconnect)
        XCTAssertTrue(has(run, AccessibilityID.keySheetField), "Reconnect does not open the key sheet")
        run.click(AccessibilityID.keySheetCancel)
    }

    // MARK: - Steps

    /// The app with Properties' flags on, the mock PriceLabs in the variant
    /// given, and Properties turned on from the catalog, opening on Houses
    /// with no houses.
    @MainActor
    private func launched(_ variant: PriceLabsMockService.Variant) throws -> TestApp {
        let run = try TestApp()
        Self.dataRootPath = run.dataRoot.path
        run.app.launchEnvironment[FeatureFlags.extensionsVariable] = "1"
        run.app.launchEnvironment[FeatureFlags.propertiesVariable] = "1"
        run.app.launchEnvironment[PriceLabsServiceChoice.variable] = variant.rawValue
        run.launch()
        setProperties(run, on: true)
        XCTAssertTrue(has(run, AccessibilityID.housesEmpty), "Houses does not open empty. On screen: \(run.visibleTexts())")
        return run
    }

    /// Turns Properties on or off from the catalog on the rail. On opens
    /// Houses, off goes back to Budgets.
    @MainActor
    private func setProperties(_ run: TestApp, on: Bool) {
        let extensions = run.app.buttons["Extensions"].firstMatch
        XCTAssertTrue(extensions.waitForExistence(timeout: 15), "no Extensions on the rail")
        extensions.click()
        let toggle = run.app.buttons[on ? "Turn on" : "Turn off"].firstMatch
        XCTAssertTrue(toggle.waitForExistence(timeout: 10), "no \(on ? "Turn on" : "Turn off") for Properties. "
                          + "On screen: \(run.visibleTexts())")
        toggle.click()
    }

    /// Connect PriceLabs from the empty Houses screen, keeping the listings
    /// named, or all of them.
    @MainActor
    private func connect(_ run: TestApp, keeping kept: [String]? = nil) {
        run.app.buttons[HousesScreen.Words.connectPriceLabs].firstMatch.click()
        run.paste("mock-key-for-tests", into: AccessibilityID.keySheetField)
        run.click(AccessibilityID.keySheetConnect)
        XCTAssertTrue(has(run, AccessibilityID.keySheetAddHouses, timeout: 15),
                      "no listings offered. On screen: \(run.visibleTexts())")
        if let kept {
            for listing in PriceLabsMockService.houses where !kept.contains(listing.name) {
                run.click(AccessibilityID.keySheetListing(listing.name))
            }
        }
        run.click(AccessibilityID.keySheetAddHouses)
    }

    @MainActor
    private func has(_ run: TestApp, _ identifier: String, timeout: TimeInterval = 10) -> Bool {
        run.element(identifier).waitForExistence(timeout: timeout)
    }
}
#endif
