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
            Field(label: Words.amount, prompt: editor.amountPrompt,
                  text: Binding(get: { editor.amountText }, set: { editor.amountText = $0 }))
            if let problem = editor.amountProblem {
                Note(problem, warning: true)
            }
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

/// Draws EntryEditor: a new entry for the budget on screen, or one opened
/// from the list to change, move or delete. What it may do, what it says, and
/// when it turns read-only are the shared code's, as on the Mac.
struct EntryEditorView: View {
    @State var editor: EntryEditor
    var close: () -> Void
    private typealias Words = EntryEditor.Words

    /// A new entry.
    init(model: AppModel, close: @escaping () -> Void) {
        _editor = State(wrappedValue: EntryEditor(model: model))
        self.close = close
    }

    /// An entry opened from the list. The editor is made once, by whoever
    /// opens it, because opening it is what marks its note seen.
    init(editor: EntryEditor, close: @escaping () -> Void) {
        _editor = State(wrappedValue: editor)
        self.close = close
    }

    var body: some View {
        // Read here, so a change redraws the sheet, and kept for the alert's
        // buttons, because GTK closes the alert before a button's action runs.
        let pending = editor.pendingDelete
        VStack(alignment: .leading, spacing: 12) {
            heading
            if editor.isReadOnly {
                details
            } else {
                fields
            }
            if let line = editor.readOnlyLine {
                Note(line)
            }
            buttons
        }
        .padding(20)
        .frame(width: 420)
        // The sheet asks its own delete question, so it shows over the sheet.
        .alert(question(pending), isPresented: Binding(get: { pending != nil },
                                                       set: { if !$0 { editor.cancelDelete() } })) {
            // Cancel first: GTK focuses the first button, so Return keeps it.
            Button(Words.cancel) { editor.cancelDelete() }
            Button(pending?.confirmLabel ?? Words.delete) {
                if editor.confirmDelete() { close() }
            }
        }
    }

    /// GTK's alert has a title and no message, so the two go together.
    private func question(_ pending: PendingDelete?) -> String {
        guard let pending else { return "" }
        return "\(pending.title)\n\n\(pending.message)"
    }

    private var heading: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(editor.title)
                .font(.title3)
            if let top = editor.topLine {
                Text(top)
                    .font(.system(size: 11))
                    .foregroundColor(.gray)
            }
            if let notice = editor.noticeLine {
                Note(notice, warning: true)
            }
        }
    }

    private var budgetChoices: [Choice<BudgetID?>] {
        editor.budgetChoices.map { Choice(value: $0.id, description: $0.name) }
    }

    @ViewBuilder
    private var fields: some View {
        Field(label: Words.merchant, prompt: Words.merchant,
              text: Binding(get: { editor.merchant }, set: { editor.merchant = $0 }))
        Field(label: Words.amount, prompt: editor.amountPrompt,
              text: Binding(get: { editor.amountText }, set: { editor.amountText = $0 }))
        if let problem = editor.amountProblem {
            Note(problem, warning: true)
        }
        DatePicker(selection: Binding(get: { editor.date }, set: { editor.date = $0 }),
                   displayedComponents: .date) {
            Text(Words.date)
                .font(.system(size: 12))
        }
        if let line = editor.periodLine {
            Note(line, warning: true)
        }
        Field(label: Words.note, prompt: Words.note,
              text: Binding(get: { editor.note }, set: { editor.note = $0 }))
        if editor.editing != nil {
            Text(Words.budget)
                .font(.system(size: 12))
            Picker(of: budgetChoices, selection: Binding(
                get: { budgetChoices.first { $0.value == editor.budgetID } },
                set: { editor.budgetID = $0?.value ?? editor.budgetID }))
        }
    }

    /// The entry as it was opened, as plain words, in place of the fields.
    private var details: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(editor.details) { detail in
                HStack(alignment: .top, spacing: 12) {
                    Text(detail.label)
                        .font(.system(size: 12))
                        .foregroundColor(.gray)
                        .frame(width: 70, alignment: .leading)
                    Text(detail.value)
                }
            }
        }
    }

    /// Delete… on the left, apart from Save. Cancel and Save, or Add, on the
    /// right, or Done alone when read-only.
    private var buttons: some View {
        HStack {
            if editor.offersDelete {
                Button(Words.delete) { editor.askDelete() }
            }
            Spacer()
            if editor.isReadOnly {
                Button(Words.done) { close() }
            } else {
                Button(Words.cancel) { close() }
                if editor.editing == nil {
                    Button(Words.add) {
                        if editor.add() { close() }
                    }
                    .disabled(!editor.canAdd)
                } else {
                    // Refused, the sheet stays open, read-only, and says why.
                    Button(editor.saveLabel) {
                        if editor.save() { close() }
                    }
                    .disabled(!editor.canSave)
                }
            }
        }
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

    /// A line's budget as chosen now, read fresh, not from the row the line
    /// was drawn with. The toolkit can lay a line out again before it draws
    /// it again, and an old row would set its list back to Choose, which
    /// undoes the choice.
    private func chosenBudget(_ row: Int) -> BudgetID? {
        screen.rows.first { $0.id == row }?.chosenBudget
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
                    get: { budgetChoices.first { $0.value == chosenBudget(row.id) } },
                    set: { screen.choose($0?.value ?? nil, for: row.id) }))
                    .frame(width: 150)
            } else {
                Spacer()
                    .frame(width: 150)
            }
        }
    }
}
