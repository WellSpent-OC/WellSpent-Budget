import Testing
import Foundation
@testable import WellSpentAppCore
import WellSpentCrypto
import WellSpentModel
import WellSpentStore

/// Home, with Bills and one house on offer, and Other, with no budgets. What
/// an extension offers comes from a test double's closure.
@MainActor
private struct Setup {
    let model: AppModel
    let home: GroupID
    let empty: GroupID
    let bills: BudgetID
    let pool = RecordID(), gone = RecordID()

    init() throws {
        model = AppModel(store: Store(database: try WellSpentDatabase.inMemory()))
        home = try #require(model.addGroup(named: "Home"))
        empty = try #require(model.addGroup(named: "Other"))
        bills = try #require(model.addBudget(named: "Bills", limit: .dollars(500), in: home))
        let offered = EntryLinkChoices(label: "House", choices: [.init(id: pool, name: "Pool House")])
        let home = self.home
        model.linkChoices = { $0 == home ? offered : nil }
        model.reload()
    }

    func saved(link: RecordID? = nil, amount: Int = -900, kind: TransactionKind? = nil) throws -> Transaction {
        let entry = Transaction(budgetID: bills, groupID: home, date: Date(), merchant: "Water",
                                amount: Money(minorUnits: amount), kind: kind, extensionLink: link)
        try model.store.save(entry, queue: false)
        model.reload()
        return entry
    }
}

@Suite("Linking an entry, and adding in a group")
@MainActor
struct EntryLinkTests {
    @Test func theRowIsThereOnlyWhenAnExtensionOffersSomething() throws {
        let setup = try Setup()
        let plain = try setup.saved()
        #expect(EntryEditor(model: setup.model, editing: plain).showsLinkRow)
        setup.model.linkChoices = { _ in nil }
        #expect(!EntryEditor(model: setup.model, editing: plain).showsLinkRow)
        setup.model.linkChoices = { _ in EntryLinkChoices(label: "House", choices: []) }
        #expect(!EntryEditor(model: setup.model, editing: plain).showsLinkRow)
    }

    @Test func savingAChoiceLinksTheEntryAndNoneTakesItOff() throws {
        let setup = try Setup()
        let bill = try setup.saved()
        let editor = EntryEditor(model: setup.model, editing: bill)
        editor.linkSelection = setup.pool
        #expect(editor.save())
        #expect(try setup.model.store.transaction(bill.id)?.extensionLink == setup.pool)

        let again = try #require(EntryEditor(model: setup.model, entry: bill.id))
        #expect(again.linkSelection == setup.pool)
        again.linkSelection = nil
        #expect(again.save())
        #expect(try setup.model.store.transaction(bill.id)?.extensionLink == nil)
    }

    /// Re-adding a removed house has to find its bills still marked.
    @Test func aLinkToSomethingNoLongerOnOfferSurvivesAnEdit() throws {
        let setup = try Setup()
        let bill = try setup.saved(link: setup.gone)
        let editor = try #require(EntryEditor(model: setup.model, entry: bill.id))
        #expect(editor.linkSelection == nil)
        editor.merchant = "Water and sewer"
        #expect(editor.save())
        let back = try #require(try setup.model.store.transaction(bill.id))
        #expect(back.merchant == "Water and sewer")
        #expect(back.extensionLink == setup.gone)
    }

    @Test func switchingToMoneyInHidesTheRowAndClearsTheLinkOnSave() throws {
        let setup = try Setup()
        let bill = try setup.saved(link: setup.pool)
        let editor = try #require(EntryEditor(model: setup.model, entry: bill.id))
        #expect(editor.showsLinkRow)
        editor.isMoneyIn = true
        #expect(!editor.showsLinkRow)
        #expect(editor.save())
        let back = try #require(try setup.model.store.transaction(bill.id))
        #expect(back.kind == .income)
        #expect(back.extensionLink == nil)
    }

    @Test func aRefundFromAStatementCanBeLinked() throws {
        let setup = try Setup()
        let refund = try setup.saved(amount: 900, kind: .refund)
        let editor = try #require(EntryEditor(model: setup.model, entry: refund.id))
        #expect(editor.isMoneyIn)
        #expect(editor.showsLinkRow)
    }

    @Test func typingMoneyInOnAddHidesTheRowAndAddsNoLink() throws {
        let setup = try Setup()
        let editor = EntryEditor(model: setup.model, addingIn: setup.home, link: setup.pool)
        editor.merchant = "Paycheck"
        editor.amountText = "10"
        editor.isMoneyIn = true
        #expect(!editor.showsLinkRow)
        #expect(editor.save())
        let added = try #require(setup.model.entries(in: setup.home).first { $0.merchant == "Paycheck" })
        #expect(added.extensionLink == nil)
    }

    @Test func aReadOnlyEntrySaysWhatItIsLinkedTo() throws {
        let setup = try Setup()
        let bill = try setup.saved(link: setup.pool)
        let details = EntryEditor(model: setup.model, editing: bill).details
        #expect(details.contains { $0.label == "House" && $0.value == "Pool House" })
    }

    /// From a house, the bill can't land in whichever budget was last on screen.
    @Test func addingInAGroupOffersOnlyThatGroupsBudgets() throws {
        let setup = try Setup()
        let elsewhere = try #require(setup.model.addBudget(named: "Fun", limit: .dollars(50), in: setup.empty))
        setup.model.selectedBudget = elsewhere
        let editor = EntryEditor(model: setup.model, addingIn: setup.home, link: setup.pool)
        #expect(editor.offersBudgetChoice)
        #expect(editor.budgetChoices.map(\.id) == [setup.bills])
        #expect(editor.budgetID == setup.bills)
        editor.merchant = "Plumber"
        editor.amountText = "90"
        #expect(editor.save())
        let added = try #require(setup.model.entries(in: setup.home).first { $0.merchant == "Plumber" })
        #expect(added.budgetID == setup.bills)
        #expect(added.extensionLink == setup.pool)
    }

    @Test func addingFromABudgetsPageStaysAsItWas() throws {
        let setup = try Setup()
        setup.model.selectedBudget = setup.bills
        let editor = EntryEditor(model: setup.model)
        #expect(!editor.offersBudgetChoice)
        editor.merchant = "Plain"
        editor.amountText = "1"
        #expect(editor.save())
        #expect(setup.model.entries(in: setup.home).contains { $0.merchant == "Plain" && $0.budgetID == setup.bills })
    }

    @Test func withNoBudgetsAManagerMakesOneOnlyWhenSaving() throws {
        let setup = try Setup()
        let editor = EntryEditor(model: setup.model, addingIn: setup.empty)
        #expect(editor.isNewBudget)
        #expect(editor.offersNewBudget)
        #expect(editor.noBudgetLine == nil)
        editor.merchant = "Plumber"
        editor.amountText = "90"
        #expect(!editor.canAdd, "a new budget needs its name and amount")
        #expect(setup.model.summaries[setup.empty]?.isEmpty != false, "opening the sheet makes nothing")
        editor.newBudgetName = "Repairs"
        editor.newBudgetAmountText = "200"
        #expect(editor.save())
        #expect(setup.model.summaries[setup.empty]?.map(\.budget.name) == ["Repairs"])
        #expect(setup.model.entries(in: setup.empty).map(\.merchant) == ["Plumber"])
    }

    @Test func oneChoiceDecidesBetweenABudgetAndANewOne() throws {
        let setup = try Setup()
        let editor = EntryEditor(model: setup.model, addingIn: setup.home)
        #expect(editor.budgetSelection == setup.bills)
        editor.budgetSelection = nil
        #expect(editor.isNewBudget)
        #expect(editor.budgetSelection == nil)
        editor.budgetSelection = setup.bills
        #expect(!editor.isNewBudget)
        #expect(editor.budgetID == setup.bills)
    }

    @Test func belowManageNilNeverMeansANewBudget() throws {
        let setup = try Setup()
        setup.model.mayManageEntries = { _ in false }
        let editor = EntryEditor(model: setup.model, addingIn: setup.home)
        editor.budgetSelection = nil
        #expect(!editor.isNewBudget)
    }

    /// Money in on a house's Add names the right budget, or none.
    @Test func moneyInNeverNamesABudgetFromSomewhereElse() throws {
        let setup = try Setup()
        let elsewhere = try #require(setup.model.addBudget(named: "Fun", limit: .dollars(50), in: setup.empty))
        setup.model.selectedBudget = elsewhere
        let lonely = try #require(setup.model.addGroup(named: "Lonely"))
        let empty = EntryEditor(model: setup.model, addingIn: lonely)
        empty.isMoneyIn = true
        #expect(empty.moneyInLine == nil)
        empty.newBudgetName = "Repairs"
        #expect(empty.moneyInLine == EntryEditor.Words.moneyInHelp(budget: "Repairs"))

        let home = EntryEditor(model: setup.model, addingIn: setup.home)
        home.isMoneyIn = true
        #expect(home.moneyInLine == EntryEditor.Words.moneyInHelp(budget: "Bills"))
        home.budgetSelection = nil
        #expect(home.moneyInLine == nil)
    }

    @Test func aClearedLinkChangeRemovesTheMark() throws {
        let setup = try Setup()
        let bill = try setup.saved(link: setup.pool)
        #expect(setup.model.updateEntry(bill.id, EntryChange(link: .cleared)) == .saved)
        #expect(try setup.model.store.transaction(bill.id)?.extensionLink == nil)
    }

    @Test func aRequestOpensOneSheetForTheHostsAsk() throws {
        let setup = try Setup()
        let host = AppExtensionHost(model: setup.model)
        host.newEntry(linkedTo: setup.pool.uuid.uuidString, in: setup.home.uuid.uuidString)
        #expect(setup.model.entrySheetRequest == .add(group: setup.home, link: setup.pool))
        let bill = try setup.saved()
        host.openEntry(bill.id.uuid.uuidString)
        #expect(setup.model.entrySheetRequest == .open(bill.id))
    }

    @Test func theHostSavesARecordOnceAndRefusesBelowManage() throws {
        let setup = try Setup()
        let host = AppExtensionHost(model: setup.model)
        let group = setup.home.uuid.uuidString
        let id = host.saveRecord(kind: "house", .everyMember, sourceKey: "1", id: nil, body: "{}", in: group,
                                 extensionID: "e")
        #expect(id != nil)
        #expect(host.saveRecord(kind: "house", .everyMember, sourceKey: "1", id: nil, body: "{}", in: group,
                                extensionID: "e") == id)
        #expect(host.records(kind: "house", .everyMember, in: group, extensionID: "e").map(\.id) == [id])
        #expect(host.records(kind: "house", .followsHistory, in: group, extensionID: "e").isEmpty)
        host.removeRecord(try #require(id), .everyMember)
        #expect(host.records(kind: "house", .everyMember, in: group, extensionID: "e").isEmpty)
        setup.model.mayManageEntries = { _ in false }
        #expect(host.saveRecord(kind: "house", .everyMember, sourceKey: "2", id: nil, body: "{}", in: group,
                                extensionID: "e") == nil)
    }

    @Test func aHostEntryCarriesItsBudgetLinkAndSign() throws {
        let setup = try Setup()
        _ = try setup.saved(link: setup.pool)
        let entry = try #require(AppExtensionHost(model: setup.model).entries(in: setup.home.uuid.uuidString).first)
        #expect(entry.budget == setup.bills.uuid.uuidString)
        #expect(entry.link == setup.pool.uuid.uuidString)
        #expect(entry.signedMinorUnits == -900)
        #expect(entry.isSpendingOrRefund)
        #expect(entry.merchant == "Water")
    }

    @Test func aGroupsSharingLineWaitsForSomeoneElse() throws {
        let setup = try Setup()
        let home = try #require(AppExtensionHost(model: setup.model).groups().first { $0.name == "Home" })
        #expect(home.sharingLine == nil)
        #expect(home.canManage)
        #expect(home.canAddEntries)
    }

    @Test func installingSlotsReachesTheEntrySheet() throws {
        let setup = try Setup()
        setup.model.install(TestExtensionSlots())
        let choices = try #require(setup.model.linkChoices(setup.empty))
        #expect(choices.label == TestExtensionSlots.label)
        #expect(choices.choices.map(\.name) == [TestExtensionSlots.choice.name])
    }

    @Test func withNoBudgetsSomeoneBelowManageIsToldToAsk() throws {
        let setup = try Setup()
        setup.model.mayManageEntries = { _ in false }
        let editor = EntryEditor(model: setup.model, addingIn: setup.empty)
        #expect(!editor.isNewBudget)
        #expect(!editor.offersNewBudget)
        #expect(editor.noBudgetLine == EntryEditor.Words.askForABudget)
        editor.merchant = "Plumber"
        editor.amountText = "90"
        #expect(!editor.canAdd)
    }
}
