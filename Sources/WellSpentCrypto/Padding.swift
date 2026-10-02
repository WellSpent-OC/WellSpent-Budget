import Foundation

/// Rounds plaintext up to a bucket before sealing.
///
/// Ciphertext length is the one thing the server always sees. Without padding it
/// leaks the length of a merchant name and whether a transaction carries a note.
/// Transactions are small, so the storage cost of rounding is close to nothing.
///
/// The smallest bucket is 1 KB. A transaction with its owner's ID is about 450
/// bytes before any merchant name or note, so a 512 byte bucket let an ordinary
/// note push one record into the next size up, which is exactly the leak this
/// exists to stop. 1 KB a transaction is about 1 MB per thousand.
public enum Padding {
    static let smallBuckets = [1024, 2048, 4096]
    static let step = 4096
    static let lengthPrefix = 4
    public static let maxPayload = Int(UInt32.max)

    public static func bucket(for size: Int) -> Int {
        if let b = smallBuckets.first(where: { $0 >= size }) { return b }
        return ((size + step - 1) / step) * step
    }

    /// `UInt32 big-endian length || plaintext || zeros`
    public static func pad(_ plaintext: Data) throws -> Data {
        guard plaintext.count <= maxPayload else {
            throw CryptoError.payloadTooLarge(limit: maxPayload, got: plaintext.count)
        }
        var out = Data(capacity: bucket(for: plaintext.count + lengthPrefix))
        withUnsafeBytes(of: UInt32(plaintext.count).bigEndian) { out.append(contentsOf: $0) }
        out.append(plaintext)
        out.append(Data(repeating: 0, count: bucket(for: out.count) - out.count))
        return out
    }

    public static func unpad(_ padded: Data) throws -> Data {
        guard padded.count >= lengthPrefix else {
            throw CryptoError.paddingCorrupt(reason: "shorter than the length prefix")
        }
        let p = Data(padded)
        let length = p.prefix(lengthPrefix).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        let end = lengthPrefix + Int(length)
        guard end <= p.count else {
            throw CryptoError.paddingCorrupt(reason: "length \(length) runs past the \(p.count) bytes present")
        }
        return p.subdata(in: lengthPrefix ..< end)
    }
}

/// Receipt images and PDFs. Coarser buckets, because exact blob sizes fingerprint
/// a known document byte for byte.
public enum BlobPadding {
    public static func bucket(for size: Int) -> Int {
        let small = 64 * 1024, large = 256 * 1024, threshold = 1024 * 1024
        let unit = size <= threshold ? small : large
        return ((size + unit - 1) / unit) * unit
    }
}
