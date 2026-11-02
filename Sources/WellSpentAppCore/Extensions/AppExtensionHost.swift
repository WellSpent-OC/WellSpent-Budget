import Foundation
#if canImport(SwiftUI)
import SwiftUI
#endif
import WellSpentCrypto
import WellSpentModel

/// The app's side of the Extension Kit's contract: what an extension may read
/// from and write to a person's budget, answered from the app model in plain
/// values. An extension sees this, never the model itself.
@MainActor
public final class AppExtensionHost: ExtensionHost {
    private let model: AppModel
    public let calendar: Calendar

    public init(model: AppModel, calendar: Calendar = AppLocale.calendar) {
        self.model = model
        self.calendar = calendar
    }

    public func today() -> Date { model.today() }

    public func groups(claimedBy extensionID: String) -> [HostGroup] {
        model.groups.filter { $0.claimedBy == extensionID }.map { HostGroup(id: Self.text($0.id.uuid), name: $0.name) }
    }

    public func addGroup(named name: String, claimedBy extensionID: String) -> String? {
        model.addGroup(named: name, claimedBy: extensionID).map { Self.text($0.uuid) }
    }

    public func releaseGroup(_ group: String, claimedBy extensionID: String) -> Bool {
        guard let id = Self.id(group).map(GroupID.init) else { return false }
        return model.releaseGroup(id, claimedBy: extensionID)
    }

    /// Made with no limit, so money brought in has somewhere to land without
    /// adding to what the group plans to spend.
    public func budget(named name: String, in group: String) -> String? {
        guard let group = Self.id(group).map(GroupID.init), model.group(named: group) != nil else { return nil }
        if let found = model.summaries[group]?.first(where: { $0.budget.name == name }) {
            return Self.text(found.budget.id.uuid)
        }
        return model.addBudget(named: name, limit: Money(minorUnits: 0), in: group, select: false)
            .map { Self.text($0.uuid) }
    }

    public func period(of group: String) -> HostPeriod? {
        guard let money = money(of: group), let day = money.wheel.day else { return nil }
        return HostPeriod(currency: money.wheel.budgeted.currency.rawValue,
                          moneyOutMinorUnits: money.wheel.spent.minorUnits,
                          day: day.day, days: day.days, start: day.start)
    }

    public func entries(in group: String) -> [HostEntry] {
        guard let group = Self.id(group).map(GroupID.init) else { return [] }
        return model.entries(in: group).map {
            HostEntry(id: Self.text($0.id.uuid), date: $0.date, amountMinorUnits: abs($0.amount.minorUnits),
                      isIncome: $0.kind == .income, importFingerprint: $0.importFingerprint)
        }
    }

    /// Amounts come in as sizes. A new entry's sign follows its kind: money in
    /// is positive, money out negative. A changed entry keeps its own sign, so
    /// a transfer, which can go either way, stays the way it went. An add for
    /// a budget outside its group is skipped.
    public func apply(_ batch: HostImport) {
        let adds = batch.add.compactMap { add -> WellSpentModel.Transaction? in
            guard let budget = Self.id(add.budget).map(BudgetID.init), let group = Self.id(add.group).map(GroupID.init),
                  let currency = Currency(rawValue: add.currency),
                  model.summaries[group]?.contains(where: { $0.budget.id == budget }) == true else { return nil }
            return WellSpentModel.Transaction(budgetID: budget, groupID: group, date: add.date, merchant: add.merchant,
                               note: add.note, amount: Money(minorUnits: add.isIncome ? abs(add.amountMinorUnits)
                                                                                   : -abs(add.amountMinorUnits),
                                                             currency: currency),
                               kind: add.isIncome ? .income : .spending, source: .statement,
                               importFingerprint: add.importFingerprint)
        }
        let changes = batch.change.compactMap { change -> AppModel.ImportedChange? in
            guard let id = Self.id(change.entry).map(RecordID.init),
                  let currency = Currency(rawValue: change.currency),
                  let entry = try? model.store.transaction(id) else { return nil }
            let size = abs(change.amountMinorUnits)
            return .init(id: id, amount: Money(minorUnits: entry.amount.minorUnits >= 0 ? size : -size, currency: currency),
                         date: change.date, note: change.note)
        }
        model.applyImport(adds: adds, changes: changes, removes: batch.remove.compactMap { Self.id($0).map(RecordID.init) })
    }

    #if canImport(SwiftUI)
    public func smallWheel(for group: String) -> AnyView? {
        guard let money = money(of: group) else { return nil }
        return AnyView(MoneyWheelView(wheel: money.wheel, geometry: .homeCard, middle: .compact))
    }
    #endif

    private func money(of group: String) -> GroupMoney? {
        guard let id = Self.id(group).map(GroupID.init), let found = model.group(named: id) else { return nil }
        return GroupMoney(group: found, summaries: model.summaries[id] ?? [], now: model.today(), calendar: calendar)
    }

    private static func text(_ uuid: UUID) -> String { uuid.uuidString }
    private static func id(_ text: String) -> UUID? { UUID(uuidString: text) }
}
