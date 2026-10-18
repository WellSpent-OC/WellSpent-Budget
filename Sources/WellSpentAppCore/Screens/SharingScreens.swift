import Foundation
import Observation
import WellSpentCrypto
import WellSpentModel
import WellSpentStore
import WellSpentSync

// Sharing on any desktop: making an invite link, joining with one, and the
// people in a group. What each screen holds, checks and says lives here; the
// Mac and Linux screens only draw it. What a person may do comes from
// MembershipRules, the copy the server enforces.

/// What the sharing screens ask of the app. The coordinator does it; a test
/// can stand in.
@MainActor
public protocol SharingActions: AnyObject {
    var account: String? { get }
    var userID: UserID? { get }
    var emailVerified: Bool { get }
    func displayName(in group: GroupID) throws -> String?
    func share(group: GroupID, groupName: String, level: AccessLevel, historyAccess: HistoryAccess,
               myName: String) async throws -> InviteLink
    func join(_ link: InviteLink, myName: String) async throws -> PendingJoin
    func members(of group: GroupID) -> [UserID: AccessLevel]
    func memberNames(in group: GroupID) -> [UserID: String]
    func founder(of group: GroupID) -> UserID?
    func setLevel(_ level: AccessLevel, of user: UserID, in group: GroupID) async throws
    func remove(_ user: UserID, from group: GroupID) async throws
    /// Takes in one group now, members and names included.
    func refresh(_ group: GroupID) async
    func mayAddEntries(in group: GroupID) -> Bool
}

extension SharingActions {
    /// This person's level in `group`. A group the server has never listed
    /// is still only on this device, and so their own.
    func myLevel(in group: GroupID) -> AccessLevel {
        if let me = userID, let level = members(of: group)[me] { return level }
        return founder(of: group) == nil ? .superadmin : .none
    }
}

// MARK: - Share

/// Making a link that invites someone into a group.
@MainActor
@Observable
public final class ShareScreen {
    public let group: GroupID
    public let groupName: String
    public var myName: String
    public var role: InviteRole
    public var history: HistoryAccess = .all
    public private(set) var link: InviteLink?
    public private(set) var failure: String?
    public private(set) var isWorking = false
    private let actions: any SharingActions

    /// `created` opens it showing a link already made, for tests.
    public init(actions: any SharingActions, group: GroupID, groupName: String, created: InviteLink? = nil) {
        self.actions = actions
        self.group = group
        self.groupName = groupName
        link = created
        myName = (try? actions.displayName(in: group)) ?? ""
        let allowed = Self.roles(holding: actions.myLevel(in: group))
        role = allowed.contains(.add) ? .add : (allowed.first ?? .add)
    }

    public var title: String { Words.shareTitle(groupName) }
    public var isSignedIn: Bool { actions.account != nil }

    /// The roles this person may invite at, as the server would allow.
    public var roles: [InviteRole] { Self.roles(holding: actions.myLevel(in: group)) }

    static func roles(holding level: AccessLevel) -> [InviteRole] {
        InviteRole.allCases.filter { MembershipRules.invite(at: $0.level, holding: level) == nil }
    }

    /// Why no link can be made, before anything is sent.
    public var notice: String? {
        if !isSignedIn { return Words.signInToShare }
        if roles.isEmpty { return Words.cannotInvite }
        return nil
    }

    public var canCreate: Bool {
        !isWorking && SharingRules.canCreate(myName: myName, signedIn: isSignedIn) && roles.contains(role)
    }

    public var createLabel: String { isWorking ? Words.creating : Words.createLink }

    /// True once the link is made.
    public func create() async -> Bool {
        guard canCreate else { return false }
        failure = nil
        isWorking = true
        defer { isWorking = false }
        do {
            link = try await actions.share(group: group, groupName: groupName, level: role.level,
                                           historyAccess: history, myName: myName)
            return true
        } catch {
            failure = AccountWording.words(for: error)
            return false
        }
    }

    public enum Words {
        public static func shareTitle(_ group: String) -> String { "Share \u{201C}\(group)\u{201D}" }
        public static let name = "Your name"
        public static let namePrompt = "How the group will see you"
        public static let role = "They can"
        public static let history = "They see"
        public static let historyAll = "Everything so far"
        public static let historyFromNow = "Only from now on"
        public static let signInToShare = "Sign in first. Sharing goes through your account."
        public static let cannotInvite = "Only a manager or admin can invite people to this group."
        public static let linkNote = "You get a link to send by text or email."
        public static let createLink = "Create Link"
        public static let creating = "Creating…"
        public static let send = "Send…"
        public static let copyLink = "Copy Link"
        public static let done = "Done"
        public static let cancel = "Cancel"
    }
}

// MARK: - Join

/// Joining a group with a link someone sent.
@MainActor
@Observable
public final class JoinScreen {
    public var linkText: String
    public var myName = ""
    public private(set) var failure: String?
    public private(set) var isWorking = false
    /// What was joined, once it went through.
    public private(set) var joined: PendingJoin?
    private let actions: any SharingActions

    public init(actions: any SharingActions, linkText: String = "") {
        self.actions = actions
        self.linkText = linkText
    }

    public var title: String { Words.title }
    public var isSignedIn: Bool { actions.account != nil }
    public var invite: InviteLink? { InviteLink(parsing: linkText) }

    /// "Robin invited you to "Household"."
    public var invitation: String? {
        guard let invite else { return nil }
        let who = invite.inviterName.isEmpty ? "Someone" : invite.inviterName
        let what = invite.groupName.isEmpty ? "a group" : "\u{201C}\(invite.groupName)\u{201D}"
        return "\(who) invited you to \(what)."
    }

    /// Why the link cannot be used, while one is typed.
    public var linkProblem: String? {
        linkText.trimmingCharacters(in: .whitespaces).isEmpty || invite != nil ? nil : Words.notALink
    }

    /// Before anything is sent: signed out, or an address not confirmed yet.
    public var notice: String? {
        if !isSignedIn { return Words.signInToJoin }
        if !actions.emailVerified { return Words.confirmToJoin }
        return nil
    }

    /// The account sheet confirms the email; the screen offers it when that
    /// is what stands in the way. The server is asked again on Join, in case
    /// it was confirmed on another device.
    public var offersEmailConfirmation: Bool { isSignedIn && !actions.emailVerified }

    public var canJoin: Bool {
        !isWorking && SharingRules.canJoin(linkText: linkText, myName: myName, signedIn: isSignedIn)
    }

    public var joinLabel: String { isWorking ? Words.joining : Words.join }

    /// True once joined. The group is there at once, filled by the sync that follows.
    public func join() async -> Bool {
        guard canJoin, let invite else { return false }
        failure = nil
        isWorking = true
        defer { isWorking = false }
        do {
            joined = try await actions.join(invite, myName: myName)
            return true
        } catch {
            failure = AccountWording.words(for: error)
            return false
        }
    }

    public enum Words {
        public static let title = "Join a Group"
        public static let link = "Invite link"
        public static let linkPrompt = "Paste the link you were sent"
        public static let name = "Your name"
        public static let namePrompt = "How the group will see you"
        public static let notALink = "That is not a WellSpent invite link."
        public static let signInToJoin = "Sign in first, or create an account. Joining adds the group to your account."
        public static let confirmToJoin = "Confirm your email first. Joining a shared group needs it."
        public static let confirmEmail = "Confirm your email…"
        public static let join = "Join"
        public static let joining = "Joining…"
        public static let cancel = "Cancel"
    }
}

// MARK: - Members

/// The people in a group: their names and levels, and what this person may
/// change about them. A group's page shows them under the group's name,
/// with one line about the group.
@MainActor
@Observable
public final class MembersScreen {
    public struct Row: Identifiable, Equatable, Sendable {
        public let id: UserID
        public let name: String
        public let level: AccessLevel
        public let isYou: Bool
        public let isFounder: Bool
        /// The levels this person may move them to, their own included.
        /// Empty when theirs cannot be changed by this person.
        public let levelChoices: [AccessLevel]
        public let mayRemove: Bool

        public var levelTitle: String { Words.levelTitle(level) }
        public var label: String { isYou ? Words.you(name) : name }
    }

    public let group: GroupID
    public let groupName: String
    public private(set) var rows: [Row] = []
    /// The line under the group's name on its page: whether it is shared,
    /// how many people are in it, and who made it. "Shared · 3 people · Made
    /// by you". Who made it is left out when nobody here knows their name.
    public private(set) var summary = ""
    /// A quiet line at the top of the page after a removal, until the next
    /// change: "Leslie was removed."
    public private(set) var removedNote: String?
    public private(set) var failure: String?
    public private(set) var isWorking = false
    /// The person whose removal is being asked about.
    public private(set) var removing: Row?
    /// The change or removal under way, if any.
    public private(set) var pending: Task<Void, Never>?
    private let actions: any SharingActions

    public init(actions: any SharingActions, group: GroupID, groupName: String) {
        self.actions = actions
        self.group = group
        self.groupName = groupName
        reload()
    }

    public var title: String { Words.title(groupName) }

    /// Asks the server who is in the group now, then shows it. For when the
    /// screen opens, so someone who just joined is there.
    public func refresh() async {
        await actions.refresh(group)
        reload()
    }

    /// Reads who is in the group, as of the last sync.
    public func reload() {
        let mine = actions.myLevel(in: group)
        let me = actions.userID
        let founder = actions.founder(of: group)
        let names = actions.memberNames(in: group)
        var members = actions.members(of: group)
        // A group only on this device yet: its one member is this person.
        if members.isEmpty, let me { members[me] = mine }
        rows = members.map { user, level in
            let isFounder = user == founder || (founder == nil && user == me)
            let isYou = user == me
            let choices = MembershipRules.grantable.sorted().filter { new in
                new == level || MembershipRules.changeLevel(from: level, to: new, ofFounder: isFounder,
                                                            holding: mine) == nil
            }
            return Row(id: user, name: names[user] ?? Words.someone, level: level, isYou: isYou,
                       isFounder: isFounder, levelChoices: choices.count > 1 ? choices : [],
                       mayRemove: !isYou && MembershipRules.remove(level, ofFounder: isFounder, isSelf: false,
                                                                   holding: mine) == nil)
        }
        .sorted { first, second in
            if first.isFounder != second.isFounder { return first.isFounder }
            if first.level != second.level { return first.level > second.level }
            return first.name.localizedCaseInsensitiveCompare(second.name) == .orderedAscending
        }
        var line = [rows.count > 1 ? Words.shared : Words.notShared]
        if !rows.isEmpty { line.append(Words.peopleCount(rows.count)) }
        if let maker = rows.first(where: \.isFounder) {
            if maker.isYou {
                line.append(Words.madeByYou)
            } else if let name = names[maker.id], !name.isEmpty {
                line.append(Words.madeBy(name))
            }
        }
        summary = Words.line(line)
    }

    /// Whether this person may leave. The founder deletes the group instead.
    /// Leaving goes through the group's delete, which sends this person's
    /// unsynced changes first; see `SyncWording.leaveGroupMessage`.
    public var mayLeave: Bool {
        guard let me = actions.userID, let row = rows.first(where: { $0.id == me }) else { return false }
        return MembershipRules.remove(row.level, ofFounder: row.isFounder, isSelf: true,
                                      holding: actions.myLevel(in: group)) == nil
    }

    /// What the leave question says: nothing about changes for someone at
    /// View, who can send none.
    public var leaveMessage: String {
        SyncWording.leaveGroupMessage(sendsChanges: actions.mayAddEntries(in: group))
    }

    /// Whether this person may invite anyone at all, at the lowest role.
    public var mayInvite: Bool {
        MembershipRules.invite(at: .read, holding: actions.myLevel(in: group)) == nil
    }

    public func setLevel(_ level: AccessLevel, for id: UserID) async {
        guard !isWorking, let row = rows.first(where: { $0.id == id }), row.level != level,
              row.levelChoices.contains(level) else { return }
        failure = nil
        removedNote = nil
        isWorking = true
        defer { isWorking = false }
        do {
            try await actions.setLevel(level, of: id, in: group)
        } catch {
            failure = AccountWording.words(for: error)
        }
        reload()
    }

    /// Asks before removing someone.
    public func askToRemove(_ id: UserID) {
        guard !isWorking, let row = rows.first(where: { $0.id == id }), row.mayRemove else { return }
        removing = row
    }

    public func keepThem() { removing = nil }

    public var removeQuestion: String? { removing.map { Words.removeTitle($0.name) } }
    public var removeMessage: String? { removing.map { Words.removeMessage($0.name, groupName) } }

    /// The answer yes, for the person asked about. It takes who to remove
    /// from the question itself and starts at once, so a dialog closing
    /// before or after its button's action runs makes no difference.
    public func remove(_ id: UserID) {
        guard !isWorking, let row = rows.first(where: { $0.id == id }), row.mayRemove else { return }
        removing = nil
        failure = nil
        removedNote = nil
        isWorking = true
        pending = Task {
            defer { isWorking = false }
            do {
                try await actions.remove(row.id, from: group)
                removedNote = Words.removed(row.name)
            } catch {
                failure = AccountWording.words(for: error)
            }
            reload()
        }
    }

    public enum Words {
        public static func title(_ group: String) -> String { "People in \u{201C}\(group)\u{201D}" }
        public static let someone = "Someone"
        public static func you(_ name: String) -> String { "\(name) (you)" }
        public static func levelTitle(_ level: AccessLevel) -> String {
            switch level {
            case .superadmin: return "Owner"
            case .admin: return "Admin"
            case .manage: return "Manage"
            case .write: return "Add"
            case .read: return "View"
            case .none: return "Removed"
            }
        }
        /// What each level lets someone do, for the level picker.
        public static func levelExplanation(_ level: AccessLevel) -> String {
            switch level {
            case .superadmin: return "Made the group. Can do everything, and delete it for everyone."
            case .admin: return "Can do what a manager does, and make or remove other managers and admins."
            case .manage: return InviteRole.manage.explanation
            case .write: return InviteRole.add.explanation
            case .read: return InviteRole.view.explanation
            case .none: return ""
            }
        }
        public static let level = "Can"
        public static let remove = "Remove…"
        public static func removeTitle(_ name: String) -> String { "Remove \(name)?" }
        public static func removeMessage(_ name: String, _ group: String) -> String {
            "\(name) loses \u{201C}\(group)\u{201D} on every device. What they added stays."
        }
        public static let removeButton = "Remove"
        public static let menuItem = "People…"
        public static let leave = "Leave Group…"
        public static func leaveTitle(_ group: String) -> String { "Leave \u{201C}\(group)\u{201D}?" }
        public static let leaveButton = "Leave"
        public static let invite = "Invite Someone…"
        public static let done = "Done"
        public static let cancel = "Cancel"
        /// Above the list of people on a group's page.
        public static let people = "People"
        /// The parts of the line under a group's name.
        public static let shared = "Shared"
        public static let notShared = "Not shared"
        public static func peopleCount(_ count: Int) -> String { count == 1 ? "1 person" : "\(count) people" }
        public static let madeByYou = "Made by you"
        public static func madeBy(_ name: String) -> String { "Made by \(name)" }
        /// The parts together: "Shared · 3 people · Made by you".
        public static func line(_ parts: [String]) -> String { parts.joined(separator: " \u{00B7} ") }
        public static func removed(_ name: String) -> String { "\(name) was removed." }
    }
}
