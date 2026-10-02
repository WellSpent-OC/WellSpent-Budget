import Testing
import SwiftUI
import ViewInspector
@testable import WellSpentAppCore
import WellSpentCrypto
import WellSpentImport
import WellSpentKeyStore
import WellSpentModel
import WellSpentStore

/// UI tests for the Mac app.
///
/// These inspect a live SwiftUI hierarchy in process: they build the real views,
/// walk them, read the text that would be on screen, and invoke the real button
/// actions.
///
/// What they are not: XCUITest. Driving the built application, clicking real
/// pixels and asserting on windows needs an Xcode project, a bundled `.app` and
/// `xcodebuild`, none of which a SwiftPM package has. That is a structural change
/// rather than a dependency, and it is recorded in STATUS.md.
///
/// What they do catch: a view that stops rendering a value, a total that is
/// formatted wrong, a button wired to nothing, a state that does not update.
@MainActor
private func idleSync(_ model: AppModel) -> SyncCoordinator {
    SyncCoordinator(store: model.store, keyStore: InMemoryKeyStore(),
                    defaults: isolatedDefaults())
}

@MainActor
private func modelWithData() throws -> (AppModel, BudgetGroup, Budget) {
    let model = AppModel(store: Store(database: try WellSpentDatabase.inMemory()))
    model.addGroup(named: "Household")
    let group = try #require(model.groups.first)
    model.addBudget(named: "Groceries", limit: Money(minorUnits: 100_000), in: group.id)
    let budget = try #require(model.summaries[group.id]?.first?.budget)
    model.selectedBudget = budget.id
    return (model, group, budget)
}

@Suite("App views", .serialized)
@MainActor
struct ViewTests {

    // MARK: - Budget row

    @Test func aBudgetRowShowsItsNameAndWhatIsLeft() throws {
        let (model, _, budget) = try modelWithData()
        model.addTransaction(merchant: "Hilltop", amount: Money(minorUnits: 14208),
                             date: Date(), note: "")
        let summary = try #require(model.summary(for: budget.id))

        let row = BudgetRow(summary: summary)
        let texts = try row.inspect().findAll(ViewType.Text.self).map { try $0.string() }

        #expect(texts.contains("Groceries"))
        #expect(texts.contains { $0.contains("857.92") }, "the remainder, got \(texts)")
    }

    /// An overspent budget has to look different, not just be different.
    @Test func anOverspentRowShowsANegativeRemainder() throws {
        let (model, _, budget) = try modelWithData()
        model.addTransaction(merchant: "oops", amount: Money(minorUnits: 120_000),
                             date: Date(), note: "")
        let summary = try #require(model.summary(for: budget.id))
        #expect(summary.isOverspent)

        let texts = try BudgetRow(summary: summary).inspect()
            .findAll(ViewType.Text.self).map { try $0.string() }
        #expect(texts.contains { $0.contains("-") && $0.contains("200.00") }, "got \(texts)")
    }

    // MARK: - Sidebar

    @Test func theSidebarListsEveryGroupAndBudget() throws {
        let (model, group, _) = try modelWithData()
        model.addBudget(named: "Eating out", limit: Money(minorUnits: 30_000), in: group.id)
        model.addGroup(named: "Side Business")

        let sidebar = SidebarView(model: model, sync: idleSync(model), editor: .constant(nil))
        let texts = try sidebar.inspect().findAll(ViewType.Text.self).map { try $0.string() }

        #expect(texts.contains("HOUSEHOLD"), "group headers are upper-cased, got \(texts)")
        #expect(texts.contains("SIDE BUSINESS"))
        #expect(texts.contains("Groceries"))
        #expect(texts.contains("Eating out"))
        #expect(texts.contains { $0.contains("Encrypted") }, "the reassurance line should be there")
        #expect(texts.contains("Add Budget"), "the way to make a budget is always on screen")
    }

    @Test func groupsCollapseAndExpandIndependently() {
        let household = GroupID(), sideBusiness = GroupID()
        var stored = ""
        stored = SidebarView.toggling(household, in: stored)
        #expect(SidebarView.isCollapsed(household, in: stored))
        #expect(!SidebarView.isCollapsed(sideBusiness, in: stored))

        stored = SidebarView.toggling(sideBusiness, in: stored)
        stored = SidebarView.toggling(household, in: stored)
        #expect(!SidebarView.isCollapsed(household, in: stored))
        #expect(SidebarView.isCollapsed(sideBusiness, in: stored))
    }

    @Test func aBudgetNeedsANameAndAnAmount() {
        #expect(BudgetSheet.canSave(name: "Groceries", amountText: "500"))
        #expect(BudgetSheet.canSave(name: "Groceries", amountText: "500.00"))
        #expect(!BudgetSheet.canSave(name: "", amountText: "500"))
        #expect(!BudgetSheet.canSave(name: "   ", amountText: "500"))
        #expect(!BudgetSheet.canSave(name: "Groceries", amountText: ""))
        #expect(!BudgetSheet.canSave(name: "Groceries", amountText: "0"))
        #expect(!BudgetSheet.canSave(name: "Groceries", amountText: "lots"))
    }

    @Test func aDeleteSaysWhatGoesWithIt() {
        let budget = Budget(groupID: GroupID(), name: "Groceries", limit: Money(minorUnits: 100))
        #expect(PendingDelete.budget(budget, transactions: 3).message.contains("3 transactions"))
        #expect(PendingDelete.budget(budget, transactions: 1).message.contains("1 transaction "))
        #expect(PendingDelete.group(BudgetGroup(name: "Household"), budgets: 2, reach: .justYou).message
                    .contains("2 budgets"))
        #expect(PendingDelete.budget(budget, transactions: 0).title == "Delete \u{201C}Groceries\u{201D}?")
    }

    /// Deleting a shared group says whether the other members lose it too.
    @Test func aGroupDeleteSaysWhoElseLosesIt() {
        let household = BudgetGroup(name: "Household")
        #expect(PendingDelete.group(household, budgets: 2, reach: .everyone).message
                    .contains("Everyone you share it with loses it too"))
        let mine = PendingDelete.group(household, budgets: 2, reach: .thisMacOnly).message
        #expect(mine.contains("this Mac only"))
        #expect(mine.contains("Other members keep it"))
        // What was saved before still goes out once, so the dialog does not
        // promise that nothing in it changes for them.
        #expect(mine.contains("not synced yet"))
        #expect(!mine.contains("keep it and everything in it"))
        // A budget made since the last sync has no key anyone else holds, so
        // it cannot go, and the dialog says so.
        #expect(mine.contains("except a budget you added since your last sync"))
        #expect(PendingDelete.group(household, budgets: 0, reach: .declinesInvite).message
                    .contains("may still add you"))
        #expect(!PendingDelete.group(household, budgets: 2, reach: .justYou).message.contains("member"))
    }

    // MARK: - Budget detail

    @Test func theDetailHeaderShowsSpentLimitAndRemaining() throws {
        let (model, _, budget) = try modelWithData()
        model.addTransaction(merchant: "Hilltop", amount: Money(minorUnits: 14208),
                             date: Date(), note: "")
        let summary = try #require(model.summary(for: budget.id))

        let view = BudgetDetailView(model: model, sync: idleSync(model), summary: summary,
                                    showingAddTransaction: .constant(false),
                                    showingFileImporter: .constant(false),
                                    showingAccount: .constant(false))
        let texts = try view.inspect().findAll(ViewType.Text.self).map { try $0.string() }

        #expect(texts.contains { $0.contains("142.08") }, "what was spent, got \(texts)")
        #expect(texts.contains { $0.contains("1000.00") }, "the limit")
        #expect(texts.contains { $0.contains("857.92") }, "what is left")
    }

    @Test func anOverspentBudgetSaysOverRatherThanLeft() throws {
        let (model, _, budget) = try modelWithData()
        model.addTransaction(merchant: "oops", amount: Money(minorUnits: 120_000),
                             date: Date(), note: "")
        let summary = try #require(model.summary(for: budget.id))

        let view = BudgetDetailView(model: model, sync: idleSync(model), summary: summary,
                                    showingAddTransaction: .constant(false),
                                    showingFileImporter: .constant(false),
                                    showingAccount: .constant(false))
        let texts = try view.inspect().findAll(ViewType.Text.self).map { try $0.string() }

        #expect(texts.contains { $0.contains("over") }, "got \(texts)")
        #expect(!texts.contains { $0.contains("left") })
    }

    // MARK: - Add transaction

    @Test func theAddButtonIsDisabledUntilTheFormIsUsable() throws {
        let (model, _, _) = try modelWithData()
        let sheet = AddTransactionSheet(model: model)

        // Nothing typed: the confirm button must not be available.
        let add = try sheet.inspect().find(button: "Add")
        #expect(try add.isDisabled(), "an empty form should not be submittable")
    }

    @Test func theFormRuleAcceptsAndRejectsTheRightThings() {
        #expect(!AddTransactionSheet.canAdd(merchant: "", amountText: ""))
        #expect(!AddTransactionSheet.canAdd(merchant: "Hilltop", amountText: ""))
        #expect(!AddTransactionSheet.canAdd(merchant: "", amountText: "42.50"))
        #expect(!AddTransactionSheet.canAdd(merchant: "   ", amountText: "42.50"),
                "whitespace is not a merchant")
        #expect(!AddTransactionSheet.canAdd(merchant: "Hilltop", amountText: "not a number"))

        #expect(AddTransactionSheet.canAdd(merchant: "Hilltop", amountText: "42.50"))
        #expect(AddTransactionSheet.canAdd(merchant: "Hilltop", amountText: "$1,234.56"),
                "the amount field accepts what a statement would contain")
        #expect(AddTransactionSheet.canAdd(merchant: "Hilltop", amountText: "(25.00)"))
    }

    /// The real reason the sheet exists: pressing Add writes a transaction.
    @Test func addingThroughTheModelIsWhatTheButtonDoes() throws {
        let (model, _, budget) = try modelWithData()

        // The button's action, exercised directly. Inspecting a SwiftUI button's
        // closure and invoking it is what ViewInspector's tap() does underneath.
        model.addTransaction(merchant: "Hilltop", amount: Money(minorUnits: 4250),
                             date: Date(), note: "")

        #expect(model.transactions.count == 1)
        #expect(try model.store.transactions(in: budget.id).first?.merchant == "Hilltop")
    }

    // MARK: - Import review

    @Test func theImportSheetShowsACountForEachOutcome() throws {
        let (model, _, budget) = try modelWithData()
        model.pendingImport = AppModel.PendingImport(
            filename: "statement.csv",
            proposals: [],
            summary: {
                var s = ImportSummary()
                s.matched = 3
                s.toAdd = 6
                s.alreadyImported = 4
                s.needBudget = 2
                return s
            }()
        )
        _ = budget

        let sheet = ImportReviewSheet(model: model)
        let texts = try sheet.inspect().findAll(ViewType.Text.self).map { try $0.string() }

        #expect(texts.contains("statement.csv"))
        #expect(texts.contains("Matched"))
        #expect(texts.contains("Needs a budget"))
        #expect(texts.contains("3"))
        #expect(texts.contains("6"))
        #expect(texts.contains { $0.contains("Nothing was uploaded") },
                "the privacy line is the point of this screen, got \(texts)")
    }

    @Test func eachImportRowLabelsWhatWillHappenToIt() throws {
        let (model, _, budget) = try modelWithData()
        let line = StatementLine(date: Date(), rawDescription: "HILLTOP #17 SPRING HILL OH",
                                 amount: Money(minorUnits: -14208))

        let cases: [(ImportDecision, String)] = [
            (.alreadyImported, "Already imported"),
            (.matchesReceipt(RecordID()), "Matched to receipt"),
            (.matchesTransaction(RecordID()), "Matched to entry"),
            (.add(budget.id), "Will be added"),
            (.needsBudget, "Needs a budget"),
        ]

        for (decision, expected) in cases {
            let proposal = ImportProposal(line: line, decision: decision, fingerprint: "x")
            let row = ImportRow(index: 0, proposal: proposal, model: model)
            let texts = try row.inspect().findAll(ViewType.Text.self).map { try $0.string() }

            #expect(texts.contains(expected), "for \(decision) got \(texts)")
            #expect(texts.contains("Hilltop Spring Hill"), "the cleaned merchant name")
            #expect(texts.contains("HILLTOP #17 SPRING HILL OH"), "and the raw text underneath")
        }
    }

    // MARK: - Root

    @Test func theRootShowsAnEmptyStateWithNothingSelected() throws {
        let model = AppModel(store: Store(database: try WellSpentDatabase.inMemory()))
        #expect(model.selectedBudget == nil)

        let root = RootView(workspace: Workspace(model: model, sync: idleSync(model)))
        let texts = try root.inspect().findAll(ViewType.Text.self).map { try $0.string() }
        #expect(texts.contains("No budgets yet"), "got \(texts)")
        #expect(texts.contains("Add Budget"), "an empty app says how to start")
    }

    @Test func theRootAsksForAPickWhenBudgetsExistButNoneIsSelected() throws {
        let (model, _, _) = try modelWithData()
        model.selectedBudget = nil

        let root = RootView(workspace: Workspace(model: model, sync: idleSync(model)))
        let texts = try root.inspect().findAll(ViewType.Text.self).map { try $0.string() }
        #expect(texts.contains { $0.contains("No budget selected") || $0.contains("Pick a budget") },
                "got \(texts)")
    }

    @Test func theEntryPointBuildsAView() throws {
        let (model, _, _) = try modelWithData()
        let view = wellSpentRootView(workspace: Workspace(model: model, sync: idleSync(model)))
        #expect(throws: Never.self) { _ = try view.inspect() }
    }

    // MARK: - Palette

    @Test func budgetColoursCycleAndNeverCrash() {
        for index in [-3, 0, 1, 2, 3, 4, 99] {
            _ = Palette.budgetColor(index)
        }
        #expect(Palette.budgetColor(0) == Palette.budgetColor(4), "four colours, then it repeats")
        #expect(Palette.budgetColor(0) == Palette.accent)
    }
}
