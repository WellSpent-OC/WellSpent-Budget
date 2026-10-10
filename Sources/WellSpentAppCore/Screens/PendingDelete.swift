import Foundation
import WellSpentCrypto
import WellSpentModel

// What a delete asks before it happens, and what Delete then does, with no
// SwiftUI, so every desktop shares it.

/// What a delete is waiting on the person to confirm.
public enum PendingDelete: Identifiable {
    case budget(Budget, transactions: Int)
    case group(BudgetGroup, budgets: Int, reach: GroupDeleteReach)

    public var id: String {
        switch self {
        case .budget(let budget, _): return "budget-\(budget.id)"
        case .group(let group, _, _): return "group-\(group.id)"
        }
    }

    /// A shared group this person may not delete for everyone. What they
    /// confirm is leaving it, so the dialog says so.
    public var isLeave: Bool {
        if case .group(_, _, .thisMacOnly) = self { return true }
        return false
    }

    public var title: String {
        switch self {
        case .budget(let budget, _): return "Delete \u{201C}\(budget.name)\u{201D}?"
        case .group(let group, _, _):
            return isLeave ? MembersScreen.Words.leaveTitle(group.name) : "Delete \u{201C}\(group.name)\u{201D}?"
        }
    }

    /// The dialog's button that goes ahead.
    public var confirmLabel: String { isLeave ? MembersScreen.Words.leaveButton : "Delete" }

    /// The message, for a leave by someone who can or cannot send changes.
    public func message(sendsChanges: Bool) -> String {
        isLeave ? SyncWording.leaveGroupMessage(sendsChanges: sendsChanges) : message
    }

    public var message: String {
        switch self {
        case .budget(_, let count):
            return count == 0
                ? "This cannot be undone."
                : "Its \(count) transaction\(count == 1 ? "" : "s") will be deleted too. This cannot be undone."
        case .group(_, let count, let reach):
            let contents = count == 0
                ? ""
                : "Its \(count) budget\(count == 1 ? "" : "s") and their transactions will be deleted too. "
            switch reach {
            case .justYou:
                return contents + "This cannot be undone."
            case .everyone:
                return "Everyone you share it with loses it too. " + contents + "This cannot be undone."
            case .thisMacOnly:
                return SyncWording.leaveGroupMessage
            case .declinesInvite:
                return "This removes the group from this computer. Your answer to the invite has already "
                    + "been sent, so the person who invited you may still add you. Nothing of theirs "
                    + "changes. To get it back, ask for a new invite link."
            }
        }
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
        case .group(let group, _, let reach):
            model.deleteGroup(group.id, reach: reach.stricter(sync.deleteReach(of: group.id)))
        }
    }
}
