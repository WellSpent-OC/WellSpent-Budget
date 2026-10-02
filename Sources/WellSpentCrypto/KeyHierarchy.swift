import Foundation
import Crypto

/// A symmetric key, tagged with what it protects and which generation it belongs to.
public struct ScopedKey: Sendable {
    public let scope: KeyScope
    public let epoch: Epoch
    public let material: SymmetricKey

    public init(scope: KeyScope, epoch: Epoch, material: SymmetricKey) {
        self.scope = scope
        self.epoch = epoch
        self.material = material
    }

    public static func generate(scope: KeyScope, epoch: Epoch = .initial) -> ScopedKey {
        ScopedKey(scope: scope, epoch: epoch, material: SymmetricKey(size: .bits256))
    }

    public var rawBytes: Data { material.withUnsafeBytes { Data($0) } }
}

public enum KeyDerivation {
    /// Per-record key, derived rather than stored.
    ///
    /// Storing a wrapped key per record would mean a row per transaction that
    /// exists only to hold 32 bytes. Deriving costs nothing and keeps a nonce
    /// mistake contained to a single record.
    public static func contentKey(scopeKey: SymmetricKey, recordID: RecordID) -> SymmetricKey {
        HKDF<SHA256>.deriveKey(
            inputKeyMaterial: scopeKey,
            salt: recordID.bytes,
            info: Context.data(Context.recordKey),
            outputByteCount: 32
        )
    }

    /// Key that protects the bytes of one receipt image or PDF.
    public static func blobKey(scopeKey: SymmetricKey, blobID: RecordID) -> SymmetricKey {
        HKDF<SHA256>.deriveKey(
            inputKeyMaterial: scopeKey,
            salt: blobID.bytes,
            info: Context.data(Context.blobKey),
            outputByteCount: 32
        )
    }

    /// Turns the twelve-word recovery code into the key that opens the escrow blob.
    ///
    /// HKDF, not scrypt, and the reason matters. A slow memory-hard function exists
    /// to make guessing a human-chosen password expensive. This input is 128 bits
    /// straight from the system generator, so there is nothing to guess. Scrypt here
    /// would only make legitimate recovery slower.
    public static func recoveryKey(entropy: Data) -> SymmetricKey {
        HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: entropy),
            info: Context.data(Context.recovery),
            outputByteCount: 32
        )
    }

    /// Binds an invite to the message you sent through iMessage.
    public static func invitePSK(inviteSecret: Data) -> SymmetricKey {
        HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: inviteSecret),
            info: Context.data(Context.invitePSK),
            outputByteCount: 32
        )
    }

    /// The public half of an invite. The server stores this and cannot reverse it.
    public static func inviteID(inviteSecret: Data) -> Data {
        var h = SHA256()
        h.update(data: Context.data(Context.inviteID))
        h.update(data: inviteSecret)
        return Data(h.finalize().prefix(16))
    }
}
