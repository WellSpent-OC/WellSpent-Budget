import Foundation
import Crypto

/// A short, readable name for a public key, for reading aloud over the phone.
///
/// 60 bits as twelve Crockford base32 characters in three groups of four. Crockford
/// leaves out I, L, O and U, so it never collides with 1, 0, or an unfortunate word.
public struct Fingerprint: Equatable, Hashable, Sendable, CustomStringConvertible {
    public let bits: Data   // 8 bytes, of which the top 60 bits are used

    static let alphabet = Array("0123456789ABCDEFGHJKMNPQRSTVWXYZ")

    public init(signing: Data, kem: Data) {
        var h = SHA256()
        h.update(data: Context.data(Context.fingerprint))
        h.update(data: signing)
        h.update(data: kem)
        bits = Data(h.finalize().prefix(8))
    }

    public var description: String {
        var value = bits.prefix(8).reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
        value >>= 4                                     // keep the top 60 bits
        var chars = [Character](repeating: "0", count: 12)
        for i in stride(from: 11, through: 0, by: -1) {
            chars[i] = Self.alphabet[Int(value & 0x1F)]
            value >>= 5
        }
        return String(chars[0..<4]) + "-" + String(chars[4..<8]) + "-" + String(chars[8..<12])
    }
}

/// The number two people compare to prove no one swapped a key on them.
///
/// Both identities go in, sorted, so both sides compute the same thing without
/// agreeing who goes first.
public struct SafetyNumber: Equatable, Sendable, CustomStringConvertible {
    public let digits: String

    public init(_ a: IdentityPublicKeys, _ b: IdentityPublicKeys) {
        let pair = [a.canonicalBytes, b.canonicalBytes].sorted { $0.lexicographicallyPrecedes($1) }
        var h = SHA256()
        h.update(data: Context.data(Context.safetyNumber))
        pair.forEach { h.update(data: $0) }
        let digest = Array(h.finalize())

        var groups: [String] = []
        for i in 0..<6 {
            let chunk = digest[(i * 4)..<(i * 4 + 4)]
            let n = chunk.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) } % 100_000
            groups.append(String(format: "%05u", n))
        }
        digits = groups.joined(separator: " ")
    }

    public var description: String { digits }
}
