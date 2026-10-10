import Foundation
import Observation
import SwiftCrossUI
import WellSpentAppCore
import WellSpentCrypto
import WellSpentImport
import WellSpentModel

/// One choice in a picker. GTK's picker shows each option's description, so
/// the words go there and the value beside them.
struct Choice<Value: Equatable>: Equatable, CustomStringConvertible {
    let value: Value
    let description: String

    static func == (a: Choice, b: Choice) -> Bool { a.value == b.value }
}

/// A labelled text field, with the problem under it when there is one.
struct Field: View {
    let label: String
    let prompt: String
    var text: Binding<String>
    var problem: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.system(size: 12))
            TextField(prompt, text: text)
            if let problem {
                Text(problem)
                    .font(.system(size: 11))
                    .foregroundColor(.red)
            }
        }
    }
}

/// Grey small print under a form.
struct Note: View {
    let text: String
    var warning = false

    init(_ text: String, warning: Bool = false) {
        self.text = text
        self.warning = warning
    }

    var body: some View {
        Text(text)
            .font(.system(size: 12))
            .foregroundColor(warning ? .red : .gray)
    }
}

// MARK: - Budget

/// Draws BudgetEditor. Layout only.
struct BudgetEditorView: View {
    @State var editor: BudgetEditor
    var close: () -> Void
    private typealias Words = BudgetEditor.Words

    init(editor: BudgetEditor, close: @escaping () -> Void) {
        _editor = State(wrappedValue: editor)
        self.close = close
    }

    private var groupChoices: [Choice<GroupID>] {
        editor.groups.map { Choice(value: $0.id, description: $0.name) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(editor.title)
                .font(.title3)
            Field(label: Words.name, prompt: Words.namePrompt,
                  text: Binding(get: { editor.name }, set: { editor.name = $0 }))
            Field(label: Words.amount, prompt: Words.amountPrompt,
                  text: Binding(get: { editor.amountText }, set: { editor.amountText = $0 }))
            if editor.needsNewGroup {
                Field(label: Words.group, prompt: Words.defaultGroupName,
                      text: Binding(get: { editor.newGroupName }, set: { editor.newGroupName = $0 }))
            } else if editor.showsGroupPicker {
                Text(Words.group)
                    .font(.system(size: 12))
                Picker(of: groupChoices, selection: Binding(
                    get: { groupChoices.first { $0.value == editor.groupID } },
                    set: { editor.groupID = $0?.value }))
            }
            Note(Words.resets)
            HStack {
                Spacer()
                Button(Words.cancel) { close() }
                Button(editor.saveLabel) {
                    if editor.save() { close() }
                }
                .disabled(!editor.canSave)
            }
        }
        .padding(20)
        .frame(width: 420)
    }
}

// MARK: - Group

/// Draws GroupEditor. Layout only.
struct GroupEditorView: View {
    @State var editor: GroupEditor
    var close: () -> Void
    private typealias Words = GroupEditor.Words

    init(editor: GroupEditor, close: @escaping () -> Void) {
        _editor = State(wrappedValue: editor)
        self.close = close
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(editor.title)
                .font(.title3)
            Field(label: Words.name, prompt: Words.namePrompt,
                  text: Binding(get: { editor.name }, set: { editor.name = $0 }))
            Note(Words.explanation)
            HStack {
                Spacer()
                Button(Words.cancel) { close() }
                Button(editor.saveLabel) {
                    if editor.save() { close() }
                }
                .disabled(!editor.canSave)
            }
        }
        .padding(20)
        .frame(width: 420)
    }
}

// MARK: - Entry

/// Draws EntryEditor: money spent, added to the budget on screen.
struct EntryEditorView: View {
    @State var editor: EntryEditor
    var close: () -> Void
    private typealias Words = EntryEditor.Words

    init(model: AppModel, close: @escaping () -> Void) {
        _editor = State(wrappedValue: EntryEditor(model: model))
        self.close = close
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(editor.title)
                .font(.title3)
            Field(label: Words.merchant, prompt: Words.merchant,
                  text: Binding(get: { editor.merchant }, set: { editor.merchant = $0 }))
            Field(label: Words.amount, prompt: "0.00",
                  text: Binding(get: { editor.amountText }, set: { editor.amountText = $0 }))
            DatePicker(selection: Binding(get: { editor.date }, set: { editor.date = $0 }),
                       displayedComponents: .date) {
                Text(Words.date)
                    .font(.system(size: 12))
            }
            Field(label: Words.note, prompt: Words.note,
                  text: Binding(get: { editor.note }, set: { editor.note = $0 }))
            HStack {
                Spacer()
                Button(Words.cancel) { close() }
                Button(Words.add) {
                    if editor.add() { close() }
                }
                .disabled(!editor.canAdd)
            }
        }
        .padding(20)
        .frame(width: 420)
    }
}

// MARK: - Import review

/// Draws ImportReviewScreen: what each line of a statement will do, a budget
/// for the lines that need one, and Import or Cancel.
struct ImportReviewView: View {
    var model: AppModel
    private typealias Words = ImportReviewScreen.Words

    private var screen: ImportReviewScreen { ImportReviewScreen(model: model) }

    /// "Choose" first, as on the Mac, so nothing chosen does not read "(None)".
    private var budgetChoices: [Choice<BudgetID?>] {
        [Choice(value: nil, description: Words.choose)]
            + screen.budgetChoices.map { Choice(value: $0.id, description: $0.name) }
    }

    static func color(_ tone: ImportReviewScreen.Tone) -> Color {
        switch tone {
        case .matched: .green
        case .toAdd: .blue
        case .alreadyImported: .gray
        case .needsBudget: .orange
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(screen.title)
                    .font(.title3)
                Text(screen.filename)
                    .font(.system(size: 11))
                    .foregroundColor(.gray)
            }
            HStack(spacing: 16) {
                ForEach(screen.tiles) { tile in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(tile.label)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(Self.color(tile.tone))
                        Text("\(tile.count)")
                            .font(.system(size: 20))
                    }
                }
            }
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(screen.rows) { row in
                        line(row)
                    }
                }
            }
            .frame(height: 340)
            Divider()
            HStack {
                Note(screen.note)
                Spacer()
                Button(Words.cancel) { screen.cancel() }
                Button(Words.importButton) { screen.commit() }
            }
        }
        .padding(18)
        .frame(width: 760)
    }

    private func line(_ row: ImportReviewScreen.Row) -> some View {
        HStack(spacing: 12) {
            Text(BudgetScreen.shortDate(row.date))
                .foregroundColor(.gray)
                .frame(width: 60)
            VStack(alignment: .leading, spacing: 1) {
                Text(row.description)
                Text(row.bankDescription)
                    .font(.system(size: 10))
                    .foregroundColor(.gray)
            }
            Spacer()
            Text(row.amount)
                .frame(width: 90)
            Text(row.status)
                .font(.system(size: 11))
                .foregroundColor(Self.color(row.tone))
                .frame(width: 130)
            if row.needsBudget {
                Picker(of: budgetChoices, selection: Binding(
                    get: { budgetChoices.first { $0.value == row.chosenBudget } },
                    set: { screen.choose($0?.value ?? nil, for: row.id) }))
                    .frame(width: 150)
            } else {
                Spacer()
                    .frame(width: 150)
            }
        }
    }
}
