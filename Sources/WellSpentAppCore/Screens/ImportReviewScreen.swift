import Foundation
import WellSpentCrypto
import WellSpentImport
import WellSpentModel

/// The review before a bank statement goes in, on every app: what each line
/// will do, a budget for the lines that need one, and Import or Cancel. The
/// statement is read on this device, and nothing is sent until Import. What
/// it says lives here. The Mac, Linux and iPhone screens only draw it.
@MainActor
public struct ImportReviewScreen {
    /// What a line will do, for its colour. Each tone has its own words too,
    /// so colour is never the only sign.
    public enum Tone: Equatable, Sendable {
        case matched, toAdd, alreadyImported, needsBudget

        /// The same colour on the Mac and the iPhone.
        public var color: ColorPair {
            switch self {
            case .matched: PaletteValues.accent
            case .toAdd: PaletteValues.blue
            case .alreadyImported: PaletteValues.muted
            case .needsBudget: PaletteValues.warning
            }
        }
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
        /// It takes a budget chosen here, so it shows the picker, chosen yet
        /// or not.
        public let needsBudget: Bool
        public let chosenBudget: BudgetID?
        /// Money in. It shows the kind list, Income unless chosen otherwise
        /// (INC-02). Nil for money out.
        public let kind: TransactionKind?
        public var isMoneyIn: Bool { kind != nil }
        /// It replaces a repeat's bill, so it offers Keep both.
        public let offersKeepBoth: Bool
        public let isKeepingBoth: Bool

        /// The date and the cleaned-up name on one line, for a phone:
        /// "Oct 2 · Trader Joes".
        public var dateAndName: String { "\(BudgetScreen.shortDate(date)) · \(description)" }
    }

    private let model: AppModel

    public init(model: AppModel) { self.model = model }

    /// Whether there is a statement to review.
    public var isOpen: Bool { model.pendingImport != nil }
    /// Names the group, so the person sees where the statement goes.
    public var title: String { model.pendingImport.map { Words.title(into: $0.groupName) } ?? Words.title }
    public var filename: String { model.pendingImport?.filename ?? "" }
    public var note: String { SyncWording.importNote }

    /// The counts as they stand: a line given a budget here counts as To add,
    /// not Needs a budget, from the moment it is chosen.
    public var tiles: [Tile] {
        guard let pending = model.pendingImport else { return [] }
        let summary = pending.summary
        let chosen = pending.proposals.indices.filter { index in
            guard case .needsBudget = pending.proposals[index].decision else { return false }
            return pending.chosenBudgets[index] != nil
        }.count
        let kept = pending.keptBoth.count
        return [Tile(label: Words.matched, count: summary.matched - kept, tone: .matched),
                Tile(label: Words.toAdd, count: summary.toAdd + chosen + kept, tone: .toAdd),
                Tile(label: Words.alreadyImported, count: summary.alreadyImported, tone: .alreadyImported),
                Tile(label: Words.needsBudget, count: summary.needBudget - chosen, tone: .needsBudget)]
    }

    public var rows: [Row] {
        guard let pending = model.pendingImport else { return [] }
        return pending.proposals.enumerated().map { index, proposal in
            var (status, tone) = Self.status(of: proposal.decision)
            let needsBudget = if case .needsBudget = proposal.decision { true } else { false }
            // Given a budget here, it will be added. It keeps its picker, so
            // the choice can still change.
            if needsBudget, pending.chosenBudgets[index] != nil { (status, tone) = (Words.willBeAdded, .toAdd) }
            var offersKeepBoth = false
            if case .replacesMade(let id) = proposal.decision {
                offersKeepBoth = true
                status = pending.keptBoth.contains(index) ? Words.willBeAdded : Self.replacing(id, model: model)
                tone = pending.keptBoth.contains(index) ? .toAdd : .matched
            }
            return Row(id: index, date: proposal.line.date, description: proposal.line.cleanedDescription,
                       bankDescription: proposal.line.rawDescription,
                       amount: proposal.line.amount.display,
                       status: status, tone: tone, isActionable: proposal.isActionable,
                       needsBudget: needsBudget, chosenBudget: pending.chosenBudgets[index],
                       kind: pending.chosenKinds[index], offersKeepBoth: offersKeepBoth,
                       isKeepingBoth: pending.keptBoth.contains(index))
        }
    }

    /// The budgets a line may be filed in: those of the group the statement
    /// goes into. A line filed in another group's budget is not in this group.
    public var budgetChoices: [Budget] {
        model.pendingImport.flatMap { model.summaries[$0.groupID] }?.map(\.budget) ?? []
    }

    /// Files a line that needs a budget; nil takes the choice back.
    public func choose(_ budget: BudgetID?, for row: Int) {
        model.pendingImport?.chosenBudgets[row] = budget
    }

    /// What a money-in line may be, in the order the list shows them:
    /// Income and Refund first, the rest behind them.
    public static let kindChoices: [TransactionKind] = [.income, .refund, .loanDraw, .savingsDraw, .transfer]

    /// Names a kind in the list.
    public static func name(of kind: TransactionKind) -> String { EntryEditor.Words.name(of: kind) }

    /// Marks a money-in line as the kind chosen. A money-out line is left alone.
    public func choose(_ kind: TransactionKind, for row: Int) {
        guard model.pendingImport?.chosenKinds[row] != nil else { return }
        model.pendingImport?.chosenKinds[row] = kind
    }

    /// Keep both: the line is added as a new entry, and the bill stays as it is.
    public func keepBoth(_ keep: Bool, for row: Int) {
        guard let proposal = model.pendingImport?.proposals[row], case .replacesMade = proposal.decision else { return }
        if keep { model.pendingImport?.keptBoth.insert(row) } else { model.pendingImport?.keptBoth.remove(row) }
    }

    /// "Replaces December's Phone bill, $85.00".
    private static func replacing(_ id: RecordID, model: AppModel) -> String {
        guard let bill = try? model.store.transaction(id), let month = bill.repeatMonth else { return Words.matchedEntry }
        return Words.replaces(month: EntryEditor.Words.monthName(month), name: bill.merchant,
                              amount: BudgetScreen.amountText(bill.amount))
    }

    /// What the system's file picker gives back. The first file chosen is read
    /// and reviewed. Nothing chosen does nothing. A picker that failed says why
    /// on the window, and no review opens.
    public func open(_ picked: Result<[URL], any Error>) {
        switch picked {
        case .success(let files):
            if let file = files.first { model.prepareImport(from: file) }
        case .failure(let error):
            model.errorMessage = error.localizedDescription
        }
    }

    public func commit() { model.commitImport() }
    public func cancel() { model.cancelImport() }

    static func status(of decision: ImportDecision) -> (String, Tone) {
        switch decision {
        case .alreadyImported: (Words.alreadyImported, .alreadyImported)
        case .matchesReceipt: (Words.matchedReceipt, .matched)
        case .matchesTransaction, .replacesMade: (Words.matchedEntry, .matched)
        case .add: (Words.willBeAdded, .toAdd)
        case .needsBudget: (Words.needsBudget, .needsBudget)
        }
    }

    public enum Words {
        public static let title = "Import a statement"
        public static func title(into group: String) -> String { "Import a statement into \u{201C}\(group)\u{201D}" }
        public static let matched = "Matched"
        public static let toAdd = "To add"
        public static let alreadyImported = "Already imported"
        public static let needsBudget = "Needs a budget"
        public static let matchedReceipt = "Matched to receipt"
        public static let matchedEntry = "Matched to entry"
        public static let willBeAdded = "Will be added"
        public static func replaces(month: String, name: String, amount: String) -> String {
            "Replaces \(month)'s \(name), \(amount)"
        }
        public static let keepBoth = "Keep both"
        public static let choose = "Choose"
        /// The name VoiceOver reads for a line's budget list.
        public static let budget = "Budget"
        /// The name VoiceOver reads for a money-in line's kind list.
        public static let kind = "Money in"
        /// The third part of a phone's kind choice: the other kinds.
        public static let more = "More\u{2026}"
        public static let importButton = "Import"
        public static let cancel = "Cancel"
    }
}
