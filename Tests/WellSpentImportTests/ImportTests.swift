import Testing
import Foundation
import Crypto
@testable import WellSpentImport
import WellSpentCrypto
import WellSpentModel

private func day(_ year: Int, _ month: Int, _ dayOfMonth: Int) -> Date {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
    var components = DateComponents()
    components.year = year; components.month = month; components.day = dayOfMonth; components.hour = 12
    return calendar.date(from: components)!
}

@Suite("Amount parsing")
struct AmountTests {
    @Test func theShapesBanksActuallyUse() {
        #expect(StatementParser.parseAmount("142.08", currency: .usd) == Money(minorUnits: 14208))
        #expect(StatementParser.parseAmount("-142.08", currency: .usd) == Money(minorUnits: -14208))
        #expect(StatementParser.parseAmount("$1,234.56", currency: .usd) == Money(minorUnits: 123456))
        #expect(StatementParser.parseAmount("(25.00)", currency: .usd) == Money(minorUnits: -2500))
        #expect(StatementParser.parseAmount("+9.99", currency: .usd) == Money(minorUnits: 999))
        #expect(StatementParser.parseAmount("", currency: .usd) == nil)
        #expect(StatementParser.parseAmount("n/a", currency: .usd) == nil)
    }

    /// Parsed through cents rather than held as a Double, so nothing drifts.
    @Test func awkwardValuesStayExact() {
        #expect(StatementParser.parseAmount("0.10", currency: .usd)?.minorUnits == 10)
        #expect(StatementParser.parseAmount("1.15", currency: .usd)?.minorUnits == 115)
        #expect(StatementParser.parseAmount("29.97", currency: .usd)?.minorUnits == 2997)
    }
}

@Suite("Date parsing")
struct DateParsingTests {
    @Test func isoAndUSOrders() {
        let calendar = Calendar(identifier: .gregorian)
        let iso = try! #require(StatementParser.parseCSVDate("2026-09-22"))
        #expect(calendar.dateComponents(in: .gmt, from: iso).month == 9)
        #expect(calendar.dateComponents(in: .gmt, from: iso).day == 22)

        let us = try! #require(StatementParser.parseCSVDate("09/22/2026"))
        #expect(calendar.dateComponents(in: .gmt, from: us).month == 9)
        #expect(calendar.dateComponents(in: .gmt, from: us).day == 22)

        let short = try! #require(StatementParser.parseCSVDate("9/5/26"))
        #expect(calendar.dateComponents(in: .gmt, from: short).year == 2026)
    }

    /// A day above 12 settles the ambiguity on its own.
    @Test func aDayAboveTwelveDisambiguates() {
        let calendar = Calendar(identifier: .gregorian)
        let parsed = try! #require(StatementParser.parseCSVDate("22/09/2026"))
        #expect(calendar.dateComponents(in: .gmt, from: parsed).day == 22)
        #expect(calendar.dateComponents(in: .gmt, from: parsed).month == 9)
    }

    @Test func ofxTimestamps() {
        let calendar = Calendar(identifier: .gregorian)
        let full = try! #require(StatementParser.parseOFXDate("20260922120000.000[-7:MST]"))
        #expect(calendar.dateComponents(in: .gmt, from: full).day == 22)

        let short = try! #require(StatementParser.parseOFXDate("20260922"))
        #expect(calendar.dateComponents(in: .gmt, from: short).day == 22)
        #expect(StatementParser.parseOFXDate("2026") == nil)
    }
}

@Suite("CSV statements")
struct CSVTests {
    @Test func signedAmountColumn() throws {
        let csv = """
        Date,Description,Amount
        09/22/2026,"HILLTOP #17 SPRING HILL OH",-142.08
        09/21/2026,"COSTCO WHSE #0472",-286.31
        09/20/2026,"PAYROLL DEPOSIT",2500.00
        """
        let lines = try StatementParser.parseCSV(csv)
        #expect(lines.count == 3)
        #expect(lines[0].amount == Money(minorUnits: -14208))
        #expect(lines[2].amount == Money(minorUnits: 250_000))
    }

    /// Descriptions contain commas constantly, so quoted fields have to work.
    @Test func quotedFieldsWithCommas() throws {
        let csv = """
        Date,Description,Amount
        09/22/2026,"SMITH, JOHN PLUMBING, LLC",-450.00
        """
        let lines = try StatementParser.parseCSV(csv)
        #expect(lines.count == 1)
        #expect(lines[0].rawDescription == "SMITH, JOHN PLUMBING, LLC")
    }

    @Test func escapedQuotesInsideAField() throws {
        let csv = """
        Date,Description,Amount
        09/22/2026,"THE ""GOOD"" DINER",-42.00
        """
        let lines = try StatementParser.parseCSV(csv)
        #expect(lines[0].rawDescription == "THE \"GOOD\" DINER")
    }

    /// Plenty of banks split money out and money in into two columns.
    @Test func separateDebitAndCreditColumns() throws {
        let csv = """
        Posting Date,Payee,Debit,Credit
        09/22/2026,HILLTOP,142.08,
        09/20/2026,PAYROLL,,2500.00
        """
        let lines = try StatementParser.parseCSV(csv)
        #expect(lines.count == 2)
        #expect(lines[0].amount == Money(minorUnits: -14208), "a debit is money going out")
        #expect(lines[1].amount == Money(minorUnits: 250_000))
    }

    @Test func headerNamesVaryByBank() throws {
        let csv = """
        Transaction Date,Merchant Name,Amount
        2026-09-22,HILLTOP,-10.00
        """
        #expect(try StatementParser.parseCSV(csv).count == 1)
    }

    @Test func aFileWithNoAmountColumnIsRefusedClearly() {
        let csv = "Date,Description\n09/22/2026,HILLTOP"
        #expect(throws: ImportError.malformedRow(line: 1, reason: "no amount column")) {
            try StatementParser.parseCSV(csv)
        }
    }

    @Test func blankAndZeroRowsAreSkipped() throws {
        let csv = """
        Date,Description,Amount
        09/22/2026,HILLTOP,-10.00

        09/23/2026,NOTHING,0.00
        """
        #expect(try StatementParser.parseCSV(csv).count == 1)
    }
}

@Suite("OFX statements")
struct OFXTests {
    private let sample = """
    OFXHEADER:100
    <OFX><BANKMSGSRSV1><STMTTRNRS><STMTRS><BANKTRANLIST>
    <STMTTRN>
    <TRNTYPE>DEBIT
    <DTPOSTED>20260922120000.000[-7:MST]
    <TRNAMT>-142.08
    <FITID>202609220001
    <NAME>HILLTOP #17
    <MEMO>SPRING HILL OH
    </STMTTRN>
    <STMTTRN>
    <TRNTYPE>CREDIT
    <DTPOSTED>20260920
    <TRNAMT>2500.00
    <FITID>202609200007
    <NAME>PAYROLL
    </STMTTRN>
    </BANKTRANLIST></STMTRS></STMTTRNRS></BANKMSGSRSV1></OFX>
    """

    @Test func parsesTransactions() throws {
        let lines = try StatementParser.parseOFX(sample)
        #expect(lines.count == 2)
        #expect(lines[0].amount == Money(minorUnits: -14208))
        #expect(lines[0].bankReference == "202609220001")
        #expect(lines[0].rawDescription.contains("HILLTOP"))
        #expect(lines[1].amount == Money(minorUnits: 250_000))
    }

    /// OFX is SGML and banks close tags inconsistently, so this must not be
    /// handed to an XML parser.
    @Test func unclosedTagsAreTolerated() throws {
        let ragged = """
        <STMTTRN>
        <DTPOSTED>20260922
        <TRNAMT>-10.00
        <NAME>CORNER SHOP
        </STMTTRN>
        """
        let lines = try StatementParser.parseOFX(ragged)
        #expect(lines.count == 1)
        #expect(lines[0].rawDescription == "CORNER SHOP")
    }

    @Test func formatDetection() {
        #expect(StatementParser.detectFormat(filename: "sep.qfx", contents: "") == .ofx)
        #expect(StatementParser.detectFormat(filename: "sep.OFX", contents: "") == .ofx)
        #expect(StatementParser.detectFormat(filename: "sep.csv", contents: "") == .csv)
        #expect(StatementParser.detectFormat(filename: "download", contents: sample) == .ofx)
        #expect(StatementParser.detectFormat(filename: "x", contents: "nothing useful") == nil)
    }
}

@Suite("Merchant names")
struct CleaningTests {
    private func clean(_ raw: String) -> String {
        StatementLine(date: Date(), rawDescription: raw, amount: Money(minorUnits: -1)).cleanedDescription
    }

    @Test func stripsTheNoiseBanksAdd() {
        #expect(clean("HILLTOP #17 SPRING HILL OH") == "Hilltop Spring Hill")
        #expect(clean("COSTCO WHSE #0472") == "Costco Whse")
        #expect(clean("SQ *TLB COFFEE") == "Tlb Coffee")
        #expect(clean("7 ELEVEN 22134") == "7 Eleven", "a short number is part of the name")
        #expect(clean("THE HOME DEPOT 0000") == "The Home Depot")
    }

    /// Acronyms get title-cased too. Distinguishing `USPS` from `THE` needs a
    /// dictionary, and `Usps Retail` is a much smaller problem than
    /// `THE Home Depot`. The raw text is kept either way.
    @Test func acronymsAreTitleCasedAndThatIsFine() {
        #expect(clean("USPS RETAIL") == "Usps Retail")
    }

    /// Cleaning must never end up with nothing.
    @Test func neverReturnsEmpty() {
        #expect(!clean("#12345").isEmpty)
        #expect(!clean("OH").isEmpty)
    }
}

@Suite("Row fingerprints")
struct FingerprintTests {
    private let key = SymmetricKey(size: .bits256)

    @Test func stableForTheSameRow() {
        let line = StatementLine(date: day(2026, 9, 22), rawDescription: "HILLTOP",
                                 amount: Money(minorUnits: -14208))
        #expect(line.fingerprint(budgetKey: key) == line.fingerprint(budgetKey: key))
    }

    /// The time of day moves between a bank's two exports of the same row.
    @Test func ignoresTheTimeOfDay() {
        let morning = StatementLine(date: day(2026, 9, 22), rawDescription: "HILLTOP",
                                    amount: Money(minorUnits: -14208))
        let evening = StatementLine(date: day(2026, 9, 22).addingTimeInterval(8 * 3600),
                                    rawDescription: "HILLTOP", amount: Money(minorUnits: -14208))
        #expect(morning.fingerprint(budgetKey: key) == evening.fingerprint(budgetKey: key))
    }

    @Test func differsWhenTheAmountOrDayDiffers() {
        let base = StatementLine(date: day(2026, 9, 22), rawDescription: "HILLTOP",
                                 amount: Money(minorUnits: -14208))
        let otherAmount = StatementLine(date: day(2026, 9, 22), rawDescription: "HILLTOP",
                                        amount: Money(minorUnits: -14209))
        let otherDay = StatementLine(date: day(2026, 9, 23), rawDescription: "HILLTOP",
                                     amount: Money(minorUnits: -14208))
        #expect(base.fingerprint(budgetKey: key) != otherAmount.fingerprint(budgetKey: key))
        #expect(base.fingerprint(budgetKey: key) != otherDay.fingerprint(budgetKey: key))
    }

    /// Keyed, so whoever steals the server database cannot use fingerprints to
    /// work out that two customers shopped at the same place.
    @Test func differsBetweenBudgets() {
        let line = StatementLine(date: day(2026, 9, 22), rawDescription: "HILLTOP",
                                 amount: Money(minorUnits: -14208))
        #expect(line.fingerprint(budgetKey: key) != line.fingerprint(budgetKey: SymmetricKey(size: .bits256)))
    }

    /// When the bank gives its own id, use it: it survives a description change.
    @Test func bankReferenceWins() {
        let first = StatementLine(date: day(2026, 9, 22), rawDescription: "HILLTOP",
                                  amount: Money(minorUnits: -14208), bankReference: "ABC123")
        let renamed = StatementLine(date: day(2026, 9, 24), rawDescription: "HILLTOP GROCERY",
                                    amount: Money(minorUnits: -14208), bankReference: "ABC123")
        #expect(first.fingerprint(budgetKey: key) == renamed.fingerprint(budgetKey: key))
    }
}

@Suite("Matching")
struct MatcherTests {
    private let key = SymmetricKey(size: .bits256)
    private let groupID = GroupID()
    private let groceries = BudgetID()
    private let fuel = BudgetID()

    private func context(receipts: [Receipt] = [], transactions: [Transaction] = [],
                         rules: [String: BudgetID] = [:], fingerprints: Set<String> = [],
                         fallback: BudgetID? = nil) -> StatementMatcher.Context {
        StatementMatcher.Context(budgetKey: key, existingFingerprints: fingerprints,
                                 receipts: receipts, recentTransactions: transactions,
                                 merchantRules: rules, defaultBudget: fallback)
    }

    @Test func aRowAlreadyImportedIsSkipped() {
        let line = StatementLine(date: day(2026, 9, 22), rawDescription: "HILLTOP",
                                 amount: Money(minorUnits: -14208))
        let seen = Set([line.fingerprint(budgetKey: key)])
        let proposals = StatementMatcher().propose([line], context: context(fingerprints: seen))
        #expect(proposals[0].decision == .alreadyImported)
        #expect(!proposals[0].isActionable)
    }

    @Test func aReceiptWithTheSameTotalAndNearbyDateMatches() {
        let receipt = Receipt(groupID: groupID, filename: "s.jpg", byteCount: 1,
                              plaintextSHA256: Data(repeating: 1, count: 32),
                              capturedAt: day(2026, 9, 21),
                              total: ExtractedField(value: "142.08", confidence: 0.99))
        let line = StatementLine(date: day(2026, 9, 22), rawDescription: "HILLTOP",
                                 amount: Money(minorUnits: -14208))
        let proposals = StatementMatcher().propose([line], context: context(receipts: [receipt]))
        #expect(proposals[0].decision == .matchesReceipt(receipt.id))
    }

    /// Amounts must agree exactly. Fuzzy money is how the wrong receipt gets
    /// attached to the wrong charge with nobody noticing.
    @Test func aCloseButDifferentAmountDoesNotMatch() {
        let receipt = Receipt(groupID: groupID, filename: "s.jpg", byteCount: 1,
                              plaintextSHA256: Data(repeating: 1, count: 32),
                              capturedAt: day(2026, 9, 21),
                              total: ExtractedField(value: "142.09", confidence: 0.99))
        let line = StatementLine(date: day(2026, 9, 22), rawDescription: "HILLTOP",
                                 amount: Money(minorUnits: -14208))
        let proposals = StatementMatcher().propose([line], context: context(receipts: [receipt]))
        #expect(proposals[0].decision == .needsBudget)
    }

    @Test func aReceiptTooLongAgoDoesNotMatch() {
        let receipt = Receipt(groupID: groupID, filename: "s.jpg", byteCount: 1,
                              plaintextSHA256: Data(repeating: 1, count: 32),
                              capturedAt: day(2026, 9, 1),
                              total: ExtractedField(value: "142.08", confidence: 0.99))
        let line = StatementLine(date: day(2026, 9, 22), rawDescription: "HILLTOP",
                                 amount: Money(minorUnits: -14208))
        let proposals = StatementMatcher().propose([line], context: context(receipts: [receipt]))
        #expect(proposals[0].decision == .needsBudget)
    }

    /// Two identical charges on one statement must claim two different receipts.
    @Test func oneReceiptIsNotUsedTwice() {
        let makeReceipt = { Receipt(groupID: self.groupID, filename: "s.jpg", byteCount: 1,
                                    plaintextSHA256: Data(repeating: 1, count: 32),
                                    capturedAt: day(2026, 9, 21),
                                    total: ExtractedField(value: "20.00", confidence: 0.99)) }
        let receipts = [makeReceipt(), makeReceipt()]
        let line = { StatementLine(date: day(2026, 9, 22), rawDescription: "COFFEE",
                                   amount: Money(minorUnits: -2000)) }

        let proposals = StatementMatcher().propose([line(), line()],
                                                   context: context(receipts: receipts))
        let matched = proposals.compactMap { proposal -> RecordID? in
            if case .matchesReceipt(let id) = proposal.decision { return id }
            return nil
        }
        #expect(matched.count == 2)
        #expect(Set(matched).count == 2, "the same receipt must not match twice")
    }

    @Test func aHandEnteredTransactionMatches() {
        let transaction = Transaction(budgetID: groceries, groupID: groupID, date: day(2026, 9, 21),
                                      merchant: "Hilltop", amount: Money(minorUnits: -14208),
                                      source: .manual)
        let line = StatementLine(date: day(2026, 9, 22), rawDescription: "HILLTOP",
                                 amount: Money(minorUnits: -14208))
        let proposals = StatementMatcher().propose([line], context: context(transactions: [transaction]))
        #expect(proposals[0].decision == .matchesTransaction(transaction.id))
    }

    /// An imported row must never match another imported row, or two real
    /// purchases quietly become one.
    @Test func anImportedTransactionIsNotMatchedAgain() {
        let transaction = Transaction(budgetID: groceries, groupID: groupID, date: day(2026, 9, 21),
                                      merchant: "Hilltop", amount: Money(minorUnits: -14208),
                                      source: .statement)
        let line = StatementLine(date: day(2026, 9, 22), rawDescription: "HILLTOP",
                                 amount: Money(minorUnits: -14208))
        let proposals = StatementMatcher().propose([line], context: context(transactions: [transaction]))
        #expect(proposals[0].decision == .needsBudget)
    }

    @Test func aLearnedMerchantRulePicksTheBudget() {
        let line = StatementLine(date: day(2026, 9, 22), rawDescription: "HILLTOP #17 SPRING HILL OH",
                                 amount: Money(minorUnits: -14208))
        let proposals = StatementMatcher().propose(
            [line], context: context(rules: ["hilltop spring hill": groceries]))
        #expect(proposals[0].decision == .add(groceries))
    }

    @Test func rulesAreLearnedFromWhatIsAlreadyFiled() {
        let filed = [
            Transaction(budgetID: groceries, groupID: groupID, date: Date(), merchant: "Hilltop",
                        amount: Money(minorUnits: -1)),
            Transaction(budgetID: groceries, groupID: groupID, date: Date(), merchant: "Hilltop",
                        amount: Money(minorUnits: -1)),
            Transaction(budgetID: fuel, groupID: groupID, date: Date(), merchant: "Hilltop",
                        amount: Money(minorUnits: -1)),
            Transaction(budgetID: fuel, groupID: groupID, date: Date(), merchant: "Chevron",
                        amount: Money(minorUnits: -1)),
        ]
        let rules = StatementMatcher.merchantRules(from: filed)
        #expect(rules["hilltop"] == groceries, "the most common budget wins")
        #expect(rules["chevron"] == fuel)
    }

    @Test func summaryCountsEachOutcome() {
        let seen = StatementLine(date: day(2026, 9, 1), rawDescription: "OLD",
                                 amount: Money(minorUnits: -100))
        let lines = [
            seen,
            StatementLine(date: day(2026, 9, 22), rawDescription: "HILLTOP",
                          amount: Money(minorUnits: -14208)),
            StatementLine(date: day(2026, 9, 23), rawDescription: "MYSTERY",
                          amount: Money(minorUnits: -500)),
        ]
        let proposals = StatementMatcher().propose(lines, context: context(
            rules: ["hilltop": groceries],
            fingerprints: [seen.fingerprint(budgetKey: key)]))

        let summary = StatementMatcher().summarise(proposals)
        #expect(summary.alreadyImported == 1)
        #expect(summary.toAdd == 1)
        #expect(summary.needBudget == 1)
    }
}
