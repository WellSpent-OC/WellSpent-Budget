import Testing
import Foundation
import GRDB
@testable import WellSpentStore
import WellSpentCrypto
import WellSpentModel

private func makeStore() throws -> Store {
    Store(database: try WellSpentDatabase.inMemory())
}

private func seedHousehold(_ store: Store) throws -> (BudgetGroup, Budget) {
    let group = BudgetGroup(name: "Household")
    try store.save(group)
    let budget = Budget(groupID: group.id, name: "Groceries",
                        limit: Money(minorUnits: 100_000))   // $1,000.00
    try store.save(budget)
    return (group, budget)
}

private func day(_ year: Int, _ month: Int, _ dayOfMonth: Int) -> Date {
    var components = DateComponents()
    components.year = year
    components.month = month
    components.day = dayOfMonth
    components.hour = 12
    return Calendar(identifier: .gregorian).date(from: components)!
}

@Suite("Money")
struct MoneyTests {
    /// The reason money is an integer here. In binary floating point
    /// 0.1 + 0.2 != 0.3, and the old schema stored amounts as `t.float`.
    @Test func addingTenCentsAHundredTimesIsExact() {
        var total = Money.zero()
        for _ in 0 ..< 100 { total += Money(minorUnits: 10) }
        #expect(total == Money(minorUnits: 1000))
        #expect(total.description == "10.00")

        var drifting = 0.0
        for _ in 0 ..< 100 { drifting += 0.10 }
        #expect(drifting != 10.0, "this is the bug integers avoid")
    }

    @Test func formatting() {
        #expect(Money(minorUnits: 14208).description == "142.08")
        #expect(Money(minorUnits: -2500).description == "-25.00")
        #expect(Money(minorUnits: 5).description == "0.05")
        #expect(Money.dollars(142.08) == Money(minorUnits: 14208))
    }

    @Test func comparisonAndArithmetic() {
        #expect(Money(minorUnits: 100) < Money(minorUnits: 200))
        #expect(Money(minorUnits: 300) - Money(minorUnits: 100) == Money(minorUnits: 200))
        #expect(Money.total([Money(minorUnits: 1), Money(minorUnits: 2)]) == Money(minorUnits: 3))
    }
}

@Suite("Budget periods")
struct PeriodTests {
    @Test func monthlyOnTheFirst() {
        let period = ResetSchedule.firstOfMonth.period(
            containing: day(2026, 9, 22), calendar: Calendar(identifier: .gregorian))
        let calendar = Calendar(identifier: .gregorian)
        #expect(calendar.component(.month, from: period.start) == 9)
        #expect(calendar.component(.day, from: period.start) == 1)
        #expect(calendar.component(.month, from: period.end) == 10)
    }

    @Test func twiceAMonth() {
        let schedule = ResetSchedule.monthly(days: [1, 15])
        let calendar = Calendar(identifier: .gregorian)
        let period = schedule.period(containing: day(2026, 9, 22), calendar: calendar)
        #expect(calendar.component(.day, from: period.start) == 15)
        #expect(calendar.component(.day, from: period.end) == 1)
        #expect(period.contains(day(2026, 9, 22)))
        #expect(!period.contains(day(2026, 9, 14)))
    }

    /// A budget that resets on the 31st still has to reset in February.
    @Test func aDayThatDoesNotExistInThisMonth() {
        let schedule = ResetSchedule.monthly(days: [31])
        let calendar = Calendar(identifier: .gregorian)
        let period = schedule.period(containing: day(2026, 2, 20), calendar: calendar)
        #expect(period.contains(day(2026, 2, 20)))
        #expect(calendar.component(.day, from: period.start) == 31)
        #expect(calendar.component(.month, from: period.start) == 1)
    }

    @Test func neverIsOneLongPeriod() {
        let period = ResetSchedule.never.period(containing: Date())
        #expect(period.contains(day(1999, 1, 1)))
        #expect(period.contains(day(2099, 1, 1)))
    }

    @Test func validation() {
        #expect(ResetSchedule.monthly(days: [1, 15]).isValid)
        #expect(!ResetSchedule.monthly(days: []).isValid)
        #expect(!ResetSchedule.monthly(days: [0]).isValid)
        #expect(!ResetSchedule.monthly(days: [32]).isValid)
        #expect(ResetSchedule.weekly(weekday: 2).isValid)
        #expect(!ResetSchedule.weekly(weekday: 9).isValid)
    }
}

@Suite("Local store")
struct LocalStoreTests {
    @Test func groupsAndBudgetsRoundTrip() throws {
        let store = try makeStore()
        let (group, budget) = try seedHousehold(store)

        #expect(try store.groups().map(\.id) == [group.id])
        #expect(try store.budgets(in: group.id).map(\.name) == ["Groceries"])
        #expect(try store.budget(budget.id)?.limit == Money(minorUnits: 100_000))
    }

    @Test func transactionsRoundTripWithExactAmounts() throws {
        let store = try makeStore()
        let (group, budget) = try seedHousehold(store)

        let transaction = Transaction(budgetID: budget.id, groupID: group.id,
                                      date: day(2026, 9, 22), merchant: "Hilltop",
                                      amount: Money(minorUnits: -14208))
        try store.save(transaction)

        let fetched = try #require(try store.transaction(transaction.id))
        #expect(fetched.merchant == "Hilltop")
        #expect(fetched.amount == Money(minorUnits: -14208))
    }

    @Test func summaryAddsUpSpending() throws {
        let store = try makeStore()
        let (group, budget) = try seedHousehold(store)

        for cents in [-14208, -28631, -5477] {
            try store.save(Transaction(budgetID: budget.id, groupID: group.id,
                                       date: day(2026, 9, 20), merchant: "shop",
                                       amount: Money(minorUnits: cents)))
        }

        let summary = try store.summary(for: budget, on: day(2026, 9, 22),
                                        calendar: Calendar(identifier: .gregorian))
        #expect(summary.spent == Money(minorUnits: 48316))
        #expect(summary.remaining == Money(minorUnits: 51684))
        #expect(summary.transactionCount == 3)
        #expect(!summary.isOverspent)
    }

    /// A refund is money coming back, so it reduces what was spent.
    @Test func refundsReduceSpending() throws {
        let store = try makeStore()
        let (group, budget) = try seedHousehold(store)

        try store.save(Transaction(budgetID: budget.id, groupID: group.id, date: day(2026, 9, 10),
                                   merchant: "Costco", amount: Money(minorUnits: -10000)))
        try store.save(Transaction(budgetID: budget.id, groupID: group.id, date: day(2026, 9, 11),
                                   merchant: "Costco refund", amount: Money(minorUnits: 2500)))

        let summary = try store.summary(for: budget, on: day(2026, 9, 12),
                                        calendar: Calendar(identifier: .gregorian))
        #expect(summary.spent == Money(minorUnits: 7500))
    }

    @Test func overspentBudgetReportsCorrectly() throws {
        let store = try makeStore()
        let (group, budget) = try seedHousehold(store)
        try store.save(Transaction(budgetID: budget.id, groupID: group.id, date: day(2026, 9, 10),
                                   merchant: "oops", amount: Money(minorUnits: -120_000)))

        let summary = try store.summary(for: budget, on: day(2026, 9, 12),
                                        calendar: Calendar(identifier: .gregorian))
        #expect(summary.isOverspent)
        #expect(summary.remaining == Money(minorUnits: -20000))
        #expect(summary.fraction == 1.0, "the bar fills, it does not overflow")
    }

    @Test func spendingOutsideThePeriodIsNotCounted() throws {
        let store = try makeStore()
        let (group, budget) = try seedHousehold(store)

        try store.save(Transaction(budgetID: budget.id, groupID: group.id, date: day(2026, 8, 20),
                                   merchant: "last month", amount: Money(minorUnits: -50000)))
        try store.save(Transaction(budgetID: budget.id, groupID: group.id, date: day(2026, 9, 5),
                                   merchant: "this month", amount: Money(minorUnits: -1000)))

        let summary = try store.summary(for: budget, on: day(2026, 9, 22),
                                        calendar: Calendar(identifier: .gregorian))
        #expect(summary.spent == Money(minorUnits: 1000))
    }

    @Test func trashedTransactionsDisappearFromTotals() throws {
        let store = try makeStore()
        let (group, budget) = try seedHousehold(store)

        let transaction = Transaction(budgetID: budget.id, groupID: group.id, date: day(2026, 9, 10),
                                      merchant: "mistake", amount: Money(minorUnits: -9999))
        try store.save(transaction)
        try store.trash(transaction)

        let summary = try store.summary(for: budget, on: day(2026, 9, 12),
                                        calendar: Calendar(identifier: .gregorian))
        #expect(summary.spent == Money.zero())
        #expect(try store.transactions(in: budget.id).isEmpty)
        // Soft deleted, so other devices can learn it went away.
        #expect(try store.transactions(in: budget.id, includeDeleted: true).count == 1)
    }

    @Test func localFullTextSearch() throws {
        let store = try makeStore()
        let (group, budget) = try seedHousehold(store)

        for name in ["Hilltop Grocery", "Costco Wholesale", "Home Depot"] {
            try store.save(Transaction(budgetID: budget.id, groupID: group.id, date: day(2026, 9, 10),
                                       merchant: name, amount: Money(minorUnits: -100)))
        }

        #expect(try store.searchTransactions("hillto").count == 1)
        #expect(try store.searchTransactions("co").count >= 1)
        #expect(try store.searchTransactions("zzzz").isEmpty)
    }

    /// Deleting a budget must not leave transactions behind. The 2014 schema had
    /// this bug: the cascade was commented out and the orphans crashed the API on
    /// load.
    @Test func deletingAGroupCascades() throws {
        let store = try makeStore()
        let (group, budget) = try seedHousehold(store)
        try store.save(Transaction(budgetID: budget.id, groupID: group.id, date: day(2026, 9, 10),
                                   merchant: "x", amount: Money(minorUnits: -1)))

        try store.database.write { db in
            _ = try db.execute(sql: "DELETE FROM budgetGroup WHERE id = ?", arguments: [group.id.uuid.uuidString])
        }

        let remaining = try store.database.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM transactionRecord") ?? -1
        }
        #expect(remaining == 0, "orphaned transactions are how the old API broke")
    }

    @Test func reimportingTheSameStatementRowIsBlocked() throws {
        let store = try makeStore()
        let (group, budget) = try seedHousehold(store)

        let first = Transaction(budgetID: budget.id, groupID: group.id, date: day(2026, 9, 10),
                                merchant: "Hilltop", amount: Money(minorUnits: -14208),
                                source: .statement, importFingerprint: "abc123")
        try store.save(first)

        #expect(try store.existingFingerprints(["abc123", "nope"], in: group.id) == ["abc123"])

        let duplicate = Transaction(budgetID: budget.id, groupID: group.id, date: day(2026, 9, 10),
                                    merchant: "Hilltop", amount: Money(minorUnits: -14208),
                                    source: .statement, importFingerprint: "abc123")
        #expect(throws: (any Error).self) { try store.save(duplicate) }
    }

    @Test func manualRowsDoNotCollideOnNullFingerprints() throws {
        let store = try makeStore()
        let (group, budget) = try seedHousehold(store)
        for _ in 0 ..< 5 {
            try store.save(Transaction(budgetID: budget.id, groupID: group.id, date: day(2026, 9, 10),
                                       merchant: "cash", amount: Money(minorUnits: -500)))
        }
        #expect(try store.transactions(in: budget.id).count == 5)
    }

    @Test func receiptsAreRecognisedByContent() throws {
        let store = try makeStore()
        let (group, _) = try seedHousehold(store)
        let hash = Data(repeating: 0xAB, count: 32)

        try store.save(Receipt(groupID: group.id, filename: "scan.jpg", byteCount: 1024,
                               plaintextSHA256: hash))
        #expect(try store.receipt(withHash: hash) != nil)
        #expect(try store.receipt(withHash: Data(repeating: 0x01, count: 32)) == nil)
    }
}

@Suite("Outbox")
struct OutboxTests {
    /// Every synced write queues itself in the same transaction. There is no path
    /// that saves a record and forgets to schedule the push.
    @Test func savingQueuesAPush() throws {
        let store = try makeStore()
        let (group, budget) = try seedHousehold(store)

        // group + budget already queued by seedHousehold
        #expect(try store.outboxCount(in: group.id) == 2)

        try store.save(Transaction(budgetID: budget.id, groupID: group.id, date: Date(),
                                   merchant: "x", amount: Money(minorUnits: -1)))
        #expect(try store.outboxCount(in: group.id) == 3)
    }

    /// A record edited five times offline should push once, not five times.
    @Test func repeatedEditsCollapseToOneEntry() throws {
        let store = try makeStore()
        let (group, budget) = try seedHousehold(store)

        var transaction = Transaction(budgetID: budget.id, groupID: group.id, date: Date(),
                                      merchant: "first", amount: Money(minorUnits: -1))
        try store.save(transaction)
        let after = try store.outboxCount(in: group.id)

        for name in ["second", "third", "fourth", "fifth"] {
            transaction.merchant = name
            transaction.updatedAt = Date()
            try store.save(transaction)
        }
        #expect(try store.outboxCount(in: group.id) == after)
    }

    @Test func lamportAdvancesWithEachQueuedWrite() throws {
        let store = try makeStore()
        let (group, budget) = try seedHousehold(store)
        let before = try store.syncState(for: group.id).lamport

        try store.save(Transaction(budgetID: budget.id, groupID: group.id, date: Date(),
                                   merchant: "x", amount: Money(minorUnits: -1)))
        #expect(try store.syncState(for: group.id).lamport == before + 1)
    }

    @Test func clearingRemovesOnlyWhatWasNamed() throws {
        let store = try makeStore()
        let (group, budget) = try seedHousehold(store)

        let transaction = Transaction(budgetID: budget.id, groupID: group.id, date: Date(),
                                      merchant: "x", amount: Money(minorUnits: -1))
        try store.save(transaction)
        let before = try store.outboxCount(in: group.id)

        try store.clearOutbox([transaction.id])
        #expect(try store.outboxCount(in: group.id) == before - 1)
    }

    /// A push clears only the rows it read. A record saved again while the push
    /// was out has a newer row, and that row has not been sent.
    @Test func clearingWhatWasReadKeepsANewerSave() throws {
        let store = try makeStore()
        let (group, budget) = try seedHousehold(store)

        var transaction = Transaction(budgetID: budget.id, groupID: group.id, date: Date(),
                                      merchant: "first", amount: Money(minorUnits: -1))
        try store.save(transaction)
        let read = try store.pendingPushes(in: group.id)

        transaction.merchant = "second"
        try store.save(transaction)
        try store.clearOutbox(read)

        let left = try store.pendingPushes(in: group.id)
        #expect(left.map(\.recordID) == [transaction.id], "only the newer save is left")

        try store.clearOutbox(left)
        #expect(try store.outboxCount(in: group.id) == 0)
    }

    /// What is done through `inOneTransaction` lands together. A save made on
    /// another thread in the meantime waits for it, so what the body read is
    /// still true when it writes. The sync engine relies on this to weigh a
    /// pulled record against the queue and write the winner, with no save by
    /// the person landing in between.
    @Test func aSaveMadeDuringOneTransactionLandsAfterIt() throws {
        let store = try makeStore()
        let (group, _) = try seedHousehold(store)
        let done = DispatchSemaphore(value: 0)

        try store.inOneTransaction { inside in
            Thread {
                var elsewhere = group
                elsewhere.name = "Elsewhere"
                try? store.save(elsewhere)
                done.signal()
            }.start()
            Thread.sleep(forTimeInterval: 0.05)
            #expect(try inside.group(group.id)?.name == "Household", "the other save waits")
            var mine = group
            mine.name = "Inside"
            try inside.save(mine)
        }
        done.wait()
        #expect(try store.group(group.id)?.name == "Elsewhere", "and lands after")
    }

    /// A re-seal row carries no edit of its own, and says so. Queued over an
    /// edit not yet sent, it stays an edit, because the record still holds it.
    @Test func aResealOverAQueuedEditStaysAnEdit() throws {
        let store = try makeStore()
        let (group, budget) = try seedHousehold(store)
        try store.clearOutbox(in: group.id)

        var renamed = budget
        renamed.name = "Food"
        try store.save(renamed)
        let edit = try #require(try store.queuedPush(RecordID(budget.id.uuid)))
        try store.queueReseal(of: group.id)

        #expect(try store.queuedPush(RecordID(group.id.uuid))?.isReseal == true)
        let both = try #require(try store.queuedPush(RecordID(budget.id.uuid)))
        #expect(!both.isReseal)
        #expect(both.owesReseal, "and it still owes the re-seal")
        #expect(both.weighedLamport == edit.lamport, "weighed at the value the edit was made at")
        #expect(both.lamport > edit.lamport, "sent at a fresh one, so the server stores the new seal")
    }

    /// An edit saved over a re-seal is an edit, and still owes the re-seal.
    /// Moved above a newer version taken in, the row only seals that again.
    @Test func aRowOwingAReSealKeepsOwingIt() throws {
        let store = try makeStore()
        let (group, budget) = try seedHousehold(store)
        try store.clearOutbox(in: group.id)
        let id = RecordID(budget.id.uuid)

        try store.queueReseal(of: group.id)
        var renamed = budget
        renamed.name = "Food"
        try store.save(renamed)
        let edit = try #require(try store.queuedPush(id))
        #expect(!edit.isReseal && edit.owesReseal)
        #expect(edit.weighedLamport == edit.lamport)

        try store.requeue(id, above: 100)
        let moved = try #require(try store.queuedPush(id))
        #expect(moved.isReseal && moved.editLamport == nil)
        #expect(moved.lamport > 100)
    }

    /// A clock at its largest value has nowhere to go. The save is refused
    /// with an error, where adding one crashed the app. Only a database that
    /// pulled a forged value before the ceiling existed can be in this state.
    @Test func aFullClockRefusesTheSaveInsteadOfCrashing() throws {
        let store = try makeStore()
        let (group, budget) = try seedHousehold(store)
        try store.database.write { db in
            try db.execute(sql: "UPDATE syncState SET lamport = ? WHERE budgetGroupId = ?",
                           arguments: [Int64.max, group.id.uuid.uuidString])
        }

        var renamed = budget
        renamed.name = "Food"
        #expect(throws: (any Error).self) { try store.save(renamed) }
        #expect(try store.budget(budget.id)?.name == "Groceries", "nothing half saved")
    }
}
