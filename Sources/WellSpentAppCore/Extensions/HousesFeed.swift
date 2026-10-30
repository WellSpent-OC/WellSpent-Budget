#if canImport(WellSpentProperties)
import Foundation
import WellSpentCrypto
import WellSpentModel
import WellSpentProperties

/// The Houses screen's feed, shared by the Mac and the iPhone: the houses a
/// person has claimed, their months and wheels from the core, their bookings
/// from PriceLabs, and the key sheet. Every number and word comes from the
/// Properties package; this only hands the core's money to it and writes
/// back the income entries the package works out (PROP-04 to 08, 14 to 17).
///
/// Bookings are read from PriceLabs on each refresh and held here, not saved:
/// with no connection the money stays, and nights and Needs you wait for the
/// connection to come back (the MVP, Riley 2026-10-30).
@MainActor @Observable
public final class HousesFeed {
    public private(set) var screen: HousesScreen
    /// Each house's group wheel, by house id, drawn on its row.
    public private(set) var wheels: [String: MoneyWheel] = [:]
    public private(set) var connection: PriceLabsConnection
    /// Open while a person connects or reconnects PriceLabs.
    public var keySheet: PriceLabsKeySheet?
    /// True while a refresh is asking PriceLabs.
    public private(set) var isRefreshing = false

    /// The secret store's names: the key, and which listing is which house.
    static let keyName = "pricelabs.key"
    static let linksName = "pricelabs.links"
    /// When stays last came in, on this device.
    static let lastBroughtInKey = "properties.pricelabs.lastBroughtIn"
    /// What a house's income from PriceLabs is filed under in its group.
    public static let bookingsBudget = "Bookings"

    @ObservationIgnored private let model: AppModel
    @ObservationIgnored private let secrets: any SecretStore
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let makeService: (String?) -> any PriceLabsService
    @ObservationIgnored private let calendar: Calendar
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private var bookings: [Booking] = []
    @ObservationIgnored private var lastBookingCount = 0

    /// `WELLSPENT_PRICELABS=mock` (or `mock-paused`, `mock-quiet`) gives the
    /// three example houses and a key store in memory, so no UI test reaches
    /// PriceLabs or a real keychain.
    public convenience init(model: AppModel,
                            environment: [String: String] = ProcessInfo.processInfo.environment,
                            defaults: UserDefaults = .standard, calendar: Calendar = AppLocale.calendar) {
        let isMock = PriceLabsServiceChoice.mockVariant(in: environment) != nil
        let secrets: any SecretStore
        #if canImport(Security)
        secrets = isMock ? InMemorySecretStore() : KeychainSecretStore()
        #else
        secrets = InMemorySecretStore()
        #endif
        self.init(model: model, secrets: secrets, defaults: defaults, calendar: calendar, now: { model.today() },
                  makeService: { key in
                      PriceLabsServiceChoice.make(processEnvironment: environment, key: key, today: model.today(),
                                                  calendar: calendar)
                  })
    }

    public init(model: AppModel, secrets: any SecretStore, defaults: UserDefaults, calendar: Calendar,
                now: @escaping () -> Date, makeService: @escaping (String?) -> any PriceLabsService) {
        self.model = model
        self.secrets = secrets
        self.defaults = defaults
        self.calendar = calendar
        self.now = now
        self.makeService = makeService
        screen = HousesScreen(houses: [], months: [], bookings: [], today: now(), calendar: calendar)
        connection = secrets.secret(named: Self.keyName) == nil ? .notConnected
            : .paused(lastBroughtIn: defaults.object(forKey: Self.lastBroughtInKey) as? Date)
        rebuild()
    }

    // MARK: - From the core

    /// The groups claimed as houses.
    public var houseGroups: [BudgetGroup] {
        model.groups.filter { $0.claimedBy == PropertiesRegistration.id }
    }

    /// Builds the screen again from the core's money and the bookings held.
    public func rebuild() {
        let today = now()
        var houses: [House] = [], months: [HouseMonth] = [], wheels: [String: MoneyWheel] = [:]
        for group in houseGroups {
            let id = Self.houseID(group.id)
            houses.append(House(id: id, name: group.name))
            guard let money = GroupMoney(group: group, summaries: model.summaries[group.id] ?? [], now: today,
                                         calendar: calendar), let day = money.wheel.day else { continue }
            wheels[id] = money.wheel
            months.append(HouseMonth(houseID: id, houseName: group.name, currency: money.wheel.budgeted.currency.rawValue,
                                     moneyInByDay: moneyInByDay(group.id, since: day.start, days: day.days),
                                     moneyOutMinorUnits: money.wheel.spent.minorUnits, day: day.day, days: day.days,
                                     monthStart: day.start))
        }
        self.wheels = wheels
        screen = HousesScreen(houses: houses, months: months, bookings: bookings, today: today, calendar: calendar)
    }

    /// Income this month by day of the month, in minor units.
    private func moneyInByDay(_ group: GroupID, since start: Date, days: Int) -> [Int: Int] {
        var byDay: [Int: Int] = [:]
        for entry in model.entries(in: group) where entry.kind == .income {
            guard let offset = calendar.dateComponents([.day], from: start, to: calendar.startOfDay(for: entry.date)).day,
                  offset >= 0, offset < days else { continue }
            byDay[offset + 1, default: 0] += entry.amount.minorUnits
        }
        return byDay
    }

    static func houseID(_ group: GroupID) -> String { group.uuid.uuidString }

    // MARK: - PriceLabs

    /// The line under the Houses title.
    public var connectionLine: String? { connection.line(now: now(), calendar: calendar) }

    /// Asks PriceLabs for every linked house's stays and writes back what
    /// they change. A failure keeps everything already brought in.
    public func refresh() async {
        guard let key = secrets.secret(named: Self.keyName) else {
            connection = .notConnected
            return
        }
        isRefreshing = true
        defer { isRefreshing = false }
        let service = makeService(key)
        let links = self.links()
        let houses = Dictionary(houseGroups.map { (Self.houseID($0.id), $0) }, uniquingKeysWith: { first, _ in first })
        do {
            var all: [Booking] = []
            for (listing, houseID) in links.sorted(by: { $0.key < $1.key }) {
                guard let group = houses[houseID] else { continue }
                let stays = try await service.reservations(for: listing)
                all += bringIn(stays, to: group.id)
            }
            bookings = all
            let at = now()
            defaults.set(at, forKey: Self.lastBroughtInKey)
            connection = .broughtIn(at: at, bookings: all.count)
        } catch {
            connection = PriceLabsConnection(failure: error as? PriceLabsError ?? .unavailable,
                                             lastBroughtIn: defaults.object(forKey: Self.lastBroughtInKey) as? Date)
        }
        rebuild()
    }

    /// Works out what a house's stays change and saves it in the core.
    private func bringIn(_ stays: [PriceLabsReservation], to group: GroupID) -> [Booking] {
        let houseID = Self.houseID(group)
        let mine = model.entries(in: group).filter {
            $0.importFingerprint?.hasPrefix(BookingImport.fingerprintPrefix) ?? false
        }
        let existing = mine.compactMap { entry in
            entry.importFingerprint.map {
                BookingImport.Existing(entryID: entry.id.uuid.uuidString, fingerprint: $0, date: entry.date,
                                       amountMinorUnits: entry.amount.minorUnits)
            }
        }
        let today = now()
        let windowStart = calendar.date(byAdding: .month, value: -1,
                                        to: calendar.dateInterval(of: .month, for: today)?.start ?? today) ?? today
        let plan = BookingImport(houseID: houseID, reservations: stays, existing: existing, windowStart: windowStart,
                                 today: today, calendar: calendar)
        let ids = Dictionary(mine.map { ($0.id.uuid.uuidString, $0.id) }, uniquingKeysWith: { first, _ in first })
        if !plan.isEmpty, let budget = bookingsBudget(in: group) {
            let adds = plan.add.compactMap { entry -> Transaction? in
                guard let currency = Currency(rawValue: entry.currency) else { return nil }
                return Transaction(budgetID: budget, groupID: group, date: entry.date, merchant: entry.merchant,
                                   note: entry.note, amount: Money(minorUnits: entry.amountMinorUnits, currency: currency),
                                   kind: .income, source: .statement, importFingerprint: entry.fingerprint)
            }
            let changes = plan.change.compactMap { change -> AppModel.ImportedChange? in
                guard let id = ids[change.entryID], let currency = Currency(rawValue: change.entry.currency) else { return nil }
                return .init(id: id, amount: Money(minorUnits: change.entry.amountMinorUnits, currency: currency),
                             date: change.entry.date, note: change.entry.note)
            }
            model.applyImport(adds: adds, changes: changes, removes: plan.remove.compactMap { ids[$0] })
        }
        return plan.bookings
    }

    /// The house's Bookings budget, made with no limit the first time, so
    /// income has somewhere to land without adding to what the house plans
    /// to spend.
    private func bookingsBudget(in group: GroupID) -> BudgetID? {
        if let found = model.summaries[group]?.first(where: { $0.budget.name == Self.bookingsBudget }) {
            return found.budget.id
        }
        return model.addBudget(named: Self.bookingsBudget, limit: Money(minorUnits: 0), in: group)
    }

    // MARK: - The key sheet

    public func openKeySheet() { keySheet = PriceLabsKeySheet() }
    public func closeKeySheet() { keySheet = nil }

    /// Checks the pasted key by asking PriceLabs for the listings. Taken, it
    /// is kept in the secret store and the listings are offered as houses.
    public func connect() async {
        guard var sheet = keySheet, sheet.mayConnect else { return }
        let key = sheet.trimmedKey
        sheet.step = .checking
        keySheet = sheet
        do {
            let listings = try await makeService(key).listings()
            try secrets.setSecret(key, named: Self.keyName)
            sheet.step = .choosing(listings.filter { links()[$0.id] == nil })
        } catch let error as PriceLabsError {
            sheet.step = .failed(error)
        } catch {
            sheet.step = .failed(.unavailable)
        }
        keySheet = sheet
        if case .choosing(let offered) = sheet.step, offered.isEmpty {
            keySheet = nil
            await refresh()
        }
    }

    /// Each chosen listing becomes a house: a new group named for it,
    /// claimed by Properties, which the person can rename (PROP-14), with its
    /// Bookings budget, so every house has a wheel from the start (PROP-04).
    /// Then its stays come in.
    public func addHouses(_ listings: [PriceLabsListing]) async {
        var links = self.links()
        for listing in listings where links[listing.id] == nil {
            guard let group = model.addGroup(named: listing.name, claimedBy: PropertiesRegistration.id) else { continue }
            _ = bookingsBudget(in: group)
            links[listing.id] = Self.houseID(group)
        }
        saveLinks(links)
        keySheet = nil
        await refresh()
    }

    /// Which PriceLabs listing is which house, kept beside the key so the
    /// person's other Apple devices know it too.
    func links() -> [String: String] {
        guard let text = secrets.secret(named: Self.linksName), let data = text.data(using: .utf8),
              let links = try? JSONDecoder().decode([String: String].self, from: data) else { return [:] }
        return links
    }

    private func saveLinks(_ links: [String: String]) {
        guard let data = try? JSONEncoder().encode(links), let text = String(data: data, encoding: .utf8) else { return }
        try? secrets.setSecret(text, named: Self.linksName)
    }
}
#endif
