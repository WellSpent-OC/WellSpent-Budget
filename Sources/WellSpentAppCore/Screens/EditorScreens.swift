import Foundation
import Observation
import WellSpentCrypto
import WellSpentImport
import WellSpentModel

// Adding and changing budgets, groups and entries on any desktop. What each
// form holds, checks and says lives here; the Mac and Linux sheets only draw
// it. Every save goes through AppModel, so it syncs like any other edit.

// MARK: - Budget

/// A new budget, or a change to one.
@MainActor
@Observable
public final class BudgetEditor {
    /// Nil when adding.
    public let editing: Budget?
    /// The groups a new budget may go in: the ones this person manages.
    public let groups: [BudgetGroup]
    public var name: String
    public var amountText: String
    public var groupID: GroupID?
    /// With no group of their own to put it in, a new budget gets a new one.
    public var newGroupName = Words.defaultGroupName
    /// How this person's region writes numbers, for the amount.
    public let locale: Locale
    private let model: AppModel

    public init(model: AppModel, editing: Budget? = nil, group: GroupID? = nil, groups: [BudgetGroup]? = nil,
                locale: Locale = AppLocale.current) {
        self.model = model
        self.editing = editing
        self.groups = groups ?? model.groups
        self.locale = locale
        name = editing?.name ?? ""
        amountText = editing.map { TypedAmount.text($0.limit.magnitude, locale: locale) } ?? ""
        groupID = editing?.groupID ?? group ?? self.groups.first?.id
    }

    public var title: String { editing == nil ? Words.newTitle : Words.editTitle }
    public var saveLabel: String { editing == nil ? Words.add : Words.save }

    /// No group to put it in: the form asks for a new group's name instead.
    public var needsNewGroup: Bool { editing == nil && groups.isEmpty }
    /// A new budget, with groups to choose from.
    public var showsGroupPicker: Bool { editing == nil && !groups.isEmpty }

    /// A name, and an amount above zero, read the way the region writes one.
    public static func canSave(name: String, amountText: String, locale: Locale = AppLocale.current) -> Bool {
        guard !name.trimmingCharacters(in: .whitespaces).isEmpty,
              let amount = TypedAmount(amountText, locale: locale).money else { return false }
        return amount.minorUnits != 0
    }

    public var canSave: Bool {
        Self.canSave(name: name, amountText: amountText, locale: locale)
            && (!needsNewGroup || !newGroupName.trimmingCharacters(in: .whitespaces).isEmpty)
    }

    /// Under the amount, when what is typed can't be read clearly.
    public var amountProblem: String? {
        TypedAmount(amountText, locale: locale) == .unclear ? TypedAmount.Words.unclear(locale: locale) : nil
    }

    /// The empty amount field's example, written the region's way.
    public var amountPrompt: String { TypedAmount.text(Money(minorUnits: 50_000), locale: locale) }

    /// True when saved.
    @discardableResult
    public func save() -> Bool {
        guard canSave, let amount = TypedAmount(amountText, locale: locale).money else { return false }
        if let editing {
            model.updateBudget(editing.id, name: name, limit: amount)
            return true
        }
        guard let group = needsNewGroup ? model.addGroup(named: newGroupName) : groupID else { return false }
        return model.addBudget(named: name, limit: amount, in: group) != nil
    }

    public enum Words {
        public static let newTitle = "New Budget"
        public static let editTitle = "Edit Budget"
        public static let name = "Name"
        public static let namePrompt = "Groceries"
        public static let amount = "Each month"
        public static let group = "Group"
        public static let defaultGroupName = "Personal"
        public static let resets = "Starts again on the 1st of each month."
        public static let add = "Add"
        public static let save = "Save"
        public static let cancel = "Cancel"
    }
}

// MARK: - Group

/// A new group, or a new name for one.
@MainActor
@Observable
public final class GroupEditor {
    /// Nil when adding.
    public let renaming: BudgetGroup?
    public var name: String
    private let model: AppModel

    public init(model: AppModel, renaming: BudgetGroup? = nil) {
        self.model = model
        self.renaming = renaming
        name = renaming?.name ?? ""
    }

    public var title: String { renaming == nil ? Words.newTitle : Words.renameTitle }
    public var saveLabel: String { renaming == nil ? Words.add : Words.save }
    public var canSave: Bool { !name.trimmingCharacters(in: .whitespaces).isEmpty }

    /// True when saved.
    @discardableResult
    public func save() -> Bool {
        guard canSave else { return false }
        if let renaming {
            model.renameGroup(renaming.id, to: name)
            return true
        }
        return model.addGroup(named: name) != nil
    }

    public enum Words {
        public static let newTitle = "New Group"
        public static let renameTitle = "Rename Group"
        public static let name = "Name"
        public static let namePrompt = "Household"
        public static let explanation =
            "A group holds budgets you track together. It is also what you will share with someone else."
        public static let add = "Add"
        public static let save = "Save"
        public static let cancel = "Cancel"
    }
}

// MARK: - Entry

/// Money spent, added by hand to the budget on screen, or an entry opened
/// from the list to change or delete, built the way `BudgetEditor` does
/// both. Opened by someone who may not change it, it says why, and its
/// only button is Done.
@MainActor
@Observable
public final class EntryEditor {
    /// Nil when adding.
    public let editing: Transaction?
    public var merchant: String
    public var amountText: String
    public var note: String
    public var date: Date
    /// The Money in switch. Off, the entry is money spent, however the
    /// amount is typed. On, it is money in: income when added here, and an
    /// opened refund stays a refund (INC-01).
    public var isMoneyIn: Bool
    /// Where an opened entry is filed. Adding files into the budget on
    /// screen, and offers no choice.
    public var budgetID: BudgetID?
    /// What this person may do with the entry, as of opening it.
    public let access: EntryAccess
    /// Said once, when this device's last change to the entry didn't go
    /// through. Opening the entry takes the note off its row.
    public let noticeLine: String?
    /// What the last Save or Delete came to. Nil until one is tried.
    public private(set) var result: EntrySaveResult?
    /// The delete question, while it is asked. The sheet asks it itself, so
    /// it shows over the sheet.
    public private(set) var pendingDelete: PendingDelete?
    /// How this person's region writes numbers, for the amount.
    public let locale: Locale
    private let model: AppModel

    /// With `editing`, the entry fills the form, and only the fields changed
    /// from it are saved.
    public init(model: AppModel, editing: Transaction? = nil, date: Date = Date(),
                locale: Locale = AppLocale.current) {
        self.model = model
        self.editing = editing
        self.locale = locale
        merchant = editing?.merchant ?? ""
        amountText = editing.map { TypedAmount.text($0.amount.magnitude, locale: locale) } ?? ""
        note = editing?.note ?? ""
        self.date = editing?.date ?? date
        isMoneyIn = editing.map { $0.kind.isMoneyIn || ($0.kind == .transfer && $0.amount.minorUnits > 0) } ?? false
        budgetID = editing?.budgetID
        access = editing.map { model.access(to: $0) } ?? .change
        noticeLine = editing.flatMap { model.takeNotice(of: $0.id) ? Words.notice : nil }
    }

    /// Opens an entry from the list, as it is stored now. Nil when there is
    /// no such entry.
    public convenience init?(model: AppModel, entry id: RecordID) {
        guard let stored = try? model.store.transaction(id) else { return nil }
        self.init(model: model, editing: stored)
    }

    public var title: String { editing == nil ? Words.title : Words.editTitle }
    public var saveLabel: String { editing == nil ? Words.add : Words.save }

    /// Someone it went to, and an amount read the way the region writes one.
    /// A negative or zero amount is taken as money out, as every entry is.
    public static func canAdd(merchant: String, amountText: String, locale: Locale = AppLocale.current) -> Bool {
        !merchant.trimmingCharacters(in: .whitespaces).isEmpty
            && TypedAmount(amountText, locale: locale).money != nil
    }

    public var canAdd: Bool { Self.canAdd(merchant: merchant, amountText: amountText, locale: locale) }

    /// The empty amount field's example, written the region's way.
    public var amountPrompt: String { TypedAmount.text(Money(minorUnits: 0), locale: locale) }

    /// Under the amount, when what is typed can't be read clearly.
    public var amountProblem: String? {
        TypedAmount(amountText, locale: locale) == .unclear ? TypedAmount.Words.unclear(locale: locale) : nil
    }

    /// Add's rule, and for an opened entry, at least one field changed.
    public var canSave: Bool {
        guard !isReadOnly, canAdd else { return false }
        return editing == nil || changes != nil
    }

    /// When this person may not change it, or a Save or Delete just found
    /// it deleted, or found they may no longer change it.
    public var isReadOnly: Bool {
        switch result {
        case .deletedMeanwhile, .notAllowed: return true
        default: return !access.mayChange
        }
    }

    /// Under the details of a read-only entry: why.
    public var readOnlyLine: String? {
        switch result {
        case .deletedMeanwhile(let who): return Words.deleted(by: who)
        case .notAllowed(let now): return Words.notAllowed(now)
        default: return access.line
        }
    }

    /// Delete… is offered on an opened entry this person may change.
    public var offersDelete: Bool { editing != nil && !isReadOnly }

    /// One detail of a read-only entry, as plain text.
    public struct Detail: Identifiable, Equatable, Sendable {
        public let label: String
        public let value: String
        public var id: String { label }
    }

    /// A read-only entry's details, as plain text in place of the fields:
    /// the entry as it was opened, since nothing here can change it. Even
    /// after a refused Save, what was typed is not shown, because nothing
    /// was changed. The amount is money without its sign, as in the list,
    /// and the note shows only when there is one. Empty when adding.
    public var details: [Detail] {
        guard let editing else { return [] }
        var shown = [Detail(label: Words.merchant, value: editing.merchant),
                     Detail(label: Words.amount, value: editing.amount.magnitude.display),
                     Detail(label: Words.date, value: Words.fullDate(editing.date))]
        if !editing.note.isEmpty { shown.append(Detail(label: Words.note, value: editing.note)) }
        if editing.kind != .spending { shown.append(Detail(label: Words.moneyIn, value: Words.name(of: editing.kind))) }
        if let budget = try? model.store.budget(editing.budgetID) {
            shown.append(Detail(label: Words.budget, value: budget.name))
        }
        return shown
    }

    /// Under the Money in switch while it is on: what money in does to the
    /// budget the entry goes in, by that budget's name. Nil while the switch
    /// is off, or when no budget is known yet.
    public var moneyInLine: String? {
        guard isMoneyIn, let id = budgetID ?? model.selectedBudget,
              let budget = model.budget(for: id) else { return nil }
        return Words.moneyInHelp(budget: budget.name)
    }

    /// Above the details: who added it, once someone else is in the group,
    /// as the list's Added by column decides. Then where it came from, in
    /// the list's words, and what it is when it is not plain spending:
    /// Income, Refund, and so on.
    public var topLine: String? {
        guard let editing else { return nil }
        var parts: [String] = []
        if model.isShared(editing.groupID) {
            let mine = editing.createdBy == nil || editing.createdBy == model.me()
            let name = editing.createdBy.flatMap { model.memberName($0, in: editing.groupID) }
            parts.append(Words.addedBy(mine ? Words.you : name ?? Words.aMember))
        }
        parts.append(editing.source.rawValue.capitalized)
        if editing.kind != .spending { parts.append(Words.name(of: editing.kind)) }
        return parts.joined(separator: " \u{00B7} ")
    }

    /// The kind the switch stands for on an opened entry: off is spending;
    /// on keeps a money-in kind the entry already has, and makes anything
    /// else income.
    private var switchedKind: TransactionKind? {
        guard let editing else { return nil }
        let wasMoneyIn = editing.kind.isMoneyIn || (editing.kind == .transfer && editing.amount.minorUnits > 0)
        if isMoneyIn == wasMoneyIn { return nil }
        return isMoneyIn ? .income : .spending
    }

    /// The budgets an opened entry may move to: the live ones in its own
    /// group. A group is what is shared, so an entry never leaves it.
    public var budgetChoices: [Budget] {
        guard let editing else { return [] }
        return model.summaries[editing.groupID]?.map(\.budget) ?? []
    }

    /// Under the date, when it falls outside the period the list shows, so
    /// nobody wonders where the entry went once it is saved.
    public var periodLine: String? {
        guard editing != nil, let budgetID, let budget = model.budget(for: budgetID) else { return nil }
        return budget.reset.period(containing: Date()).contains(date) ? nil : Words.outOfPeriod
    }

    /// The fields changed from the entry as opened, or nil when none is.
    /// Amounts compare as money, so 142.1 and 142.10 are the same, and
    /// dates by the day the field shows.
    private var changes: EntryChange? {
        guard let editing else { return nil }
        var changes = EntryChange()
        if merchant != editing.merchant { changes.merchant = merchant }
        if let amount = TypedAmount(amountText, currency: editing.amount.currency, locale: locale).money,
           amount.magnitude != editing.amount.magnitude {
            changes.amount = amount.magnitude
        }
        if !AppLocale.calendar.isDate(date, inSameDayAs: editing.date) { changes.date = date }
        if note != editing.note { changes.note = note }
        if let budgetID, budgetID != editing.budgetID { changes.budget = budgetID }
        if let kind = switchedKind { changes.kind = kind }
        return changes == EntryChange() ? nil : changes
    }

    /// True when added. It goes in the budget on screen; with none, nothing
    /// is added.
    @discardableResult
    public func add() -> Bool {
        guard canAdd, let amount = TypedAmount(amountText, locale: locale).money,
              let budget = model.selectedBudget, model.budget(for: budget) != nil else { return false }
        model.addTransaction(merchant: merchant, amount: amount, date: date, note: note,
                             kind: isMoneyIn ? .income : .spending)
        return model.errorMessage == nil
    }

    /// Adds, or saves only the fields changed here. True when the sheet may
    /// close. Otherwise the result says why, and the sheet draws it.
    @discardableResult
    public func save() -> Bool {
        guard let editing else { return add() }
        guard canSave, let changes else { return false }
        result = model.updateEntry(editing.id, changes)
        return result == .saved
    }

    /// Delete… asks first. When the entry was deleted meanwhile, or this
    /// person may no longer change it, there is nothing to ask: the sheet
    /// turns read-only and says why.
    public func askDelete() {
        guard let editing, offersDelete else { return }
        if let refusal = model.refusal(toChange: editing.id) {
            result = refusal
            return
        }
        pendingDelete = model.deleteQuestion(for: editing.id)
    }

    /// The question's Cancel: nothing changes, and the sheet stays open.
    public func cancelDelete() { pendingDelete = nil }

    /// The question's Delete, for the entry the sheet is about, whether or
    /// not the question is still up: a dialog may close before its button's
    /// action runs. True when the sheet may close.
    @discardableResult
    public func confirmDelete() -> Bool {
        pendingDelete = nil
        guard let editing, !isReadOnly else { return false }
        result = model.deleteEntry(editing.id)
        return result == .saved
    }

    public enum Words {
        public static let title = "New transaction"
        public static let editTitle = "Transaction"
        public static let merchant = "Merchant"
        public static let amount = "Amount"
        public static let date = "Date"
        public static let note = "Note"
        public static let budget = "Budget"
        public static let add = "Add"
        public static let save = "Save"
        public static let cancel = "Cancel"
        public static let done = "Done"
        public static let delete = "Delete\u{2026}"
        public static let refund = "Refund"
        /// The switch's label. Placeholder words until the word check.
        public static let moneyIn = "Money in"
        /// Under the switch while it is on. Placeholder words too.
        public static func moneyInHelp(budget: String) -> String { "Adds to \(budget) instead of spending from it." }
        public static let income = "Income"
        public static let transfer = "Transfer"
        public static let borrowed = "Borrowed"
        public static let fromSavings = "From savings"
        public static let cardPayment = "Card payment"
        /// What an entry is, for the top line and the import review. Spending
        /// has no word: it is what every entry was.
        public static func name(of kind: TransactionKind) -> String {
            switch kind {
            case .spending: return ""
            case .refund: return refund
            case .income: return income
            case .transfer: return transfer
            case .loanDraw: return borrowed
            case .savingsDraw: return fromSavings
            case .cardPayment: return cardPayment
            }
        }
        public static let you = "you"
        public static let aMember = "a member"
        public static func addedBy(_ who: String) -> String { "Added by \(who)" }
        /// A read-only entry's date, such as "Oct 5, 2026".
        public static func fullDate(_ date: Date) -> String {
            date.formatted(Date.FormatStyle(date: .abbreviated, time: .omitted, locale: AppLocale.current,
                                            calendar: AppLocale.calendar))
        }
        public static let outOfPeriod = "This moves it out of this period."
        public static let notice = "Your last change to this didn't go through. This is the version everyone sees."
        public static let nothingChanged = "Nothing was changed."
        /// After a move down: nothing was saved, and why.
        public static func notAllowed(_ access: EntryAccess) -> String {
            ([nothingChanged] + [access.line].compactMap { $0 }).joined(separator: " ")
        }
        public static func deleted(by who: EntrySaveResult.Deleter) -> String {
            switch who {
            case .you: return "You deleted this on another computer while it was open here."
            case .someone(let name?): return "\(name) deleted this while you had it open."
            case .someone(nil): return "Someone deleted this while you had it open."
            }
        }
        public static func budgetGone(_ budget: String) -> String {
            "Nothing was changed, because \(budget) was deleted."
        }
        public static func budgetElsewhere(_ budget: String) -> String {
            "Nothing was changed, because \(budget) is in another group."
        }
    }
}
