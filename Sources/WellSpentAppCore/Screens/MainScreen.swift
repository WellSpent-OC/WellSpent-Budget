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
        /// Said above the group's budgets: it is waiting on its founder.
        public let note: String?
        /// Empty while the group is hidden.
        public let budgets: [BudgetSummary]

        public var id: GroupID { group.id }
        public var title: String { group.name }
        /// The tooltip on the group's name, which hides or shows its budgets.
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
    }

    // MARK: - The left side

    public var sections: [Section] {
        model.groups.map { group in
            let isCollapsed = SidebarRules.isCollapsed(group.id, in: collapsed)
            let waiting = sync.waitingForFounder.contains(group.id)
            return Section(group: group, isCollapsed: isCollapsed,
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

    public var selectedBudget: BudgetID? {
        get { model.selectedBudget }
        set { model.selectedBudget = newValue }
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
    public func confirm(_ pending: PendingDelete) {
        pendingDelete = nil
        pending.confirm(model: model, sync: sync)
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
    }
}
