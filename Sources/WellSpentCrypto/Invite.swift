import Foundation
import Crypto

/// How much of the past a new member can read.
public enum HistoryAccess: String, Codable, Sendable {
    /// Wrap the current keys. They see everything back to the beginning.
    /// Right for a spouse.
    case all
    /// Bump the epoch first, then wrap only the new keys. They cannot read
    /// anything written before they joined. Right for a business partner.
    case fromNow
}

/// What the server is told about a pending invite. Note what is absent: the
/// invite secret. The server stores a hash it cannot reverse.
public struct Invite: Codable, Sendable {
    public let id: Data                       // 16 bytes, SHA-256 of the secret
    public let scope: KeyScope
    public let level: AccessLevel
    public let historyAccess: HistoryAccess
    public let inviterUserID: UserID
    public let inviterKeys: IdentityPublicKeys
    public let expiresAt: Date

    public init(id: Data, scope: KeyScope, level: AccessLevel, historyAccess: HistoryAccess,
                inviterUserID: UserID, inviterKeys: IdentityPublicKeys, expiresAt: Date) {
        self.id = id
        self.scope = scope
        self.level = level
        self.historyAccess = historyAccess
        self.inviterUserID = inviterUserID
        self.inviterKeys = inviterKeys
        self.expiresAt = expiresAt
    }
}

/// The half that travels by iMessage and never touches the server.
public struct InviteSecret: Sendable {
    public let bytes: Data                    // 32 random bytes

    public init() {
        // SymmetricKey pulls from the system's cryptographic generator, which is
        // the same source used for every other key here.
        bytes = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
    }
    public init(bytes: Data) throws {
        guard bytes.count == 32 else { throw CryptoError.badKeyLength(expected: 32, got: bytes.count) }
        self.bytes = bytes
    }
    public var id: Data { KeyDerivation.inviteID(inviteSecret: bytes) }
}

public struct InviteAcceptance: Codable, Sendable {
    public let accepterUserID: UserID
    public let accepterKeys: IdentityPublicKeys
    public let displayName: String

    public init(accepterUserID: UserID, accepterKeys: IdentityPublicKeys, displayName: String) {
        self.accepterUserID = accepterUserID
        self.accepterKeys = accepterKeys
        self.displayName = displayName
    }
}

public struct SealedAcceptance: Codable, Sendable {
    public let inviteID: Data
    public let encapsulatedKey: Data
    public let ciphertext: Data
}

/// Invites, bound to the message you actually sent.
///
/// The problem this solves: the server hands you a public key and claims it is
/// your partner's. If the server is lying, it reads everything and neither of you
/// notices. Verification screens do not fix this, because nobody taps them.
///
/// The fix uses a fact about how people really share: the invite link goes over
/// iMessage, and the server does not control iMessage. The link carries a random
/// secret that the server never sees, and that secret becomes an HPKE pre-shared
/// key. If the sealed acceptance opens, the sender held the secret, which means it
/// is the person you texted. A server in the middle cannot forge it and cannot
/// substitute its own key.
public enum InviteCrypto {
    static func info(_ invite: Invite) -> Data {
        Context.data(Context.invitePSK) + invite.id
    }

    /// Run by the person accepting. Proves they hold the secret from the link.
    public static func sealAcceptance(
        _ acceptance: InviteAcceptance,
        invite: Invite,
        secret: InviteSecret
    ) throws -> SealedAcceptance {
        var hpke = try HPKE.Sender(
            recipientKey: try invite.inviterKeys.kemKey,
            ciphersuite: KeyWrap.suite,
            info: info(invite),
            presharedKey: KeyDerivation.invitePSK(inviteSecret: secret.bytes),
            presharedKeyIdentifier: invite.id
        )
        let ct = try hpke.seal(try JSONEncoder().encode(acceptance))
        return SealedAcceptance(inviteID: invite.id, encapsulatedKey: hpke.encapsulatedKey, ciphertext: ct)
    }

    /// Run by the inviter. A thrown error here means the acceptance did not come
    /// from whoever received the link, so do not add them.
    public static func openAcceptance(
        _ sealed: SealedAcceptance,
        invite: Invite,
        secret: InviteSecret,
        inviter: IdentityKeyPair
    ) throws -> InviteAcceptance {
        var hpke = try HPKE.Recipient(
            privateKey: inviter.kem,
            ciphersuite: KeyWrap.suite,
            info: info(invite),
            encapsulatedKey: sealed.encapsulatedKey,
            presharedKey: KeyDerivation.invitePSK(inviteSecret: secret.bytes),
            presharedKeyIdentifier: invite.id
        )
        return try JSONDecoder().decode(InviteAcceptance.self, from: try hpke.open(sealed.ciphertext))
    }
}
