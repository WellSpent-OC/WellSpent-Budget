import Foundation
import SwiftCrossUI
import WellSpentAppCore
import WellSpentModel

/// What the repeats sheet shows: a budget's short list, or one repeat's own
/// sheet chosen from it. One sheet at a time, as everywhere here, so a repeat
/// opens in the list's place, and closing it goes back to the list.
enum RepeatsSheet {
    case list(Budget)
    case rule(RepeatEditor, from: Budget)
}

/// A budget's repeats: a short list, each row opening its own sheet
/// (REPEAT-12). What it says is RepeatsList's. Layout only.
struct RepeatsListView: View {
    let budget: Budget
    let model: AppModel
    var open: (RepeatEditor) -> Void
    var close: () -> Void

    var body: some View {
        let list = RepeatsList(budget: budget, model: model)
        VStack(alignment: .leading, spacing: 12) {
            Text(list.title)
                .font(.system(size: 17, weight: .semibold))
            ForEach(list.rows) { row in
                Button(action: { RepeatEditor(model: model, rule: row.id).map(open) }) {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(row.name)
                            Text(row.line)
                                .font(.system(size: 11))
                                .foregroundColor(Palette.muted)
                        }
                        Spacer()
                        Text(row.amount)
                    }
                }
                .buttonStyle(.plain)
            }
            HStack {
                Spacer()
                Button(RepeatsList.Words.done) { close() }
                    .defaultAction()
            }
        }
        .padding(20)
        .frame(width: 420)
        .foregroundColor(Palette.ink)
        .background(Palette.surface)
    }
}

/// A repeat's own sheet: what changes from this month on, or Stop repeating.
/// Below its owner or a manager it says so, with nothing to change (REPEAT-11,
/// 12). What it says and does is RepeatEditor's. Layout only.
struct RepeatRuleView: View {
    @State var editor: RepeatEditor
    @State private var confirmsStop = false
    var close: () -> Void
    private typealias Words = RepeatEditor.Words

    init(editor: RepeatEditor, close: @escaping () -> Void) {
        _editor = State(wrappedValue: editor)
        self.close = close
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(editor.name)
                    .font(.system(size: 17, weight: .semibold))
                Text(Words.subtitle)
                    .font(.system(size: 11))
                    .foregroundColor(Palette.muted)
            }
            if editor.mayChange {
                Field(label: Words.merchant, prompt: Words.merchant,
                      text: Binding(get: { editor.name }, set: { editor.name = $0 }))
                Field(label: Words.amount, prompt: Words.amount,
                      text: Binding(get: { editor.amountText }, set: { editor.amountText = $0 }))
                Field(label: Words.day, prompt: Words.day,
                      text: Binding(get: { editor.dayText }, set: { editor.dayText = $0 }))
            } else {
                // Nothing to change, so the terms as plain words, as a
                // read-only entry shows its details.
                VStack(alignment: .leading, spacing: 6) {
                    ForEach([(Words.amount, editor.amountText), (Words.day, editor.dayText)], id: \.0) { label, value in
                        HStack(alignment: .top, spacing: 12) {
                            Text(label)
                                .font(.system(size: 12))
                                .foregroundColor(Palette.muted)
                                .frame(width: 110, alignment: .leading)
                            Text(value)
                        }
                    }
                }
            }
            Note(editor.readOnlyLine ?? Words.note)
            // Each button keeps its width, as on an entry's sheet.
            HStack {
                if editor.mayChange {
                    Button(Words.stop) { confirmsStop = true }
                        .fixedSize()
                }
                Spacer()
                if editor.mayChange {
                    Button(Words.cancel) { close() }
                        .fixedSize()
                    Button(Words.save) { if editor.save() { close() } }
                        .defaultAction()
                        .disabled(!editor.canSave)
                        .fixedSize()
                } else {
                    Button(Words.close) { close() }
                        .defaultAction()
                }
            }
        }
        .padding(20)
        .frame(width: 420)
        .foregroundColor(Palette.ink)
        .background(Palette.surface)
        // GTK's alert has a title and no message, so the two go together.
        .alert("\(Words.stopTitle)\n\n\(Words.stopMessage)", isPresented: $confirmsStop) {
            // Cancel first: GTK focuses the first button, so Return keeps it.
            Button(Words.cancel) {}
            Button(Words.stopConfirm) {
                editor.stop()
                close()
            }
        }
    }
}
