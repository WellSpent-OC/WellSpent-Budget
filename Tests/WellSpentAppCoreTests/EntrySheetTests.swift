// SwiftUI and ViewInspector exist only on Apple systems.
#if canImport(SwiftUI)
import Testing
import Foundation
import SwiftUI
import ViewInspector
@testable import WellSpentAppCore
import WellSpentCrypto
import WellSpentKeyStore
import WellSpentModel
import WellSpentStore

/// Household, with Groceries and Eating out, and Robin's “Hilltop Grocery”,
/// $142.08, today, in Groceries, as a sync leaves it. This person is Leslie,
/// at Manage. The Undo bar waits an hour, so nothing races the clock.
@MainActor
private struct Drawn {
    let model: AppModel
    let sync: SyncCoordinator
    let group: GroupID
    let groceries: BudgetID
    let robin = UserID()
    let leslie = UserID()
    let hilltop: RecordID

    init() throws {
        model = AppModel(store: Store(database: try WellSpentDatabase.inMemory()), undoWindow: .seconds(3600))
        sync = SyncCoordinator(store: model.store, keyStore: InMemoryKeyStore(), defaults: isolatedDefaults())
        group = try #require(model.addGroup(named: "Household"))
        groceries = try #require(model.addBudget(named: "Groceries", limit: .dollars(500), in: group))
        model.addBudget(named: "Eating out", limit: .dollars(200), in: group)
        let entry = Transaction(budgetID: groceries, groupID: group, date: Date(), merchant: "Hilltop Grocery",
                                amount: Money(minorUnits: -14208), createdBy: robin)
        try model.store.save(entry, queue: false)
        try model.store.save(MemberProfile(groupID: group, userID: robin, displayName: "Robin"), queue: false)
        hilltop = entry.id
        let me = leslie
        model.me = { me }
        model.selectedBudget = groceries
        model.reload()
    }

    /// Moves this person to a level, as a sync does when the server says so.
    func at(_ level: AccessLevel) {
        model.mayAddEntries = { _ in level.allows(.write) }
        model.mayManageEntries = { _ in level.allows(.manage) }
    }

    func editor() throws -> EntryEditor { try #require(EntryEditor(model: model, entry: hilltop)) }

    /// The right side of the window, open on Groceries.
    func detail() throws -> BudgetDetailView {
        BudgetDetailView(model: model, sync: sync, summary: try #require(model.summary(for: groceries)),
                         showingAddTransaction: .constant(false), showingFileImporter: .constant(false),
                         showingAccount: .constant(false), editor: .constant(nil),
                         main: MainScreen(workspace: Workspace(model: model, sync: sync)))
    }

    func row() throws -> BudgetScreen.Row {
        let screen = BudgetScreen(summary: try #require(model.summary(for: groceries)), model: model, me: leslie)
        return try #require(screen.rows.first { $0.id == hilltop })
    }
}

@MainActor
private func texts(_ view: some View) throws -> [String] {
    try view.inspect().findAll(ViewType.Text.self).map { try $0.string() }
}

/// The buttons' words, in the order they are drawn.
@MainActor
private func buttons(_ view: some View) throws -> [String] {
    try view.inspect().findAll(ViewType.Button.self).map { try $0.labelView().text().string() }
}

@Suite("An entry's sheet, and the budget's list, drawn", .serialized)
@MainActor
struct EntrySheetTests {
    // MARK: - The sheet

    /// Cooper's sheet: the top line, the four fields and the Budget list,
    /// with Delete… on the left and Save dimmed until something changes.
    @Test func anOpenedEntryShowsItsFieldsWithDeleteOnTheLeftAndSaveDimmed() throws {
        let drawn = try Drawn()
        let sheet = EntrySheet(editor: try drawn.editor())

        let shown = try texts(sheet)
        #expect(shown.contains("Transaction"))
        #expect(shown.contains("Manual"), "the top line: where it came from")
        #expect(try buttons(sheet) == ["Delete\u{2026}", "Cancel", "Save"])
        #expect(try sheet.inspect().find(button: "Save").isDisabled())
        #expect(try sheet.inspect().findAll(ViewType.TextField.self).count == 3, "Merchant, Amount and Note")
        let budgets = try sheet.inspect().find(ViewType.Picker.self).findAll(ViewType.Text.self)
            .map { try $0.string() }
        #expect(budgets.contains("Groceries") && budgets.contains("Eating out"))
        #expect(!shown.contains("Done"))
    }

    /// At View: the details as plain text, the line saying why, and Done.
    @Test func aReadOnlyEntryShowsPlainTextItsLineAndOnlyDone() throws {
        let drawn = try Drawn()
        drawn.at(.read)
        let sheet = EntrySheet(editor: try drawn.editor())

        let shown = try texts(sheet)
        for words in ["Hilltop Grocery", "$142.08", "Groceries", "You can view this group but not change it."] {
            #expect(shown.contains(words), "missing \(words) in \(shown)")
        }
        #expect(try buttons(sheet) == ["Done"])
        #expect(try sheet.inspect().findAll(ViewType.TextField.self).isEmpty, "plain text, not fields")
    }

    @Test func aDateOutsideThisPeriodShowsItsLine() throws {
        let drawn = try Drawn()
        let editor = try drawn.editor()
        editor.date = try #require(Calendar.current.date(byAdding: .month, value: -2, to: editor.date))

        #expect(try texts(EntrySheet(editor: editor)).contains("This moves it out of this period."))
    }

    @Test func anEntryWhoseLastChangeDidNotGoThroughSaysSo() throws {
        let drawn = try Drawn()
        let thisDevice = DeviceID()
        drawn.model.thisDevice = { thisDevice }
        try drawn.model.store.recordConflict(recordID: drawn.hilltop, recordType: .transaction, payloadJSON: "{}",
                                             lamport: 3, device: thisDevice)

        let shown = try texts(EntrySheet(editor: try drawn.editor()))

        #expect(shown.contains("Your last change to this didn't go through. This is the version everyone sees."))
    }

    /// Deleted by a sync while it was open: Save saves nothing, and the
    /// sheet turns read-only and says so, with only Done.
    @Test func anEntryDeletedWhileOpenTurnsTheSheetReadOnly() throws {
        let drawn = try Drawn()
        let editor = try drawn.editor()
        editor.amountText = "124.08"
        try drawn.model.store.trash(try #require(try drawn.model.store.transaction(drawn.hilltop)), queue: false)

        #expect(!editor.save())

        let sheet = EntrySheet(editor: editor)
        #expect(try texts(sheet).contains("Someone deleted this while you had it open."))
        #expect(try buttons(sheet) == ["Done"])
    }

    /// The sheet asks its own question, so it shows over the sheet.
    @Test func deleteAsksItsQuestionOverTheSheet() throws {
        let drawn = try Drawn()
        let editor = try drawn.editor()
        editor.askDelete()

        let question = try EntrySheet(editor: editor).inspect().find(ViewType.ConfirmationDialog.self)

        #expect(try question.title().string() == "Delete \u{201C}Hilltop Grocery\u{201D}, $142.08?")
        #expect(try question.message().text().string() == "It comes out of Groceries.")
        try question.actions().find(button: "Delete").tap()
        #expect(try drawn.model.store.transaction(drawn.hilltop)?.isDeleted == true)
    }

    @Test func addingShowsTheFormAsBefore() throws {
        let drawn = try Drawn()
        let sheet = EntrySheet(model: drawn.model)

        #expect(try texts(sheet).contains("New transaction"))
        #expect(try buttons(sheet) == ["Cancel", "Add"])
        #expect((try? sheet.inspect().find(ViewType.Picker.self)) == nil, "it goes in the budget on screen")
    }

    // MARK: - The budget's list

    /// After a delete, a bar at the top of the budget says what went, and
    /// its Undo brings the entry back.
    @Test func theUndoBarSaysWhatWentAndUndoBringsItBack() throws {
        let drawn = try Drawn()
        #expect((try? drawn.detail().inspect().find(button: "Undo")) == nil, "no bar before a delete")
        #expect(drawn.model.deleteEntry(drawn.hilltop) == .saved)

        let detail = try drawn.detail()
        #expect(try texts(detail).contains("Deleted \u{201C}Hilltop Grocery\u{201D}, $142.08."))
        try detail.inspect().find(button: "Undo").tap()

        #expect(try drawn.model.store.transaction(drawn.hilltop)?.isDeleted == false)
        #expect(drawn.model.undoOffer == nil)
    }

    /// A row's description: the merchant, the note, and a quiet line when
    /// this computer's last change to it didn't go through.
    @Test func aRowShowsItsNoteAndANoticeWhenAChangeDidNotGoThrough() throws {
        let drawn = try Drawn()
        drawn.model.updateEntry(drawn.hilltop, EntryChange(note: "milk"))
        #expect(try texts(EntryDescription(row: try drawn.row())) == ["Hilltop Grocery", "milk"])

        let thisDevice = DeviceID()
        drawn.model.thisDevice = { thisDevice }
        try drawn.model.store.recordConflict(recordID: drawn.hilltop, recordType: .transaction, payloadJSON: "{}",
                                             lamport: 3, device: thisDevice)
        drawn.model.reload()

        #expect(try texts(EntryDescription(row: try drawn.row()))
                == ["Hilltop Grocery", "milk", "Your change didn't go through."])
    }
}

#endif
