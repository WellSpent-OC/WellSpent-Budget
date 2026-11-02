import Foundation
import Testing
import WellSpentAppCore
import WellSpentCrypto
import WellSpentModel
import WellSpentStore

/// The app's side of the extension contract: an extension reads and writes a
/// person's budget in plain values, and sees only the groups it claimed.
@Suite("The extension host")
@MainActor
struct AppExtensionHostTests {
    private let today = WheelCalendar.date(2026, 10, 18)
    private let claimer = "wellspent.example"

    private func host() throws -> (AppModel, AppExtensionHost) {
        let model = AppModel(store: Store(database: try WellSpentDatabase.inMemory()))
        let day = today
        model.today = { day }
        return (model, AppExtensionHost(model: model, calendar: WheelCalendar.calendar))
    }

    @Test func anExtensionSeesOnlyTheGroupsItClaimed() throws {
        let (model, host) = try host()
        _ = model.addGroup(named: "Household")
        let made = try #require(host.addGroup(named: "Studio", claimedBy: claimer))
        _ = model.addGroup(named: "Other", claimedBy: "wellspent.other")
        #expect(host.groups(claimedBy: claimer) == [HostGroup(id: made, name: "Studio")])
        #expect(host.today() == today)
    }

    @Test func aReleasedGroupStaysAsAPlainGroupWithItsEntries() throws {
        let (model, host) = try host()
        let group = try #require(host.addGroup(named: "Studio", claimedBy: claimer))
        let budget = try #require(host.budget(named: "Income", in: group))
        host.apply(HostImport(add: [.init(budget: budget, group: group, date: today, merchant: "A guest", note: "",
                                          amountMinorUnits: 100, currency: "USD", isIncome: true,
                                          importFingerprint: "example:100")]))
        #expect(!host.releaseGroup(group, claimedBy: "wellspent.other"), "only the extension that claimed it")
        #expect(host.releaseGroup(group, claimedBy: claimer))
        #expect(host.groups(claimedBy: claimer).isEmpty)
        let plain = try #require(model.groups.first { $0.name == "Studio" })
        #expect(plain.claimedBy == nil)
        #expect(model.entries(in: plain.id).map(\.amount.minorUnits) == [100], "its money stays")
        #expect(!host.releaseGroup(group, claimedBy: claimer), "already plain")
        #expect(!host.releaseGroup("not an id", claimedBy: claimer))
        #expect(!host.releaseGroup(UUID().uuidString, claimedBy: claimer), "no such group")
    }

    @Test func aBudgetIsFoundOrMadeOnce() throws {
        let (model, host) = try host()
        let group = try #require(host.addGroup(named: "Studio", claimedBy: claimer))
        let first = try #require(host.budget(named: "Income", in: group))
        #expect(host.budget(named: "Income", in: group) == first)
        #expect(model.selectedBudget == nil, "made without opening it")
        #expect(host.budget(named: "Income", in: "not an id") == nil)
        #expect(host.budget(named: "Income", in: UUID().uuidString) == nil, "no such group")
    }

    @Test func anImportIsAddedChangedAndRemovedInPlainValues() throws {
        let (model, host) = try host()
        let group = try #require(host.addGroup(named: "Studio", claimedBy: claimer))
        let budget = try #require(host.budget(named: "Income", in: group))
        func add(_ amount: Int, income: Bool = true) -> HostImport.Add {
            .init(budget: budget, group: group, date: today, merchant: "A guest", note: "", amountMinorUnits: amount,
                  currency: "USD", isIncome: income, importFingerprint: "example:\(amount)")
        }
        host.apply(HostImport(add: [add(100), add(200), add(50, income: false)]))
        var entries = host.entries(in: group).sorted { $0.amountMinorUnits < $1.amountMinorUnits }
        #expect(entries.map(\.amountMinorUnits) == [50, 100, 200])
        #expect(entries.map(\.isIncome) == [false, true, true])
        #expect(entries.allSatisfy { $0.importFingerprint?.hasPrefix("example:") == true })
        let saved = model.groups.flatMap { model.entries(in: $0.id) }.map(\.amount.minorUnits).sorted()
        #expect(saved == [-50, 100, 200], "money out is saved as money out")

        let hundred = try #require(entries.first { $0.amountMinorUnits == 100 })
        let fifty = try #require(entries.first { $0.amountMinorUnits == 50 })
        host.apply(HostImport(change: [.init(entry: hundred.id, amountMinorUnits: 150, currency: "USD", date: today,
                                             note: "moved")],
                              remove: [fifty.id, "not an id"]))
        entries = host.entries(in: group).sorted { $0.amountMinorUnits < $1.amountMinorUnits }
        #expect(entries.map(\.amountMinorUnits) == [150, 200])
        #expect(entries.allSatisfy { $0.isIncome }, "a changed entry keeps its kind")

        host.apply(HostImport(add: [.init(budget: "not an id", group: group, date: today, merchant: "", note: "",
                                          amountMinorUnits: 1, currency: "USD", isIncome: true,
                                          importFingerprint: "example:bad")],
                              change: [.init(entry: hundred.id, amountMinorUnits: 1, currency: "XXX", date: today,
                                             note: "")]))
        #expect(host.entries(in: group).count == 2, "bad ids and currencies are skipped")
        #expect(host.entries(in: "not an id").isEmpty)
    }

    /// A transfer can go either way, so a change keeps the way it went.
    @Test func aChangedTransferKeepsItsOwnSign() throws {
        let (model, host) = try host()
        let group = try #require(host.addGroup(named: "Studio", claimedBy: claimer))
        let budget = try #require(host.budget(named: "Income", in: group))
        let groupID = try #require(UUID(uuidString: group).map(GroupID.init))
        let budgetID = try #require(UUID(uuidString: budget).map(BudgetID.init))
        func transfer(_ minorUnits: Int) -> WellSpentModel.Transaction {
            .init(budgetID: budgetID, groupID: groupID, date: today, merchant: "Savings", note: "",
                  amount: Money(minorUnits: minorUnits, currency: .usd), kind: .transfer, source: .manual)
        }
        model.applyImport(adds: [transfer(300), transfer(-700)], changes: [], removes: [])
        let entries = host.entries(in: group)
        #expect(entries.count == 2 && entries.allSatisfy { !$0.isIncome })
        host.apply(HostImport(change: entries.map {
            .init(entry: $0.id, amountMinorUnits: $0.amountMinorUnits + 100, currency: "USD", date: today, note: "")
        }))
        let saved = model.entries(in: groupID).map(\.amount.minorUnits).sorted()
        #expect(saved == [-800, 400], "in stays in, out stays out")
    }

    @Test func anAddForAnotherGroupsBudgetIsSkipped() throws {
        let (_, host) = try host()
        let studio = try #require(host.addGroup(named: "Studio", claimedBy: claimer))
        let other = try #require(host.addGroup(named: "Loft", claimedBy: claimer))
        let otherBudget = try #require(host.budget(named: "Income", in: other))
        host.apply(HostImport(add: [.init(budget: otherBudget, group: studio, date: today, merchant: "A guest",
                                          note: "", amountMinorUnits: 100, currency: "USD", isIncome: true,
                                          importFingerprint: "example:crossed")]))
        #expect(host.entries(in: studio).isEmpty)
        #expect(host.entries(in: other).isEmpty)
    }

    @Test func aGroupsPeriodSaysWhatItSpentAndWhereTodayFalls() throws {
        // A budget's totals count this real month, so this test does too.
        let (model, host) = try host()
        let now = Date()
        model.today = { now }
        let group = try #require(host.addGroup(named: "Studio", claimedBy: claimer))
        #expect(host.period(of: group) == nil, "no budgets yet")
        let id = GroupID(try #require(UUID(uuidString: group)))
        let budget = try #require(model.addBudget(named: "Cleaning", limit: Money(minorUnits: 40_000), in: id,
                                                  select: false))
        try model.store.save(Transaction(budgetID: budget, groupID: id, date: now, merchant: "Cleaner",
                                         amount: Money(minorUnits: -12_500)))
        model.reload()
        let period = try #require(host.period(of: group))
        #expect(period.currency == "USD")
        #expect(period.moneyOutMinorUnits == 12_500)
        let calendar = WheelCalendar.calendar
        #expect(period.day == calendar.component(.day, from: now))
        #expect(period.days == calendar.range(of: .day, in: .month, for: now)?.count)
        #expect(host.period(of: "not an id") == nil)
        #if canImport(SwiftUI)
        #expect(host.smallWheel(for: group) != nil)
        #expect(host.smallWheel(for: "not an id") == nil)
        #endif
    }
}
