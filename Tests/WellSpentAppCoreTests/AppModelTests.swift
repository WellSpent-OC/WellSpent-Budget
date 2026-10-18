import Testing
import Foundation
@testable import WellSpentAppCore
import Observation
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

    @Test func deletingRemovesItFromTheListAndTheTotal() throws {
        let (model, _, budget) = try seededModel()
        model.addTransaction(merchant: "mistake", amount: Money(minorUnits: 9999),
                             date: Date(), note: "")
        let row = try #require(model.transactions.first)

        #expect(model.deleteEntry(row.id) == .saved)

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

    /// A statement goes into the group whose budget is open. It always went into
    /// the first group, so a shop statement read from a shop budget landed in
    /// the household, and the shop's own lines were never found as duplicates.
    @Test func aStatementGoesIntoTheGroupOfTheOpenBudget() throws {
        let model = try makeModel()
        let household = try #require(model.addGroup(named: "Household"))
        let shop = try #require(model.addGroup(named: "Shop"))
        #expect(model.groups.first?.id == household, "the shop is not the first group")
        let groceries = try #require(model.addBudget(named: "Groceries", limit: Money(minorUnits: 50_000), in: household))
        let supplies = try #require(model.addBudget(named: "Supplies", limit: Money(minorUnits: 50_000), in: shop))
        let url = try writeCSV("Date,Description,Amount\n09/22/2026,\"OFFICE DEPOT\",-42.10")
        defer { try? FileManager.default.removeItem(at: url) }

        model.selectedBudget = supplies
        model.prepareImport(from: url)
        #expect(model.pendingImport?.groupID == shop)
        let screen = ImportReviewScreen(model: model)
        #expect(screen.title == "Import a statement into \u{201C}Shop\u{201D}")
        #expect(screen.budgetChoices.map(\.name) == ["Supplies"])

        screen.choose(supplies, for: 0)
        screen.commit()
        #expect(try model.store.transactions(in: supplies).count == 1)
        #expect(try model.store.transactions(in: groceries).isEmpty)

        // The same statement again, from the shop: its line is found as already in.
        model.prepareImport(from: url)
        #expect(screen.rows.map(\.status) == ["Already imported"])
        screen.cancel()

        // Adding is judged for the group the statement goes into.
        model.mayAddEntries = { $0 == household }
        model.prepareImport(from: url)
        #expect(model.errorMessage == "You can view this group but not add to it.")
        #expect(model.pendingImport == nil)
        model.dismissError()
        model.selectedBudget = groceries
        model.prepareImport(from: url)
        #expect(model.pendingImport?.groupID == household)
    }

    /// Importing a statement again leaves a line deleted since then deleted.
    /// It counted as new, and filing it again stopped the import partway
    /// with a database error, because the deleted row still held its mark.
    @Test func aDeletedLineStaysDeletedWhenItsStatementIsImportedAgain() throws {
        let (model, group, budget) = try seededModel()
        let url = try writeCSV("""
        Date,Description,Amount
        10/02/2026,"TRADER JOES #123",-54.20
        10/03/2026,"CORNER BAKERY",-12.00
        """)
        defer { try? FileManager.default.removeItem(at: url) }
        model.prepareImport(from: url)
        model.pendingImport?.chosenBudgets = [0: budget.id, 1: budget.id]
        model.commitImport()
        let joes = try #require(try model.store.transactions(in: budget.id).first { $0.note == "TRADER JOES #123" })
        #expect(model.deleteEntry(joes.id) == .saved)

        model.prepareImport(from: url)
        let review = ImportReviewScreen(model: model)
        #expect(review.rows.map(\.status) == ["Already imported", "Already imported"])
        review.choose(budget.id, for: 0)
        review.commit()

        #expect(model.errorMessage == nil, "the import finishes")
        #expect(try model.store.transaction(joes.id)?.isDeleted == true, "the line stays deleted")
        #expect(try model.store.transactions(in: budget.id).map(\.note) == ["CORNER BAKERY"])
        #expect(try model.store.statements(in: group.id).count == 2, "the statement is recorded")
    }

    /// A line whose budget was deleted comes back, so it can be filed in
    /// another budget. Filing it stopped the import with a database error.
    @Test func aLineWhoseBudgetWasDeletedIsOfferedAgainAndCanBeFiledElsewhere() throws {
        let (model, group, groceries) = try seededModel()
        let eatingOut = try #require(model.addBudget(named: "Eating out", limit: Money(minorUnits: 30_000),
                                                     in: group.id))
        let url = try writeCSV("""
        Date,Description,Amount
        10/02/2026,"TRADER JOES #123",-54.20
        10/03/2026,"CORNER BAKERY",-12.00
        """)
        defer { try? FileManager.default.removeItem(at: url) }
        model.selectedBudget = groceries.id
        model.prepareImport(from: url)
        model.pendingImport?.chosenBudgets = [0: groceries.id, 1: groceries.id]
        model.commitImport()
        model.deleteBudget(groceries.id)

        model.prepareImport(from: url)
        let review = ImportReviewScreen(model: model)
        #expect(review.rows.map(\.status) == ["Needs a budget", "Needs a budget"])
        #expect(review.budgetChoices.map(\.name) == ["Eating out"])
        review.choose(eatingOut, for: 0)
        review.choose(eatingOut, for: 1)
        review.commit()

        #expect(model.errorMessage == nil, "the import finishes")
        #expect(try model.store.transactions(in: eatingOut).map(\.merchant).sorted() == ["Corner Bakery", "Trader Joes"])
        // Filed again, it counts as imported from now on.
        model.prepareImport(from: url)
        #expect(review.rows.map(\.status) == ["Already imported", "Already imported"])
        review.cancel()
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

    /// A statement that cannot be used is named and explained. Raw error text,
    /// such as "Error Domain=NSCocoaErrorDomain Code=260", never shows.
    @Test func aStatementThatCannotBeUsedIsExplainedInWords() throws {
        let (model, _, _) = try seededModel()
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("wellspent-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        func problem(_ name: String, _ contents: Data?) throws -> String {
            let url = folder.appendingPathComponent(name)
            if let contents { try contents.write(to: url) }
            model.dismissError()
            model.prepareImport(from: url)
            #expect(model.pendingImport == nil)
            let message = model.errorMessage ?? ""
            #expect(!message.contains("Error Domain") && !message.contains("ImportError"), "\(message)")
            return message
        }
        let download = "Download a CSV, OFX or QFX file from your bank and import that."

        #expect(try problem("gone.csv", nil)
                == "\u{201C}gone.csv\u{201D} is not there any more. It may have been moved or deleted.")
        #expect(try problem("notes.txt", Data("just some words".utf8))
                == "\u{201C}notes.txt\u{201D} is not a statement this app can read. \(download)")
        #expect(try problem("header.csv", Data("Date,Description,Amount\n".utf8))
                == "\u{201C}header.csv\u{201D} has no entries to import.")
        #expect(try problem("columns.csv", Data("Date,Payee\n09/22/2026,HILLTOP".utf8))
                == "Line 1 of \u{201C}columns.csv\u{201D} could not be read: no amount column. \(download)")
        // Not UTF-8. Foundation's error code for this differs by platform, so
        // only the start of the sentence is fixed.
        #expect(try problem("latin.csv", Data([0x44, 0x61, 0xFF, 0xFE, 0x2C, 0x0A]))
                .hasPrefix("\u{201C}latin.csv\u{201D} could not"))
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

    /// Beside a list, as on the Mac, a budget opens by itself while none is
    /// open. A phone shows a budget in place of the list, so there nothing
    /// opens one but a tap, and deleting the open one goes back to the list.
    @Test func onAPhoneOnlyATapOpensABudget() throws {
        let store = Store(database: try WellSpentDatabase.inMemory())
        let setUp = AppModel(store: store)
        let group = try #require(setUp.addGroup(named: "Household"))
        let groceries = try #require(setUp.addBudget(named: "Groceries", limit: Money(minorUnits: 100_000), in: group))
        let eatingOut = try #require(setUp.addBudget(named: "Eating out", limit: Money(minorUnits: 30_000), in: group))
        let utilities = try #require(setUp.addBudget(named: "Utilities", limit: Money(minorUnits: 45_000), in: group))

        let phone = AppModel(store: store, opensFirstBudget: false)
        #expect(phone.selectedBudget == nil, "it starts on the list")
        phone.reload()
        #expect(phone.selectedBudget == nil, "a sync bringing changes in opens nothing")

        phone.selectedBudget = groceries
        phone.reload()
        #expect(phone.selectedBudget == groceries, "a tapped budget stays open through a sync")
        phone.deleteBudget(groceries)
        #expect(phone.selectedBudget == nil, "back to the list, not into the next budget")

        // The Mac, over the same budgets: one opens at once, and another
        // after the open one is deleted.
        let mac = AppModel(store: store)
        #expect(mac.selectedBudget == eatingOut)
        mac.deleteBudget(eatingOut)
        #expect(mac.selectedBudget == utilities)
    }

    /// A budget deleted on another device closes here when the sync brings
    /// the delete in, as one deleted here does: a phone goes back to the
    /// list, and the Mac opens the next budget.
    @Test func aBudgetDeletedElsewhereClosesAtTheNextSync() throws {
        let store = Store(database: try WellSpentDatabase.inMemory())
        let setUp = AppModel(store: store)
        let group = try #require(setUp.addGroup(named: "Household"))
        let groceries = try #require(setUp.addBudget(named: "Groceries", limit: Money(minorUnits: 100_000), in: group))
        let eatingOut = try #require(setUp.addBudget(named: "Eating out", limit: Money(minorUnits: 30_000), in: group))

        let phone = AppModel(store: store, opensFirstBudget: false)
        phone.selectedBudget = groceries
        let mac = AppModel(store: store)
        mac.selectedBudget = groceries

        // The other device's delete, as a sync writes it into this store.
        AppModel(store: store).deleteBudget(groceries)
        phone.reload()
        mac.reload()

        #expect(phone.selectedBudget == nil, "back to the list")
        #expect(phone.transactions.isEmpty)
        #expect(mac.selectedBudget == eatingOut, "the next budget, as after a delete here")
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

// MARK: - One transaction

/// Whole seconds, so a date read back from the database compares equal.
private let earlier = Date(timeIntervalSince1970: 1_790_000_000)

/// Household, with Groceries and Eating out, and Robin's “Hilltop Grocery”,
/// $142.08, today, in Groceries, as a sync leaves it. This person is Leslie,
/// at Manage, looking at Groceries.
@MainActor
private struct Household {
    let model: AppModel
    let group: GroupID
    let groceries: BudgetID
    let eatingOut: BudgetID
    let robin = UserID()
    let leslie = UserID()
    let hilltop: RecordID

    init(undoWindow: Duration = .seconds(3600)) throws {
        model = AppModel(store: Store(database: try WellSpentDatabase.inMemory()), undoWindow: undoWindow)
        group = try #require(model.addGroup(named: "Household"))
        groceries = try #require(model.addBudget(named: "Groceries", limit: Money(minorUnits: 50_000), in: group))
        eatingOut = try #require(model.addBudget(named: "Eating out", limit: Money(minorUnits: 20_000), in: group))
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

    func stored() throws -> Transaction { try #require(try model.store.transaction(hilltop)) }
    func spent(_ budget: BudgetID) -> Money? { model.summary(for: budget)?.spent }

    /// Moves this person to a level, as a sync does when the server says so.
    func at(_ level: AccessLevel) {
        model.mayAddEntries = { _ in level.allows(.write) }
        model.mayManageEntries = { _ in level.allows(.manage) }
    }
}

@Suite("App model, one transaction", .serialized)
@MainActor
struct AppModelEntryTests {
    @Test func aChangeKeepsTheOwnerSourceImportMarkAndCreatedDate() throws {
        let s = try Household()
        let receipt = RecordID()
        let line = Transaction(budgetID: s.groceries, groupID: s.group, date: Date(), merchant: "Trader Joes",
                               note: "TRADER JOES #123", amount: Money(minorUnits: -5420), source: .statement,
                               receiptID: receipt, importFingerprint: "LINE-1", createdBy: s.robin,
                               createdAt: earlier, updatedAt: earlier)
        try s.model.store.save(line, queue: false)

        let result = s.model.updateEntry(line.id, EntryChange(merchant: "Trader Joe's",
                                                              amount: Money(minorUnits: 6000), note: "Weekly shop"))

        #expect(result == .saved)
        let changed = try #require(try s.model.store.transaction(line.id))
        #expect(changed.merchant == "Trader Joe's" && changed.note == "Weekly shop")
        #expect(changed.amount == Money(minorUnits: -6000), "still money out")
        #expect(changed.createdBy == s.robin, "Added by still says Robin")
        #expect(changed.source == .statement)
        #expect(changed.importFingerprint == "LINE-1")
        #expect(changed.receiptID == receipt)
        #expect(changed.createdAt == earlier)
        #expect(changed.groupID == s.group && changed.budgetID == s.groceries)
        #expect(changed.updatedAt > earlier)
        #expect(try s.model.store.queuedPush(line.id) != nil, "it syncs")
        #expect(s.spent(s.groceries) == Money(minorUnits: 14208 + 6000), "the total changes at once")
    }

    /// An edit changes the amount, never whether money went out or came in.
    @Test func aChangeKeepsWhetherMoneyWentOutOrCameIn() throws {
        let s = try Household()
        let refund = Transaction(budgetID: s.groceries, groupID: s.group, date: Date(), merchant: "Trader Joes",
                                 amount: Money(minorUnits: 5420), source: .statement)
        try s.model.store.save(refund, queue: false)

        #expect(s.model.updateEntry(refund.id, EntryChange(amount: Money(minorUnits: -6000))) == .saved)
        #expect(try s.model.store.transaction(refund.id)?.amount == Money(minorUnits: 6000), "a refund stays a refund")
        #expect(s.model.updateEntry(s.hilltop, EntryChange(amount: Money(minorUnits: 12408))) == .saved)
        #expect(try s.stored().amount == Money(minorUnits: -12408))
    }

    @Test func aChangeAndADeleteAreRefusedAtView() throws {
        let s = try Household()
        try s.model.store.clearOutbox(in: s.group)
        s.at(.read)

        #expect(s.model.updateEntry(s.hilltop, EntryChange(merchant: "Changed")) == .notAllowed(.viewOnly))
        #expect(s.model.deleteEntry(s.hilltop) == .notAllowed(.viewOnly))

        #expect(try s.stored().merchant == "Hilltop Grocery")
        #expect(try !s.stored().isDeleted)
        #expect(try s.model.store.outboxCount(in: s.group) == 0, "nothing saved that would never sync")
        #expect(s.model.undoOffer == nil)
    }

    @Test func atAddSomeoneElsesEntryIsRefusedAndTheirOwnIsNot() throws {
        let s = try Household()
        s.at(.write)

        #expect(s.model.updateEntry(s.hilltop, EntryChange(merchant: "Changed"))
                == .notAllowed(.someoneElses(name: "Robin")))
        #expect(s.model.deleteEntry(s.hilltop) == .notAllowed(.someoneElses(name: "Robin")))
        #expect(try s.stored().merchant == "Hilltop Grocery" && !s.stored().isDeleted)

        s.model.addTransaction(merchant: "Costco", amount: Money(minorUnits: 2863), date: Date(), note: "")
        let costco = try #require(s.model.transactions.first { $0.merchant == "Costco" })
        #expect(s.model.updateEntry(costco.id, EntryChange(note: "bulk")) == .saved)
        #expect(s.model.deleteEntry(costco.id) == .saved)
    }

    /// A move to another budget in the same group.
    @Test func aMoveTakesTheEntryOutOfOneBudgetAndIntoTheOther() throws {
        let s = try Household()

        #expect(s.model.updateEntry(s.hilltop, EntryChange(budget: s.eatingOut)) == .saved)

        #expect(s.model.transactions.isEmpty, "gone from Groceries' list")
        #expect(s.spent(s.groceries) == .zero())
        #expect(s.spent(s.eatingOut) == Money(minorUnits: 14208))
        s.model.selectedBudget = s.eatingOut
        #expect(s.model.transactions.map(\.merchant) == ["Hilltop Grocery"])
        #expect(try s.stored().groupID == s.group && s.stored().createdBy == s.robin)
    }

    @Test func aMoveToABudgetInAnotherGroupOrOneDeletedIsRefused() throws {
        let s = try Household()
        let side = try #require(s.model.addGroup(named: "Side Business"))
        let tools = try #require(s.model.addBudget(named: "Tools", limit: Money(minorUnits: 10_000), in: side))
        s.model.selectedBudget = s.groceries

        #expect(s.model.updateEntry(s.hilltop, EntryChange(note: "moved", budget: tools)) == .failed)
        #expect(s.model.errorMessage == "Nothing was changed, because Tools is in another group.")
        #expect(try s.stored().budgetID == s.groceries && s.stored().note == "")

        s.model.dismissError()
        s.model.deleteBudget(s.eatingOut)
        s.model.selectedBudget = s.groceries
        #expect(s.model.updateEntry(s.hilltop, EntryChange(budget: s.eatingOut)) == .failed)
        #expect(s.model.errorMessage == "Nothing was changed, because Eating out was deleted.")
        #expect(try s.stored().budgetID == s.groceries)
        #expect(s.model.transactions.map(\.id) == [s.hilltop])
    }

    /// The list shows only the current period, so the entry leaves it.
    @Test func aDateBeforeThisPeriodTakesTheEntryOutOfThisList() throws {
        let s = try Household()
        let twoMonthsAgo = try #require(Calendar.current.date(byAdding: .month, value: -2, to: Date()))

        #expect(s.model.updateEntry(s.hilltop, EntryChange(date: twoMonthsAgo)) == .saved)

        #expect(s.model.transactions.isEmpty)
        #expect(s.spent(s.groceries) == .zero())
        #expect(try !s.stored().isDeleted, "moved, not deleted")
    }
}

@Suite("Undo after a delete", .serialized)
@MainActor
struct UndoTests {
    @Test func undoBringsTheEntryBackWithTheSameDetails() throws {
        let s = try Household()
        let before = try s.stored()

        #expect(s.model.deleteEntry(s.hilltop) == .saved)
        let offer = try #require(s.model.undoOffer)
        #expect(offer.entry == s.hilltop)
        #expect(offer.message == "Deleted \u{201C}Hilltop Grocery\u{201D}, $142.08.")
        #expect(offer.button == "Undo")
        #expect(s.model.transactions.isEmpty)

        s.model.undoDelete()

        #expect(s.model.undoOffer == nil, "the bar goes")
        let back = try s.stored()
        #expect(!back.isDeleted)
        #expect(back.merchant == before.merchant && back.amount == before.amount && back.date == before.date)
        #expect(back.note == before.note && back.budgetID == before.budgetID)
        #expect(back.createdBy == s.robin, "Added by still says Robin")
        #expect(s.model.transactions.map(\.id) == [s.hilltop])
        #expect(s.spent(s.groceries) == Money(minorUnits: 14208))
        #expect(try s.model.store.queuedPush(s.hilltop)?.isDeleted == false, "a newer live version is what syncs")
    }

    @Test(.timeLimit(.minutes(1)))
    func theBarGoesAfterItsWindowAndTheDeleteStays() async throws {
        let s = try Household(undoWindow: .zero)

        s.model.deleteEntry(s.hilltop)
        #expect(s.model.undoOffer != nil)
        await whenTrue { s.model.undoOffer == nil }

        #expect(try s.stored().isDeleted)
        #expect(s.model.transactions.isEmpty)
    }

    @Test func theBarGoesAtTheNextChangeButNotWhenASyncBringsChangesIn() throws {
        let s = try Household()
        s.model.deleteEntry(s.hilltop)

        s.model.reload()
        #expect(s.model.undoOffer != nil, "a sync reloads, and the bar stays")
        s.model.addTransaction(merchant: "Costco", amount: Money(minorUnits: 2863), date: Date(), note: "")

        #expect(s.model.undoOffer == nil)
        #expect(try s.stored().isDeleted, "the delete stays")
    }

    @Test func aSecondDeleteReplacesTheBar() throws {
        let s = try Household()
        s.model.addTransaction(merchant: "Costco", amount: Money(minorUnits: 2863), date: Date(), note: "")
        let costco = try #require(s.model.transactions.first { $0.merchant == "Costco" })

        s.model.deleteEntry(s.hilltop)
        s.model.deleteEntry(costco.id)
        #expect(s.model.undoOffer?.entry == costco.id)
        #expect(s.model.undoOffer?.message == "Deleted \u{201C}Costco\u{201D}, $28.63.")
        s.model.undoDelete()

        #expect(try s.stored().isDeleted, "only the last delete can be undone")
        #expect(s.model.transactions.map(\.merchant) == ["Costco"])
    }

    @Test func undoIsRefusedInWordsAfterAMoveDownToView() throws {
        let s = try Household()
        s.model.deleteEntry(s.hilltop)
        s.at(.read)

        s.model.undoDelete()

        #expect(s.model.undoOffer == nil, "the bar goes")
        #expect(s.model.errorMessage == "This can't be undone now. You can view this group but not change it.")
        #expect(try s.stored().isDeleted, "nothing comes back")
    }

    @Test func undoIsRefusedInWordsAtAddOnSomeoneElsesEntry() throws {
        let s = try Household()
        s.model.deleteEntry(s.hilltop)
        s.at(.write)

        s.model.undoDelete()

        #expect(s.model.errorMessage == "This can't be undone now. Only Robin, or a manager, can change this.")
        #expect(try s.stored().isDeleted)
    }

    @Test func undoIsRefusedInWordsWhenTheBudgetWasDeleted() throws {
        let s = try Household()
        s.model.deleteEntry(s.hilltop)
        // Someone deletes Groceries, and a sync brings it in.
        var gone = try #require(try s.model.store.budget(s.groceries))
        gone.isDeleted = true
        try s.model.store.save(gone, queue: false)
        s.model.reload()

        s.model.undoDelete()

        #expect(s.model.errorMessage == "This can't be undone now, because Groceries was deleted.")
        #expect(try s.stored().isDeleted)
        #expect(s.model.undoOffer == nil)
    }

    /// Someone's newer edit brought it back already: Undo only clears the bar.
    @Test func undoOfAnEntryAlreadyBackOnlyClearsTheBar() throws {
        let s = try Household()
        s.model.deleteEntry(s.hilltop)
        var back = try s.stored()
        back.isDeleted = false
        back.note = "Robin's newer edit"
        try s.model.store.save(back, queue: false)
        try s.model.store.clearOutbox(in: s.group)
        s.model.reload()
        #expect(s.model.undoOffer != nil, "a sync does not take the bar away")

        s.model.undoDelete()

        #expect(s.model.undoOffer == nil)
        #expect(s.model.errorMessage == nil)
        #expect(try s.stored().note == "Robin's newer edit")
        #expect(try s.model.store.outboxCount(in: s.group) == 0, "nothing more to send")
    }

    /// The budget screen carries the bar for the views to draw.
    @Test func theBudgetScreenCarriesTheBar() throws {
        let s = try Household()
        let summary = try #require(s.model.summary(for: s.groceries))
        #expect(BudgetScreen(summary: summary, model: s.model, me: s.leslie).undo == nil)

        s.model.deleteEntry(s.hilltop)

        let after = try #require(s.model.summary(for: s.groceries))
        #expect(BudgetScreen(summary: after, model: s.model, me: s.leslie).undo == s.model.undoOffer)
        #expect(BudgetScreen(summary: after, model: s.model, me: s.leslie).undo?.button == "Undo")
    }
}

/// Waits until `condition` holds, without polling or sleeping: it wakes
/// each time something the condition reads changes.
@MainActor
func whenTrue(_ condition: @escaping @MainActor () -> Bool) async {
    while !condition() {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            withObservationTracking {
                _ = condition()
            } onChange: {
                continuation.resume()
            }
        }
    }
}
