import Foundation
import WellSpentCrypto
import WellSpentModel

/// One budget on the right side of the main window, on any desktop: how much
/// is spent and left this period, and its entries. What it says lives here;
/// the Mac and Linux screens only draw it.
@MainActor
public struct BudgetScreen {
    /// One entry in the list.
    public struct Row: Identifiable, Equatable, Sendable {
        public let id: RecordID
        public let date: Date
        public let merchant: String
        public let note: String
        /// "You", or the name that member gave the group.
        public let addedBy: String
        public let source: String
        /// Without its sign: every entry is money out.
        public let amount: String
        /// Whether this person may change or delete it, for its menu. The
        /// row looks the same either way, and a click opens it either way.
        public let mayChange: Bool
        /// Under the merchant, when this device's last change to it didn't
        /// go through, until the entry is opened.
        public let notice: String?
    }

    public let summary: BudgetSummary
    public let rows: [Row]
    /// "Added by" only means something once someone else is in the group.
    public let showsAddedBy: Bool
    /// Whether Add and Import statement are offered: they take Add, as the
    /// server decides.
    public let mayAdd: Bool
    /// The bar at the top after a delete, with its Undo button.
    public let undo: UndoOffer?

    public init(summary: BudgetSummary, model: AppModel, me: UserID?) {
        self.summary = summary
        let group = summary.budget.groupID
        // Asked once for the whole list: every entry is in this group.
        let mayAdd = model.mayAddEntries(group)
        let mayManage = model.mayManageEntries(group)
        rows = model.transactions.map { transaction in
            Row(id: transaction.id, date: transaction.date, merchant: transaction.merchant, note: transaction.note,
                addedBy: model.addedBy(transaction, me: me), source: transaction.source.rawValue.capitalized,
                amount: transaction.amount.magnitude.display,
                mayChange: model.access(to: transaction, mayAdd: mayAdd, mayManage: mayManage).mayChange,
                notice: model.notices.contains(transaction.id) ? Words.notice : nil)
        }
        showsAddedBy = model.isShared(group)
        self.mayAdd = mayAdd
        undo = model.undoOffer
    }

    public var title: String { summary.budget.name }
    public var spent: String { summary.spent.display }
    public var ofLimit: String { "of \(summary.budget.limit.display) this period" }
    public var isOverspent: Bool { summary.isOverspent }

    /// How much is left, or how far over it is.
    public var standing: String {
        summary.isOverspent
            ? "\(summary.remaining.magnitude.display) over"
            : "\(summary.remaining.display) left"
    }

    /// How full the bar is, 0 to 1.
    public var fraction: Double { summary.fraction }

    /// "3 transactions since Oct 1".
    public var countLine: String {
        let count = summary.transactionCount
        let since = summary.period.start.formatted(.dateTime.day().month(.abbreviated))
        return "\(count) transaction\(count == 1 ? "" : "s") since \(since)"
    }

    /// A short date for the list, as the Mac's table shows it.
    public static func shortDate(_ date: Date) -> String {
        date.formatted(.dateTime.day().month(.abbreviated))
    }

    public enum Words {
        public static let empty = "Nothing spent in this budget this period."
        public static let date = "Date"
        public static let description = "Description"
        public static let addedBy = "Added by"
        public static let source = "Source"
        public static let amount = "Amount"
        public static let add = "Add"
        public static let importStatement = "Import statement"
        public static let notice = "Your change didn't go through."
    }
}
