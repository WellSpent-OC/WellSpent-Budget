import Foundation
import Observation
import WellSpentCrypto
import WellSpentModel

// The main window on any desktop: the groups and their budgets on the left,
// what each one's menu offers, the question a delete or a leave asks first,
// the footer, and what the right side shows. What a person may do comes from
// the coordinator's reading of their level, the same one the server holds
// them to. The Mac and Linux screens only draw it.

@MainActor
@Observable
public final class MainScreen {
    /// One group on the left, with its budgets unless it is hidden.
    public struct Section: Identifiable {
        public let group: BudgetGroup
        public let isCollapsed: Bool
        /// Whether this group's page shows on the right. Its name is marked
        /// on the left while it does, so the person knows where they are.
        public let isPageOpen: Bool
        /// Said above the group's budgets: it is waiting on its founder.
        public let note: String?
        /// Empty while the group is hidden.
        public let budgets: [BudgetSummary]

        public var id: GroupID { group.id }
        public var title: String { group.name }
        /// The tooltip on the arrow beside the group's name, which hides or
        /// shows its budgets.
        public var toggleHelp: String { isCollapsed ? Words.showBudgets : Words.hideBudgets }
    }

    /// What a menu item or button asks for. The screens open a sheet for
    /// each, except the two deletes, which go to `ask(_:)`.
    public enum Action: Equatable {
        case newBudget(in: GroupID?)
        case editBudget(Budget)
        case deleteBudget(Budget)
        case newGroup
        case renameGroup(BudgetGroup)
        case share(BudgetGroup)
        case people(BudgetGroup)
        case join
        case deleteGroup(BudgetGroup)

        /// Whether `ask(_:)` handles it, with a question first.
        public var asksFirst: Bool {
            switch self {
            case .deleteBudget, .deleteGroup: return true
            default: return false
            }
        }
    }

    public struct MenuItem: Identifiable, Equatable {
        public let action: Action
        public let title: String
        public let isDestructive: Bool

        public var id: String { title }
    }

    /// What an entry's row asks for: its sheet, or a delete, which asks
    /// first. Kept apart from `Action`, which each desktop handles case by
    /// case. A new case there would stop the Linux app building until its
    /// screens draw it.
    public enum EntryAction: Equatable {
        case open(RecordID)
        case delete(RecordID)

        /// Whether `ask(_:)` handles it, with a question first.
        public var asksFirst: Bool {
            if case .delete = self { return true }
            return false
        }
    }

    public struct EntryMenuItem: Identifiable, Equatable {
        public let action: EntryAction
        public let title: String
        public let isDestructive: Bool

        public var id: String { title }
    }

    /// What the right side shows.
    public enum Detail: Equatable {
        case budget(BudgetSummary)
        case noBudgets
        case noneSelected
    }

    /// Signing in to another account swaps the workspace's budgets, so they
    /// are read from it each time, never kept.
    public let workspace: Workspace
    private var model: AppModel { workspace.model }
    private var sync: SyncCoordinator { workspace.sync }
    private let defaults: UserDefaults

    /// Hidden groups, as stored: a view preference for this computer, kept
    /// in this build's settings, so it never syncs.
    public private(set) var collapsed: String
    /// The delete or leave waiting on the person to confirm.
    public private(set) var pendingDelete: PendingDelete?

    /// The setting's name, the same one the Mac's sidebar has always used.
    static let collapsedKey = "sidebar.collapsedGroups"

    public init(workspace: Workspace) {
        self.workspace = workspace
        defaults = workspace.sync.defaults
        collapsed = defaults.string(forKey: Self.collapsedKey) ?? ""
        // Someone else deleting the group, or taking this person out of it,
        // closes its page for good.
        workspace.afterReload.append { [weak self] in self?.closePageIfItsGroupIsGone() }
    }

    // MARK: - The left side

    public var sections: [Section] {
        let open = openGroup?.id
        return model.groups.map { group in
            let isCollapsed = SidebarRules.isCollapsed(group.id, in: collapsed)
            let waiting = sync.waitingForFounder.contains(group.id)
            return Section(group: group, isCollapsed: isCollapsed, isPageOpen: group.id == open,
                           note: waiting && !isCollapsed ? SyncWording.waitingForFounder : nil,
                           budgets: isCollapsed ? [] : model.summaries[group.id] ?? [])
        }
    }

    /// Below the groups: groups waiting on their founder that this device
    /// holds nothing of, so no section speaks for them.
    public var waitingNote: String? {
        let held = (try? model.store.groups(includeDeleted: true)) ?? model.groups
        let unseen = SidebarRules.unseenWaiting(sync.waitingForFounder, held: held)
        return unseen > 0 ? SyncWording.waitingGroups(unseen) : nil
    }

    /// Hides or shows a group's budgets, and remembers it.
    public func toggle(_ group: GroupID) {
        collapsed = SidebarRules.toggling(group, in: collapsed)
        defaults.set(collapsed, forKey: Self.collapsedKey)
        defaults.saveNow()
    }

    /// The budget picked on the left, and none while a group's page or an
    /// invitation shows. Picking one opens it in place of either. The list
    /// letting go of its pick is not a click on a budget, so they stay.
    public var selectedBudget: BudgetID? {
        get { openGroup == nil && invitation == nil ? model.selectedBudget : nil }
        set {
            if newValue == nil, openGroup != nil || invitation != nil { return }
            page = nil
            workspace.closeInvitation()
            model.selectedBudget = newValue
        }
    }

    // MARK: - A group's page

    /// The group whose page shows on the right, where a budget opens: its
    /// people, and what this person may change about them. A click on the
    /// group's name opens it, and so does People… in its menu. It closes
    /// when a budget opens, picked on the left or opened on its own as a
    /// new one is, and once the group is gone from here. An invitation
    /// shows in its place.
    public var openGroup: BudgetGroup? {
        guard invitation == nil, let page, page.over == model.selectedBudget else { return nil }
        return model.group(named: page.group)
    }

    /// The group whose page is open, and the budget that was open under it.
    private var page: (group: GroupID, over: BudgetID?)?

    /// Opens a group's page, in place of whatever shows on the right, an
    /// invitation included. On a phone, whose budgets open only by a tap,
    /// the page is a screen of its own over the list: the open budget
    /// closes, so Back, or a leave, goes to the list and not to it.
    public func openPage(of group: GroupID) {
        workspace.closeInvitation()
        if !model.opensFirstBudget { model.selectedBudget = nil }
        page = (group, model.selectedBudget)
    }

    /// Closes a group's page with nothing in its place, as Back does on a
    /// phone. A desktop never needs it: something else always opens there.
    public func closePage() {
        page = nil
    }

    /// A page whose group is gone closes for good, so it does not come back
    /// by itself if the group does, such as after joining it again.
    private func closePageIfItsGroupIsGone() {
        if let page, model.group(named: page.group) == nil { self.page = nil }
    }

    /// Leave Group… on a group's page. It asks first, with the question
    /// Leave… in the group's menu asks, and it is always a leave, never a
    /// delete for everyone, whatever this person's level.
    public func askToLeave(_ group: BudgetGroup) {
        pendingDelete = .group(group, budgets: model.summaries[group.id]?.count ?? 0,
                               transactions: model.transactionCount(inGroup: group.id), reach: .thisMacOnly)
    }

    // MARK: - An invitation

    /// The invitation page a clicked invite link put up
    /// (`Workspace.open(_:)`). It shows on the right in place of a budget or
    /// a group's page, with nothing picked or marked on the left, until the
    /// person joins or picks a budget or a group there.
    public var invitation: JoinScreen? { workspace.invitation }

    /// Join, on the invitation page. Once in, the page gives way to the
    /// group's own page, with its people. False when the join did not go
    /// through, and the page stays, saying why.
    @discardableResult
    public func joinInvitation() async -> Bool {
        guard let invitation, await invitation.join(), let joined = invitation.joined else { return false }
        // Another link opened while this one joined: its page stays up.
        guard workspace.invitation === invitation else { return true }
        openPage(of: joined.groupID)
        return true
    }

    /// Opens the first budget shown on the left, as a tap on it would. For a
    /// window asked to start on a budget (`StartingScreen`).
    public func openFirstBudget() {
        selectedBudget = sections.lazy.compactMap { $0.budgets.first?.budget.id }.first
    }

    // MARK: - Menus

    /// A group's menu, in parts the screens separate with dividers.
    public func groupMenu(_ group: BudgetGroup) -> [[MenuItem]] {
        var parts: [[MenuItem]] = []
        // A group waiting on its founder has nobody to share it or list.
        if !sync.waitingForFounder.contains(group.id) {
            parts.append([MenuItem(action: .share(group), title: Words.share, isDestructive: false),
                          MenuItem(action: .people(group), title: MembersScreen.Words.menuItem,
                                   isDestructive: false)])
        }
        if sync.mayManageBudgets(in: group.id) {
            parts.append([MenuItem(action: .newBudget(in: group.id), title: Words.newBudget(in: group.name),
                                   isDestructive: false),
                          MenuItem(action: .renameGroup(group), title: Words.rename, isDestructive: false)])
        }
        // Someone who may not delete a shared group for everyone leaves it.
        let leaves = sync.deleteReach(of: group.id) == .thisMacOnly
        parts.append([MenuItem(action: .deleteGroup(group), title: leaves ? Words.leave : Words.delete,
                               isDestructive: true)])
        return parts
    }

    /// A budget's menu. Changing or deleting a budget takes Manage; below
    /// that, the server would refuse it, so nothing is offered.
    public func budgetMenu(_ budget: Budget) -> [[MenuItem]] {
        guard sync.mayManageBudgets(in: budget.groupID) else { return [] }
        return [[MenuItem(action: .editBudget(budget), title: Words.edit, isDestructive: false)],
                [MenuItem(action: .deleteBudget(budget), title: Words.delete, isDestructive: true)]]
    }

    /// An entry's menu, the same way: offered only to someone who may
    /// change it, since the server would refuse anyone else.
    public func entryMenu(_ row: BudgetScreen.Row) -> [[EntryMenuItem]] {
        guard row.mayChange else { return [] }
        return [[EntryMenuItem(action: .open(row.id), title: Words.edit, isDestructive: false)],
                [EntryMenuItem(action: .delete(row.id), title: Words.delete, isDestructive: true)]]
    }

    /// Like Add List in Reminders: the common action is the button, the
    /// rarer ones are in its menu.
    public var addButton: MenuItem {
        MenuItem(action: .newBudget(in: nil), title: Words.addBudget, isDestructive: false)
    }

    public var addMenu: [MenuItem] {
        [MenuItem(action: .newGroup, title: Words.newGroup, isDestructive: false),
         MenuItem(action: .join, title: Words.join, isDestructive: false)]
    }

    /// The groups a new budget may go in: the ones this person manages.
    public var groupsForNewBudget: [BudgetGroup] {
        model.groups.filter { sync.mayManageBudgets(in: $0.id) }
    }

    // MARK: - Deleting and leaving

    /// Asks before a delete or a leave. Anything else is a sheet the screens
    /// open themselves.
    public func ask(_ action: Action) {
        switch action {
        case .deleteBudget(let budget):
            pendingDelete = .budget(budget, transactions: model.transactionCount(inBudget: budget.id))
        case .deleteGroup(let group):
            pendingDelete = .group(group, budgets: model.summaries[group.id]?.count ?? 0,
                                   transactions: model.transactionCount(inGroup: group.id),
                                   reach: sync.deleteReach(of: group.id))
        default:
            break
        }
    }

    /// The answer yes, for the delete that was asked about. It takes it from
    /// the question itself, so a dialog closing before or after its button
    /// runs makes no difference.
    ///
    /// A group's page stays open unless its own group is what went. A delete
    /// is not a click on a budget, even when the budget that was open before
    /// the page goes and another one is picked in its place.
    public func confirm(_ pending: PendingDelete) {
        pendingDelete = nil
        let shown = openGroup?.id
        pending.confirm(model: model, sync: sync)
        if let shown, model.group(named: shown) != nil { page = (shown, model.selectedBudget) }
        closePageIfItsGroupIsGone()
    }

    /// Asks before an entry's delete, with the window's own question.
    /// Opening one is a sheet the screens open themselves.
    public func ask(_ action: EntryAction) {
        guard case .delete(let id) = action else { return }
        pendingDelete = model.deleteQuestion(for: id)
    }

    public func keepIt() { pendingDelete = nil }

    /// What the question says. A leave by someone at View promises nothing
    /// about changes, since they can send none.
    public func message(for pending: PendingDelete) -> String {
        guard case .group(let group, _, _, _) = pending else { return pending.message }
        return pending.message(sendsChanges: sync.mayAddEntries(in: group.id))
    }

    // MARK: - The footer

    /// Whether budgets go through the server or stay on this computer.
    /// Whether there is a session, not the signed-in state, which is also
    /// false while a sync runs or after one fails.
    public var footer: String { SyncWording.footer(signedIn: sync.account != nil) }
    public var accountTitle: String { SyncWording.accountTitle(signedIn: sync.account != nil) }
    public var accountHelp: String { SyncWording.accountHelp(account: sync.account) }

    /// The sync button is shown only while signed in: signed out, the
    /// account button is the way in.
    public var showsSync: Bool { sync.account != nil }
    public var syncTitle: String { SyncWording.syncTitle(for: sync.state) }
    public var syncHelp: String { SyncWording.syncHelp(for: sync.state, lastSyncedAt: sync.lastSyncedAt) }
    public var syncShowsProgress: Bool { SyncWording.showsProgress(for: sync.state) }
    /// Why the last sync failed, for a screen with no tooltips to say it in.
    /// Only while signed in: a wrong password at sign-in also leaves the state
    /// failed, and that belongs to the sign-in sheet, not under Sign in.
    public var syncFailure: String? {
        guard sync.account != nil, case .failed(let message) = sync.state else { return nil }
        return message
    }

    public var isBusy: Bool { sync.isBusy }

    /// A sync now. A failed one is tried again; signed out, nothing happens.
    public func syncNow() async {
        guard sync.account != nil else { return }
        await sync.syncAll()
    }

    // MARK: - The right side

    public var detail: Detail {
        if let id = model.selectedBudget, let summary = model.summary(for: id) { return .budget(summary) }
        return model.summaries.values.allSatisfy(\.isEmpty) ? .noBudgets : .noneSelected
    }

    // MARK: - Words

    public enum Words {
        /// Closes the window's error alert.
        public static let ok = "OK"
        public static let share = "Share…"
        public static let rename = "Rename…"
        public static let edit = "Edit…"
        public static let delete = "Delete…"
        public static let leave = "Leave…"
        public static func newBudget(in group: String) -> String { "New Budget in \(group)…" }
        public static let addBudget = "Add Budget"
        public static let newGroup = "New Group…"
        public static let join = "Join a Group…"
        public static let showBudgets = "Show budgets"
        public static let hideBudgets = "Hide budgets"
        public static let noBudgetsTitle = "No budgets yet"
        public static let noBudgetsText = "A budget is an amount to spend each month."
        public static let noneSelectedTitle = "No budget selected"
        public static let noneSelectedText = "Pick a budget on the left."
        public static let cancel = "Cancel"
        /// The title of the window's alert when something fails.
        public static let errorTitle = "Something went wrong"
        /// Shown in place of the window when the budgets cannot be opened at all.
        public static func couldNotOpen(_ appName: String) -> String { "\(appName) could not open its database" }
    }
}
