import Foundation
import WellSpentCrypto
import WellSpentModel

// Who may change or delete one entry, and what a change, a delete or an
// undo comes to, with no SwiftUI, so every desktop shares it.

/// Whether this person may change one entry, and if not, the line the
/// read-only sheet shows.
public enum EntryAccess: Equatable, Sendable {
    case change
    /// At View, on someone else's entry.
    case viewOnly
    /// At View, on an entry this person added.
    case viewOnlyOwn
    /// At Add, on someone else's entry: the name that person set for the
    /// group, or nil when they set none.
    case someoneElses(name: String?)

    public var mayChange: Bool { self == .change }

    /// Why it can't be changed. Nil for an entry this person may change.
    public var line: String? {
        switch self {
        case .change: return nil
        case .viewOnly: return Words.viewOnly
        case .viewOnlyOwn: return Words.viewOnlyOwn
        case .someoneElses(let name): return Words.someoneElses(name)
        }
    }

    public enum Words {
        public static let viewOnly = "You can view this group but not change it."
        public static let viewOnlyOwn = "You can only view this group now, so you can't change what you added."
        public static func someoneElses(_ name: String?) -> String {
            guard let name else { return "Only the person who added this, or a manager, can change this." }
            return "Only \(name), or a manager, can change this."
        }
    }
}

extension AppModel {
    /// The server's rule for one entry, which the sync engine also applies
    /// before sending: Manage, Admin and Owner change anyone's entries, Add
    /// changes only that person's own, and View changes nothing. An entry
    /// with no owner yet counts as this person's own. It has never synced,
    /// because the first send stamps its sender as the owner.
    public func access(to entry: Transaction) -> EntryAccess {
        access(to: entry, mayAdd: mayAddEntries(entry.groupID), mayManage: mayManageEntries(entry.groupID))
    }

    /// The same, with the group's levels read once for a whole list.
    func access(to entry: Transaction, mayAdd: Bool, mayManage: Bool) -> EntryAccess {
        let own = entry.createdBy == nil || entry.createdBy == me()
        guard mayAdd else { return own ? .viewOnlyOwn : .viewOnly }
        if own || mayManage { return .change }
        return .someoneElses(name: entry.createdBy.flatMap { memberName($0, in: entry.groupID) })
    }
}

/// What a change, or a delete, of one entry came to.
public enum EntrySaveResult: Equatable, Sendable {
    /// Who deleted an entry while it was open.
    public enum Deleter: Equatable, Sendable {
        /// This person, on another computer.
        case you
        /// Someone else, by the name they set for the group, or nil when
        /// they set none.
        case someone(name: String?)
    }

    case saved
    /// Deleted since it was opened. Nothing was saved, so it stays deleted:
    /// a save would have brought it back for everyone.
    case deletedMeanwhile(by: Deleter)
    /// This person may not change it now, after a move down, say. Nothing
    /// was saved.
    case notAllowed(EntryAccess)
    /// Nothing was saved, and the app's error says why.
    case failed
}

/// The fields a person changed in an entry. Nil leaves a field as stored,
/// so a change someone else made to it meanwhile stays.
public struct EntryChange: Equatable, Sendable {
    public var merchant: String?
    /// Its size. The sign follows the entry's kind: money out stays money
    /// out, a refund stays a refund, income stays money in. A transfer keeps
    /// the sign it had.
    public var amount: Money?
    public var date: Date?
    public var note: String?
    /// Another budget in the entry's own group.
    public var budget: BudgetID?

    public init(merchant: String? = nil, amount: Money? = nil, date: Date? = nil, note: String? = nil,
                budget: BudgetID? = nil) {
        self.merchant = merchant
        self.amount = amount
        self.date = date
        self.note = note
        self.budget = budget
    }
}

/// The bar at the top of the budget after a delete, with its Undo button.
/// It is the only way to undo a delete.
public struct UndoOffer: Equatable, Sendable {
    public let entry: RecordID
    /// "Deleted “Hilltop Grocery”, $142.08."
    public let message: String
    /// "Undo"
    public let button: String

    init(deleting entry: Transaction) {
        self.entry = entry.id
        message = Words.deleted(entry.merchant, entry.amount.magnitude.display)
        button = Words.undo
    }

    public enum Words {
        public static let undo = "Undo"
        public static func deleted(_ merchant: String, _ amount: String) -> String {
            "Deleted \u{201C}\(merchant)\u{201D}, \(amount)."
        }
        /// When this person may no longer change it: the second sentence is
        /// the line the read-only sheet would show.
        public static func refused(_ access: EntryAccess) -> String {
            (["This can't be undone now."] + [access.line].compactMap { $0 }).joined(separator: " ")
        }
        public static func budgetGone(_ budget: String) -> String {
            "This can't be undone now, because \(budget) was deleted."
        }
    }
}
