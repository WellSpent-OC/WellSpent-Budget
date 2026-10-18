import Testing
import Foundation
@testable import WellSpentAppCore
import WellSpentCrypto
import WellSpentModel
import WellSpentImport
import WellSpentStore

@MainActor
private func emptyModel() throws -> AppModel {
    AppModel(store: Store(database: try WellSpentDatabase.inMemory()))
}

@Suite("Editor screens", .serialized)
@MainActor
struct EditorScreensTests {
    // MARK: - Budget

    @Test func aNewBudgetGoesInTheChosenGroup() throws {
        let model = try emptyModel()
        let household = try #require(model.addGroup(named: "Household"))
        let business = try #require(model.addGroup(named: "Side business"))

        let editor = BudgetEditor(model: model, group: business)
        #expect(editor.title == "New Budget" && editor.saveLabel == "Add")
        #expect(editor.showsGroupPicker && !editor.needsNewGroup)
        #expect(editor.groupID == business, "opened from a group's menu, it starts in that group")
        #expect(!editor.canSave)
        #expect(!editor.save(), "nothing to save yet")

        editor.name = "Materials"
        editor.amountText = "250"
        #expect(editor.canSave)
        #expect(editor.save())
        #expect(model.summaries[business]?.map(\.budget.name) == ["Materials"])
        #expect(model.summaries[business]?.first?.budget.limit == .dollars(250))
        #expect(model.summaries[household]?.isEmpty ?? true)
    }

    /// With no group of their own, a new budget gets a new group, named
    /// "Personal" unless changed.
    @Test func withNoGroupANewBudgetMakesOne() throws {
        let model = try emptyModel()
        let editor = BudgetEditor(model: model)
        #expect(editor.needsNewGroup && !editor.showsGroupPicker)
        #expect(editor.newGroupName == "Personal")
        editor.name = "Groceries"
        editor.amountText = "500.00"
        editor.newGroupName = "  "
        #expect(!editor.canSave, "a new group needs a name")
        editor.newGroupName = "Personal"
        #expect(editor.save())
        #expect(model.groups.map(\.name) == ["Personal"])
        #expect(model.summaries[model.groups[0].id]?.map(\.budget.name) == ["Groceries"])
    }

    @Test func editingABudgetChangesItsNameAndAmount() throws {
        let model = try emptyModel()
        let group = try #require(model.addGroup(named: "Household"))
        let id = try #require(model.addBudget(named: "Groceries", limit: .dollars(500), in: group))
        let editor = BudgetEditor(model: model, editing: try #require(model.budget(for: id)))

        #expect(editor.title == "Edit Budget" && editor.saveLabel == "Save")
        #expect(!editor.showsGroupPicker && !editor.needsNewGroup)
        #expect(editor.name == "Groceries")
        #expect(StatementParser.parseAmount(editor.amountText, currency: .usd) == .dollars(500))

        editor.name = "Food"
        editor.amountText = "650"
        #expect(editor.save())
        #expect(model.budget(for: id)?.name == "Food")
        #expect(model.budget(for: id)?.limit == .dollars(650))
    }

    @Test func aBudgetNeedsANameAndAnAmountAboveZero() {
        #expect(BudgetEditor.canSave(name: "Groceries", amountText: "500"))
        #expect(BudgetEditor.canSave(name: "Groceries", amountText: "500.00"))
        #expect(!BudgetEditor.canSave(name: "", amountText: "500"))
        #expect(!BudgetEditor.canSave(name: "   ", amountText: "500"))
        #expect(!BudgetEditor.canSave(name: "Groceries", amountText: ""))
        #expect(!BudgetEditor.canSave(name: "Groceries", amountText: "0"))
        #expect(!BudgetEditor.canSave(name: "Groceries", amountText: "lots"))
    }

    // MARK: - Group

    @Test func aGroupIsAddedAndRenamed() throws {
        let model = try emptyModel()
        let adding = GroupEditor(model: model)
        #expect(adding.title == "New Group" && adding.saveLabel == "Add")
        #expect(!adding.canSave)
        adding.name = "Household"
        #expect(adding.save())
        let group = try #require(model.groups.first)
        #expect(group.name == "Household")

        let renaming = GroupEditor(model: model, renaming: group)
        #expect(renaming.title == "Rename Group" && renaming.saveLabel == "Save")
        #expect(renaming.name == "Household")
        renaming.name = " "
        #expect(!renaming.save())
        renaming.name = "Home"
        #expect(renaming.save())
        #expect(model.groups.map(\.name) == ["Home"])
    }

    // MARK: - Entry

    @Test func anEntryGoesInTheBudgetOnScreenAsMoneyOut() throws {
        let model = try emptyModel()
        let group = try #require(model.addGroup(named: "Household"))
        let budget = try #require(model.addBudget(named: "Groceries", limit: .dollars(500), in: group))

        let editor = EntryEditor(model: model)
        #expect(editor.title == "New transaction")
        editor.merchant = "Hilltop Grocery"
        editor.amountText = "42.50"
        model.selectedBudget = nil
        #expect(!editor.add(), "no budget on screen, so nowhere to put it")

        model.selectedBudget = budget
        #expect(editor.add())
        #expect(model.transactions.map(\.merchant) == ["Hilltop Grocery"])
        #expect(model.transactions.first?.amount == Money(minorUnits: -4250))
    }

    @Test func anEntryNeedsAMerchantAndAnAmount() {
        #expect(EntryEditor.canAdd(merchant: "Hilltop", amountText: "12"))
        #expect(!EntryEditor.canAdd(merchant: "", amountText: "12"))
        #expect(!EntryEditor.canAdd(merchant: "  ", amountText: "12"))
        #expect(!EntryEditor.canAdd(merchant: "Hilltop", amountText: ""))
        #expect(!EntryEditor.canAdd(merchant: "Hilltop", amountText: "twelve"))
    }

    // MARK: - Budget screen

    @Test func theBudgetSaysWhatIsSpentAndLeft() throws {
        let model = try emptyModel()
        let group = try #require(model.addGroup(named: "Household"))
        let id = try #require(model.addBudget(named: "Groceries", limit: .dollars(100), in: group))
        model.selectedBudget = id
        model.addTransaction(merchant: "Hilltop Grocery", amount: .dollars(40), date: Date(), note: "milk")

        let screen = BudgetScreen(summary: try #require(model.summary(for: id)), model: model, me: nil)
        #expect(screen.title == "Groceries")
        #expect(screen.spent == "$40.00")
        #expect(screen.ofLimit == "of $100.00 this period")
        #expect(screen.standing == "$60.00 left" && !screen.isOverspent)
        #expect(screen.countLine.hasPrefix("1 transaction since "))
        #expect(screen.rows.map(\.merchant) == ["Hilltop Grocery"])
        #expect(screen.rows.first?.note == "milk")
        #expect(screen.rows.first?.amount == "$40.00")
        #expect(screen.rows.first?.addedBy == "You")
        #expect(screen.rows.first?.source == "Manual")
        #expect(!screen.showsAddedBy, "nobody else is in the group")

        model.addTransaction(merchant: "Costco", amount: .dollars(75), date: Date(), note: "")
        let over = BudgetScreen(summary: try #require(model.summary(for: id)), model: model, me: nil)
        #expect(over.isOverspent && over.standing == "$15.00 over")
        #expect(over.countLine.hasPrefix("2 transactions since "))
    }

    // MARK: - Import review

    @Test func theImportReviewSaysWhatEachLineWillDo() throws {
        let model = try emptyModel()
        let group = try #require(model.addGroup(named: "Household"))
        let groceries = try #require(model.addBudget(named: "Groceries", limit: .dollars(500), in: group))
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("statement-\(UUID().uuidString).csv")
        try """
        Date,Description,Amount
        09/22/2026,"HILLTOP #17 SPRING HILL OH",-142.08
        09/21/2026,"COSTCO WHSE #0472",-286.31
        """.write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }

        let screen = ImportReviewScreen(model: model)
        #expect(!screen.isOpen && screen.rows.isEmpty && screen.tiles.isEmpty)
        model.prepareImport(from: url)
        #expect(screen.isOpen)
        #expect(screen.title == "Import a statement into \u{201C}Household\u{201D}")
        #expect(screen.filename == url.lastPathComponent)
        #expect(screen.note == "Read on this computer. Nothing is sent until you add it.")
        #expect(screen.tiles.map(\.label) == ["Matched", "To add", "Already imported", "Needs a budget"])
        #expect(screen.tiles.map(\.count) == [0, 0, 0, 2])
        #expect(screen.rows.map(\.status) == ["Needs a budget", "Needs a budget"])
        #expect(screen.rows.allSatisfy { $0.needsBudget && $0.isActionable && $0.chosenBudget == nil })
        #expect(screen.rows.first?.description == "Hilltop Spring Hill")
        #expect(screen.rows.first?.amount == "-$142.08")
        #expect(screen.budgetChoices.map(\.name) == ["Groceries"])

        screen.choose(groceries, for: 0)
        #expect(screen.rows[0].chosenBudget == groceries && screen.rows[1].chosenBudget == nil)
        screen.commit()
        #expect(!screen.isOpen)
        #expect(try model.store.transactions(in: groceries).count == 1, "the line left without a budget is skipped")

        // The same statement again: the line already in is shown and skipped.
        model.prepareImport(from: url)
        #expect(screen.rows.map(\.status) == ["Already imported", "Needs a budget"])
        #expect(!screen.rows[0].isActionable)
        screen.cancel()
        #expect(!screen.isOpen)
        #expect(try model.store.transactions(in: groceries).count == 1)
    }
}

// MARK: - Entry, changed

/// Household, with Groceries and Eating out, and Robin's “Hilltop Grocery”,
/// $142.08, today, in Groceries, as a sync leaves it. This person is Leslie,
/// at Manage, looking at Groceries.
@MainActor
private struct Hilltop {
    let model: AppModel
    let group: GroupID
    let groceries: BudgetID
    let eatingOut: BudgetID
    let robin = UserID()
    let leslie = UserID()
    let id: RecordID

    init() throws {
        model = try emptyModel()
        group = try #require(model.addGroup(named: "Household"))
        groceries = try #require(model.addBudget(named: "Groceries", limit: .dollars(500), in: group))
        eatingOut = try #require(model.addBudget(named: "Eating out", limit: .dollars(200), in: group))
        let entry = Transaction(budgetID: groceries, groupID: group, date: Date(), merchant: "Hilltop Grocery",
                                amount: Money(minorUnits: -14208), createdBy: robin)
        try model.store.save(entry, queue: false)
        try model.store.save(MemberProfile(groupID: group, userID: robin, displayName: "Robin"), queue: false)
        id = entry.id
        let me = leslie
        model.me = { me }
        model.selectedBudget = groceries
        model.reload()
    }

    func stored() throws -> Transaction { try #require(try model.store.transaction(id)) }
    func editor() throws -> EntryEditor { try #require(EntryEditor(model: model, entry: id)) }
    func row() throws -> BudgetScreen.Row {
        let screen = BudgetScreen(summary: try #require(model.summary(for: groceries)), model: model, me: leslie)
        return try #require(screen.rows.first { $0.id == id })
    }

    /// Moves this person to a level, as a sync does when the server says so.
    func at(_ level: AccessLevel) {
        model.mayAddEntries = { _ in level.allows(.write) }
        model.mayManageEntries = { _ in level.allows(.manage) }
    }

    /// Another entry, saved as a sync would leave it.
    func entry(_ merchant: String, amount: Int, source: TransactionSource = .manual, note: String = "",
               by owner: UserID?) throws -> RecordID {
        let made = Transaction(budgetID: groceries, groupID: group, date: Date(), merchant: merchant, note: note,
                               amount: Money(minorUnits: amount), source: source, createdBy: owner)
        try model.store.save(made, queue: false)
        model.reload()
        return made.id
    }
}

@Suite("Editor screens, an entry opened", .serialized)
@MainActor
struct EntryEditorTests {
    @Test func anEntryOpensFilledInWithSaveDimmed() throws {
        let s = try Hilltop()
        let stored = try s.stored()

        let editor = try s.editor()

        #expect(editor.title == "Transaction" && editor.saveLabel == "Save")
        #expect(editor.merchant == "Hilltop Grocery")
        #expect(editor.amountText == "142.08")
        #expect(editor.date == stored.date)
        #expect(editor.note == "")
        #expect(editor.budgetID == s.groceries)
        #expect(!editor.canSave, "nothing changed yet")
        #expect(!editor.isReadOnly && editor.offersDelete)
        #expect(editor.readOnlyLine == nil && editor.periodLine == nil && editor.noticeLine == nil)
        #expect(editor.result == nil && editor.pendingDelete == nil)
        #expect(EntryEditor(model: s.model, entry: RecordID()) == nil, "nothing there to open")
    }

    @Test func saveLightsOnARealChangeAndDimsWhenItIsPutBack() throws {
        let s = try Hilltop()
        let editor = try s.editor()

        editor.amountText = "124.08"
        #expect(editor.canSave)
        editor.amountText = "142.080"
        #expect(!editor.canSave, "amounts compare as money")
        editor.merchant = "Hilltop"
        #expect(editor.canSave)
        editor.merchant = "Hilltop Grocery"
        #expect(!editor.canSave)
        editor.note = "milk"
        #expect(editor.canSave)
        editor.note = ""
        #expect(!editor.canSave)
        let original = editor.date
        editor.date = try #require(Calendar.current.date(byAdding: .day, value: -1, to: original))
        #expect(editor.canSave)
        editor.date = original
        #expect(!editor.canSave)
        editor.budgetID = s.eatingOut
        #expect(editor.canSave)
        editor.budgetID = s.groceries
        #expect(!editor.canSave)

        editor.merchant = "  "
        #expect(!editor.canSave, "a merchant is still needed, as on Add")
        editor.merchant = "Hilltop Grocery"
        editor.amountText = "lots"
        #expect(!editor.canSave, "so is an amount")
        #expect(!editor.save())
        #expect(try s.stored().amount == Money(minorUnits: -14208))
    }

    /// Save writes only the fields changed here, onto the entry as it is
    /// stored now. Robin's note, brought in by a sync while the sheet was
    /// open, stays.
    @Test func savingWritesOnlyWhatWasChanged() throws {
        let s = try Hilltop()
        let editor = try s.editor()
        var robins = try s.stored()
        robins.note = "for the party"
        try s.model.store.save(robins, queue: false)
        s.model.reload()

        editor.amountText = "124.08"
        #expect(editor.save())

        #expect(editor.result == .saved)
        let saved = try s.stored()
        #expect(saved.amount == Money(minorUnits: -12408))
        #expect(saved.note == "for the party", "Robin's note stays")
        #expect(saved.merchant == "Hilltop Grocery")
        #expect(try s.row().amount == "$124.08")
    }

    @Test func aRefundStaysARefund() throws {
        let s = try Hilltop()
        let refund = try s.entry("Trader Joes", amount: 5420, source: .statement, note: "TRADER JOES #123",
                                 by: s.robin)
        let editor = try #require(EntryEditor(model: s.model, entry: refund))
        #expect(editor.amountText == "54.20")
        #expect(editor.note == "TRADER JOES #123", "the bank's text is the note, and can be changed")

        editor.amountText = "60.00"
        #expect(editor.save())

        #expect(try s.model.store.transaction(refund)?.amount == Money(minorUnits: 6000))
    }

    @Test func aDateOutsideThisPeriodSaysSo() throws {
        let s = try Hilltop()
        let editor = try s.editor()
        let today = editor.date

        editor.date = try #require(Calendar.current.date(byAdding: .month, value: -2, to: today))
        #expect(editor.periodLine == "This moves it out of this period.")
        editor.date = today
        #expect(editor.periodLine == nil)
    }

    @Test func theBudgetListHoldsOnlyTheEntrysGroup() throws {
        let s = try Hilltop()
        let side = try #require(s.model.addGroup(named: "Side Business"))
        s.model.addBudget(named: "Tools", limit: .dollars(100), in: side)
        s.model.selectedBudget = s.groceries

        let editor = try s.editor()
        #expect(editor.budgetChoices.map(\.name) == ["Groceries", "Eating out"])

        editor.budgetID = s.eatingOut
        #expect(editor.save())
        #expect(try s.stored().budgetID == s.eatingOut)
    }

    /// At View, and on someone else's entry at Add.
    @Test func aReadOnlyEntryShowsWhyAndOffersNoSave() throws {
        let s = try Hilltop()
        s.at(.read)
        let viewing = try s.editor()
        #expect(viewing.isReadOnly && !viewing.offersDelete)
        #expect(viewing.readOnlyLine == "You can view this group but not change it.")
        viewing.amountText = "1.00"
        #expect(!viewing.canSave && !viewing.save())
        viewing.askDelete()
        #expect(viewing.pendingDelete == nil)
        #expect(!viewing.confirmDelete())
        #expect(try s.stored().amount == Money(minorUnits: -14208) && !s.stored().isDeleted)

        s.at(.write)
        let adding = try s.editor()
        #expect(adding.isReadOnly)
        #expect(adding.readOnlyLine == "Only Robin, or a manager, can change this.")
        let own = try s.entry("Costco", amount: -2863, by: s.leslie)
        let mine = try #require(EntryEditor(model: s.model, entry: own))
        #expect(!mine.isReadOnly && mine.offersDelete, "her own, she may change and delete")
    }

    /// A read-only sheet shows the details as plain text, not fields: the
    /// entry as it was opened, with the amount as money and the date in
    /// full. The note shows only when there is one.
    @Test func aReadOnlyEntryShowsItsDetailsAsPlainText() throws {
        let s = try Hilltop()
        s.at(.read)
        let stored = try s.stored()

        let viewing = try s.editor()

        #expect(viewing.details.map(\.label) == ["Merchant", "Amount", "Date", "Budget"])
        #expect(viewing.details.map(\.value) == ["Hilltop Grocery", "$142.08",
                                                  stored.date.formatted(date: .abbreviated, time: .omitted),
                                                  "Groceries"])
        let noted = try s.entry("Trader Joes", amount: 5420, source: .statement, note: "TRADER JOES #123",
                                by: s.robin)
        let refund = try #require(EntryEditor(model: s.model, entry: noted))
        #expect(refund.details.first { $0.label == "Note" }?.value == "TRADER JOES #123")
        #expect(refund.details.first { $0.label == "Amount" }?.value == "$54.20", "money, without a sign")
        #expect(EntryEditor(model: s.model).details.isEmpty, "a new entry has fields, not details")
    }

    /// Turned read-only by a refused Save, the sheet shows the entry as it
    /// is, not what was typed: nothing was changed.
    @Test func aRefusedSaveShowsTheEntryAsItIsNotWhatWasTyped() throws {
        let s = try Hilltop()
        let editor = try s.editor()
        editor.amountText = "1.00"
        s.at(.read)

        #expect(!editor.save())

        #expect(editor.isReadOnly)
        #expect(editor.details.first { $0.label == "Amount" }?.value == "$142.08")
    }

    /// Moved down to View while the sheet was open, with a change typed.
    @Test func savingAfterAMoveDownChangesNothingAndSaysWhy() throws {
        let s = try Hilltop()
        let saving = try s.editor()
        let deleting = try s.editor()
        saving.amountText = "124.08"
        s.at(.read)

        #expect(!saving.save())
        #expect(saving.result == .notAllowed(.viewOnly))
        #expect(saving.isReadOnly && !saving.canSave && !saving.offersDelete)
        #expect(saving.readOnlyLine == "Nothing was changed. You can view this group but not change it.")
        deleting.askDelete()
        #expect(deleting.pendingDelete == nil, "no question to ask")
        #expect(deleting.readOnlyLine == "Nothing was changed. You can view this group but not change it.")
        #expect(try s.stored().amount == Money(minorUnits: -14208) && !s.stored().isDeleted)

        // At Add on Robin's entry, after a move down from Manage.
        s.at(.manage)
        let again = try s.editor()
        again.note = "milk"
        s.at(.write)
        #expect(!again.save())
        #expect(again.readOnlyLine == "Nothing was changed. Only Robin, or a manager, can change this.")
    }

    /// The note on the row goes once the entry has been opened.
    @Test func openingAnEntryWithANoteWaitingMarksItSeen() throws {
        let s = try Hilltop()
        let thisDevice = DeviceID()
        s.model.thisDevice = { thisDevice }
        try s.model.store.recordConflict(recordID: s.id, recordType: .transaction, payloadJSON: "{}", lamport: 3,
                                         device: thisDevice)
        s.model.reload()
        #expect(try s.row().notice == "Your change didn't go through.")

        let editor = try s.editor()

        #expect(editor.noticeLine == "Your last change to this didn't go through. This is the version everyone sees.")
        #expect(try s.row().notice == nil, "the row's line is gone")
        #expect(try s.editor().noticeLine == nil, "said once")
    }

    /// The source, and who added it, but only once someone else is in the
    /// group, as the list's Added by column decides.
    @Test func theTopLineSaysWhereItCameFromAndWhoAddedIt() throws {
        let s = try Hilltop()
        let refund = try s.entry("Trader Joes", amount: 5420, source: .statement, by: s.robin)
        let unnamed = try s.entry("Sunny's", amount: -5477, by: UserID())
        let own = try s.entry("Costco", amount: -2863, by: s.leslie)
        func top(_ id: RecordID) -> String? { EntryEditor(model: s.model, entry: id)?.topLine }

        #expect(top(s.id) == "Manual", "nobody else is in the group")
        #expect(top(refund) == "Statement \u{00B7} Refund")

        try s.model.store.replaceMembers([s.robin: .superadmin, s.leslie: .manage], in: s.group)
        #expect(top(s.id) == "Added by Robin \u{00B7} Manual")
        #expect(top(refund) == "Added by Robin \u{00B7} Statement \u{00B7} Refund")
        #expect(top(unnamed) == "Added by a member \u{00B7} Manual")
        #expect(top(own) == "Added by you \u{00B7} Manual")
    }

    /// The delete question, asked inside the sheet so it shows over it.
    @Test func deleteAsksFirstAndCancelKeepsTheEntryAndTheSheet() throws {
        let s = try Hilltop()
        let editor = try s.editor()

        editor.askDelete()
        let pending = try #require(editor.pendingDelete)
        #expect(pending.title == "Delete \u{201C}Hilltop Grocery\u{201D}, $142.08?")
        #expect(pending.message == "It comes out of Groceries.", "nobody else is in the group")
        #expect(pending.confirmLabel == "Delete")
        editor.cancelDelete()
        #expect(editor.pendingDelete == nil)
        #expect(try !s.stored().isDeleted)
        #expect(!editor.isReadOnly, "the sheet stays as it was")

        editor.askDelete()
        #expect(editor.confirmDelete())
        #expect(editor.result == .saved)
        #expect(editor.pendingDelete == nil)
        #expect(try s.stored().isDeleted)
        #expect(s.model.transactions.isEmpty)
        #expect(s.model.undoOffer?.entry == s.id)
    }

    @Test func addingWorksAsBefore() throws {
        let s = try Hilltop()
        let editor = EntryEditor(model: s.model)

        #expect(editor.title == "New transaction" && editor.saveLabel == "Add")
        #expect(editor.editing == nil && editor.topLine == nil && editor.budgetChoices.isEmpty)
        #expect(!editor.isReadOnly && !editor.offersDelete && editor.readOnlyLine == nil)
        #expect(!editor.canSave)
        editor.merchant = "Costco"
        editor.amountText = "28.63"
        #expect(editor.canSave)
        #expect(editor.save())
        #expect(s.model.transactions.contains { $0.merchant == "Costco" && $0.amount == Money(minorUnits: -2863) })
    }
}
