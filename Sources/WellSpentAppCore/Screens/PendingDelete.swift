import Foundation
import WellSpentCrypto
import WellSpentModel

// What a delete asks before it happens, and what Delete then does, with no
// SwiftUI, so every desktop shares it.

/// What a delete is waiting on the person to confirm.
public enum PendingDelete: Identifiable {
    case budget(Budget, transactions: Int)
    /// A group, with how many budgets and transactions go with it, in every
    /// period. A group's delete is final on the server, so it offers no
    /// Undo. The count of transactions has a default only so that a screen
    /// that words its own leave, as the Linux People sheet does, still builds.
    case group(BudgetGroup, budgets: Int, transactions: Int = 0, reach: GroupDeleteReach)
    /// One entry, with its budget's name and its group's, and whether anyone
    /// else is in the group.
    case entry(Transaction, budget: String, group: String, shared: Bool)

    public var id: String {
        switch self {
        case .budget(let budget, _): return "budget-\(budget.id)"
        case .group(let group, _, _, _): return "group-\(group.id)"
        case .entry(let entry, _, _, _): return "entry-\(entry.id)"
        }
    }

    /// A shared group this person may not delete for everyone. What they
    /// confirm is leaving it, so the dialog says so.
    public var isLeave: Bool {
        if case .group(_, _, _, .thisMacOnly) = self { return true }
        return false
    }

    public var title: String {
        switch self {
        case .budget(let budget, _): return "Delete \u{201C}\(budget.name)\u{201D}?"
        case .group(let group, _, _, _):
            return isLeave ? MembersScreen.Words.leaveTitle(group.name) : "Delete \u{201C}\(group.name)\u{201D}?"
        case .entry(let entry, _, _, _):
            return "Delete \u{201C}\(entry.merchant)\u{201D}, \(entry.amount.magnitude.display)?"
        }
    }

    /// The dialog's button that goes ahead.
    public var confirmLabel: String { isLeave ? MembersScreen.Words.leaveButton : "Delete" }

    /// The message, for a leave by someone who can or cannot send changes.
    public func message(sendsChanges: Bool) -> String {
        isLeave ? SyncWording.leaveGroupMessage(sendsChanges: sendsChanges, taking: groupContents) : message
    }

    public var message: String {
        switch self {
        case .budget(_, let count):
            return count == 0
                ? "This cannot be undone."
                : "Its \(count) transaction\(count == 1 ? "" : "s") will be deleted too. This cannot be undone."
        case .group(_, _, _, let reach):
            // A delete that takes entries asks first and says how many.
            let contents = groupContents.map { "Its \($0) will be deleted too. " } ?? ""
            switch reach {
            case .justYou:
                return contents + "This cannot be undone."
            case .everyone:
                return "Everyone you share it with loses it too. " + contents + "This cannot be undone."
            case .thisMacOnly:
                return SyncWording.leaveGroupMessage(sendsChanges: true, taking: groupContents)
            case .declinesInvite:
                return "This removes the group from this computer. Your answer to the invite has already "
                    + "been sent, so the person who invited you may still add you. Nothing of theirs "
                    + "changes. To get it back, ask for a new invite link."
            }
        // Undo follows a delete, so the question no longer says it can't be undone.
        case .entry(_, let budget, let group, let shared):
            return shared ? "It comes out of \(budget) for everyone in \(group)." : "It comes out of \(budget)."
        }
    }

    /// What a group takes with it, in words: "2 budgets and 14 transactions".
    /// A count of none is left out. Nil for a group holding neither, and for
    /// anything but a group.
    var groupContents: String? {
        guard case .group(_, let budgets, let transactions, _) = self else { return nil }
        var parts: [String] = []
        if budgets > 0 { parts.append("\(budgets) budget\(budgets == 1 ? "" : "s")") }
        if transactions > 0 { parts.append("\(transactions) transaction\(transactions == 1 ? "" : "s")") }
        return parts.isEmpty ? nil : parts.joined(separator: " and ")
    }
}

extension PendingDelete {
    /// What the dialog's Delete button does.
    ///
    /// The reach the dialog showed can be out of date by the time Delete is
    /// pressed: a sync may have finished a join while it was open, for one. So
    /// it is worked out again now, and the reading that sends less wins.
    @MainActor
    public func confirm(model: AppModel, sync: SyncCoordinator) {
        switch self {
        case .budget(let budget, _): model.deleteBudget(budget.id)
        case .group(let group, _, _, let reach):
            model.deleteGroup(group.id, reach: reach.stricter(sync.deleteReach(of: group.id)))
        case .entry(let entry, _, _, _):
            // Asked from the row's menu, with no sheet open to say why it
            // was refused. Deleted meanwhile, it is gone, as asked.
            if case .notAllowed(let access) = model.deleteEntry(entry.id) {
                model.errorMessage = EntryEditor.Words.notAllowed(access)
            }
        }
    }
}
