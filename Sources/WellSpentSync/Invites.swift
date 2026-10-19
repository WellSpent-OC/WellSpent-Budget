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
    /// Each build's link type. A computer opens a link in whichever app claims
    /// its type, so the live and staging builds each have their own: a link
    /// opened in the other build would reach a server that has never heard of
    /// the invite. Live keeps the type links have always had, so links already
    /// sent still open it. `AppEnvironment.inviteScheme` says which build has
    /// which.
    public static let liveScheme = "wellspent"
    public static let stagingScheme = "wellspent-staging"
    static let schemes = [liveScheme, stagingScheme]

    /// The link's type, which says the build that made it.
    public let scheme: String
    public let secret: Data
    public let groupName: String
    public let inviterName: String

    public init(secret: Data, groupName: String, inviterName: String, scheme: String) {
        self.secret = secret
        self.groupName = groupName
        self.inviterName = inviterName
        self.scheme = scheme
    }

    /// `wellspent://join#s=<secret>&g=<group>&f=<inviter>`, with the link's own
    /// type in front. In the fragment, so a browser that opens it never sends
    /// any of it to a server.
    public var url: String {
        var components = URLComponents()
        components.queryItems = [
            URLQueryItem(name: "s", value: secret.base64URL),
            URLQueryItem(name: "g", value: groupName),
            URLQueryItem(name: "f", value: inviterName),
        ]
        return "\(scheme)://join#" + (components.percentEncodedQuery ?? "")
    }

    /// Reads a pasted link of either build's type. Forgiving about spaces and
    /// line breaks a message app may have added around it, strict about
    /// everything else.
    public init?(parsing text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let scheme = Self.schemes.first(where: { trimmed.hasPrefix("\($0)://join#") }) else { return nil }
        let fragment = String(trimmed.dropFirst("\(scheme)://join#".count))
        // Foundation stops the whole app on a fragment that is not valid
        // percent-encoding, such as a link typed or pasted halfway through
        // ("...g=Vegas%"). So the fragment is checked first, and anything that
        // would not survive the setter is simply not a link.
        guard fragment.removingPercentEncoding != nil,
              fragment.unicodeScalars.allSatisfy({ CharacterSet.urlQueryAllowed.contains($0) || $0 == "%" })
        else { return nil }
        var components = URLComponents()
        components.percentEncodedQuery = fragment
        let items = components.queryItems ?? []
        func value(_ name: String) -> String? { items.first { $0.name == name }?.value }
        guard let secret = value("s").flatMap(Data.init(base64URL:)), secret.count == 32 else {
            return nil
        }
        self.init(secret: secret, groupName: value("g") ?? "", inviterName: value("f") ?? "", scheme: scheme)
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
