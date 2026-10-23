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
                    .foregroundColor(Palette.warning)
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
            .foregroundColor(warning ? Palette.warning : Palette.muted)
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
                .font(.system(size: 17, weight: .semibold))
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
                .defaultAction()
                .disabled(!editor.canSave)
            }
        }
        .padding(20)
        .frame(width: 420)
        .foregroundColor(Palette.ink)
        .background(Palette.surface)
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
                .font(.system(size: 17, weight: .semibold))
            Field(label: Words.name, prompt: Words.namePrompt,
                  text: Binding(get: { editor.name }, set: { editor.name = $0 }))
            Note(Words.explanation)
            HStack {
                Spacer()
                Button(Words.cancel) { close() }
                Button(editor.saveLabel) {
                    if editor.save() { close() }
                }
                .defaultAction()
                .disabled(!editor.canSave)
            }
        }
        .padding(20)
        .frame(width: 420)
        .foregroundColor(Palette.ink)
        .background(Palette.surface)
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
        .foregroundColor(Palette.ink)
        .background(Palette.surface)
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
                .font(.system(size: 17, weight: .semibold))
            if let top = editor.topLine {
                Text(top)
                    .font(.system(size: 11))
                    .foregroundColor(Palette.muted)
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
        .calendarArrows()
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
                        .foregroundColor(Palette.muted)
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
                    .defaultAction()
                    .disabled(!editor.canAdd)
                } else {
                    // Refused, the sheet stays open, read-only, and says why.
                    Button(editor.saveLabel) {
                        if editor.save() { close() }
                    }
                    .defaultAction()
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
    private static let width: Double = 760

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
        Color(tone.color)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            list
            Divider()
            footer
        }
        .foregroundColor(Palette.ink)
        .frame(width: Self.width, height: 560)
        .background(Palette.surface)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Text(screen.title)
                    .font(.system(size: 17, weight: .semibold))
                Text(screen.filename)
                    .font(.money(11, weight: .regular))
                    .lineLimit(1)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(RoundedRectangle(cornerRadius: 5).fill(Palette.sidebar))
                    .help(screen.filename)
                Spacer()
            }
            HStack(spacing: 10) {
                ForEach(screen.tiles) { tile in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(tile.label)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(Self.color(tile.tone))
                        Text("\(tile.count)")
                            .font(.money(20))
                    }
                    .padding(10)
                    .frame(width: summaryWidth, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 8)
                        .fill(Self.color(tile.tone).opacity(0.08)))
                }
            }
        }
        .padding(18)
    }

    /// Equal cards across the fixed-width sheet, after its padding and gaps.
    private var summaryWidth: Double {
        let count = Double(max(screen.tiles.count, 1))
        return (Self.width - 36 - (count - 1) * 10) / count
    }

    private var list: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(screen.rows) { row in
                    line(row)
                    Divider()
                }
            }
        }
        .frame(maxHeight: .infinity)
    }

    private var footer: some View {
        HStack {
            Text(screen.note)
                .font(.system(size: 11))
                .foregroundColor(Palette.muted)
            Spacer()
            Button(Words.cancel) { screen.cancel() }
            Button(Words.importButton) { screen.commit() }.defaultAction()
        }
        .padding(16)
    }

    private func line(_ row: ImportReviewScreen.Row) -> some View {
        HStack(spacing: 12) {
            Text(BudgetScreen.shortDate(row.date))
                .font(.money(11, weight: .regular))
                .foregroundColor(Palette.muted)
                .frame(width: 54, alignment: .leading)
            VStack(alignment: .leading, spacing: 1) {
                Text(row.description)
                    .font(.system(size: 12, weight: .medium))
                Text(row.bankDescription)
                    .font(.system(size: 10))
                    .foregroundColor(Palette.muted)
                    .lineLimit(1)
            }
            Spacer()
            Text(row.amount)
                .font(.money(12, weight: .regular))
                .frame(width: 84, alignment: .trailing)
            HStack(spacing: 5) {
                Circle()
                    .fill(Self.color(row.tone))
                    .frame(width: 5, height: 5)
                Text(row.status)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(Self.color(row.tone))
            }
            .frame(width: 140, alignment: .leading)
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
        .padding(.horizontal, 18)
        .padding(.vertical, 9)
    }
}
