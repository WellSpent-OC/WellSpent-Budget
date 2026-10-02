import Foundation

/// Deterministic bytes for anything that gets signed or hashed.
///
/// Signatures need one exact byte sequence that both sides produce identically.
/// `JSONEncoder` looks like it would do, and it will not: key order, number
/// formatting and date encoding have all changed between Foundation versions, and
/// Foundation on Linux is a different implementation again. A signature that
/// verifies on your Mac and fails on the Linux box is a miserable bug to find.
///
/// So every field is written explicitly, length-prefixed. Length prefixes matter:
/// without them `"ab" + "c"` and `"a" + "bc"` produce the same bytes, and an
/// attacker gets to move a boundary without breaking the signature.
public struct CanonicalWriter {
    private(set) public var bytes = Data()

    public init() {}

    public mutating func write(_ value: UInt8)  { bytes.append(value) }
    public mutating func write(_ value: UInt32) { withUnsafeBytes(of: value.bigEndian) { bytes.append(contentsOf: $0) } }
    public mutating func write(_ value: UInt64) { withUnsafeBytes(of: value.bigEndian) { bytes.append(contentsOf: $0) } }
    public mutating func write(_ value: Bool)   { bytes.append(value ? 1 : 0) }

    /// Length-prefixed, so field boundaries cannot be shifted.
    public mutating func write(_ data: Data) {
        write(UInt32(data.count))
        bytes.append(data)
    }

    public mutating func write(_ string: String) { write(Data(string.utf8)) }

    public mutating func write(_ id: some OpaqueID) { write(id.bytes) }

    /// Absent and empty must not encode the same way.
    public mutating func writeOptional(_ id: (some OpaqueID)?) {
        if let id { write(true); write(id) } else { write(false) }
    }

    /// Whole seconds, truncated, because that is exactly what survives the JSON
    /// round trip these values make on their way to disk and back.
    ///
    /// This is not a detail. `JSONEncoder`'s `.iso8601` strategy writes
    /// `2026-09-27T10:00:00Z` with no fractional part, so a `Date` carrying 0.7 of
    /// a second comes back as a different `Date`. Sign the full precision and the
    /// signature verifies in memory, then fails the moment the record is reloaded.
    /// Sign what round-trips instead. `CanonicalTime.normalize` is the other half of
    /// this: the stored value is truncated at creation so the two always agree.
    public mutating func write(_ date: Date) {
        write(UInt64(bitPattern: CanonicalTime.seconds(date)))
    }
}

/// Dates that are signed have to survive being written down and read back.
///
/// Named `CanonicalTime` rather than `Timestamp` on purpose: Fluent exports a
/// `@Timestamp` property wrapper, and a server file importing both would silently
/// pick the wrong one.
public enum CanonicalTime {
    public static func seconds(_ date: Date) -> Int64 {
        Int64(date.timeIntervalSince1970.rounded(.down))
    }

    /// Truncate to the precision the serialiser keeps, so what is signed and what
    /// is stored can never disagree.
    public static func normalize(_ date: Date) -> Date {
        Date(timeIntervalSince1970: TimeInterval(seconds(date)))
    }
}
