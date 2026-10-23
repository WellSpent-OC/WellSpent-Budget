import Foundation
import WellSpentCrypto

// What readable sync sends and receives. Each type matches one the server
// defines in `Server/Sources/WellSpentServerCore`, named beside it.

/// One record as the server stores it. Matches `SyncRecordV2`.
public struct WireRecord: Codable, Sendable, Equatable {
    public let id: RecordID
    public let type: RecordType
    /// The budget the record belongs to; a budget names itself. Nil for
    /// records that belong to the whole group.
    public let budgetID: BudgetID?
    public let lamport: UInt64
    /// The device that wrote this version. Breaks ties between equal Lamport values.
    public let clientID: DeviceID
    public let isDeleted: Bool
    /// The record as JSON, in `RecordCodec`'s encoding.
    public let body: String
    /// Set by the server on pull, and ignored by it on push.
    public var createdBy: UserID?
    public var updatedBy: UserID?
    public var serverSeq: UInt64?

    public init(id: RecordID, type: RecordType, budgetID: BudgetID?, lamport: UInt64, clientID: DeviceID,
                isDeleted: Bool, body: String, createdBy: UserID? = nil, updatedBy: UserID? = nil,
                serverSeq: UInt64? = nil) {
        self.id = id
        self.type = type
        self.budgetID = budgetID
        self.lamport = lamport
        self.clientID = clientID
        self.isDeleted = isDeleted
        self.body = body
        self.createdBy = createdBy
        self.updatedBy = updatedBy
        self.serverSeq = serverSeq
    }
}

/// One page of a group's records, in server order. Matches `PullV2Response`.
public struct ReadablePull: Sendable, Equatable {
    public let records: [WireRecord]
    /// Where the next pull starts.
    public let serverSeq: UInt64
    public let hasMore: Bool

    public init(records: [WireRecord], serverSeq: UInt64, hasMore: Bool) {
        self.records = records
        self.serverSeq = serverSeq
        self.hasMore = hasMore
    }
}

/// A group this account belongs to. Matches `GroupResponse`.
public struct ServerGroup: Sendable, Equatable {
    public let id: GroupID
    public let founderID: UserID
    public let level: AccessLevel
    /// Empty until the founder has moved the group to readable sync. Never
    /// fingerprint with an empty key.
    public let importKey: Data
    /// The first server sequence this person may see. Zero for full history.
    public let historyFloor: UInt64
    public let deleted: Bool

    public init(id: GroupID, founderID: UserID, level: AccessLevel, importKey: Data,
                historyFloor: UInt64, deleted: Bool) {
        self.id = id
        self.founderID = founderID
        self.level = level
        self.importKey = importKey
        self.historyFloor = historyFloor
        self.deleted = deleted
    }
}

/// Someone in a group. Matches `MemberResponse`.
public struct ServerMember: Sendable, Equatable {
    public let userID: UserID
    public let level: AccessLevel

    public init(userID: UserID, level: AccessLevel) {
        self.userID = userID
        self.level = level
    }
}

/// A signed-in device. Matches `SessionResponse`. Saved in the key store
/// under `.session`.
///
/// The server renews a session that is in use, at most once a day, and
/// never sends the new expiry back. So `expiresAt` is only what it was at
/// sign-in: never sign out because it has passed. The server says when a
/// session has ended.
public struct ServerSession: Codable, Sendable, Equatable {
    public let userID: UserID
    public let token: String
    public let expiresAt: Date
    public let emailVerified: Bool

    public init(userID: UserID, token: String, expiresAt: Date, emailVerified: Bool) {
        self.userID = userID
        self.token = token
        self.expiresAt = expiresAt
        self.emailVerified = emailVerified
    }
}

/// The signed-in account. Matches `MeResponse`.
public struct Me: Codable, Sendable, Equatable {
    public let userID: UserID
    public let email: String
    public let emailVerified: Bool

    public init(userID: UserID, email: String, emailVerified: Bool) {
        self.userID = userID
        self.email = email
        self.emailVerified = emailVerified
    }
}

/// One device signed in to the account. Matches `SessionInfo`.
public struct DeviceSession: Codable, Sendable, Equatable {
    public let id: UUID
    public let deviceLabel: String?
    public let createdAt: Date?
    public let lastUsedAt: Date
    /// The session this device is using.
    public let current: Bool

    public init(id: UUID, deviceLabel: String?, createdAt: Date?, lastUsedAt: Date, current: Bool) {
        self.id = id
        self.deviceLabel = deviceLabel
        self.createdAt = createdAt
        self.lastUsedAt = lastUsedAt
        self.current = current
    }
}

/// An invite just made. The token is shown once, in the link. Matches
/// `InviteCreatedResponse`.
public struct CreatedInvite: Sendable, Equatable {
    public let id: UUID
    public let token: String
    public let expiresAt: Date

    public init(id: UUID, token: String, expiresAt: Date) {
        self.id = id
        self.token = token
        self.expiresAt = expiresAt
    }
}

/// What an invite link offers, shown before joining. Matches `InvitePreview`.
public struct InviteTerms: Sendable, Equatable {
    public let groupID: GroupID
    public let level: AccessLevel
    public let history: HistoryAccess
    public let expiresAt: Date
    public let invitationID: UUID?
    public let inviteeName: String?

    public init(groupID: GroupID, level: AccessLevel, history: HistoryAccess, expiresAt: Date,
                invitationID: UUID? = nil, inviteeName: String? = nil) {
        self.groupID = groupID
        self.level = level
        self.history = history
        self.expiresAt = expiresAt
        self.invitationID = invitationID
        self.inviteeName = inviteeName
    }
}

/// An invite not yet accepted. Matches `InviteInfo`.
public struct ServerInvite: Identifiable, Sendable, Equatable {
    public let id: UUID
    public let level: AccessLevel
    public let history: HistoryAccess
    public let expiresAt: Date
    public let inviterID: UserID
    public let email: String?
    public let inviteeName: String?
    public let inviterName: String?
    public let status: String

    public init(id: UUID, level: AccessLevel, history: HistoryAccess, expiresAt: Date, inviterID: UserID,
                email: String? = nil, inviteeName: String? = nil, inviterName: String? = nil,
                status: String = "pending") {
        self.id = id
        self.level = level
        self.history = history
        self.expiresAt = expiresAt
        self.inviterID = inviterID
        self.email = email
        self.inviteeName = inviteeName
        self.inviterName = inviterName
        self.status = status
    }
}

/// A sent email invitation. Its bearer token is never returned to the sender.
public struct SentEmailInvite: Sendable, Equatable {
    public let id: UUID
    public let expiresAt: Date

    public init(id: UUID, expiresAt: Date) {
        self.id = id
        self.expiresAt = expiresAt
    }
}

/// An invitation addressed to the signed-in account, before membership exists.
public struct IncomingInvitation: Identifiable, Sendable, Equatable {
    public let id: UUID
    public let groupID: GroupID
    public let groupName: String
    public let inviterName: String
    public let inviteeName: String
    public let level: AccessLevel
    public let history: HistoryAccess
    public let expiresAt: Date

    public init(id: UUID, groupID: GroupID, groupName: String, inviterName: String,
                inviteeName: String, level: AccessLevel, history: HistoryAccess, expiresAt: Date) {
        self.id = id
        self.groupID = groupID
        self.groupName = groupName
        self.inviterName = inviterName
        self.inviteeName = inviteeName
        self.level = level
        self.history = history
        self.expiresAt = expiresAt
    }
}

/// Why a call to the readable server failed, where the app must tell the
/// cases apart.
public enum ReadableTransportError: Error, Equatable, Sendable {
    /// This device's session is over: signed out elsewhere, the password
    /// changed, or never signed in. The only failure that signs the device out.
    case sessionEnded(String)
    /// Signing in: the email or the password is wrong.
    case badCredentials
    /// Changing the password: the current one is wrong. The session is fine.
    case wrongCurrentPassword
    /// The server has no readable sync yet.
    case serverNotUpdated
    /// A legacy server created a link instead of delivering an email.
    case emailInvitationsNotSupported
    case http(status: Int, reason: String)
    case malformed(String)
}

extension AccessLevel {
    /// A level as the server sends it. A rung this build does not know is
    /// taken as the nearest one below it, never above, and never as
    /// superadmin, which only ever means itself.
    public init(serverValue raw: Int) {
        if let known = AccessLevel(rawValue: raw) {
            self = known
        } else {
            self = AccessLevel.allCases.filter { $0 != .superadmin && $0.rawValue < raw }.max() ?? .none
        }
    }
}

extension HistoryAccess {
    /// A history setting as the server sends it. One this build does not know
    /// is taken as the narrower one.
    public init(serverValue raw: String) {
        self = HistoryAccess(rawValue: raw) ?? .fromNow
    }
}

extension InviteLink {
    /// A link carrying a readable invite, of the type of the build making it.
    /// The server's token is 32 random bytes in URL-safe base64, the same
    /// shape as the sealed app's secret, so links look and parse as they
    /// always have.
    public init?(token: String, groupName: String, inviterName: String, scheme: String) {
        guard let secret = Data(base64URL: token), secret.count == 32 else { return nil }
        self.init(secret: secret, groupName: groupName, inviterName: inviterName, scheme: scheme)
    }

    /// The readable invite token this link carries.
    public var token: String { secret.base64URL }
}
