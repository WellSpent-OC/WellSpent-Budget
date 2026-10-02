import Testing
import Foundation
@testable import WellSpentAppCore
import WellSpentCrypto
import WellSpentImport
import WellSpentModel
import WellSpentStore

/// Tests for the Mac app's logic.
///
/// Until this target existed the app was 775 lines in an executable target, which
/// no test could depend on and llvm-cov could not see, so it was neither tested
/// nor counted. The SwiftUI views stay in the executable, because a view body
/// needs a UI harness rather than a unit test. Everything that decides anything
/// lives here.
@MainActor
private func makeModel() throws -> AppModel {
    AppModel(store: Store(database: try WellSpentDatabase.inMemory()))
}

@MainActor
private func seededModel() throws -> (AppModel, BudgetGroup, Budget) {
    let model = try makeModel()
    model.addGroup(named: "Household")
    let group = try #require(model.groups.first)
    model.addBudget(named: "Groceries", limit: Money(minorUnits: 100_000), in: group.id)
    let budget = try #require(model.summaries[group.id]?.first?.budget)
    model.selectedBudget = budget.id
    return (model, group, budget)
}

@Suite("App model", .serialized)
@MainActor
struct AppModelTests {

    @Test func startsEmpty() throws {
        let model = try makeModel()
        #expect(model.groups.isEmpty)
        #expect(model.transactions.isEmpty)
        #expect(model.selectedBudget == nil)
        #expect(model.errorMessage == nil)
    }

    @Test func addingAGroupAndABudget() throws {
        let model = try makeModel()
        model.addGroup(named: "Household")

        #expect(model.groups.count == 1)
        let group = try #require(model.groups.first)
        #expect(group.name == "Household")

        model.addBudget(named: "Groceries", limit: Money(minorUnits: 50_000), in: group.id)
        let summaries = try #require(model.summaries[group.id])
        #expect(summaries.count == 1)
        #expect(summaries[0].budget.name == "Groceries")
        #expect(summaries[0].budget.limit == Money(minorUnits: 50_000))
    }

    /// The first budget added should become the selection, so the window is never
    /// staring at an empty pane after the first action.
    @Test func theFirstBudgetBecomesTheSelection() throws {
        let model = try makeModel()
        model.addGroup(named: "Household")
        let group = try #require(model.groups.first)

        #expect(model.selectedBudget == nil)
        model.addBudget(named: "Groceries", limit: Money(minorUnits: 1000), in: group.id)
        #expect(model.selectedBudget != nil)
    }

    @Test func addingATransactionStoresItAsMoneyOut() throws {
        let (model, _, budget) = try seededModel()

        // Typed as a positive number, because nobody types a minus into a spend field.
        model.addTransaction(merchant: "Hilltop", amount: Money(minorUnits: 14208),
                             date: Date(), note: "weekly shop")

        #expect(model.transactions.count == 1)
        let row = try #require(model.transactions.first)
        #expect(row.merchant == "Hilltop")
        #expect(row.note == "weekly shop")
        #expect(row.amount == Money(minorUnits: -14208), "a spend is stored negative")

        let summary = try #require(model.summary(for: budget.id))
        #expect(summary.spent == Money(minorUnits: 14208))
        #expect(summary.remaining == Money(minorUnits: 85792))
    }

    @Test func aNegativeAmountIsNotDoubleNegated() throws {
        let (model, _, budget) = try seededModel()
        model.addTransaction(merchant: "Costco", amount: Money(minorUnits: -5000),
                             date: Date(), note: "")

        #expect(model.transactions.first?.amount == Money(minorUnits: -5000))
        #expect(try #require(model.summary(for: budget.id)).spent == Money(minorUnits: 5000))
    }

    @Test func addingATransactionWithNothingSelectedDoesNothing() throws {
        let model = try makeModel()
        model.addTransaction(merchant: "nowhere", amount: Money(minorUnits: 100),
                             date: Date(), note: "")
        #expect(model.transactions.isEmpty)
        #expect(model.errorMessage == nil, "it should be a no-op, not an error")
    }

    @Test func trashingRemovesItFromTheListAndTheTotal() throws {
        let (model, _, budget) = try seededModel()
        model.addTransaction(merchant: "mistake", amount: Money(minorUnits: 9999),
                             date: Date(), note: "")
        let row = try #require(model.transactions.first)

        model.trash(row)

        #expect(model.transactions.isEmpty)
        #expect(try #require(model.summary(for: budget.id)).spent == Money.zero())
        // Soft deleted, so other devices learn it went away.
        #expect(try model.store.transactions(in: budget.id, includeDeleted: true).count == 1)
    }

    @Test func changingTheSelectionReloadsTheTransactions() throws {
        let (model, group, groceries) = try seededModel()
        model.addTransaction(merchant: "in groceries", amount: Money(minorUnits: 100),
                             date: Date(), note: "")

        model.addBudget(named: "Fuel", limit: Money(minorUnits: 20_000), in: group.id)
        let fuel = try #require(model.summaries[group.id]?.first { $0.budget.name == "Fuel" }?.budget)

        model.selectedBudget = fuel.id
        #expect(model.transactions.isEmpty)

        model.selectedBudget = groceries.id
        #expect(model.transactions.count == 1)
    }

    @Test func lookupsByIdentifier() throws {
        let (model, group, budget) = try seededModel()

        #expect(model.budget(for: budget.id)?.name == "Groceries")
        #expect(model.group(named: group.id)?.name == "Household")
        #expect(model.summary(for: BudgetID()) == nil)
        #expect(model.group(named: GroupID()) == nil)
    }

    @Test func errorsAreSurfacedAndDismissable() throws {
        let model = try makeModel()
        model.errorMessage = "something went wrong"
        #expect(model.errorMessage != nil)

        model.dismissError()
        #expect(model.errorMessage == nil)
    }

    @Test func firstRunSeedsSomethingToLookAt() throws {
        let model = try makeModel()
        try model.seedFirstRun()

        #expect(model.groups.count == 2)
        #expect(model.groups.map(\.name).sorted() == ["Household", "Side Business"])

        let household = try #require(model.groups.first { $0.name == "Household" })
        #expect(model.summaries[household.id]?.count == 3)

        let allTransactions = try model.store.budgets(in: household.id)
            .flatMap { try model.store.transactions(in: $0.id) }
        #expect(allTransactions.count == 6)
    }
}

@Suite("App model, statement import", .serialized)
@MainActor
struct AppModelImportTests {
    private func writeCSV(_ contents: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("wellspent-\(UUID().uuidString).csv")
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    @Test func preparingAnImportProposesWithoutWriting() throws {
        let (model, _, budget) = try seededModel()
        let url = try writeCSV("""
        Date,Description,Amount
        09/22/2026,"HILLTOP #17 SPRING HILL OH",-142.08
        09/21/2026,"COSTCO WHSE #0472",-286.31
        """)
        defer { try? FileManager.default.removeItem(at: url) }

        model.prepareImport(from: url)

        let pending = try #require(model.pendingImport)
        #expect(pending.proposals.count == 2)
        #expect(pending.summary.needBudget == 2, "no rules yet, so a person must pick")
        #expect(model.errorMessage == nil)
        // Nothing written until it is confirmed.
        #expect(try model.store.transactions(in: budget.id).isEmpty)
    }

    @Test func committingWritesTheRowsItWasToldTo() throws {
        let (model, _, budget) = try seededModel()
        let url = try writeCSV("""
        Date,Description,Amount
        09/22/2026,"HILLTOP #17 SPRING HILL OH",-142.08
        09/21/2026,"COSTCO WHSE #0472",-286.31
        """)
        defer { try? FileManager.default.removeItem(at: url) }

        model.prepareImport(from: url)
        // Answer the two "needs a budget" rows.
        model.pendingImport?.chosenBudgets = [0: budget.id, 1: budget.id]
        model.commitImport()

        #expect(model.pendingImport == nil)
        let rows = try model.store.transactions(in: budget.id)
        #expect(rows.count == 2)
        #expect(rows.allSatisfy { $0.source == .statement })
        #expect(rows.contains { $0.merchant == "Hilltop Spring Hill" })
        #expect(try model.store.statements(in: rows[0].groupID).count == 1)
    }

    @Test func rowsWithNoBudgetChosenAreLeftAlone() throws {
        let (model, _, budget) = try seededModel()
        let url = try writeCSV("""
        Date,Description,Amount
        09/22/2026,"HILLTOP",-10.00
        09/21/2026,"COSTCO",-20.00
        """)
        defer { try? FileManager.default.removeItem(at: url) }

        model.prepareImport(from: url)
        model.pendingImport?.chosenBudgets = [0: budget.id]   // only the first
        model.commitImport()

        #expect(try model.store.transactions(in: budget.id).count == 1)
    }

    @Test func aMerchantAlreadyFiledPicksItsOwnBudget() throws {
        let (model, _, budget) = try seededModel()
        model.addTransaction(merchant: "Hilltop", amount: Money(minorUnits: 500),
                             date: Date(), note: "")

        let url = try writeCSV("""
        Date,Description,Amount
        09/22/2026,"HILLTOP",-142.08
        """)
        defer { try? FileManager.default.removeItem(at: url) }

        model.prepareImport(from: url)
        let pending = try #require(model.pendingImport)
        #expect(pending.summary.toAdd == 1, "the rule learned from the row already filed")

        model.commitImport()
        #expect(try model.store.transactions(in: budget.id).count == 2)
    }

    @Test func cancellingThrowsTheProposalAway() throws {
        let (model, _, budget) = try seededModel()
        let url = try writeCSV("Date,Description,Amount\n09/22/2026,HILLTOP,-10.00")
        defer { try? FileManager.default.removeItem(at: url) }

        model.prepareImport(from: url)
        #expect(model.pendingImport != nil)

        model.cancelImport()
        #expect(model.pendingImport == nil)
        #expect(try model.store.transactions(in: budget.id).isEmpty)
    }

    @Test func aFileThatIsNotAStatementReportsRatherThanCrashing() throws {
        let (model, _, _) = try seededModel()
        let url = try writeCSV("this is not a statement")
        defer { try? FileManager.default.removeItem(at: url) }

        model.prepareImport(from: url)

        #expect(model.pendingImport == nil)
        #expect(model.errorMessage != nil, "the person should be told")
    }

    @Test func importingWithNoGroupSaysSoInsteadOfFailingQuietly() throws {
        let model = try makeModel()          // no group at all
        let url = try writeCSV("Date,Description,Amount\n09/22/2026,HILLTOP,-10.00")
        defer { try? FileManager.default.removeItem(at: url) }

        model.prepareImport(from: url)

        #expect(model.pendingImport == nil)
        #expect(model.errorMessage?.contains("budget group") == true)
    }

    @Test func committingWithNothingPendingIsANoOp() throws {
        let (model, _, budget) = try seededModel()
        model.commitImport()
        #expect(try model.store.transactions(in: budget.id).isEmpty)
        #expect(model.errorMessage == nil)
    }

    /// The fingerprints are keyed, and the key used to be generated at launch. So
    /// the same statement imported after a restart hashed differently, nothing
    /// matched, and every row came back as new. This needs a file on disk rather
    /// than the in-memory database, because the whole question is what survives.
    @Test func reImportingTheSameStatementAfterARestartSkipsEveryRow() throws {
        let dbURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("wellspent-restart-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: dbURL) }

        let statement = try writeCSV("""
        Date,Description,Amount
        09/22/2026,"HILLTOP #17 SPRING HILL OH",-142.08
        09/21/2026,"COSTCO WHSE #0472",-286.31
        """)
        defer { try? FileManager.default.removeItem(at: statement) }

        // First launch: import and commit both rows.
        let budgetID: BudgetID
        do {
            let model = AppModel(store: Store(database: try WellSpentDatabase.open(at: dbURL)))
            model.addGroup(named: "Household")
            let group = try #require(model.groups.first)
            model.addBudget(named: "Groceries", limit: Money(minorUnits: 100_000), in: group.id)
            budgetID = try #require(model.summaries[group.id]?.first?.budget.id)

            model.prepareImport(from: statement)
            model.pendingImport?.chosenBudgets = [0: budgetID, 1: budgetID]
            model.commitImport()
            #expect(try model.store.transactions(in: budgetID).count == 2)
        }

        // Next launch: the same file, the same database, a new model.
        let model = AppModel(store: Store(database: try WellSpentDatabase.open(at: dbURL)))
        model.prepareImport(from: statement)

        let pending = try #require(model.pendingImport)
        #expect(pending.summary.alreadyImported == 2,
                "both rows should be recognised, got \(pending.summary)")
        model.commitImport()
        #expect(try model.store.transactions(in: budgetID).count == 2, "and nothing duplicated")
    }

    /// A row given a budget from another group was filed under the group
    /// being imported into. Every other member refused it, so it showed on
    /// this Mac and nowhere else. It is filed under its budget's own group.
    @Test func anImportedRowIsFiledUnderItsBudgetsGroup() throws {
        let (model, household, _) = try seededModel()
        let side = try #require(model.addGroup(named: "Side Business"))
        let tools = try #require(model.addBudget(named: "Tools", limit: Money(minorUnits: 50_000),
                                                 in: side))
        #expect(model.groups.first?.id == household.id, "the import goes to Household")
        let url = try writeCSV("""
        Date,Description,Amount
        09/22/2026,"HARDWARE STORE",-42.00
        """)
        defer { try? FileManager.default.removeItem(at: url) }

        model.prepareImport(from: url)
        model.pendingImport?.chosenBudgets = [0: tools]
        model.commitImport()

        let row = try #require(try model.store.transactions(in: tools).first)
        #expect(row.groupID == side)
    }

    /// In a group shared with this person, the keys come from whoever shared
    /// it, and this Mac never replaces a key it holds. A key made here for
    /// fingerprints before the real one arrived would be kept, and nothing
    /// anyone else sealed would open. The import waits for the keys instead.
    @Test func importingIntoASharedGroupWaitsForItsKeys() throws {
        let (model, group, _) = try seededModel()
        try model.store.save(PendingJoin(groupID: group.id, groupName: "Household",
                                         inviterName: "Robin", displayName: "Leslie", level: .write))
        let url = try writeCSV("""
        Date,Description,Amount
        09/22/2026,"HILLTOP",-10.00
        """)
        defer { try? FileManager.default.removeItem(at: url) }

        model.prepareImport(from: url)
        #expect(model.pendingImport == nil)
        #expect(model.errorMessage?.contains("Sync") == true)
        #expect(try model.store.cachedKeys(scope: .group(group.id)).isEmpty, "no key made up here")
    }

    // MARK: - Making and removing budgets

    @Test func aNewBudgetGoesLastInItsGroupInTheNextColorAndIsSelected() throws {
        let (model, group, first) = try seededModel()
        let id = try #require(model.addBudget(named: "  Eating out ", limit: Money(minorUnits: -30_000),
                                              in: group.id))
        let added = try #require(model.budget(for: id))
        #expect(added.name == "Eating out", "trimmed")
        #expect(added.limit == Money(minorUnits: 30_000), "a limit is never negative")
        #expect(added.sortOrder > first.sortOrder)
        #expect(added.colorIndex != first.colorIndex)
        #expect(model.selectedBudget == id)
    }

    @Test func editingChangesNameAndAmount() throws {
        let (model, _, budget) = try seededModel()
        model.updateBudget(budget.id, name: "Food", limit: Money(minorUnits: 80_000))
        let edited = try #require(model.budget(for: budget.id))
        #expect(edited.name == "Food")
        #expect(edited.limit == Money(minorUnits: 80_000))
        #expect(edited.groupID == budget.groupID)
    }

    @Test func deletingABudgetTakesItsTransactionsAndSyncsTheDeletion() throws {
        let (model, group, budget) = try seededModel()
        model.addTransaction(merchant: "Hilltop", amount: Money(minorUnits: 14208), date: Date(), note: "")
        #expect(model.transactionCount(inBudget: budget.id) == 1)

        model.deleteBudget(budget.id)
        #expect(model.summaries[group.id]?.isEmpty == true)
        #expect(model.selectedBudget == nil)
        #expect(try model.store.transactions(in: budget.id).isEmpty)
        #expect(try model.store.transactions(in: budget.id, includeDeleted: true).count == 1,
                "marked deleted, not removed, so other devices hear about it")
    }

    @Test func groupsCanBeAddedRenamedAndDeletedWithTheirBudgets() throws {
        let (model, group, budget) = try seededModel()
        let other = try #require(model.addGroup(named: "Side Business"))
        model.renameGroup(other, to: "Side Business LLC")
        #expect(model.group(named: other)?.name == "Side Business LLC")

        model.deleteGroup(group.id, reach: .justYou)
        #expect(model.groups.map(\.id) == [other])
        #expect(try model.store.budget(budget.id)?.isDeleted == true)
        #expect(model.selectedBudget == nil)
    }

    /// Only a delete the person was told reaches everyone, or nobody else
    /// because nobody else is in it, queues anything. The other two stay on
    /// this Mac whatever the store says by the time they are confirmed.
    @Test(arguments: [(GroupDeleteReach.justYou, true), (.everyone, true),
                      (.thisMacOnly, false), (.declinesInvite, false)])
    func aGroupDeleteQueuesOnlyWhatItPromised(reach: GroupDeleteReach, queues: Bool) throws {
        let (model, group, _) = try seededModel()
        try model.store.clearOutbox(in: group.id)

        model.deleteGroup(group.id, reach: reach)

        #expect((try model.store.outboxCount(in: group.id) > 0) == queues)
        #expect(model.groups.isEmpty, "gone from this Mac either way")
    }

    // MARK: - Who added it

    @Test func addedBySaysYouForYourOwnAndTheirNameOtherwise() throws {
        let (model, group, budget) = try seededModel()
        let me = UserID(), leslie = UserID()
        let mine = Transaction(budgetID: budget.id, groupID: group.id, date: Date(),
                               merchant: "a", amount: Money(minorUnits: -1), createdBy: me)
        let notYetPushed = Transaction(budgetID: budget.id, groupID: group.id, date: Date(),
                                       merchant: "b", amount: Money(minorUnits: -1))
        let hers = Transaction(budgetID: budget.id, groupID: group.id, date: Date(),
                               merchant: "c", amount: Money(minorUnits: -1), createdBy: leslie)

        #expect(model.addedBy(mine, me: me) == "You")
        #expect(model.addedBy(notYetPushed, me: me) == "You", "nobody else can have made it yet")
        #expect(model.addedBy(hers, me: me) == "A member", "before she has given a name")

        try model.store.save(MemberProfile(groupID: group.id, userID: leslie, displayName: "Leslie"),
                             queue: false)
        #expect(model.addedBy(hers, me: me) == "Leslie")
    }

    @Test func aGroupNobodyElseHasJoinedIsNotShared() throws {
        let (model, group, _) = try seededModel()
        #expect(model.memberCount(in: group.id) == 1)
        #expect(!model.isShared(group.id))
    }

    @Test func settingYourNameQueuesItForTheGroup() throws {
        let (model, group, _) = try seededModel()
        let me = UserID()
        model.setDisplayName("  Robin ", for: me, in: group.id)
        let saved = try model.store.profiles(in: group.id)
        #expect(saved.map(\.displayName) == ["Robin"])
        #expect(try model.store.pendingPushes(in: group.id).contains { $0.recordType == .memberProfile })
    }
}
