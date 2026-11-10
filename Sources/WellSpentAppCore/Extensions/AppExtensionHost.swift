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

    #if canImport(SwiftUI)
    private let lockedCard: (String) -> AnyView?

    /// `lockedCard` draws the app's locked card for a record the plan has
    /// locked, and answers nil for an open one.
    public init(model: AppModel, calendar: Calendar = AppLocale.calendar,
                lockedCard: @escaping (String) -> AnyView? = { _ in nil }) {
        self.model = model
        self.calendar = calendar
        self.lockedCard = lockedCard
    }

    public func lockedPage(for record: String) -> AnyView? { lockedCard(record) }
    #else
    public init(model: AppModel, calendar: Calendar = AppLocale.calendar) {
        self.model = model
        self.calendar = calendar
    }
    #endif

    public func today() -> Date { model.today() }

    public func groups(claimedBy extensionID: String) -> [HostGroup] {
        model.groups.filter { $0.claimedBy == extensionID }.map { HostGroup(id: Self.text($0.id.uuid), name: $0.name) }
    }

    public func addGroup(named name: String, claimedBy extensionID: String) -> String? {
        model.addGroup(named: name, claimedBy: extensionID).map { Self.text($0.uuid) }
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
                          // A house's month counts the whole month's bills, later dates too.
                          moneyOutMinorUnits: (money.wheel.spent + money.wheel.coming).minorUnits,
                          day: day.day, days: day.days, start: day.start)
    }

    public func entries(in group: String) -> [HostEntry] {
        guard let group = Self.id(group).map(GroupID.init) else { return [] }
        return model.entries(in: group).map {
            HostEntry(id: Self.text($0.id.uuid), date: $0.date, amountMinorUnits: abs($0.amount.minorUnits),
                      isIncome: $0.kind == .income, importFingerprint: $0.importFingerprint,
                      budget: Self.text($0.budgetID.uuid), link: $0.extensionLink.map { Self.text($0.uuid) },
                      signedMinorUnits: $0.amount.minorUnits, isSpendingOrRefund: $0.kind == .spending || $0.kind == .refund,
                      merchant: $0.merchant, addedBy: model.addedBy($0, me: model.me()))
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

    public var revision: Int { model.revision }

    public func groups() -> [HostGroup] {
        model.groups.map { group in
            HostGroup(id: Self.text(group.id.uuid), name: group.name, canManage: model.mayManageEntries(group.id),
                      canAddEntries: model.mayAddEntries(group.id), sharingLine: model.sharingLine(of: group.id))
        }
    }

    public func addGroup(named name: String) -> String? {
        model.addGroup(named: name).map { Self.text($0.uuid) }
    }

    public func budgets(in group: String) -> [HostBudget] {
        guard let group = Self.id(group).map(GroupID.init) else { return [] }
        return (model.summaries[group] ?? []).map {
            HostBudget(id: Self.text($0.budget.id.uuid), name: $0.budget.name, limitMinorUnits: $0.budget.limit.minorUnits,
                       currency: $0.budget.limit.currency.rawValue)
        }
    }

    public func records(kind: String, _ visibility: HostRecord.Visibility, in group: String,
                        extensionID: String) -> [HostRecord] {
        guard let group = Self.id(group).map(GroupID.init) else { return [] }
        switch visibility {
        case .everyMember:
            let found: [ExtensionSetting] = model.extensionRecords(in: group, extensionID: extensionID, kind: kind)
            return found.map(Self.hostRecord)
        case .followsHistory:
            let found: [ExtensionEntry] = model.extensionRecords(in: group, extensionID: extensionID, kind: kind)
            return found.map(Self.hostRecord)
        }
    }

    @discardableResult
    public func saveRecord(kind: String, _ visibility: HostRecord.Visibility, sourceKey: String?, id: String?,
                           body: String, in group: String, extensionID: String) -> String? {
        guard let group = Self.id(group).map(GroupID.init) else { return nil }
        switch visibility {
        case .everyMember:
            let record = ExtensionSetting(groupID: group, extensionID: extensionID, kind: kind, sourceKey: sourceKey,
                                          body: body)
            return saving(record, over: sourceKey == nil ? id : nil)
        case .followsHistory:
            let record = ExtensionEntry(groupID: group, extensionID: extensionID, kind: kind, sourceKey: sourceKey,
                                        body: body)
            return saving(record, over: sourceKey == nil ? id : nil)
        }
    }

    /// Saves `record`, or with an id, over the record held there. That has to be
    /// the caller's own, of the same type, group, extension and kind. The store
    /// saves by ID alone, so another one would be replaced here while the server
    /// refused it, and this device would stay wrong until a full pull.
    private func saving<V>(_ record: ExtensionRecord<V>, over id: String?) -> String? {
        var record = record
        if let id {
            guard let known = Self.id(id).map(RecordID.init), !known.isNameBased,
                  let held: ExtensionRecord<V> = try? model.store.extensionRecord(known),
                  held.groupID == record.groupID, held.extensionID == record.extensionID, held.kind == record.kind
            else { return nil }
            record.id = known
        }
        return model.save(record).map { Self.text($0.uuid) }
    }

    /// The record stays as a mark that it was removed, with its body cleared,
    /// so its details don't stay on the server. Saving the same key again
    /// brings it back with a new body.
    public func removeRecord(_ id: String, _ visibility: HostRecord.Visibility) {
        guard let id = Self.id(id).map(RecordID.init) else { return }
        switch visibility {
        case .everyMember:
            let found: ExtensionSetting? = try? model.store.extensionRecord(id)
            if var found { found.isDeleted = true; found.body = ""; found.updatedAt = Date(); _ = model.save(found) }
        case .followsHistory:
            let found: ExtensionEntry? = try? model.store.extensionRecord(id)
            if var found { found.isDeleted = true; found.body = ""; found.updatedAt = Date(); _ = model.save(found) }
        }
    }

    public func newEntry(linkedTo record: String?, in group: String) {
        guard let group = Self.id(group).map(GroupID.init) else { return }
        model.entrySheetRequest = .add(group: group, link: record.flatMap(Self.id).map(RecordID.init))
    }

    public func openEntry(_ id: String) {
        guard let id = Self.id(id).map(RecordID.init) else { return }
        model.entrySheetRequest = .open(id)
    }

    private static func hostRecord<V>(_ record: ExtensionRecord<V>) -> HostRecord {
        HostRecord(id: text(record.id.uuid), group: text(record.groupID.uuid), kind: record.kind,
                   sourceKey: record.sourceKey, body: record.body)
    }

    #if canImport(SwiftUI)
    public func wheel(_ values: HostWheel, size: HostWheelSize) -> AnyView? {
        guard let currency = Currency(rawValue: values.currency) else { return nil }
        let wheel = MoneyWheel(scope: .group, budgeted: Money(minorUnits: values.coversMinorUnits, currency: currency),
                               spent: Money(minorUnits: values.plannedMinorUnits, currency: currency), day: nil)
        let geometry: WheelGeometry
        switch size {
        case .homeCard: geometry = .homeCard
        case .budgetPage: geometry = .groupDesktop
        case .budgetPhone: geometry = .budgetPhone
        }
        return AnyView(MoneyWheelView(wheel: wheel, geometry: geometry, middle: .compact))
    }

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
