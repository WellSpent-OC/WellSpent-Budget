import Foundation
import Testing
@testable import WellSpentAppCore
import WellSpentCrypto
import WellSpentImport
import WellSpentModel
import WellSpentStore

/// A statement line that is really a repeat's bill takes its place, so the bill
/// counts once, in the same budget, with the same mark (REPEAT-14, 15).
@Suite("The statement match")
@MainActor
struct StatementMatchTests {
    private let model: AppModel
    private let group: GroupID
    private let budget: BudgetID
    private let other: BudgetID
    private let house = RecordID()

    private static func day(_ month: Int, _ day: Int) -> Date {
        AppLocale.calendar.date(from: DateComponents(year: 2026, month: month, day: day, hour: 12))!
    }

    init() throws {
        model = AppModel(store: Store(database: try WellSpentDatabase.inMemory()), undoWindow: .seconds(3600))
        model.today = { Self.day(12, 16) }
        let me = UserID()
        model.me = { me }
        group = try #require(model.addGroup(named: "Home"))
        other = try #require(model.addBudget(named: "Mortgage", limit: Money(minorUnits: 100_000), in: group))
        budget = try #require(model.addBudget(named: "Utilities", limit: Money(minorUnits: 60_000), in: group))
        model.selectedBudget = budget
    }

    /// $85.00 repeats on the 14th. December's bill is made, marked with the house.
    private func aPhoneBill(link: RecordID? = nil) throws -> Transaction {
        model.addRepeatingTransaction(merchant: "Phone bill", amount: Money(minorUnits: 8_500), date: Self.day(11, 14),
                                      note: "", budget: budget, link: link)
        model.reload()
        return try #require(try bills().first { $0.repeatMonth == "2026-12" })
    }

    private func bills() throws -> [Transaction] {
        try model.store.transactions(in: budget, period: nil).filter { $0.merchant == "Phone bill" }
    }

    private func statement(_ lines: String) throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).csv")
        try "Date,Description,Amount\n\(lines)\n".write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }
        model.prepareImport(from: url)
    }

    private var screen: ImportReviewScreen { ImportReviewScreen(model: model) }

    private func spent() throws -> Int {
        try model.store.transactions(in: budget, period: nil)
            .filter { $0.repeatMonth != "2026-11" && !$0.isDeleted }
            .filter { Calendar.current.component(.month, from: $0.date) == 12 }
            .reduce(0) { $0 + $1.amount.minorUnits }
    }

    // Scenario REPEAT-14
    @Test func aCloseLineTakesTheBillsPlaceAndCountsOnce() throws {
        let bill = try aPhoneBill()
        try statement("12/15/2026,\"VERIZON WIRELESS\",-85.40")
        let row = try #require(screen.rows.first)
        #expect(row.status == "Replaces December's Phone bill, $85.00")
        #expect(row.tone == .matched && row.offersKeepBoth && !row.isKeepingBoth)
        #expect(screen.tiles.first?.count == 1)

        screen.commit()
        model.reload()
        #expect(try spent() == -8_540, "counted once, at the bank's amount")
        let line = try #require(try model.store.transactions(in: budget, period: nil).first { $0.source == .statement })
        #expect(line.amount.minorUnits == -8_540)
        #expect(line.budgetID == budget)
        #expect(try model.store.transaction(bill.id)?.isDeleted != false, "the made bill is gone")

        model.reload()
        #expect(try bills().filter { $0.repeatMonth == "2026-12" && !$0.isDeleted }.isEmpty, "the repeat doesn't make it again")
        #expect(model.repeats(in: budget, group: group).count == 1, "and the repeat carries on")
    }

    // Scenario REPEAT-14
    /// The bank's line keeps the bill's mark, or a house's NOI would move.
    @Test func theLineTakesTheBillsBudgetAndHouseMark() throws {
        _ = try aPhoneBill(link: house)
        // A merchant with no history, so nothing says which budget but the bill.
        try statement("12/15/2026,\"ACME PHONE\",-85.00")
        screen.commit()
        let line = try #require(try model.store.transactions(in: budget, period: nil).first { $0.source == .statement })
        #expect(line.extensionLink == house)
        #expect(line.budgetID == budget)
        let marked = try model.store.transactions(in: budget, period: nil)
            .filter { $0.extensionLink == house && !$0.isDeleted && Calendar.current.component(.month, from: $0.date) == 12 }
        #expect(marked.map(\.amount.minorUnits) == [-8_500], "one marked bill, the same money")
    }

    // Scenario REPEAT-15
    @Test func keepBothLeavesBothAsTheyWere() throws {
        let bill = try aPhoneBill(link: house)
        try statement("12/15/2026,\"VERIZON WIRELESS\",-85.40")
        screen.keepBoth(true, for: 0)
        let row = try #require(screen.rows.first)
        #expect(row.status == ImportReviewScreen.Words.willBeAdded && row.tone == .toAdd && row.isKeepingBoth)
        #expect(screen.tiles.map(\.count).prefix(2) == [0, 1])

        screen.commit()
        #expect(try model.store.transaction(bill.id)?.isDeleted == false)
        #expect(try model.store.transaction(bill.id)?.amount.minorUnits == -8_500)
        let line = try #require(try model.store.transactions(in: budget, period: nil).first { $0.source == .statement })
        #expect(line.amount.minorUnits == -8_540)
        #expect(line.extensionLink == nil, "a separate bill isn't marked by a guess")
    }

    @Test func keepBothCanBeTakenBack() throws {
        _ = try aPhoneBill()
        try statement("12/15/2026,\"VERIZON WIRELESS\",-85.40")
        screen.keepBoth(true, for: 0)
        screen.keepBoth(false, for: 0)
        #expect(screen.rows.first?.status == "Replaces December's Phone bill, $85.00")
    }

    /// 10 percent, or $5 when that's larger: on $85.00 that's $8.50. Within 4 days.
    @Test(arguments: [("-93.50", "12/15/2026", true), ("-93.51", "12/15/2026", false), ("-76.50", "12/15/2026", true),
                      ("-76.49", "12/15/2026", false),
                      ("-85.00", "12/18/2026", true), ("-85.00", "12/19/2026", false), ("85.00", "12/15/2026", false)])
    func whatCountsAsClose(amount: String, date: String, matches: Bool) throws {
        _ = try aPhoneBill()
        try statement("\(date),\"ACME\",\(amount)")
        let decision = try #require(model.pendingImport?.proposals.first?.decision)
        if case .replacesMade = decision { #expect(matches) } else { #expect(!matches) }
    }

    /// On a small bill, the $5 is the larger.
    @Test(arguments: [("-25.00", true), ("-25.01", false)])
    func aSmallBillHasFiveDollars(amount: String, matches: Bool) throws {
        model.addRepeatingTransaction(merchant: "Parking", amount: Money(minorUnits: 2_000), date: Self.day(11, 14),
                                      note: "", budget: budget)
        model.reload()
        try statement("12/15/2026,\"ACME\",\(amount)")
        let decision = try #require(model.pendingImport?.proposals.first?.decision)
        if case .replacesMade = decision { #expect(matches) } else { #expect(!matches) }
    }

    /// A merchant that usually goes in another budget isn't this bill.
    @Test func aMerchantRuleForAnotherBudgetDoesNotMatch() throws {
        _ = try aPhoneBill()
        model.selectedBudget = other
        model.addTransaction(merchant: "Acme", amount: Money(minorUnits: 1_000), date: Self.day(10, 1), note: "")
        model.selectedBudget = budget
        try statement("12/15/2026,\"ACME\",-85.00")
        #expect(model.pendingImport?.proposals.first?.decision == .add(other))
    }

    /// Replacing deletes the bill, so someone who may not delete it can't. The line
    /// is still that bill, so it's skipped, and the money counts once.
    @Test func aBillThisPersonMayNotChangeIsSkippedNotAdded() throws {
        let bill = try aPhoneBill()
        model.me = { UserID() }
        model.mayManageEntries = { _ in false }
        try statement("12/15/2026,\"ACME\",-85.00")
        #expect(model.pendingImport?.proposals.first?.decision == .matchesTransaction(bill.id))

        screen.commit()
        #expect(try model.store.transaction(bill.id)?.isDeleted == false)
        #expect(try spent() == -8_500, "counted once")
    }

    /// Moved down while the review was open: the bill stays and the line is skipped.
    @Test func movedDownDuringTheReviewLeavesTheBill() throws {
        let bill = try aPhoneBill()
        try statement("12/15/2026,\"ACME\",-85.40")
        #expect(model.pendingImport?.proposals.first?.decision == .replacesMade(bill.id))

        model.me = { UserID() }
        model.mayManageEntries = { _ in false }
        screen.commit()
        #expect(try model.store.transaction(bill.id)?.isDeleted == false)
        #expect(try spent() == -8_500, "counted once, as the bill")
    }

    // Scenario REPEAT-14
    /// The bank's date wins, across a month's end too. December reads light and
    /// January carries the line, and the total for the year doesn't move.
    @Test func aLineInTheNextMonthStillTakesTheBillsPlace() throws {
        let january3 = AppLocale.calendar.date(from: DateComponents(year: 2027, month: 1, day: 3, hour: 12))!
        model.today = { january3 }
        model.addRepeatingTransaction(merchant: "Phone bill", amount: Money(minorUnits: 8_500), date: Self.day(11, 30),
                                      note: "", budget: budget)
        model.reload()
        let bill = try #require(try bills().first { $0.repeatMonth == "2026-12" })
        let total = { [self] in
            try model.store.transactions(in: budget, period: nil).filter { !$0.isDeleted }
                .reduce(0) { $0 + $1.amount.minorUnits }
        }
        let before = try total()

        try statement("01/02/2027,\"VERIZON WIRELESS\",-85.00")
        #expect(screen.rows.first?.status == "Replaces December's Phone bill, $85.00")
        screen.commit()
        model.reload()

        #expect(try model.store.transaction(bill.id)?.isDeleted != false)
        #expect(try total() == before, "the year's total is unchanged")
        let line = try #require(try model.store.transactions(in: budget, period: nil).first { $0.source == .statement })
        #expect(AppLocale.calendar.component(.month, from: line.date) == 1, "the bank's date")
    }

    /// Two made bills fit one line: the one closest to the line's date takes
    /// it. The phone bill is made on the 14th and the cable bill on the 12th.
    @Test(arguments: [("12/15/2026", "Phone bill"), ("12/12/2026", "Cable")])
    func ifTwoFitTheClosestDateWins(date: String, winner: String) throws {
        _ = try aPhoneBill()
        model.addRepeatingTransaction(merchant: "Cable", amount: Money(minorUnits: 8_600), date: Self.day(11, 12),
                                      note: "", budget: budget, link: nil)
        model.reload()
        let made = try model.store.transactions(in: budget, period: nil).filter { $0.repeatMonth == "2026-12" }
        #expect(Set(made.map(\.merchant)) == ["Phone bill", "Cable"], "both December bills are made")

        try statement("\(date),\"ACME\",-85.50")
        let decision = try #require(model.pendingImport?.proposals.first?.decision)
        guard case .replacesMade(let id) = decision else {
            Issue.record("the line replaces no bill: \(decision)")
            return
        }
        #expect(try model.store.transaction(id)?.merchant == winner)
    }

    /// A made bill in another group is never this line's bill, though its
    /// amount and date fit.
    @Test func aBillInAnotherGroupDoesNotMatch() throws {
        let cabin = try #require(model.addGroup(named: "Cabin"))
        let cabinPhone = try #require(model.addBudget(named: "Cabin utilities", limit: Money(minorUnits: 60_000),
                                                      in: cabin, select: false))
        model.addRepeatingTransaction(merchant: "Phone bill", amount: Money(minorUnits: 8_500), date: Self.day(11, 14),
                                      note: "", budget: cabinPhone, link: nil)
        model.selectedBudget = budget
        model.reload()
        #expect(try model.store.transactions(in: cabinPhone, period: nil).contains { $0.repeatMonth == "2026-12" },
                "the cabin's December bill is made")

        try statement("12/15/2026,\"ACME\",-85.00")
        let decisions = try #require(model.pendingImport?.proposals.map(\.decision))
        #expect(!decisions.contains { if case .replacesMade = $0 { true } else { false } },
                "a line in Home replaced the cabin's bill: \(decisions)")
    }

    @Test func twoLinesDoNotClaimOneBill() throws {
        _ = try aPhoneBill()
        try statement("12/15/2026,\"ACME\",-85.00\n12/16/2026,\"ACME TWO\",-85.00")
        let decisions = try #require(model.pendingImport?.proposals.map(\.decision))
        let replaced = decisions.filter { if case .replacesMade = $0 { true } else { false } }
        #expect(replaced.count == 1)
    }
}
