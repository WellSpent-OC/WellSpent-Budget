import Foundation
import Crypto
import WellSpentCrypto
import WellSpentModel

/// What the app proposes to do with one statement line.
public enum ImportDecision: Equatable, Sendable {
    /// Already imported. The same row, recognised by fingerprint.
    case alreadyImported
    /// Lines up with a receipt that is already filed.
    case matchesReceipt(RecordID)
    /// Lines up with a transaction entered by hand.
    case matchesTransaction(RecordID)
    /// Takes the place of a bill a repeat made, so it counts once. The person
    /// can say no before importing.
    case replacesMade(RecordID)
    /// New, and a rule or an earlier row says which budget it belongs in.
    case add(BudgetID)
    /// New, and nothing suggests a budget. A person has to pick.
    case needsBudget
}

public struct ImportProposal: Equatable, Sendable {
    public let line: StatementLine
    public let decision: ImportDecision
    public let fingerprint: String

    public init(line: StatementLine, decision: ImportDecision, fingerprint: String) {
        self.line = line
        self.decision = decision
        self.fingerprint = fingerprint
    }

    public var isActionable: Bool {
        switch decision {
        case .alreadyImported: return false
        default: return true
        }
    }
}

public struct ImportSummary: Equatable, Sendable {
    public var alreadyImported = 0
    public var matched = 0
    public var toAdd = 0
    public var needBudget = 0

    public init() {}
}

/// Decides what happens to each line, without writing anything.
///
/// All of this runs on the device, against the local copy of the budget. The
/// server is never asked, and never learns a merchant name or an amount.
public struct StatementMatcher: Sendable {
    /// How far apart a receipt and a statement line can be and still be the same
    /// purchase. Card transactions commonly post a day or two after the swipe.
    public static let dateTolerance: TimeInterval = 4 * 86_400

    public struct Context: Sendable {
        public let budgetKey: SymmetricKey
        public let existingFingerprints: Set<String>
        public let receipts: [Receipt]
        public let recentTransactions: [Transaction]
        /// Merchant, lowercased, to the budget it went in last time.
        public let merchantRules: [String: BudgetID]
        public let defaultBudget: BudgetID?
        /// Whether this person may delete a bill, which replacing it does.
        public let mayReplace: @Sendable (Transaction) -> Bool

        public init(budgetKey: SymmetricKey, existingFingerprints: Set<String>,
                    receipts: [Receipt], recentTransactions: [Transaction],
                    merchantRules: [String: BudgetID], defaultBudget: BudgetID? = nil,
                    mayReplace: @escaping @Sendable (Transaction) -> Bool = { _ in true }) {
            self.mayReplace = mayReplace
            self.budgetKey = budgetKey
            self.existingFingerprints = existingFingerprints
            self.receipts = receipts
            self.recentTransactions = recentTransactions
            self.merchantRules = merchantRules
            self.defaultBudget = defaultBudget
        }
    }

    public init() {}

    public func propose(_ lines: [StatementLine], context: Context) -> [ImportProposal] {
        var claimedReceipts = Set<RecordID>()
        var claimedTransactions = Set<RecordID>()

        return lines.map { line in
            let fingerprint = line.fingerprint(budgetKey: context.budgetKey)

            if context.existingFingerprints.contains(fingerprint) {
                return ImportProposal(line: line, decision: .alreadyImported, fingerprint: fingerprint)
            }

            // A receipt is the strongest match: the person kept the paper, so the
            // amount came off the till rather than out of a bank's description.
            if let receipt = bestReceipt(for: line, in: context, excluding: claimedReceipts) {
                claimedReceipts.insert(receipt.id)
                return ImportProposal(line: line, decision: .matchesReceipt(receipt.id),
                                      fingerprint: fingerprint)
            }

            // Then a bill a repeat made. The bank's line takes its place, so the
            // real date and amount win and the bill counts once.
            if let bill = bestMadeBill(for: line, in: context, excluding: claimedTransactions) {
                claimedTransactions.insert(bill.id)
                // Someone who may not delete the bill can't replace it. The line
                // is still that bill, so it's skipped and the money counts once.
                let decision: ImportDecision = context.mayReplace(bill)
                    ? .replacesMade(bill.id) : .matchesTransaction(bill.id)
                return ImportProposal(line: line, decision: decision, fingerprint: fingerprint)
            }

            // Then a transaction someone typed in before the statement arrived.
            if let transaction = bestTransaction(for: line, in: context, excluding: claimedTransactions) {
                claimedTransactions.insert(transaction.id)
                return ImportProposal(line: line, decision: .matchesTransaction(transaction.id),
                                      fingerprint: fingerprint)
            }

            let merchant = line.cleanedDescription.lowercased()
            if let budget = context.merchantRules[merchant] {
                return ImportProposal(line: line, decision: .add(budget), fingerprint: fingerprint)
            }
            // A looser pass, so "Hilltop Grocery" still finds a rule for "Hilltop".
            if let match = context.merchantRules.first(where: {
                merchant.contains($0.key) || $0.key.contains(merchant)
            }) {
                return ImportProposal(line: line, decision: .add(match.value), fingerprint: fingerprint)
            }
            if let fallback = context.defaultBudget {
                return ImportProposal(line: line, decision: .add(fallback), fingerprint: fingerprint)
            }
            return ImportProposal(line: line, decision: .needsBudget, fingerprint: fingerprint)
        }
    }

    public func summarise(_ proposals: [ImportProposal]) -> ImportSummary {
        var summary = ImportSummary()
        for proposal in proposals {
            switch proposal.decision {
            case .alreadyImported: summary.alreadyImported += 1
            case .matchesReceipt, .matchesTransaction, .replacesMade: summary.matched += 1
            case .add: summary.toAdd += 1
            case .needsBudget: summary.needBudget += 1
            }
        }
        return summary
    }

    // MARK: - Matching

    /// Exact amount, and a date close enough to allow for posting delay.
    ///
    /// Amount is required to be exact on purpose. A fuzzy amount match on money is
    /// how a budgeting app quietly attaches the wrong receipt to the wrong charge,
    /// and the person has no way to notice.
    private func bestReceipt(for line: StatementLine, in context: Context,
                             excluding claimed: Set<RecordID>) -> Receipt? {
        context.receipts
            .filter { receipt in
                guard !claimed.contains(receipt.id), receipt.transactionID == nil else { return false }
                guard let total = receipt.total.flatMap({ parseMoney($0.value, line.amount.currency) })
                else { return false }
                guard total.magnitude == line.amount.magnitude else { return false }
                return abs(receipt.capturedAt.timeIntervalSince(line.date)) <= Self.dateTolerance
            }
            .min { abs($0.capturedAt.timeIntervalSince(line.date)) < abs($1.capturedAt.timeIntervalSince(line.date)) }
    }

    private func bestTransaction(for line: StatementLine, in context: Context,
                                 excluding claimed: Set<RecordID>) -> Transaction? {
        context.recentTransactions
            .filter { transaction in
                guard !claimed.contains(transaction.id), !transaction.isDeleted else { return false }
                // Only hand-entered rows, so an imported row never matches another
                // imported row and quietly merges two real purchases.
                guard transaction.source == .manual, transaction.repeatRuleID == nil else { return false }
                guard transaction.amount.magnitude == line.amount.magnitude else { return false }
                return abs(transaction.date.timeIntervalSince(line.date)) <= Self.dateTolerance
            }
            .min { abs($0.date.timeIntervalSince(line.date)) < abs($1.date.timeIntervalSince(line.date)) }
    }

    /// A bill's amount can differ from the bank's: a phone bill with tax. So,
    /// unlike a receipt, it's close and not exact: within 10 percent or $5,
    /// whichever is larger.
    private func bestMadeBill(for line: StatementLine, in context: Context,
                              excluding claimed: Set<RecordID>) -> Transaction? {
        guard line.amount.minorUnits < 0 else { return nil }
        let ruled = context.merchantRules[line.cleanedDescription.lowercased()]
        return context.recentTransactions
            .filter { bill in
                guard bill.repeatRuleID != nil, !bill.isDeleted, !claimed.contains(bill.id),
                      bill.amount.currency == line.amount.currency, bill.amount.minorUnits < 0 else { return false }
                // The merchant's usual budget, when it has one, has to be the bill's.
                // A made bill's own name doesn't count: it would always agree.
                if let ruled, ruled != bill.budgetID { return false }
                let gap = abs(bill.amount.minorUnits - line.amount.minorUnits)
                guard gap <= max(abs(bill.amount.minorUnits) / 10, 500) else { return false }
                return abs(bill.date.timeIntervalSince(line.date)) <= Self.dateTolerance
            }
            .min { abs($0.date.timeIntervalSince(line.date)) < abs($1.date.timeIntervalSince(line.date)) }
    }

    private func parseMoney(_ text: String, _ currency: Currency) -> Money? {
        StatementParser.parseAmount(text, currency: currency)
    }
}

public extension StatementMatcher {
    /// Learns from what is already filed: which budget a merchant usually lands in.
    static func merchantRules(from transactions: [Transaction]) -> [String: BudgetID] {
        var counts: [String: [BudgetID: Int]] = [:]
        for transaction in transactions where !transaction.isDeleted {
            let key = transaction.merchant.lowercased().trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty else { continue }
            counts[key, default: [:]][transaction.budgetID, default: 0] += 1
        }
        return counts.compactMapValues { $0.max(by: { $0.value < $1.value })?.key }
    }
}
