import Foundation
import WellSpentCrypto

/// The server calls sharing needs, beyond syncing.
///
/// The server never sees an invite's secret. It stores a hash of it, hands the
/// invite's terms to whoever presents that hash, and holds the sealed answer
/// until the inviter's app collects it.
public protocol InviteTransport: SyncTransport {
    func appendMembership(_ entry: MembershipLogEntry, group: GroupID,
                          wrappedKeys: [WrappedKey]) async throws
    func createInvite(_ invite: NewInvite) async throws
    func lookupInvite(id: Data) async throws -> InviteLookup
    func acceptInvite(id: Data, sealed: SealedAcceptance) async throws
    func invites(in group: GroupID) async throws -> [PendingInvite]
    func deleteInvite(id: Data) async throws
    /// Budget keys sealed under the group key, for a budget added to a group
    /// that is already shared.
    func uploadKeys(_ keys: [WrappedKey], group: GroupID) async throws
}

/// What the inviter tells the server. The secret is not in here.
public struct NewInvite: Sendable, Equatable {
    public let id: Data
    public let group: GroupID
    public let level: AccessLevel
    public let historyAccess: HistoryAccess
    public let expiresAt: Date

    public init(id: Data, group: GroupID, level: AccessLevel, historyAccess: HistoryAccess,
                expiresAt: Date) {
        self.id = id
        self.group = group
        self.level = level
        self.historyAccess = historyAccess
        self.expiresAt = expiresAt
    }
}

/// What the server tells the person holding the link.
public struct InviteLookup: Sendable, Equatable {
    public let group: GroupID
    public let level: AccessLevel
    public let historyAccess: HistoryAccess
    public let inviterUserID: UserID
    public let inviterKeys: IdentityPublicKeys
    public let expiresAt: Date

    public init(group: GroupID, level: AccessLevel, historyAccess: HistoryAccess,
                inviterUserID: UserID, inviterKeys: IdentityPublicKeys, expiresAt: Date) {
        self.group = group
        self.level = level
        self.historyAccess = historyAccess
        self.inviterUserID = inviterUserID
        self.inviterKeys = inviterKeys
        self.expiresAt = expiresAt
    }

    func invite(id: Data) -> Invite {
        Invite(id: id, scope: .group(group), level: level, historyAccess: historyAccess,
               inviterUserID: inviterUserID, inviterKeys: inviterKeys, expiresAt: expiresAt)
    }
}

/// One of a group's open invites, as its inviter sees it.
public struct PendingInvite: Sendable {
    public let id: Data
    public let level: AccessLevel
    public let historyAccess: HistoryAccess
    public let expiresAt: Date
    /// Still sealed. Nil until the person answers.
    public let acceptance: SealedAcceptance?

    public init(id: Data, level: AccessLevel, historyAccess: HistoryAccess, expiresAt: Date,
                acceptance: SealedAcceptance?) {
        self.id = id
        self.level = level
        self.historyAccess = historyAccess
        self.expiresAt = expiresAt
        self.acceptance = acceptance
    }
}

/// The link that travels by text or email.
///
/// The secret is the part that matters: it never goes to the server, and an
/// answer sealed with it proves it came from whoever got the link. The group
/// and inviter names ride along so the person joining knows what they are
/// joining before anything is decrypted. They are not trusted for anything:
/// the real group name arrives, encrypted, once they are in.
public struct InviteLink: Sendable, Equatable {
    public static let scheme = "wellspent"

    public let secret: Data
    public let groupName: String
    public let inviterName: String

    public init(secret: Data, groupName: String, inviterName: String) {
        self.secret = secret
        self.groupName = groupName
        self.inviterName = inviterName
    }

    /// `wellspent://join#s=<secret>&g=<group>&f=<inviter>`. In the fragment, so a
    /// browser that opens it never sends any of it to a server.
    public var url: String {
        var components = URLComponents()
        components.queryItems = [
            URLQueryItem(name: "s", value: secret.base64URL),
            URLQueryItem(name: "g", value: groupName),
            URLQueryItem(name: "f", value: inviterName),
        ]
        return "\(Self.scheme)://join#" + (components.percentEncodedQuery ?? "")
    }

    /// Reads a pasted link. Forgiving about spaces and line breaks a message app
    /// may have added around it, strict about everything else.
    public init?(parsing text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("\(Self.scheme)://join#") else { return nil }
        let fragment = String(trimmed.dropFirst("\(Self.scheme)://join#".count))
        var components = URLComponents()
        components.percentEncodedQuery = fragment
        let items = components.queryItems ?? []
        func value(_ name: String) -> String? { items.first { $0.name == name }?.value }
        guard let secret = value("s").flatMap(Data.init(base64URL:)), secret.count == 32 else {
            return nil
        }
        self.init(secret: secret, groupName: value("g") ?? "", inviterName: value("f") ?? "")
    }
}

extension Data {
    var base64URL: String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    init?(base64URL text: String) {
        var base64 = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        self.init(base64Encoded: base64)
    }

    var hexString: String { map { String(format: "%02x", $0) }.joined() }
}
