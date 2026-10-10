// The Mac screens. SwiftUI exists only on Apple systems; the Linux app draws
// the same shared logic with its own screens.
#if canImport(SwiftUI)
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
    case members(BudgetGroup)

    var id: String {
        switch self {
        case .newBudget(let group): return "new-budget-\(group.map { "\($0)" } ?? "")"
        case .editBudget(let budget): return "edit-budget-\(budget.id)"
        case .newGroup: return "new-group"
        case .renameGroup(let group): return "rename-group-\(group.id)"
        case .share(let group): return "share-\(group.id)"
        case .join: return "join"
        case .members(let group): return "members-\(group.id)"
        }
    }
}

// MARK: - Budget

/// Draws BudgetEditor. What it checks and says lives there, shared with every
/// desktop; this is layout only.
struct BudgetSheet: View {
    @State private var editor: BudgetEditor
    @Environment(\.dismiss) private var dismiss
    private typealias Words = BudgetEditor.Words

    init(model: AppModel, editing: Budget? = nil, group: GroupID? = nil, groups: [BudgetGroup]? = nil) {
        _editor = State(initialValue: BudgetEditor(model: model, editing: editing, group: group, groups: groups))
    }

    static func canSave(name: String, amountText: String) -> Bool {
        BudgetEditor.canSave(name: name, amountText: amountText)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(editor.title)
                .font(.system(size: 17, weight: .semibold))

            Form {
                TextField(Words.name, text: Bindable(editor).name, prompt: Text(Words.namePrompt))
                TextField(Words.amount, text: Bindable(editor).amountText, prompt: Text(Words.amountPrompt))
                    .font(.money(13, weight: .regular))
                if editor.needsNewGroup {
                    TextField(Words.group, text: Bindable(editor).newGroupName)
                } else if editor.showsGroupPicker {
                    Picker(Words.group, selection: Bindable(editor).groupID) {
                        ForEach(editor.groups) { group in
                            Text(group.name).tag(GroupID?.some(group.id))
                        }
                    }
                }
            }
            .formStyle(.grouped)

            Text(Words.resets)
                .font(.system(size: 11))
                .foregroundStyle(Palette.muted)

            HStack {
                Spacer()
                Button(Words.cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(editor.saveLabel) {
                    editor.save()
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!editor.canSave)
            }
        }
        .padding(20)
        .frame(width: 400)
    }
}

// MARK: - Group

/// Draws GroupEditor; layout only.
struct GroupSheet: View {
    @State private var editor: GroupEditor
    @Environment(\.dismiss) private var dismiss
    private typealias Words = GroupEditor.Words

    init(model: AppModel, renaming: BudgetGroup? = nil) {
        _editor = State(initialValue: GroupEditor(model: model, renaming: renaming))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(editor.title)
                .font(.system(size: 17, weight: .semibold))

            Form {
                TextField(Words.name, text: Bindable(editor).name, prompt: Text(Words.namePrompt))
            }
            .formStyle(.grouped)

            Text(Words.explanation)
                .font(.system(size: 11))
                .foregroundStyle(Palette.muted)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Spacer()
                Button(Words.cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(editor.saveLabel) {
                    editor.save()
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!editor.canSave)
            }
        }
        .padding(20)
        .frame(width: 400)
    }
}

#endif
