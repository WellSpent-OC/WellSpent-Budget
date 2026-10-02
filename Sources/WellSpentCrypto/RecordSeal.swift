import Foundation
import Crypto

/// Sealing and opening one record. AES-GCM, because both target platforms have
/// AES in hardware. ChaCha20-Poly1305 appears elsewhere only because it is what
/// the standard Curve25519 HPKE suite specifies.
public enum RecordSeal {
    public static let nonceSize = 12

    public struct Sealed: Codable, Hashable, Sendable {
        public let nonce: Data
        public let ciphertext: Data      // ciphertext with the authentication tag appended
        public init(nonce: Data, ciphertext: Data) {
            self.nonce = nonce
            self.ciphertext = ciphertext
        }
    }

    /// The nonce is fresh and random on every call even though the content key is
    /// already unique per record. Two devices can then edit offline without
    /// coordinating, which is the whole point of a local-first app.
    public static func seal(_ plaintext: Data, scopeKey: SymmetricKey, recordID: RecordID) throws -> Sealed {
        let key = KeyDerivation.contentKey(scopeKey: scopeKey, recordID: recordID)
        let box = try AES.GCM.seal(try Padding.pad(plaintext), using: key, nonce: AES.GCM.Nonce())
        return Sealed(nonce: Data(box.nonce), ciphertext: box.ciphertext + box.tag)
    }

    public static func open(_ sealed: Sealed, scopeKey: SymmetricKey, recordID: RecordID) throws -> Data {
        guard sealed.nonce.count == nonceSize else {
            throw CryptoError.nonceWrongSize(expected: nonceSize, got: sealed.nonce.count)
        }
        let key = KeyDerivation.contentKey(scopeKey: scopeKey, recordID: recordID)
        let box = try AES.GCM.SealedBox(combined: sealed.nonce + sealed.ciphertext)
        return try Padding.unpad(try AES.GCM.open(box, using: key))
    }
}
