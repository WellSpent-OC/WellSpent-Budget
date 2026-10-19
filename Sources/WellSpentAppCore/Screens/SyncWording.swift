import Foundation

/// Words about syncing shown around the main window, on any desktop.
public enum SyncWording {
    /// What the words call the device this app runs on, as in "Kept on this
    /// iPhone only". Each app sets it once at launch, before any screen is
    /// drawn, and never again, which is why reading it needs no actor. An app
    /// that never sets it, such as the Linux one, says "computer".
    nonisolated(unsafe) public static var device = "computer"

    /// The foot of the sidebar.
    public static func footer(signedIn: Bool, device: String = device) -> String {
        signedIn ? "Syncs through WellSpent's server" : "Kept on this \(device) only"
    }

    public static let signedOutHelp = "Sign in to sync with your other devices."

    /// The account button in the toolbar.
    public static func accountTitle(signedIn: Bool) -> String {
        signedIn ? "Account" : "Sign in"
    }

    public static func accountHelp(account: String?) -> String {
        guard let account else { return signedOutHelp }
        return "Signed in as \(account)."
    }

    /// Under a group whose founder has not updated WellSpent yet. Its
    /// budgets stay here meanwhile.
    public static let waitingForFounder = "Waiting for the person who made this group to update WellSpent."

    /// In the sidebar, for groups waiting on their founder that this device
    /// holds nothing of yet, so they have no section of their own.
    public static func waitingGroups(_ count: Int) -> String {
        count == 1
            ? "A group is waiting for the person who made it to update WellSpent."
            : "\(count) groups are waiting for the people who made them to update WellSpent."
    }

    /// Asked before a member who may not delete a shared group for everyone
    /// deletes it: for them, it is leaving.
    public static let leaveGroupMessage = leaveGroupMessage(sendsChanges: true)

    /// The same, for someone who can or cannot send changes. Someone at View
    /// cannot leave changes behind: they have none to send. `contents` is
    /// what goes from their devices with the group, such as "2 budgets and
    /// 14 transactions", when there is any.
    public static func leaveGroupMessage(sendsChanges: Bool, taking contents: String? = nil) -> String {
        let removed = "You leave the group, and it is removed from all your devices"
            + (contents.map { ", with its \($0)" } ?? "") + ". The others in it keep it. "
        let changes = sendsChanges
            ? "Anything you changed in it on this device that has not synced yet still goes to them first. "
                + "Changes on your other devices that have not synced yet do not reach them. "
            : ""
        return removed + changes + "Only the person who made it, or an admin, can delete it for everyone. "
            + "To come back, ask for a new invite link."
    }

    /// When someone at View tries to add an entry or import a statement.
    public static let viewOnly = "You can view this group but not add to it."

    /// Under a new invite link. The server makes it, and adds the person the
    /// moment they join.
    public static let inviteNote = "Send this to the person you are inviting. It works once and expires in 7 days."

    /// At the foot of the import review.
    public static var importNote: String { importNote(device: device) }

    public static func importNote(device: String) -> String {
        "Read on this \(device). Nothing is sent until you add it."
    }

    // MARK: - The sync button

    /// Shown while a sync runs, whoever started it, so a sync nobody clicked
    /// for is still visible.
    public static func showsProgress(for state: SyncCoordinator.State) -> Bool {
        if case .busy = state { return true }
        return false
    }

    /// The sync button's words.
    public static func syncTitle(for state: SyncCoordinator.State) -> String {
        switch state {
        case .signedOut: return "Sign in"
        case .busy(let what): return what
        case .signedIn: return "Sync"
        case .failed: return "Sync failed"
        }
    }

    /// The detail behind the sync button: a button has no room for a sentence,
    /// and a failure that says nothing is worse than no button at all.
    public static func syncHelp(for state: SyncCoordinator.State, lastSyncedAt: Date?) -> String {
        switch state {
        case .signedOut: return signedOutHelp
        case .busy(let what): return what
        case .failed(let why): return why
        case .signedIn(let email):
            guard let at = lastSyncedAt else { return "Signed in as \(email). Not synced yet." }
            return "Signed in as \(email). Last synced at "
                 + at.formatted(date: .omitted, time: .shortened) + "."
        }
    }
}
