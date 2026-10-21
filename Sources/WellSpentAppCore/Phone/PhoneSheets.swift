// The iPhone's screens, built the iPhone's way. Layout only.
#if os(iOS)
import SwiftUI
import WellSpentCrypto
import WellSpentModel

// Every sheet here has Cancel on the left of the top bar and its main button
// on the right, and ends after its fields. A delete is a row of its own at
// the end.

/// A new entry. Draws `EntryEditor`. An entry opened from the list has its
/// own sheet, PhoneOpenedEntrySheet, with the same fields.
struct PhoneEntrySheet: View {
    @State private var editor: EntryEditor
    @Environment(\.dismiss) private var dismiss
    private typealias Words = EntryEditor.Words

    init(model: AppModel) {
        _editor = State(initialValue: EntryEditor(model: model))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    PhoneEntryFields(editor: editor)
                }
                .listRowBackground(Palette.surface)
            }
            .phoneSheet(title: editor.title)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(Words.cancel) { dismiss() }
                        .accessibilityIdentifier(AccessibilityID.entryCancel)
                }
                ToolbarItem(placement: .confirmationAction) {
                    // As on the Mac: the sheet closes, and a refusal shows on
                    // the window.
                    Button(Words.add) {
                        editor.add()
                        dismiss()
                    }
                    .disabled(!editor.canAdd)
                    .accessibilityIdentifier(AccessibilityID.entryAdd)
                }
            }
        }
    }
}

/// A new budget, or one being changed. Draws `BudgetEditor`.
struct PhoneBudgetSheet: View {
    @State private var editor: BudgetEditor
    /// Asks the delete question once the sheet has closed. Only for a budget
    /// being changed.
    private let delete: (() -> Void)?
    @Environment(\.dismiss) private var dismiss
    private typealias Words = BudgetEditor.Words

    init(model: AppModel, editing: Budget? = nil, group: GroupID? = nil, groups: [BudgetGroup]? = nil,
         delete: (() -> Void)? = nil) {
        _editor = State(initialValue: BudgetEditor(model: model, editing: editing, group: group, groups: groups))
        self.delete = delete
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    PhoneField(Words.name) {
                        TextField(Words.name, text: Bindable(editor).name, prompt: Text(Words.namePrompt))
                            .textInputAutocapitalization(.words)
                            .accessibilityIdentifier(AccessibilityID.budgetEditorName)
                    }
                    PhoneField(Words.amount) {
                        TextField(Words.amount, text: Bindable(editor).amountText, prompt: Text(editor.amountPrompt))
                            .keyboardType(.decimalPad)
                            .accessibilityIdentifier(AccessibilityID.budgetEditorAmount)
                    }
                    if let problem = editor.amountProblem {
                        Text(problem)
                            .font(.footnote)
                            .foregroundStyle(Palette.warning)
                            .accessibilityIdentifier(AccessibilityID.budgetEditorAmountProblem)
                    }
                    if editor.needsNewGroup {
                        PhoneField(Words.group) {
                            TextField(Words.group, text: Bindable(editor).newGroupName)
                                .textInputAutocapitalization(.words)
                                .accessibilityIdentifier(AccessibilityID.budgetEditorGroup)
                        }
                    } else if editor.showsGroupPicker {
                        Picker(Words.group, selection: Bindable(editor).groupID) {
                            ForEach(editor.groups) { group in
                                Text(group.name).tag(GroupID?.some(group.id))
                            }
                        }
                        .accessibilityIdentifier(AccessibilityID.budgetEditorGroup)
                    }
                } footer: {
                    Text(Words.resets)
                }
                .listRowBackground(Palette.surface)

                if let delete {
                    Section {
                        Button(role: .destructive) {
                            delete()
                            dismiss()
                        } label: {
                            Text(MainScreen.Words.delete)
                                .frame(maxWidth: .infinity)
                        }
                    }
                    .listRowBackground(Palette.surface)
                }
            }
            .phoneSheet(title: editor.title)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(Words.cancel) { dismiss() }
                        .accessibilityIdentifier(AccessibilityID.budgetEditorCancel)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(editor.saveLabel) {
                        editor.save()
                        dismiss()
                    }
                    .disabled(!editor.canSave)
                    .accessibilityIdentifier(AccessibilityID.budgetEditorSave)
                }
            }
        }
    }
}

/// A new group, or a group's new name. Draws `GroupEditor`.
struct PhoneGroupSheet: View {
    @State private var editor: GroupEditor
    @Environment(\.dismiss) private var dismiss
    private typealias Words = GroupEditor.Words

    init(model: AppModel, renaming: BudgetGroup? = nil) {
        _editor = State(initialValue: GroupEditor(model: model, renaming: renaming))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    PhoneField(Words.name) {
                        TextField(Words.name, text: Bindable(editor).name, prompt: Text(Words.namePrompt))
                            .textInputAutocapitalization(.words)
                            .accessibilityIdentifier(AccessibilityID.groupEditorName)
                    }
                } footer: {
                    Text(Words.explanation)
                }
                .listRowBackground(Palette.surface)
            }
            .phoneSheet(title: editor.title)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(Words.cancel) { dismiss() }
                        .accessibilityIdentifier(AccessibilityID.groupEditorCancel)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(editor.saveLabel) {
                        editor.save()
                        dismiss()
                    }
                    .disabled(!editor.canSave)
                    .accessibilityIdentifier(AccessibilityID.groupEditorSave)
                }
            }
        }
    }
}

/// A field with its label above it, in small words, as in the design.
/// The label also names the field for VoiceOver, through the field's own.
struct PhoneField<Field: View>: View {
    let label: String
    @ViewBuilder let field: Field

    init(_ label: String, @ViewBuilder field: () -> Field) {
        self.label = label
        self.field = field()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.caption)
                .foregroundStyle(Palette.muted)
                .accessibilityHidden(true)
            field
        }
        .padding(.vertical, 2)
    }
}

extension View {
    /// A sheet's form on the page colour, with its title in the top bar.
    func phoneSheet(title: String) -> some View {
        scrollContentBackground(.hidden)
            .background(Palette.ground)
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
    }
}

#endif
