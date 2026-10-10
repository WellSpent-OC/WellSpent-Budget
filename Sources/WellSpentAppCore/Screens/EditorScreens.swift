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
    private let model: AppModel

    public init(model: AppModel, editing: Budget? = nil, group: GroupID? = nil, groups: [BudgetGroup]? = nil) {
        self.model = model
        self.editing = editing
        self.groups = groups ?? model.groups
        name = editing?.name ?? ""
        amountText = editing.map { $0.limit.magnitude.description } ?? ""
        groupID = editing?.groupID ?? group ?? self.groups.first?.id
    }

    public var title: String { editing == nil ? Words.newTitle : Words.editTitle }
    public var saveLabel: String { editing == nil ? Words.add : Words.save }

    /// No group to put it in: the form asks for a new group's name instead.
    public var needsNewGroup: Bool { editing == nil && groups.isEmpty }
    /// A new budget, with groups to choose from.
    public var showsGroupPicker: Bool { editing == nil && !groups.isEmpty }

    /// A name, and an amount above zero.
    public static func canSave(name: String, amountText: String) -> Bool {
        guard !name.trimmingCharacters(in: .whitespaces).isEmpty,
              let amount = StatementParser.parseAmount(amountText, currency: .usd) else { return false }
        return amount.minorUnits != 0
    }

    public var canSave: Bool {
        Self.canSave(name: name, amountText: amountText)
            && (!needsNewGroup || !newGroupName.trimmingCharacters(in: .whitespaces).isEmpty)
    }

    /// True when saved.
    @discardableResult
    public func save() -> Bool {
        guard canSave, let amount = StatementParser.parseAmount(amountText, currency: .usd) else { return false }
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
        public static let amountPrompt = "500.00"
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

/// Money spent, added by hand to the budget on screen.
@MainActor
@Observable
public final class EntryEditor {
    public var merchant = ""
    public var amountText = ""
    public var note = ""
    public var date: Date
    private let model: AppModel

    public init(model: AppModel, date: Date = Date()) {
        self.model = model
        self.date = date
    }

    public var title: String { Words.title }

    /// Someone it went to, and an amount. A negative or zero amount is taken
    /// as money out, as every entry is.
    public static func canAdd(merchant: String, amountText: String) -> Bool {
        !merchant.trimmingCharacters(in: .whitespaces).isEmpty
            && StatementParser.parseAmount(amountText, currency: .usd) != nil
    }

    public var canAdd: Bool { Self.canAdd(merchant: merchant, amountText: amountText) }

    /// True when added. It goes in the budget on screen; with none, nothing
    /// is added.
    @discardableResult
    public func add() -> Bool {
        guard canAdd, let amount = StatementParser.parseAmount(amountText, currency: .usd),
              let budget = model.selectedBudget, model.budget(for: budget) != nil else { return false }
        model.addTransaction(merchant: merchant, amount: amount, date: date, note: note)
        return model.errorMessage == nil
    }

    public enum Words {
        public static let title = "New transaction"
        public static let merchant = "Merchant"
        public static let amount = "Amount"
        public static let date = "Date"
        public static let note = "Note"
        public static let add = "Add"
        public static let cancel = "Cancel"
    }
}
