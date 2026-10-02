import Foundation
import Crypto

/// The public half of a person, as everyone else sees them.
public struct IdentityPublicKeys: Codable, Hashable, Sendable {
    public let signing: Data    // Ed25519, 32 bytes
    public let kem: Data        // X25519, 32 bytes

    public init(signing: Data, kem: Data) throws {
        guard signing.count == 32 else { throw CryptoError.badKeyLength(expected: 32, got: signing.count) }
        guard kem.count == 32 else { throw CryptoError.badKeyLength(expected: 32, got: kem.count) }
        self.signing = signing
        self.kem = kem
    }

    public var canonicalBytes: Data { signing + kem }
    public var fingerprint: Fingerprint { Fingerprint(signing: signing, kem: kem) }

    public var signingKey: Curve25519.Signing.PublicKey {
        get throws { try .init(rawRepresentation: signing) }
    }
    public var kemKey: Curve25519.KeyAgreement.PublicKey {
        get throws { try .init(rawRepresentation: kem) }
    }
}

/// A person's long-lived keys. These travel between that person's own devices,
/// which is exactly why they cannot live in the Secure Enclave: nothing in the
/// Enclave can be exported, and the iPhone needs this same key.
public struct IdentityKeyPair: Sendable {
    public let signing: Curve25519.Signing.PrivateKey
    public let kem: Curve25519.KeyAgreement.PrivateKey

    public init(signing: Curve25519.Signing.PrivateKey, kem: Curve25519.KeyAgreement.PrivateKey) {
        self.signing = signing
        self.kem = kem
    }

    public static func generate() -> IdentityKeyPair {
        IdentityKeyPair(signing: .init(), kem: .init())
    }

    public var publicKeys: IdentityPublicKeys {
        // Force-try is safe: CryptoKit always hands back 32 raw bytes for these curves.
        try! IdentityPublicKeys(signing: signing.publicKey.rawRepresentation,
                                kem: kem.publicKey.rawRepresentation)
    }

    /// Exactly the bytes the recovery code protects, and nothing else.
    ///
    /// Every group key and budget key already sits on the server, sealed to the
    /// X25519 key below. Restore these 64 bytes and the rest follows.
    public var escrowBytes: Data {
        signing.rawRepresentation + kem.rawRepresentation
    }

    public init(escrowBytes: Data) throws {
        guard escrowBytes.count == 64 else {
            throw CryptoError.badKeyLength(expected: 64, got: escrowBytes.count)
        }
        signing = try .init(rawRepresentation: escrowBytes.prefix(32))
        kem = try .init(rawRepresentation: escrowBytes.suffix(32))
    }
}

/// One device, one signing key, never exported.
///
/// Every record envelope is signed with this, so a stolen device can be cut off by
/// name without touching the identity key.
public struct DeviceKeyPair: Sendable {
    public let id: DeviceID
    public let signing: Curve25519.Signing.PrivateKey

    public init(id: DeviceID = DeviceID(), signing: Curve25519.Signing.PrivateKey = .init()) {
        self.id = id
        self.signing = signing
    }
    public var publicKey: Data { signing.publicKey.rawRepresentation }
}
