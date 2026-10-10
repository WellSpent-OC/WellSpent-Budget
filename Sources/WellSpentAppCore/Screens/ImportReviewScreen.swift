import Foundation
import WellSpentCrypto
import WellSpentImport
import WellSpentModel

/// The review before a bank statement goes in, on any desktop: what each line
/// will do, a budget for the lines that need one, and Import or Cancel. The
/// statement is read on this computer; nothing is sent until Import. What it
/// says lives here; the Mac and Linux screens only draw it.
@MainActor
public struct ImportReviewScreen {
    /// What a line will do, for its colour.
    public enum Tone: Equatable, Sendable {
        case matched, toAdd, alreadyImported, needsBudget
    }

    /// One count across the top.
    public struct Tile: Identifiable, Equatable, Sendable {
        public let label: String
        public let count: Int
        public let tone: Tone
        public var id: String { label }
    }

    /// One line of the statement.
    public struct Row: Identifiable, Equatable, Sendable {
        /// Its place in the statement, which is how a chosen budget is kept.
        public let id: Int
        public let date: Date
        public let description: String
        /// The line as the bank wrote it.
        public let bankDescription: String
        public let amount: String
        public let status: String
        public let tone: Tone
        /// Faded: it will not be added.
        public let isActionable: Bool
        public let needsBudget: Bool
        public let chosenBudget: BudgetID?
    }

    private let model: AppModel

    public init(model: AppModel) { self.model = model }

    /// Whether there is a statement to review.
    public var isOpen: Bool { model.pendingImport != nil }
    public var title: String { Words.title }
    public var filename: String { model.pendingImport?.filename ?? "" }
    public var note: String { SyncWording.importNote }

    public var tiles: [Tile] {
        guard let summary = model.pendingImport?.summary else { return [] }
        return [Tile(label: Words.matched, count: summary.matched, tone: .matched),
                Tile(label: Words.toAdd, count: summary.toAdd, tone: .toAdd),
                Tile(label: Words.alreadyImported, count: summary.alreadyImported, tone: .alreadyImported),
                Tile(label: Words.needsBudget, count: summary.needBudget, tone: .needsBudget)]
    }

    public var rows: [Row] {
        guard let pending = model.pendingImport else { return [] }
        return pending.proposals.enumerated().map { index, proposal in
            let (status, tone) = Self.status(of: proposal.decision)
            let needsBudget = if case .needsBudget = proposal.decision { true } else { false }
            return Row(id: index, date: proposal.line.date, description: proposal.line.cleanedDescription,
                       bankDescription: proposal.line.rawDescription, amount: proposal.line.amount.display,
                       status: status, tone: tone, isActionable: proposal.isActionable,
                       needsBudget: needsBudget, chosenBudget: pending.chosenBudgets[index])
        }
    }

    /// The budgets a line may be filed in: those of the group the statement
    /// goes into. A line filed in another group's budget is not in this group.
    public var budgetChoices: [Budget] {
        model.groups.first.flatMap { model.summaries[$0.id] }?.map(\.budget) ?? []
    }

    /// Files a line that needs a budget; nil takes the choice back.
    public func choose(_ budget: BudgetID?, for row: Int) {
        model.pendingImport?.chosenBudgets[row] = budget
    }

    public func commit() { model.commitImport() }
    public func cancel() { model.cancelImport() }

    static func status(of decision: ImportDecision) -> (String, Tone) {
        switch decision {
        case .alreadyImported: (Words.alreadyImported, .alreadyImported)
        case .matchesReceipt: (Words.matchedReceipt, .matched)
        case .matchesTransaction: (Words.matchedEntry, .matched)
        case .add: (Words.willBeAdded, .toAdd)
        case .needsBudget: (Words.needsBudget, .needsBudget)
        }
    }

    public enum Words {
        public static let title = "Import a statement"
        public static let matched = "Matched"
        public static let toAdd = "To add"
        public static let alreadyImported = "Already imported"
        public static let needsBudget = "Needs a budget"
        public static let matchedReceipt = "Matched to receipt"
        public static let matchedEntry = "Matched to entry"
        public static let willBeAdded = "Will be added"
        public static let choose = "Choose"
        public static let importButton = "Import"
        public static let cancel = "Cancel"
    }
}
