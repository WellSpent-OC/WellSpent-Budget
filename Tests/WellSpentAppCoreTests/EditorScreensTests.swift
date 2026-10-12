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
