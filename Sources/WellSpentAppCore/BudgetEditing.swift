// The Mac screens. SwiftUI exists only on Apple systems; the Linux app draws
// the same shared logic with its own screens.
#if canImport(SwiftUI)
import SwiftUI
import WellSpentCrypto
import WellSpentImport
import WellSpentModel

// MARK: - Which sheet

/// The window's editing sheets. One value rather than a boolean each, so only
/// one can ever be open.
enum EditorSheet: Identifiable {
    case newBudget(in: GroupID?)
    case editBudget(Budget)
    case newGroup
    case renameGroup(BudgetGroup)
    case share(BudgetGroup)
    case join
    /// An entry opened from the budget's list. The editor is made when the
    /// entry is opened, because opening it is what marks its note seen.
    case entry(EntryEditor)

    var id: String {
        switch self {
        case .newBudget(let group): return "new-budget-\(group.map { "\($0)" } ?? "")"
        case .editBudget(let budget): return "edit-budget-\(budget.id)"
        case .newGroup: return "new-group"
        case .renameGroup(let group): return "rename-group-\(group.id)"
        case .share(let group): return "share-\(group.id)"
        case .join: return "join"
        case .entry(let editor): return "entry-\(editor.editing.map { "\($0.id)" } ?? "")"
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
                    .accessibilityIdentifier(AccessibilityID.budgetEditorName)
                TextField(Words.amount, text: Bindable(editor).amountText, prompt: Text(editor.amountPrompt))
                    .font(.money(13, weight: .regular))
                    .accessibilityIdentifier(AccessibilityID.budgetEditorAmount)
                if let problem = editor.amountProblem {
                    Text(problem)
                        .font(.system(size: 11))
                        .foregroundStyle(Palette.warning)
                        .accessibilityIdentifier(AccessibilityID.budgetEditorAmountProblem)
                }
                if editor.needsNewGroup {
                    TextField(Words.group, text: Bindable(editor).newGroupName)
                        .accessibilityIdentifier(AccessibilityID.budgetEditorGroup)
                } else if editor.showsGroupPicker {
                    Picker(Words.group, selection: Bindable(editor).groupID) {
                        ForEach(editor.groups) { group in
                            Text(group.name).tag(GroupID?.some(group.id))
                        }
                    }
                    .accessibilityIdentifier(AccessibilityID.budgetEditorGroup)
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
                    .accessibilityIdentifier(AccessibilityID.budgetEditorCancel)
                Button(editor.saveLabel) {
                    editor.save()
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!editor.canSave)
                .accessibilityIdentifier(AccessibilityID.budgetEditorSave)
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
                    .accessibilityIdentifier(AccessibilityID.groupEditorName)
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
                    .accessibilityIdentifier(AccessibilityID.groupEditorCancel)
                Button(editor.saveLabel) {
                    editor.save()
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!editor.canSave)
                .accessibilityIdentifier(AccessibilityID.groupEditorSave)
            }
        }
        .padding(20)
        .frame(width: 400)
    }
}

#endif
