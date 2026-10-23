import Foundation
import Observation
import WellSpentCrypto
import WellSpentSync

@MainActor
public protocol EmailInvitationActions: SharingActions {
    func sendEmailInvitation(group: GroupID, groupName: String, email: String, inviteeName: String,
                             myName: String, level: AccessLevel, history: HistoryAccess) async throws -> SentEmailInvite
    func acceptInvitation(_ invitation: IncomingInvitation) async throws -> GroupID
}

/// The same email form on every platform. Legacy links still use ShareScreen.
@MainActor
@Observable
public final class EmailInviteScreen {
    public let group: GroupID
    public let groupName: String
    public var email = ""
    public var inviteeName = ""
    public var myName: String
    public var role: InviteRole
    public var history: HistoryAccess = .all
    public private(set) var sent: SentEmailInvite?
    public private(set) var failure: String?
    public private(set) var isWorking = false
    private var sentEmail: String?
    private let actions: any EmailInvitationActions

    public init(actions: any EmailInvitationActions, group: GroupID, groupName: String) {
        self.actions = actions
        self.group = group
        self.groupName = groupName
        myName = (try? actions.displayName(in: group)) ?? ""
        let allowed = ShareScreen.roles(holding: actions.myLevel(in: group))
        role = allowed.contains(.add) ? .add : (allowed.first ?? .add)
    }

    public var title: String { "Invite someone to \u{201C}\(groupName)\u{201D}" }
    public var roles: [InviteRole] { ShareScreen.roles(holding: actions.myLevel(in: group)) }
    public var notice: String? {
        if actions.account == nil { return ShareScreen.Words.signInToShare }
        if !actions.emailVerified { return "Confirm your email before inviting someone." }
        if roles.isEmpty { return ShareScreen.Words.cannotInvite }
        for name in [myName, inviteeName] where !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            if Self.validName(name) == nil { return Words.nameProblem }
        }
        return nil
    }
    public var canSend: Bool {
        let address = SyncCoordinator.normalised(email: email)
        return !isWorking && sent == nil && notice == nil && roles.contains(role)
            && AccountRules.normalisedEmail(address) != nil
            && Self.validName(myName) != nil && Self.validName(inviteeName) != nil
    }

    /// The same trimmed 1...50 character rule as the server, including
    /// invisible control and format characters.
    public static func validName(_ raw: String) -> String? {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 50,
              !name.unicodeScalars.contains(where: {
                  $0.properties.generalCategory == .control || $0.properties.generalCategory == .format
              }) else { return nil }
        return name
    }
    public var sendLabel: String { isWorking ? Words.sending : Words.send }
    public var note: String { Words.note }
    public var sentMessage: String? {
        guard sent != nil, let sentEmail else { return nil }
        return "Invitation sent to \(sentEmail). It stays Pending until they accept or reject it."
    }

    @discardableResult
    public func send() async -> Bool {
        guard canSend else { return false }
        failure = nil
        isWorking = true
        defer { isWorking = false }
        do {
            let recipient = SyncCoordinator.normalised(email: email)
            let made = try await actions.sendEmailInvitation(group: group, groupName: groupName, email: recipient,
                inviteeName: inviteeName, myName: myName, level: role.level, history: history)
            sentEmail = recipient
            sent = made
            return true
        } catch is CancellationError {
            return false
        } catch {
            failure = AccountWording.words(for: error)
            return false
        }
    }

    public enum Words {
        public static let email = "Their email"
        public static let emailPrompt = "name@example.com"
        public static let inviteeName = "Their name"
        public static let inviteeNamePrompt = "How the group will see them"
        public static let name = ShareScreen.Words.name
        public static let namePrompt = ShareScreen.Words.namePrompt
        public static let role = ShareScreen.Words.role
        public static let history = ShareScreen.Words.history
        public static let historyAll = ShareScreen.Words.historyAll
        public static let historyFromNow = ShareScreen.Words.historyFromNow
        public static let cancel = ShareScreen.Words.cancel
        public static let done = ShareScreen.Words.done
        public static let send = "Send Invite"
        public static let sending = "Sending…"
        public static let sent = "Invitation sent"
        public static let note = "WellSpent emails the invitation. They can accept or reject it in their group list."
        public static let nameProblem = "Names must have 1 to 50 characters and no control characters."
    }
}

public enum EmailInvitationWords {
    public static let incomingTitle = "Invitations"
    public static let invited = "Invited"
    public static let accept = "Accept"
    public static let reject = "Reject"
    public static let pending = "Pending"
    public static let rejected = "Rejected"
    public static let cancelInvite = "Cancel Invite"
    public static let rejectMessage = "This invitation will close. To join later, ask for a new invitation."
    public static let cancelMessage = "They will no longer be able to accept this invitation. You can send a new one later."
    public static func from(_ name: String) -> String { "Invited by \(name)" }
    public static func rejectQuestion(_ groupName: String) -> String { "Reject the invitation to \u{201C}\(groupName)\u{201D}?" }
    public static func cancelQuestion(_ recipient: String) -> String { "Cancel the invitation to \(recipient)?" }
    public static func recipient(_ invitation: ServerInvite) -> String {
        invitation.inviteeName ?? invitation.email ?? "Someone"
    }
    public static func status(_ invitation: ServerInvite) -> String {
        invitation.status == "rejected" ? rejected : pending
    }
    public static func terms(_ invitation: IncomingInvitation) -> String {
        "\(MembersScreen.Words.levelTitle(invitation.level)) · \(JoinScreen.Words.sees(invitation.history))"
    }
}
