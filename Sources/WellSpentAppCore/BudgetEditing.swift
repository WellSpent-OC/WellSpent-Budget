import SwiftUI
import WellSpentCrypto
import WellSpentImport
import WellSpentModel

// MARK: - Which sheet

/// The sidebar's editing sheets. One value rather than four booleans, so only one
/// can ever be open.
enum EditorSheet: Identifiable {
    case newBudget(in: GroupID?)
    case editBudget(Budget)
    case newGroup
    case renameGroup(BudgetGroup)
    case share(BudgetGroup)
    case join

    var id: String {
        switch self {
        case .newBudget(let group): return "new-budget-\(group.map { "\($0)" } ?? "")"
        case .editBudget(let budget): return "edit-budget-\(budget.id)"
        case .newGroup: return "new-group"
        case .renameGroup(let group): return "rename-group-\(group.id)"
        case .share(let group): return "share-\(group.id)"
        case .join: return "join"
        }
    }
}

/// What a delete is waiting on the person to confirm.
enum PendingDelete: Identifiable {
    case budget(Budget, transactions: Int)
    case group(BudgetGroup, budgets: Int, reach: GroupDeleteReach)

    var id: String {
        switch self {
        case .budget(let budget, _): return "budget-\(budget.id)"
        case .group(let group, _, _): return "group-\(group.id)"
        }
    }

    var title: String {
        switch self {
        case .budget(let budget, _): return "Delete \u{201C}\(budget.name)\u{201D}?"
        case .group(let group, _, _): return "Delete \u{201C}\(group.name)\u{201D}?"
        }
    }

    var message: String {
        switch self {
        case .budget(_, let count):
            return count == 0
                ? "This cannot be undone."
                : "Its \(count) transaction\(count == 1 ? "" : "s") will be deleted too. This cannot be undone."
        case .group(_, let count, let reach):
            let contents = count == 0
                ? ""
                : "Its \(count) budget\(count == 1 ? "" : "s") and their transactions will be deleted too. "
            switch reach {
            case .justYou:
                return contents + "This cannot be undone."
            case .everyone:
                return "Everyone you share it with loses it too. " + contents + "This cannot be undone."
            case .thisMacOnly:
                return "It is removed from this Mac only. Other members keep it. "
                    + "Changes you made to it that have not synced yet, deletes included, still go to them, "
                    + "except a budget you added since your last sync, which is dropped with everything in it. "
                    + "Only the person who made it, or an admin, can delete it for everyone. "
                    + "To get it back, ask for a new invite link."
            case .declinesInvite:
                return "This removes the group from this Mac. Your answer to the invite has already "
                    + "been sent, so the person who invited you may still add you. Nothing of theirs "
                    + "changes. To get it back, ask for a new invite link."
            }
        }
    }
}

// MARK: - Budget

struct BudgetSheet: View {
    @Bindable var model: AppModel
    /// Nil when adding.
    let editing: Budget?
    /// The groups a new budget can go in: the ones this person manages.
    let groups: [BudgetGroup]
    @Environment(\.dismiss) private var dismiss

    @State private var name: String
    @State private var amountText: String
    @State private var groupID: GroupID?
    @State private var newGroupName = "Personal"

    init(model: AppModel, editing: Budget? = nil, group: GroupID? = nil,
         groups: [BudgetGroup]? = nil) {
        self.model = model
        self.editing = editing
        self.groups = groups ?? model.groups
        _name = State(initialValue: editing?.name ?? "")
        _amountText = State(initialValue: editing.map { $0.limit.magnitude.description } ?? "")
        _groupID = State(initialValue: editing?.groupID ?? group ?? self.groups.first?.id)
    }

    /// A name, and an amount above zero. Lifted out so it can be tested without
    /// driving `@State`.
    static func canSave(name: String, amountText: String) -> Bool {
        guard !name.trimmingCharacters(in: .whitespaces).isEmpty,
              let amount = StatementParser.parseAmount(amountText, currency: .usd) else { return false }
        return amount.minorUnits != 0
    }

    /// With no group of their own to put it in, a new budget gets a new group.
    private var needsNewGroup: Bool { editing == nil && groups.isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(editing == nil ? "New Budget" : "Edit Budget")
                .font(.system(size: 17, weight: .semibold))

            Form {
                TextField("Name", text: $name, prompt: Text("Groceries"))
                TextField("Each month", text: $amountText, prompt: Text("500.00"))
                    .font(.money(13, weight: .regular))
                if needsNewGroup {
                    TextField("Group", text: $newGroupName)
                } else if editing == nil {
                    Picker("Group", selection: $groupID) {
                        ForEach(groups) { group in
                            Text(group.name).tag(GroupID?.some(group.id))
                        }
                    }
                }
            }
            .formStyle(.grouped)

            Text("Starts again on the 1st of each month.")
                .font(.system(size: 11))
                .foregroundStyle(Palette.muted)

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(editing == nil ? "Add" : "Save") {
                    save()
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!Self.canSave(name: name, amountText: amountText)
                          || (needsNewGroup && newGroupName.trimmingCharacters(in: .whitespaces).isEmpty))
            }
        }
        .padding(20)
        .frame(width: 400)
    }

    private func save() {
        guard let amount = StatementParser.parseAmount(amountText, currency: .usd) else { return }
        if let editing {
            model.updateBudget(editing.id, name: name, limit: amount)
            return
        }
        let group = needsNewGroup ? model.addGroup(named: newGroupName) : groupID
        guard let group else { return }
        model.addBudget(named: name, limit: amount, in: group)
    }
}

// MARK: - Group

struct GroupSheet: View {
    @Bindable var model: AppModel
    /// Nil when adding.
    let renaming: BudgetGroup?
    @Environment(\.dismiss) private var dismiss

    @State private var name: String

    init(model: AppModel, renaming: BudgetGroup? = nil) {
        self.model = model
        self.renaming = renaming
        _name = State(initialValue: renaming?.name ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(renaming == nil ? "New Group" : "Rename Group")
                .font(.system(size: 17, weight: .semibold))

            Form {
                TextField("Name", text: $name, prompt: Text("Household"))
            }
            .formStyle(.grouped)

            Text("A group holds budgets you track together. It is also what you will share with someone else.")
                .font(.system(size: 11))
                .foregroundStyle(Palette.muted)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(renaming == nil ? "Add" : "Save") {
                    if let renaming {
                        model.renameGroup(renaming.id, to: name)
                    } else {
                        model.addGroup(named: name)
                    }
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 400)
    }
}
