// The iPhone's screens, built the iPhone's way. Layout only.
#if os(iOS)
import SwiftUI
import WellSpentCrypto
import WellSpentModel

/// An entry opened from a budget's list, to change it, move it to another
/// budget in its group, or delete it. Draws `EntryEditor`. Cancel and Save
/// sit in the top bar, and Delete is a row of its own at the end. When this
/// person may not change it, the details are plain text with a line saying
/// why, and Done is the only button. A swipe down closes it unsaved, as
/// Cancel and Done do.
struct PhoneOpenedEntrySheet: View {
    @Bindable var editor: EntryEditor
    @Environment(\.dismiss) private var dismiss
    private typealias Words = EntryEditor.Words

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    if let top = editor.topLine {
                        Text(top)
                            .font(.footnote)
                            .foregroundStyle(Palette.muted)
                            .accessibilityIdentifier(AccessibilityID.entryTopLine)
                    }
                    if let notice = editor.noticeLine {
                        Text(notice)
                            .font(.footnote)
                            .foregroundStyle(Palette.ink)
                            .accessibilityIdentifier(AccessibilityID.entryNoticeLine)
                    }
                }
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: 0, leading: 4, bottom: 4, trailing: 4))

                if editor.isReadOnly {
                    details
                } else {
                    Section {
                        PhoneEntryFields(editor: editor)
                    }
                    .listRowBackground(Palette.surface)
                }

                if editor.offersDelete {
                    Section {
                        Button {
                            editor.askDelete()
                        } label: {
                            Text(PhoneWording.button(Words.delete))
                                .foregroundStyle(Palette.warning)
                                .frame(maxWidth: .infinity)
                        }
                        .accessibilityIdentifier(AccessibilityID.entryDelete)
                    }
                    .listRowBackground(Palette.surface)
                }
            }
            .phoneSheet(title: editor.title)
            .toolbar { buttons }
        }
        // The sheet asks its own question, from the bottom of the screen, so
        // it shows over the sheet. The red Delete stands apart from Cancel.
        .confirmationDialog(editor.pendingDelete?.title ?? "",
                            isPresented: Binding(get: { editor.pendingDelete != nil },
                                                 set: { if !$0 { editor.cancelDelete() } }),
                            titleVisibility: .visible,
                            presenting: editor.pendingDelete) { pending in
            Button(pending.confirmLabel, role: .destructive) {
                if editor.confirmDelete() { dismiss() }
            }
            Button(Words.cancel, role: .cancel) { editor.cancelDelete() }
        } message: { pending in
            Text(pending.message)
        }
    }

    /// The entry as plain text, with the line saying why it can't be changed.
    private var details: some View {
        Section {
            ForEach(editor.details) { detail in
                LabeledContent(detail.label) {
                    Text(detail.value)
                        .accessibilityIdentifier(AccessibilityID.entryDetail(detail.label))
                }
            }
        } footer: {
            if let line = editor.readOnlyLine {
                Text(line)
                    .foregroundStyle(Palette.ink)
                    .accessibilityIdentifier(AccessibilityID.entryReadOnlyLine)
            }
        }
        .listRowBackground(Palette.surface)
    }

    /// Cancel on the left and Save on the right, or Done alone when the
    /// entry can't be changed. A refused Save keeps the sheet open, and it
    /// turns read-only and says why.
    @ToolbarContentBuilder
    private var buttons: some ToolbarContent {
        if editor.isReadOnly {
            ToolbarItem(placement: .confirmationAction) {
                Button(Words.done) { dismiss() }
                    .accessibilityIdentifier(AccessibilityID.entryDone)
            }
        } else {
            ToolbarItem(placement: .cancellationAction) {
                Button(Words.cancel) { dismiss() }
                    .accessibilityIdentifier(AccessibilityID.entryCancel)
            }
            ToolbarItem(placement: .confirmationAction) {
                Button(editor.saveLabel) {
                    if editor.save() { dismiss() }
                }
                .disabled(!editor.canSave)
                .accessibilityIdentifier(AccessibilityID.entrySave)
            }
        }
    }
}

/// An entry's fields, the same for adding one and for one opened from the
/// list: Merchant, Amount, Date, Note, and for an opened entry its Budget,
/// with a line under the date when it moves the entry out of this period.
struct PhoneEntryFields: View {
    @Bindable var editor: EntryEditor
    private typealias Words = EntryEditor.Words

    var body: some View {
        PhoneField(Words.merchant) {
            TextField(Words.merchant, text: $editor.merchant)
                .textInputAutocapitalization(.words)
                .accessibilityIdentifier(AccessibilityID.entryMerchant)
        }
        PhoneField(Words.amount) {
            TextField(Words.amount, text: $editor.amountText)
                .keyboardType(.decimalPad)
                .accessibilityIdentifier(AccessibilityID.entryAmount)
        }
        if let problem = editor.amountProblem {
            Text(problem)
                .font(.footnote)
                .foregroundStyle(Palette.warning)
                .accessibilityIdentifier(AccessibilityID.entryAmountProblem)
        }
        DatePicker(Words.date, selection: $editor.date, displayedComponents: .date)
            .datePickerStyle(.compact)
            .accessibilityIdentifier(AccessibilityID.entryDate)
        if let line = editor.periodLine {
            Text(line)
                .font(.footnote)
                .foregroundStyle(Palette.warning)
                .accessibilityIdentifier(AccessibilityID.entryPeriodLine)
        }
        PhoneField(Words.note) {
            TextField(Words.note, text: $editor.note)
                .accessibilityIdentifier(AccessibilityID.entryNote)
        }
        if editor.editing != nil {
            Picker(Words.budget, selection: $editor.budgetID) {
                ForEach(editor.budgetChoices) { budget in
                    Text(budget.name).tag(BudgetID?.some(budget.id))
                }
            }
            .pickerStyle(.menu)
            .accessibilityIdentifier(AccessibilityID.entryBudget)
        }
    }
}

#endif
