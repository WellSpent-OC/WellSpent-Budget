import Testing
import Foundation
import WellSpentCrypto
import WellSpentModel

/// What an entry's kind means, and how a record body carries it.
@Suite("Entry kind")
struct EntryKindTests {
    @Test func theKindAnOldRowImpliedComesFromItsSign() {
        #expect(TransactionKind.inferred(from: Money(minorUnits: -1)) == .spending)
        #expect(TransactionKind.inferred(from: Money(minorUnits: 0)) == .spending)
        #expect(TransactionKind.inferred(from: Money(minorUnits: 1)) == .refund)
    }

    @Test func spendingAndRefundsCountAsSpentAndNothingElseDoes() {
        #expect(TransactionKind.allCases.filter(\.countsAsSpent) == [.spending, .refund])
    }

    @Test func moneyInKindsAreStoredPositive() {
        #expect(TransactionKind.allCases.filter(\.isMoneyIn) == [.refund, .income, .loanDraw, .savingsDraw])
        #expect(!TransactionKind.transfer.isMoneyIn, "a transfer is left as typed")
    }

    /// A body written before kinds existed has no "kind" key. It decodes with
    /// the kind its sign implied, so an older app's records keep their meaning.
    @Test func aBodyWithNoKindDecodesWithTheKindItsSignImplied() throws {
        for (cents, expected) in [(-4200, TransactionKind.spending), (2500, .refund)] {
            let old = Transaction(budgetID: BudgetID(), groupID: GroupID(), date: Date(timeIntervalSince1970: 1_760_000_000),
                                  merchant: "Hilltop", amount: Money(minorUnits: cents), kind: .income)
            var json = try JSONSerialization.jsonObject(with: RecordCodec.encoder.encode(old)) as! [String: Any]
            #expect(json["kind"] as? String == "income", "encoding always writes the kind")
            json.removeValue(forKey: "kind")
            let data = try JSONSerialization.data(withJSONObject: json)
            let decoded = try RecordCodec.decoder.decode(Transaction.self, from: data)
            #expect(decoded.kind == expected)
            #expect(decoded.amount == old.amount)
            #expect(decoded.id == old.id)
        }
    }

    /// A body with a kind keeps it through the record codec, and a second
    /// trip reads the same. (Bytes are not compared: the codec does not sort
    /// keys, and the sync layer compares through its own sorted encoder.)
    @Test func aBodyWithAKindRoundTripsExactly() throws {
        let entry = Transaction(budgetID: BudgetID(), groupID: GroupID(), date: Date(timeIntervalSince1970: 1_760_000_000),
                                merchant: "Airbnb", note: "payout", amount: Money(minorUnits: 131000), kind: .income,
                                source: .statement, importFingerprint: "abc", createdBy: UserID(),
                                createdAt: Date(timeIntervalSince1970: 1_760_000_100),
                                updatedAt: Date(timeIntervalSince1970: 1_760_000_200))
        let data = try RecordCodec.encoder.encode(entry)
        let back = try RecordCodec.decoder.decode(Transaction.self, from: data)
        #expect(back == entry)
        #expect(try RecordCodec.decoder.decode(Transaction.self, from: RecordCodec.encoder.encode(back)) == entry)
    }

    /// A group body from before has no "claimedBy" and decodes as unclaimed.
    @Test func aGroupBodyWithNoClaimDecodesUnclaimed() throws {
        let group = BudgetGroup(name: "Household", claimedBy: "wellspent.properties")
        var json = try JSONSerialization.jsonObject(with: RecordCodec.encoder.encode(group)) as! [String: Any]
        json.removeValue(forKey: "claimedBy")
        let back = try RecordCodec.decoder.decode(BudgetGroup.self, from: try JSONSerialization.data(withJSONObject: json))
        #expect(back.claimedBy == nil)
        #expect(back.name == "Household")
    }

    @Test func aSummaryWithOnlySpendingHasZeroMoneyIn() {
        let budget = Budget(groupID: GroupID(), name: "Groceries", limit: Money(minorUnits: 100_000))
        let period = BudgetPeriod(start: Date(timeIntervalSince1970: 0), end: Date(timeIntervalSince1970: 86_400))
        let summary = BudgetSummary(budget: budget, period: period, spent: Money(minorUnits: 4000), transactionCount: 1)
        #expect(summary.moneyIn == Money(minorUnits: 0))
        #expect(summary.borrowed == Money(minorUnits: 0))
        #expect(summary.fromSavings == Money(minorUnits: 0))
        #expect(summary.cashFlow == Money(minorUnits: -4000))
    }
}
