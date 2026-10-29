import Testing
import Foundation
import Observation
@testable import WellSpentAppCore
import WellSpentCrypto
import WellSpentKeyStore
import WellSpentModel
import WellSpentImport
import WellSpentStore
import WellSpentSync

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

    // Scenario INC-01
    /// The Money in switch. On, a new entry is income, stored positive, and
    /// its row shows a plus sign. An opened entry shows the switch as it is,
    /// and flipping it saves the kind: a refund switched off is spending, a
    /// spending switched on is income.
    @Test func anEntryMarkedMoneyInIsIncomeAndShowsAPlusSign() throws {
        let model = try emptyModel()
        let group = try #require(model.addGroup(named: "Pool House"))
        let bookings = try #require(model.addBudget(named: "Bookings", limit: .dollars(2000), in: group))
        model.selectedBudget = bookings

        let editor = EntryEditor(model: model)
        #expect(!editor.isMoneyIn, "off to start: every entry is money spent unless marked")
        editor.merchant = "Airbnb"
        editor.amountText = "1310.00"
        editor.isMoneyIn = true
        #expect(editor.add())
        let payout = try #require(model.transactions.first { $0.merchant == "Airbnb" })
        #expect(payout.amount == Money(minorUnits: 131_000) && payout.kind == .income)

        let screen = BudgetScreen(summary: try #require(model.summaries[group]?.first), model: model, me: nil)
        #expect(screen.rows.first { $0.merchant == "Airbnb" }?.amount == "+$1310.00")
        #expect(BudgetScreen.amountText(Money(minorUnits: -4250)) == "$42.50", "money out shows no sign")

        // Opened, the switch is on and the top line says Income.
        let opened = try #require(EntryEditor(model: model, entry: payout.id))
        #expect(opened.isMoneyIn)
        #expect(opened.topLine == "Manual \u{00B7} Income")
        #expect(!opened.canSave, "nothing changed yet")
        opened.isMoneyIn = false
        #expect(opened.canSave)
        #expect(opened.save())
        let turned = try #require(try model.store.transaction(payout.id))
        #expect(turned.kind == .spending && turned.amount == Money(minorUnits: -131_000))

        // A refund opened shows the switch on, and stays a refund when saved as is.
        let refund = Transaction(budgetID: bookings, groupID: group, date: Date(), merchant: "Cleaner refund",
                                 amount: Money(minorUnits: 2500))
        try model.store.save(refund)
        model.reload()
        let openedRefund = try #require(EntryEditor(model: model, entry: refund.id))
        #expect(openedRefund.isMoneyIn && openedRefund.topLine == "Manual \u{00B7} Refund")
        openedRefund.amountText = "30"
        #expect(openedRefund.save())
        #expect(try model.store.transaction(refund.id)?.kind == .refund)
        #expect(try model.store.transaction(refund.id)?.amount == Money(minorUnits: 3000))

        // Switched on, a spending entry becomes income.
        let spending = try #require(model.transactions.first { $0.merchant == "Airbnb" })
        let openedSpending = try #require(EntryEditor(model: model, entry: spending.id))
        #expect(!openedSpending.isMoneyIn)
        openedSpending.isMoneyIn = true
        #expect(openedSpending.save())
        #expect(try model.store.transaction(spending.id)?.kind == .income)
        #expect(try model.store.transaction(spending.id)?.amount == Money(minorUnits: 131_000))
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

    // Scenario PAGE-14
    // A group's menu, and a budget's, are drawn from this person's level. When
    // a sync moves Robin up to Admin, a screen that drew them is told to draw
    // them again, though nothing else it shows changed. Before, the sidebar
    // kept offering Leave… with no Delete… until it was redrawn for some
    // other reason.
    @Test func aSyncThatChangesTheLevelTellsTheMenusToRedraw() async throws {
        let server = InMemoryReadableServer()
        let leslie = try await signedUp("leslie@example.com", on: server)
        let group = try #require(AppModel(store: leslie.store).addGroup(named: "Household"))
        await leslie.syncAll()
        let link = try await leslie.share(group: group, groupName: "Household", level: .write, historyAccess: .all,
                                          myName: "Leslie")
        let robin = try await signedUp("robin@example.com", on: server)
        _ = try await robin.join(link, myName: "Robin")
        await robin.syncAll()
        #expect(!robin.mayManageBudgets(in: group), "at Add, Robin may not manage budgets")
        #expect(robin.deleteReach(of: group) == .thisMacOnly, "at Add, Robin leaves rather than deletes")

        // The sidebar asks these while it draws the group's menu.
        let told = Told()
        withObservationTracking {
            _ = robin.mayManageBudgets(in: group)
            _ = robin.deleteReach(of: group)
        } onChange: {
            told.set()
        }
        try await leslie.setLevel(.admin, of: try #require(robin.userID), in: group)
        await robin.syncAll()

        #expect(robin.mayManageBudgets(in: group) && robin.deleteReach(of: group) == .everyone,
                "the sync brought the new level")
        #expect(told.value, "a screen that drew the menus is told to draw them again")
    }

    // Scenario PAGE-17
    // Leslie added Costco, then Robin removed her, so nobody else is in the
    // group. Her entry still says she added it: the column shows while any
    // entry was added by someone else, not only while the group is shared.
    // Robin's own entries alone, as before, show none.
    @Test func entriesSomeoneRemovedAddedStillSayWhoAddedThem() async throws {
        let server = InMemoryReadableServer()
        let robin = try await signedUp("robin@example.com", on: server)
        let robinsModel = AppModel(store: robin.store)
        robinsModel.me = { robin.userID }
        let group = try #require(robinsModel.addGroup(named: "Household"))
        let groceries = try #require(robinsModel.addBudget(named: "Groceries", limit: .dollars(500), in: group))
        robinsModel.selectedBudget = groceries
        robinsModel.addTransaction(merchant: "Hilltop Grocery", amount: .dollars(40), date: Date(), note: "")
        await robin.syncAll()
        let alone = BudgetScreen(summary: try #require(robinsModel.summary(for: groceries)), model: robinsModel,
                                 me: robin.userID)
        #expect(!alone.showsAddedBy, "Robin's own entries alone show no Added by")

        let link = try await robin.share(group: group, groupName: "Household", level: .write, historyAccess: .all,
                                         myName: "Robin")
        let leslie = try await signedUp("leslie@example.com", on: server)
        _ = try await leslie.join(link, myName: "Leslie")
        await leslie.syncAll()
        let lesliesModel = AppModel(store: leslie.store)
        lesliesModel.selectedBudget = groceries
        lesliesModel.addTransaction(merchant: "Costco", amount: .dollars(99), date: Date(), note: "")
        await leslie.syncAll()
        await robin.syncAll()
        let leslieID = try #require(leslie.userID)
        try await robin.remove(leslieID, from: group)
        await robin.syncAll()

        robinsModel.reload()
        robinsModel.selectedBudget = groceries
        #expect(!robinsModel.isShared(group), "Robin is the only one left")
        let after = BudgetScreen(summary: try #require(robinsModel.summary(for: groceries)), model: robinsModel,
                                 me: robin.userID)
        #expect(after.showsAddedBy, "the column went with the last other person")
        #expect(after.rows.first { $0.merchant == "Costco" }?.addedBy == "Leslie", "her name went with her")
        #expect(after.rows.first { $0.merchant == "Hilltop Grocery" }?.addedBy == "You")
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

    // Scenario INC-02
    /// A statement line that is money in is offered as Income, with Refund
    /// and the rest to choose from, and lands as the kind chosen. The next
    /// line from the same payer is offered the way the last one was marked.
    @Test func theImportReviewOffersMoneyInAsIncomeOrRefund() throws {
        let model = try emptyModel()
        let group = try #require(model.addGroup(named: "Pool House"))
        let bookings = try #require(model.addBudget(named: "Bookings", limit: .dollars(2000), in: group))
        model.selectedBudget = bookings
        func statement(_ lines: String) throws -> URL {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("statement-\(UUID().uuidString).csv")
            try "Date,Description,Amount\n\(lines)".write(to: url, atomically: true, encoding: .utf8)
            return url
        }
        let first = try statement("""
        10/05/2026,"AIRBNB PAYOUT",1310.00
        10/04/2026,"CLEANING CO",-120.00
        """)
        defer { try? FileManager.default.removeItem(at: first) }

        let screen = ImportReviewScreen(model: model)
        model.prepareImport(from: first)
        #expect(screen.rows.map(\.kind) == [.income, nil], "money in is offered as income; money out has no kind")
        #expect(screen.rows[0].isMoneyIn && !screen.rows[1].isMoneyIn)
        #expect(ImportReviewScreen.kindChoices.prefix(2) == [.income, .refund])
        #expect(ImportReviewScreen.name(of: .income) == "Income" && ImportReviewScreen.name(of: .refund) == "Refund")
        screen.choose(.refund, for: 1)
        #expect(screen.rows[1].kind == nil, "a money-out line takes no kind")
        screen.choose(.refund, for: 0)
        #expect(screen.rows[0].kind == .refund)
        screen.choose(bookings, for: 0)
        screen.choose(bookings, for: 1)
        screen.commit()
        let landed = try model.store.transactions(in: bookings)
        #expect(landed.first { $0.merchant == "Airbnb Payout" }?.kind == .refund)
        #expect(landed.first { $0.merchant == "Airbnb Payout" }?.amount == Money(minorUnits: 131_000))
        #expect(landed.first { $0.amount == Money(minorUnits: -12_000) }?.kind == .spending)

        // The next payout from the same payer is offered the same way.
        let second = try statement("""
        10/12/2026,"AIRBNB PAYOUT",980.00
        10/12/2026,"VRBO PAYOUT",640.00
        """)
        defer { try? FileManager.default.removeItem(at: second) }
        model.prepareImport(from: second)
        #expect(screen.rows.map(\.kind) == [.refund, .income])
        screen.cancel()
    }

    // Scenario INC-02
    /// Two money-in entries from the same payer on the same day: the one
    /// marked most recently decides how the next line is offered, whatever
    /// order the store hands them back in.
    @Test func theSamePayerOnTheSameDayFollowsTheLatestMark() throws {
        let day = Date(timeIntervalSince1970: 1_790_000_000)
        func entry(_ kind: TransactionKind, changedAt seconds: TimeInterval) -> Transaction {
            Transaction(budgetID: BudgetID(), groupID: GroupID(), date: day, merchant: "Airbnb Payout",
                        amount: Money(minorUnits: 100_000), kind: kind, updatedAt: day.addingTimeInterval(seconds))
        }
        let line = StatementLine(date: day, rawDescription: "AIRBNB PAYOUT", amount: Money(minorUnits: 98_000))
        let proposals = [ImportProposal(line: line, decision: .needsBudget, fingerprint: "x")]
        let older = entry(.income, changedAt: 10), newer = entry(.refund, changedAt: 20)
        #expect(AppModel.moneyInKinds(for: proposals, remembering: [older, newer]) == [0: .refund])
        #expect(AppModel.moneyInKinds(for: proposals, remembering: [newer, older]) == [0: .refund])
    }

    /// A line given a budget will be added, so the counts and its row say so
    /// at once, and say "Needs a budget" again if the choice is taken back. They
    /// used to stay as the statement was first read, until Import.
    @Test func choosingABudgetMovesALineToToAdd() throws {
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
        model.prepareImport(from: url)
        #expect(screen.tiles.map(\.count) == [0, 0, 0, 2])

        screen.choose(groceries, for: 0)
        #expect(screen.tiles.map(\.count) == [0, 1, 0, 1])
        #expect(screen.rows.map(\.status) == ["Will be added", "Needs a budget"])
        #expect(screen.rows.map(\.tone) == [.toAdd, .needsBudget])
        #expect(screen.rows[0].needsBudget, "its budget can still be changed")

        screen.choose(groceries, for: 1)
        #expect(screen.tiles.map(\.count) == [0, 2, 0, 0])

        screen.choose(nil, for: 0)
        #expect(screen.tiles.map(\.count) == [0, 1, 0, 1])
        #expect(screen.rows[0].status == "Needs a budget" && screen.rows[0].tone == .needsBudget)
        screen.cancel()
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
        editor.amountText = "$142.08"
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

@Suite("Editor screens, amounts the region's way", .serialized)
@MainActor
struct EditorAmountTests {
    static let us = Locale(identifier: "en_US")
    static let germany = Locale(identifier: "de_DE")

    // Scenario ENTRY-12
    @Test func whereACommaMarksDecimals12_50SavesAs12_50() throws {
        let model = try emptyModel()
        let group = try #require(model.addGroup(named: "Household"))
        let budget = try #require(model.addBudget(named: "Groceries", limit: .dollars(500), in: group))
        model.selectedBudget = budget

        let editor = EntryEditor(model: model, locale: Self.germany)
        editor.merchant = "Hilltop Grocery"
        editor.amountText = "12,50"
        #expect(editor.canAdd && editor.amountProblem == nil)
        #expect(editor.add())
        #expect(model.transactions.first?.amount == Money(minorUnits: -1_250))
    }

    // Scenario ENTRY-13
    @Test func anUnclearAmountDimsAddAndSaysHowToTypeIt() throws {
        let editor = EntryEditor(model: try emptyModel(), locale: Self.us)
        editor.merchant = "Hilltop Grocery"
        editor.amountText = "12,50"
        #expect(!editor.canAdd)
        #expect(editor.amountProblem == "That amount can't be read clearly. Type it like 12.50.")
        editor.amountText = ""
        #expect(editor.amountProblem == nil, "an empty field says nothing")
        editor.amountText = "12.50"
        #expect(editor.canAdd && editor.amountProblem == nil)
    }

    @Test func anOpenedEntryShowsItsAmountTheRegionsWayWithSaveDimmed() throws {
        let s = try Hilltop()
        let editor = EntryEditor(model: s.model, editing: try s.stored(), locale: Self.germany)
        #expect(editor.amountText == "142,08")
        #expect(editor.amountProblem == nil && !editor.canSave, "nothing changed yet")
        editor.amountText = "142,10"
        #expect(editor.canSave)
        editor.amountText = "142.10"
        #expect(!editor.canSave && editor.amountProblem != nil, "a dot is a thousands mark here")
    }

    // Scenario BUDGET-16
    @Test func aBudgetReadsItsAmountTheRegionsWayToo() throws {
        let model = try emptyModel()
        let group = try #require(model.addGroup(named: "Household"))
        let editor = BudgetEditor(model: model, group: group, locale: Self.germany)
        #expect(editor.amountPrompt == "500,00")
        editor.name = "Groceries"
        editor.amountText = "500.00"
        #expect(!editor.canSave)
        #expect(editor.amountProblem == "That amount can't be read clearly. Type it like 12,50.")
        editor.amountText = "1.500,00"
        #expect(editor.canSave && editor.amountProblem == nil)
        #expect(editor.save())
        let saved = try #require(model.summaries[group]?.first?.budget)
        #expect(saved.limit == .dollars(1_500))

        let reopened = BudgetEditor(model: model, editing: saved, locale: Self.germany)
        #expect(reopened.amountText == "1500,00")
    }
}

/// An open budget trades its bar for its wheel: the day of its period under
/// its name, the wheel and its figures, and the pace words when there are
/// any, with Edit Budget only for someone who may change budgets.
@Suite("Budget screen, its wheel", .serialized)
@MainActor
struct BudgetWheelScreenTests {
    private let calendar = WheelCalendar.calendar

    /// The screen for `name`, `limit` a month with `spent` spent, on the
    /// given day of October 2026, in a group on `model`. Cents.
    private func budgetScreen(_ name: String = "Groceries", limit: Int, spent: Int, october day: Int,
                        model: AppModel) throws -> BudgetScreen {
        let group = try #require(model.addGroup(named: "Household"))
        let now = WheelCalendar.date(2026, 10, day)
        let summary = WheelCalendar.summary(name, limit: limit, spent: spent, on: now, in: group)
        return BudgetScreen(summary: summary, model: model, me: nil, now: now, calendar: calendar)
    }

    // Scenario WHEEL-05
    @Test func anOpenBudgetShowsItsWheelAndTheDayOfItsPeriod() throws {
        let screen = try budgetScreen(limit: 100_000, spent: 55_536, october: 18, model: emptyModel())
        let now = WheelCalendar.date(2026, 10, 18)
        #expect(screen.wheel == MoneyWheel(budget: screen.summary, now: now, calendar: calendar))
        #expect(screen.dayLine == "October · day 18 of 31")
        #expect(screen.wheel.spokenSummary == "Left $445 of $1,000")
        #expect(screen.wheel.figures.map(\.amount) == ["$555.36", "$444.64", "$419.35"])
        #expect(screen.pace == nil, "more is left than expected, and it is not the last week")
    }

    // Scenario WHEEL-08
    @Test func spendingFasterThanAnEvenPaceOffersEditBudgetOnlyToSomeoneWhoMayChangeIt() throws {
        let model = try emptyModel()
        let gas = try budgetScreen("Gas", limit: 18_000, spent: 12_200, october: 18, model: model)
        #expect(gas.wheel.isWarning)
        #expect(gas.pace?.text == "At this pace, Gas runs out around Oct 26, five days early.")
        #expect(gas.pace?.offersEdit == true)

        model.mayManageEntries = { _ in false }
        let atAdd = try budgetScreen("Gas", limit: 18_000, spent: 12_200, october: 18, model: model)
        #expect(atAdd.pace?.text == "At this pace, Gas runs out around Oct 26, five days early.")
        #expect(atAdd.pace?.offersEdit == false)
    }

    // Scenario WHEEL-09
    @Test func inTheLastWeekOnlySomeoneWhoMayChangeItIsAskedToLowerIt() throws {
        let model = try emptyModel()
        let groceries = try budgetScreen(limit: 100_000, spent: 50_000, october: 26, model: model)
        #expect(groceries.pace?.kind == .underPace)
        #expect(groceries.pace?.offersEdit == true)

        model.mayManageEntries = { _ in false }
        #expect(try budgetScreen(limit: 100_000, spent: 50_000, october: 26, model: model).pace == nil)
    }

    /// A budget that never resets has no day of its period to show.
    @Test func aBudgetThatNeverResetsHasNoDayLine() throws {
        let model = try emptyModel()
        let group = try #require(model.addGroup(named: "Household"))
        let now = WheelCalendar.date(2026, 10, 18)
        let summary = BudgetSummary(
            budget: Budget(groupID: group, name: "Savings", limit: .dollars(500), reset: .never),
            period: ResetSchedule.never.period(containing: now, calendar: calendar),
            spent: .dollars(100), transactionCount: 1)
        let screen = BudgetScreen(summary: summary, model: model, me: nil, now: now, calendar: calendar)
        #expect(screen.dayLine == nil)
        #expect(screen.pace == nil)
        #expect(screen.wheel.figures.map(\.label) == ["Spent", "Left"])
    }
}

/// One person's device on a shared in-memory server, signed up with the
/// email confirmed.
@MainActor
private func signedUp(_ email: String, on server: InMemoryReadableServer) async throws -> SyncCoordinator {
    let store = Store(database: try WellSpentDatabase.inMemory())
    let transport = StubReadableTransport(server: server)
    let sync = SyncCoordinator(store: store, keyStore: InMemoryKeyStore(), defaults: isolatedDefaults(),
                               makeTransport: { _ in transport })
    try await sync.signUp(email: email, password: "a-long-password")
    try await sync.verifyEmail(code: try #require(server.lastCode(for: email, purpose: .verify)))
    return sync
}

/// Whether an observation's change was heard, for a test to read after.
private final class Told: @unchecked Sendable {
    private let lock = NSLock()
    private var heard = false
    func set() { lock.lock(); heard = true; lock.unlock() }
    var value: Bool { lock.lock(); defer { lock.unlock() }; return heard }
}
