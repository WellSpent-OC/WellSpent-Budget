#if canImport(WellSpentProperties)
import Foundation
import Testing
import WellSpentAppCore
import WellSpentCrypto
import WellSpentModel
import WellSpentProperties
import WellSpentStore

/// Fails every call the same way, as a key that stopped working does.
private struct FailingService: PriceLabsService {
    let error: PriceLabsError
    func listings() async throws -> [PriceLabsListing] { throw error }
    func reservations(for listing: PriceLabsListing.ID) async throws -> [PriceLabsReservation] { throw error }
}

/// The Houses feed on the Mac's and the iPhone's shared side: houses from the
/// core's claimed groups, and PriceLabs' stays written back as income, here
/// with the mock's three example houses on October 18.
@Suite("Houses feed", .serialized)
@MainActor
struct HousesFeedTests {
    private let calendar = WheelCalendar.calendar
    private let today = WheelCalendar.date(2026, 10, 18)

    private func model() throws -> AppModel {
        let model = AppModel(store: Store(database: try WellSpentDatabase.inMemory()))
        let today = self.today
        model.today = { today }
        return model
    }

    private func feed(_ model: AppModel, secrets: InMemorySecretStore = InMemorySecretStore(),
                      service: (any PriceLabsService)? = nil) -> HousesFeed {
        let today = self.today, calendar = self.calendar
        return HousesFeed(model: model, secrets: secrets, defaults: isolatedDefaults(), calendar: calendar,
                          now: { today }, makeService: { key in
                              if let service { return service }
                              return key == nil ? PriceLabsUnconnectedService()
                                  : PriceLabsMockService(today: today, calendar: calendar)
                          })
    }

    /// Live entries PriceLabs brought in, in every group.
    private func priceLabsEntries(_ model: AppModel) -> [Transaction] {
        model.groups.flatMap { model.entries(in: $0.id) }
            .filter { $0.importFingerprint?.hasPrefix("pricelabs:") ?? false }
    }

    // Scenario PROP-03
    @Test func withNoHousesTheScreenSaysSo() throws {
        let feed = feed(try model())
        #expect(feed.screen.state == .noHouses)
        #expect(feed.connection == .notConnected && feed.connectionLine == nil)
        #expect(feed.wheels.isEmpty)
    }

    // Scenario PROP-14
    /// Pasted, the key is checked, kept, and the listings are offered. Each
    /// one chosen becomes a group claimed by Properties, and its stays that
    /// have checked in become income in the house's Bookings budget.
    @Test func connectingBringsInBookingsAsIncome() async throws {
        let model = try model()
        let secrets = InMemorySecretStore()
        let feed = feed(model, secrets: secrets)
        feed.openKeySheet()
        feed.keySheet?.key = "  test-key \n"
        await feed.connect()
        #expect(secrets.secret(named: "pricelabs.key") == "test-key", "kept trimmed")
        guard case .choosing(let offered) = feed.keySheet?.step else {
            Issue.record("no listings offered: \(String(describing: feed.keySheet))")
            return
        }
        #expect(offered.map(\.name) == ["Pool House", "Mountain Cabin", "City Loft"])

        await feed.addHouses(Array(offered.prefix(2)))
        #expect(feed.keySheet == nil)
        #expect(feed.houseGroups.map(\.name) == ["Mountain Cabin", "Pool House"], "in the core's order, by name")
        #expect(model.groups.count == 2, "the listing not chosen made nothing")
        #expect(feed.screen.state == .houses)
        #expect(feed.screen.rows.map(\.name) == ["Mountain Cabin", "Pool House"])

        let entries = priceLabsEntries(model)
        #expect(!entries.isEmpty)
        #expect(entries.allSatisfy { $0.kind == .income && $0.amount.minorUnits > 0 && $0.date <= today })
        let budgets = Set(entries.map(\.budgetID))
        let names = model.summaries.values.flatMap { $0 }.filter { budgets.contains($0.budget.id) }.map(\.budget.name)
        #expect(Set(names) == ["Bookings"])
        guard case .broughtIn(_, let count) = feed.connection else {
            Issue.record("not brought in: \(feed.connection)")
            return
        }
        #expect(count > entries.count, "stays still to come are nights, not money")
        #expect(feed.connectionLine?.hasPrefix("PriceLabs brought in \(count) bookings") == true)
        #expect(feed.wheels.count == 2, "every house has a wheel, with income this month or not")
        #expect(feed.screen.tiles[0].value.hasPrefix("+"), "income with nothing spent is cash flow ahead")

        // The same stays again change nothing.
        let before = priceLabsEntries(model)
        await feed.refresh()
        #expect(priceLabsEntries(model).map(\.id) == before.map(\.id))
    }

    // Scenario PROP-04
    /// A house whose only stay is still to come has its Bookings budget, and
    /// so its wheel, from the moment it is added.
    @Test func aHouseWithNoIncomeYetStillHasItsWheel() async throws {
        let model = try model()
        let today = self.today, calendar = self.calendar
        let feed = HousesFeed(model: model, secrets: InMemorySecretStore(), defaults: isolatedDefaults(),
                              calendar: calendar, now: { today }, makeService: { _ in
                                  PriceLabsMockService(today: today, calendar: calendar, variant: .quiet)
                              })
        feed.openKeySheet()
        feed.keySheet?.key = "k"
        await feed.connect()
        guard case .choosing(let offered) = feed.keySheet?.step else { Issue.record("no listings"); return }
        await feed.addHouses(offered)
        #expect(priceLabsEntries(model).isEmpty, "every stay is still to come")
        #expect(feed.wheels.count == 3)
        #expect(Set(feed.houseGroups.compactMap { model.summaries[$0.id]?.first?.budget.name }) == ["Bookings"])
        #expect(model.selectedBudget == nil, "making a house's Bookings opens nothing")
        #expect(feed.screen.needsYou.isEmpty, "the quiet mock leaves nothing needing the host")
    }

    // Scenario PROP-17
    @Test func thePausedMockConnectsAndThenPauses() async throws {
        let model = try model()
        let today = self.today, calendar = self.calendar
        let feed = HousesFeed(model: model, secrets: InMemorySecretStore(), defaults: isolatedDefaults(),
                              calendar: calendar, now: { today }, makeService: { _ in
                                  PriceLabsMockService(today: today, calendar: calendar, variant: .paused)
                              })
        feed.openKeySheet()
        feed.keySheet?.key = "k"
        await feed.connect()
        guard case .choosing(let offered) = feed.keySheet?.step else { Issue.record("no listings"); return }
        await feed.addHouses(offered)
        #expect(feed.connection == .paused(lastBroughtIn: nil))
        #expect(feed.connection.offersReconnect)
        #expect(feed.screen.rows.count == 3)
    }

    @Test func eachMockVariantMakesTheFeedKeepItsKeyInMemory() throws {
        for value in ["mock", "mock-paused", "mock-quiet"] {
            let feed = HousesFeed(model: try model(), environment: [PriceLabsServiceChoice.variable: value],
                                  defaults: isolatedDefaults(), calendar: calendar)
            #expect(feed.connection == .notConnected, "\(value): a fresh in-memory store has no key")
        }
    }

    /// A house already linked is not offered again, and with nothing new to
    /// offer the sheet closes and the stays come in.
    @Test func listingsAlreadyHousesAreNotOfferedAgain() async throws {
        let model = try model()
        let secrets = InMemorySecretStore()
        let feed = feed(model, secrets: secrets)
        feed.openKeySheet()
        feed.keySheet?.key = "k"
        await feed.connect()
        guard case .choosing(let offered) = feed.keySheet?.step else { Issue.record("no listings"); return }
        await feed.addHouses(offered)
        feed.openKeySheet()
        feed.keySheet?.key = "k"
        await feed.connect()
        #expect(feed.keySheet == nil)
        #expect(model.groups.count == 3)
        await feed.addHouses(offered)
        #expect(model.groups.count == 3, "a listing already a house makes no second group")
    }

    // Scenario PROP-17
    /// A key that stops working pauses the line, offers Reconnect, and keeps
    /// every entry already brought in.
    @Test func aPausedKeyKeepsWhatCameIn() async throws {
        let model = try model()
        let secrets = InMemorySecretStore()
        let working = feed(model, secrets: secrets)
        working.openKeySheet()
        working.keySheet?.key = "k"
        await working.connect()
        guard case .choosing(let offered) = working.keySheet?.step else { Issue.record("no listings"); return }
        await working.addHouses(offered)
        let kept = priceLabsEntries(model).count

        let paused = HousesFeed(model: model, secrets: secrets, defaults: isolatedDefaults(), calendar: calendar,
                                now: { [today] in today }, makeService: { _ in FailingService(error: .keyRejected) })
        #expect(paused.connection == .paused(lastBroughtIn: nil), "a key with no bring-in yet on this device")
        await paused.refresh()
        #expect(paused.connection.offersReconnect)
        #expect(paused.connectionLine == "PriceLabs is paused.")
        #expect(priceLabsEntries(model).count == kept)
        #expect(paused.screen.rows.count == 3, "the houses stay")
    }

    @Test func aKeyPriceLabsRefusesIsNeverKept() async throws {
        let secrets = InMemorySecretStore()
        let feed = feed(try model(), secrets: secrets, service: FailingService(error: .keyRejected))
        feed.openKeySheet()
        await feed.connect()
        #expect(feed.keySheet?.step == .entering, "no key, nothing to check")
        feed.keySheet?.key = "bad"
        await feed.connect()
        #expect(feed.keySheet?.step == .failed(.keyRejected))
        #expect(feed.keySheet?.failure == PriceLabsKeySheet.Words.rejected)
        #expect(secrets.secret(named: "pricelabs.key") == nil)
        feed.closeKeySheet()
        #expect(feed.keySheet == nil)
    }

    @Test func withNoKeyARefreshSaysNotConnected() async throws {
        let feed = feed(try model())
        await feed.refresh()
        #expect(feed.connection == .notConnected)
        #expect(!feed.isRefreshing)
    }

    /// A house's month counts its income by day and its spending, and its
    /// wheel is its group's.
    @Test func aHousesMonthAndWheelComeFromItsGroup() throws {
        let model = try model()
        let group = try #require(model.addGroup(named: "Pool House", claimedBy: PropertiesRegistration.id))
        _ = model.addGroup(named: "Household")
        let rent = try #require(model.addBudget(named: "Mortgage", limit: Money(minorUnits: 300_000), in: group))
        model.applyImport(adds: [
            Transaction(budgetID: rent, groupID: group, date: WheelCalendar.date(2026, 10, 2), merchant: "Bank",
                        amount: Money(minorUnits: -250_000), kind: .spending),
            Transaction(budgetID: rent, groupID: group, date: WheelCalendar.date(2026, 10, 9), merchant: "Airbnb",
                        amount: Money(minorUnits: 400_000), kind: .income),
            Transaction(budgetID: rent, groupID: group, date: WheelCalendar.date(2026, 9, 9), merchant: "Airbnb",
                        amount: Money(minorUnits: 100_000), kind: .income),
        ], changes: [], removes: [])
        let feed = feed(model)
        #expect(feed.houseGroups.map(\.name) == ["Pool House"], "only claimed groups are houses")
        let row = try #require(feed.screen.rows.first)
        #expect(row.cashFlowWords == "+$1,500.00", "October's $4,000 in less $2,500 out")
        #expect(row.coveredWords == "Covered the mortgage Oct 9")
        #expect(feed.wheels.values.first?.moneyIn == Money(minorUnits: 400_000))
    }

    @Test func secretsInMemoryCanBeRemoved() throws {
        let secrets = InMemorySecretStore(["a": "1"])
        #expect(secrets.secret(named: "a") == "1")
        secrets.removeSecret(named: "a")
        #expect(secrets.secret(named: "a") == nil)
    }
}
#endif
