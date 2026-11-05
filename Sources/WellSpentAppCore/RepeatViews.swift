#if os(macOS)
import SwiftUI
import WellSpentCrypto
import WellSpentExtensionKit
import WellSpentModel

/// A budget's repeats: a short list, each opening its own sheet. Layout only.
struct RepeatsListSheet: View {
    let budget: Budget
    let model: AppModel
    @State private var opened: RepeatEditor?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let list = RepeatsList(budget: budget, model: model)
        VStack(alignment: .leading, spacing: 12) {
            Text(list.title)
                .font(.system(size: 17, weight: .semibold))
            ForEach(list.rows) { row in
                Button {
                    opened = RepeatEditor(model: model, rule: row.id)
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(row.name)
                            Text(row.line)
                                .font(.system(size: 11))
                                .foregroundStyle(Palette.muted)
                        }
                        Spacer()
                        Text(row.amount)
                            .monospacedDigit()
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier(AccessibilityID.repeatRow(row.name))
                if row != list.rows.last { Divider() }
            }
            HStack {
                Spacer()
                Button(RepeatsList.Words.done) { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 420)
        .sheet(item: $opened) { RepeatRuleSheet(editor: $0) }
    }
}

extension RepeatEditor: Identifiable {
    public nonisolated var id: RecordID { ruleID }
}

/// A repeat's own sheet. Read only below its owner or a manager. Layout only.
struct RepeatRuleSheet: View {
    @State var editor: RepeatEditor
    @State private var confirmsStop = false
    @Environment(\.dismiss) private var dismiss
    private typealias Words = RepeatEditor.Words

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(editor.name)
                    .font(.system(size: 17, weight: .semibold))
                Text(Words.subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.muted)
            }
            Form {
                TextField(Words.merchant, text: $editor.name)
                TextField(Words.amount, text: $editor.amountText)
                TextField(Words.day, text: $editor.dayText)
                if let offered = editor.linkChoices {
                    Picker(offered.label, selection: $editor.linkID) {
                        Text(EntryEditor.Words.noLink).tag(RecordID?.none)
                        ForEach(offered.choices) { Text($0.name).tag(RecordID?.some($0.id)) }
                    }
                }
            }
            .formStyle(.grouped)
            .disabled(!editor.mayChange)
            Text(editor.readOnlyLine ?? Words.note)
                .font(.system(size: 12))
                .foregroundStyle(Palette.muted)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                if editor.mayChange {
                    Button(Words.stop) { confirmsStop = true }
                        .accessibilityIdentifier(AccessibilityID.repeatStop)
                }
                Spacer()
                if editor.mayChange {
                    Button(Words.cancel) { dismiss() }
                        .keyboardShortcut(.cancelAction)
                    Button(Words.save) { if editor.save() { dismiss() } }
                        .keyboardShortcut(.defaultAction)
                        .disabled(!editor.canSave)
                        .accessibilityIdentifier(AccessibilityID.repeatSave)
                } else {
                    Button(Words.close) { dismiss() }
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(20)
        .frame(width: 420)
        .confirmationDialog(Words.stopTitle, isPresented: $confirmsStop) {
            Button(Words.stopConfirm, role: .destructive) {
                editor.stop()
                dismiss()
            }
            Button(Words.cancel, role: .cancel) {}
        } message: {
            Text(Words.stopMessage)
        }
    }
}
#endif
