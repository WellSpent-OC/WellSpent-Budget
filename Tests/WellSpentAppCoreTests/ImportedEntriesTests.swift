import Foundation
import Testing
import WellSpentAppCore
import WellSpentCrypto
import WellSpentModel
import WellSpentStore

/// What an extension's importer writes into the core: claimed groups, and
/// entries saved, changed and removed in one change.
@Suite("Imported entries")
@MainActor
struct ImportedEntriesTests {
    private let today = WheelCalendar.date(2026, 10, 18)

    private func model() throws -> AppModel {
        AppModel(store: Store(database: try WellSpentDatabase.inMemory()))
    }

    /// Live imported entries, in every group.
    private func imported(_ model: AppModel) -> [Transaction] {
        model.groups.flatMap { model.entries(in: $0.id) }.filter { $0.importFingerprint != nil }
    }

    @Test func aGroupCanBeClaimedFromTheStart() throws {
        let model = try model()
        let studio = try #require(model.addGroup(named: " Studio ", claimedBy: "wellspent.example"))
        let plain = try #require(model.addGroup(named: "Household"))
        #expect(model.group(named: studio)?.claimedBy == "wellspent.example")
        #expect(model.group(named: studio)?.name == "Studio")
        #expect(model.group(named: plain)?.claimedBy == nil)
    }

    /// With nothing open, the Mac opens the first plain group's first
    /// budget, never one in a group an extension claims.
    @Test func aClaimedGroupsBudgetNeverOpensByItself() throws {
        let model = try model()
        let studio = try #require(model.addGroup(named: "A Studio", claimedBy: "wellspent.example"))
        _ = model.addBudget(named: "Income", limit: Money(minorUnits: 0), in: studio, select: false)
        model.reload()
        #expect(model.selectedBudget == nil, "only a claimed group's budget exists")
        let plain = try #require(model.addGroup(named: "Household"))
        let groceries = try #require(model.addBudget(named: "Groceries", limit: Money(minorUnits: 50_000), in: plain,
                                                     select: false))
        model.reload()
        #expect(model.selectedBudget == groceries)
    }

    @Test func aBudgetMadeForThePersonOpensNothing() throws {
        let model = try model()
        let group = try #require(model.addGroup(named: "Household"))
        let groceries = try #require(model.addBudget(named: "Groceries", limit: Money(minorUnits: 50_000), in: group))
        #expect(model.selectedBudget == groceries, "a budget the person makes opens")
        let made = try #require(model.addBudget(named: "Income", limit: Money(minorUnits: 0), in: group,
                                                select: false))
        #expect(model.selectedBudget == groceries, "what was open stays open")
        #expect(model.budget(for: made)?.name == "Income")
    }

    /// What an importer worked out is saved, changed and removed, and nothing
    /// lands in a group this person may not add to.
    @Test func anImportIsSavedChangedAndRemoved() throws {
        let model = try model()
        let group = try #require(model.addGroup(named: "Studio", claimedBy: "wellspent.example"))
        let budget = try #require(model.addBudget(named: "Income", limit: Money(minorUnits: 0), in: group))
        func entry(_ amount: Int) -> Transaction {
            Transaction(budgetID: budget, groupID: group, date: today, merchant: "Airbnb",
                        amount: Money(minorUnits: amount), kind: .income, importFingerprint: "example:\(amount)")
        }
        let first = entry(100), second = entry(200)
        model.applyImport(adds: [first, second], changes: [], removes: [])
        #expect(imported(model).count == 2)
        model.applyImport(adds: [], changes: [.init(id: first.id, amount: Money(minorUnits: 150), date: today,
                                                    note: "moved")],
                          removes: [second.id])
        let left = imported(model)
        #expect(left.map(\.amount.minorUnits) == [150] && left.first?.note == "moved")
        #expect(model.undoOffer == nil, "an import offers no Undo")
        model.applyImport(adds: [], changes: [.init(id: second.id, amount: Money(minorUnits: 1), date: today,
                                                    note: "")], removes: [second.id])
        #expect(imported(model).count == 1, "a deleted entry stays deleted")

        model.mayAddEntries = { _ in false }
        model.applyImport(adds: [entry(300)], changes: [], removes: [first.id])
        #expect(imported(model).map(\.amount.minorUnits) == [150])
        model.applyImport(adds: [], changes: [], removes: [])
    }

}
