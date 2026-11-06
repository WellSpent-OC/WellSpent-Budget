// The iPhone's screens, built the iPhone's way. Layout only.
#if os(iOS)
import SwiftUI
import WellSpentCrypto
import WellSpentModel

extension RepeatEditor: Identifiable {
    public nonisolated var id: RecordID { ruleID }
}

/// A budget's repeats: a short list, each opening its own sheet (REPEAT-12).
struct PhoneRepeatsListSheet: View {
    let budget: Budget
    let model: AppModel
    @State private var opened: RepeatEditor?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let list = RepeatsList(budget: budget, model: model)
        NavigationStack {
            Form {
                Section {
                    ForEach(list.rows) { row in
                        Button {
                            opened = RepeatEditor(model: model, rule: row.id)
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(row.name)
                                        .foregroundStyle(Palette.ink)
                                    Text(row.line)
                                        .font(.footnote)
                                        .foregroundStyle(Palette.muted)
                                }
                                Spacer(minLength: 8)
                                Text(row.amount)
                                    .monospacedDigit()
                                    .foregroundStyle(Palette.ink)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier(AccessibilityID.repeatRow(row.name))
                    }
                }
                .listRowBackground(Palette.surface)
            }
            .phoneSheet(title: list.title)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(RepeatsList.Words.done) { dismiss() }
                }
            }
            .sheet(item: $opened) { PhoneRepeatRuleSheet(editor: $0) }
        }
    }
}

/// A repeat's own sheet. Read only below its owner or a manager, with Close its
/// one button. Stop repeating is a row of its own at the end.
private struct PhoneRepeatRuleSheet: View {
    @State var editor: RepeatEditor
    @State private var confirmsStop = false
    @Environment(\.dismiss) private var dismiss
    private typealias Words = RepeatEditor.Words

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    PhoneField(Words.merchant) {
                        TextField(Words.merchant, text: $editor.name)
                            .textInputAutocapitalization(.words)
                    }
                    PhoneField(Words.amount) {
                        TextField(Words.amount, text: $editor.amountText)
                            .keyboardType(.decimalPad)
                    }
                    PhoneField(Words.day) {
                        TextField(Words.day, text: $editor.dayText)
                            .keyboardType(.numberPad)
                    }
                    if let offered = editor.linkChoices {
                        Picker(offered.label, selection: $editor.linkID) {
                            Text(EntryEditor.Words.noLink).tag(RecordID?.none)
                            ForEach(offered.choices) { Text($0.name).tag(RecordID?.some($0.id)) }
                        }
                        .pickerStyle(.menu)
                    }
                } header: {
                    Text(Words.subtitle)
                } footer: {
                    Text(editor.readOnlyLine ?? Words.note)
                }
                .disabled(!editor.mayChange)
                .listRowBackground(Palette.surface)

                if editor.mayChange {
                    Section {
                        Button {
                            confirmsStop = true
                        } label: {
                            Text(PhoneWording.button(Words.stop))
                                .foregroundStyle(Palette.warning)
                                .frame(maxWidth: .infinity)
                        }
                        .accessibilityIdentifier(AccessibilityID.repeatStop)
                        .confirmationDialog(Words.stopTitle, isPresented: $confirmsStop, titleVisibility: .visible) {
                            Button(Words.stopConfirm, role: .destructive) {
                                editor.stop()
                                dismiss()
                            }
                            Button(Words.cancel, role: .cancel) {}
                        } message: {
                            Text(Words.stopMessage)
                        }
                    }
                    .listRowBackground(Palette.surface)
                }
            }
            .phoneSheet(title: editor.name)
            .toolbar {
                if editor.mayChange {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(Words.cancel) { dismiss() }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button(Words.save) { if editor.save() { dismiss() } }
                            .disabled(!editor.canSave)
                            .accessibilityIdentifier(AccessibilityID.repeatSave)
                    }
                } else {
                    ToolbarItem(placement: .confirmationAction) {
                        Button(Words.close) { dismiss() }
                    }
                }
            }
        }
    }
}
#endif
