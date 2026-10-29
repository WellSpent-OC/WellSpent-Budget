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
        /// Money out shows its size with no sign, since that is what every
        /// entry was. Money in shows a plus sign: "+$1310.00".
        public let amount: String
        /// Whether this person may change or delete it, for its menu. The
        /// row looks the same either way, and a click opens it either way.
        public let mayChange: Bool
        /// Under the merchant, when this device's last change to it didn't
        /// go through, until the entry is opened.
        public let notice: String?

        /// Under the merchant on a phone: "Oct 10 · Manual". Who added it
        /// shows on its own, beside the amount.
        public var detailLine: String { "\(BudgetScreen.shortDate(date)) · \(source)" }
    }

    /// "$42.50" for money out, "+$1310.00" for money in.
    public static func amountText(_ amount: Money) -> String {
        amount.minorUnits > 0 ? "+" + amount.magnitude.display : amount.magnitude.display
    }

    public let summary: BudgetSummary
    public let rows: [Row]
    /// "Added by" means something once someone else is in the group, or
    /// once any entry here is someone else's, even after they left.
    public let showsAddedBy: Bool
    /// Whether Add and Import statement are offered: they take Add, as the
    /// server decides.
    public let mayAdd: Bool
    /// The bar at the top after a delete, with its Undo button.
    public let undo: UndoOffer?
    /// What is left this period, drawn as the budget's wheel.
    public let wheel: MoneyWheel
    /// The pace words under the wheel's figures, when there are any.
    public let pace: BudgetPace?

    /// `now` and `calendar` place today in the budget's period, for its
    /// wheel and its pace words. With no `now`, today is the model's
    /// (`AppModel.today`).
    public init(summary: BudgetSummary, model: AppModel, me: UserID?, now: Date? = nil,
                calendar: Calendar = AppLocale.calendar) {
        self.summary = summary
        let group = summary.budget.groupID
        // Asked once for the whole list: every entry is in this group.
        let mayAdd = model.mayAddEntries(group)
        let mayManage = model.mayManageEntries(group)
        rows = model.transactions.map { transaction in
            Row(id: transaction.id, date: transaction.date, merchant: transaction.merchant, note: transaction.note,
                addedBy: model.addedBy(transaction, me: me), source: transaction.source.rawValue.capitalized,
                amount: Self.amountText(transaction.amount),
                mayChange: model.access(to: transaction, mayAdd: mayAdd, mayManage: mayManage).mayChange,
                notice: model.notices.contains(transaction.id) ? Words.notice : nil)
        }
        // Shown while someone else is in the group, and while any entry is
        // someone else's, so a removed person's entries keep their name
        // (PAGE-17). Only this person's own entries, alone, show none.
        showsAddedBy = model.isShared(group)
            || model.transactions.contains { $0.createdBy != nil && $0.createdBy != me }
        self.mayAdd = mayAdd
        undo = model.undoOffer
        let wheel = MoneyWheel(budget: summary, now: now ?? model.today(), calendar: calendar)
        self.wheel = wheel
        // Changing a budget takes Manage, the level the workspace answers
        // `mayManageEntries` with.
        pace = BudgetPace(wheel: wheel, budgetName: summary.budget.name, mayEdit: mayManage, calendar: calendar)
    }

    public var title: String { summary.budget.name }
    /// Under the budget's name: "October · day 18 of 31". None for a budget
    /// that never resets.
    public var dayLine: String? { wheel.day?.line }
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
        let since = summary.period.start.formatted(.dateTime.day().month(.abbreviated).locale(AppLocale.current))
        return "\(count) transaction\(count == 1 ? "" : "s") since \(since)"
    }

    /// "$3275.00 in", after the count line, once the period has money in.
    /// Nil until it does: a budget with no money in says nothing about it.
    public var moneyInLine: String? {
        summary.moneyIn.minorUnits > 0 ? Words.moneyIn(summary.moneyIn.display) : nil
    }

    /// A short date for the list, as the Mac's table shows it.
    nonisolated public static func shortDate(_ date: Date) -> String {
        date.formatted(.dateTime.day().month(.abbreviated).locale(AppLocale.current))
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
        /// The period's money in, after the count line. Placeholder words.
        public static func moneyIn(_ amount: String) -> String { "\(amount) in" }
        /// What a tap on a row does, said by VoiceOver after the row's words.
        public static let rowHelp = "Opens the transaction."
    }
}
