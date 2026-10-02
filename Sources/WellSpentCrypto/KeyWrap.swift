import Foundation
import Crypto

/// How a key reaches someone else.
public enum WrapKind: UInt8, Codable, Sendable {
    /// Sealed to one person's X25519 key. Used for group keys, and for a single
    /// budget shared on its own.
    case hpkeToIdentity = 1
    /// Sealed under the group key. Used for the budget keys inside a group.
    case aesUnderGroupKey = 2
}

/// Names the ciphersuite in every wrapped key and every envelope.
///
/// One byte, and it is the entire migration path. `XWingMLKEM768X25519` is already
/// sitting in swift-crypto 5 and macOS 26 for when X25519 stops being enough.
public enum CiphersuiteID: UInt8, Codable, Sendable {
    case curve25519_chachaPoly_aesgcm256 = 1
}

public struct WrappedKey: Codable, Sendable {
    public let scope: KeyScope
    public let epoch: Epoch
    public let wrapKind: WrapKind
    public let ciphersuite: CiphersuiteID
    public let recipientUserID: UserID?     // nil for aesUnderGroupKey
    public let senderUserID: UserID
    public let encapsulatedKey: Data?       // nil for aesUnderGroupKey
    public let nonce: Data?                 // used for aesUnderGroupKey
    public let ciphertext: Data

    public init(scope: KeyScope, epoch: Epoch, wrapKind: WrapKind, ciphersuite: CiphersuiteID,
                recipientUserID: UserID?, senderUserID: UserID, encapsulatedKey: Data?,
                nonce: Data?, ciphertext: Data) {
        self.scope = scope
        self.epoch = epoch
        self.wrapKind = wrapKind
        self.ciphersuite = ciphersuite
        self.recipientUserID = recipientUserID
        self.senderUserID = senderUserID
        self.encapsulatedKey = encapsulatedKey
        self.nonce = nonce
        self.ciphertext = ciphertext
    }
}

public enum KeyWrap {
    public static let suite = HPKE.Ciphersuite.Curve25519_SHA256_ChachaPoly

    static func info(for scope: KeyScope, epoch: Epoch) -> Data {
        switch scope {
        case .group(let id):
            return Context.data(Context.groupWrap) + id.bytes + withUnsafeBytes(of: epoch.value.bigEndian) { Data($0) }
        case .budget(let id):
            return Context.data(Context.budgetWrap) + id.bytes + withUnsafeBytes(of: epoch.value.bigEndian) { Data($0) }
        }
    }

    /// Seal a key to one person, in HPKE auth mode.
    ///
    /// Auth mode mixes the sender's own private key into the derivation, so the
    /// recipient learns who wrapped this without a second signature to verify.
    public static func wrapToIdentity(
        _ key: ScopedKey,
        recipient: IdentityPublicKeys,
        recipientUserID: UserID,
        sender: IdentityKeyPair,
        senderUserID: UserID
    ) throws -> WrappedKey {
        var hpke = try HPKE.Sender(
            recipientKey: try recipient.kemKey,
            ciphersuite: suite,
            info: info(for: key.scope, epoch: key.epoch),
            authenticatedBy: sender.kem
        )
        let ct = try hpke.seal(key.rawBytes)
        return WrappedKey(
            scope: key.scope, epoch: key.epoch,
            wrapKind: .hpkeToIdentity, ciphersuite: .curve25519_chachaPoly_aesgcm256,
            recipientUserID: recipientUserID, senderUserID: senderUserID,
            encapsulatedKey: hpke.encapsulatedKey, nonce: nil, ciphertext: ct
        )
    }

    public static func unwrapToIdentity(
        _ wrapped: WrappedKey,
        recipient: IdentityKeyPair,
        sender: IdentityPublicKeys
    ) throws -> ScopedKey {
        guard let enc = wrapped.encapsulatedKey else {
            throw CryptoError.badKeyLength(expected: 32, got: 0)
        }
        var hpke = try HPKE.Recipient(
            privateKey: recipient.kem,
            ciphersuite: suite,
            info: info(for: wrapped.scope, epoch: wrapped.epoch),
            encapsulatedKey: enc,
            authenticatedBy: try sender.kemKey
        )
        let raw = try hpke.open(wrapped.ciphertext)
        return ScopedKey(scope: wrapped.scope, epoch: wrapped.epoch, material: SymmetricKey(data: raw))
    }

    /// Seal a budget key under its group key, so joining a group brings every
    /// budget in it along without a wrap per member per budget.
    public static func wrapUnderGroupKey(
        _ key: ScopedKey,
        groupKey: SymmetricKey,
        senderUserID: UserID
    ) throws -> WrappedKey {
        let box = try AES.GCM.seal(key.rawBytes, using: groupKey, nonce: AES.GCM.Nonce(),
                                   authenticating: info(for: key.scope, epoch: key.epoch))
        return WrappedKey(
            scope: key.scope, epoch: key.epoch,
            wrapKind: .aesUnderGroupKey, ciphersuite: .curve25519_chachaPoly_aesgcm256,
            recipientUserID: nil, senderUserID: senderUserID,
            encapsulatedKey: nil, nonce: Data(box.nonce), ciphertext: box.ciphertext + box.tag
        )
    }

    public static func unwrapUnderGroupKey(_ wrapped: WrappedKey, groupKey: SymmetricKey) throws -> ScopedKey {
        guard let nonce = wrapped.nonce else {
            throw CryptoError.nonceWrongSize(expected: RecordSeal.nonceSize, got: 0)
        }
        let box = try AES.GCM.SealedBox(combined: nonce + wrapped.ciphertext)
        let raw = try AES.GCM.open(box, using: groupKey,
                                   authenticating: info(for: wrapped.scope, epoch: wrapped.epoch))
        return ScopedKey(scope: wrapped.scope, epoch: wrapped.epoch, material: SymmetricKey(data: raw))
    }
}
