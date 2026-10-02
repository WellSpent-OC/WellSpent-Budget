import Foundation
import Crypto

/// Identifiers are generated on the client, never by the server.
///
/// The old app learned this the hard way. `api/sync.rb` carries the comment
/// "sync_id must be created in client or we could end up with unsinked
/// duplicates", and migration 009 added the unique index that turned silent
/// duplicate rows into a loud error. An offline device has to be able to name a
/// record before it can reach anyone to ask.
public protocol OpaqueID: Hashable, Codable, Sendable, CustomStringConvertible {
    var uuid: UUID { get }
    init(_ uuid: UUID)
}

public extension OpaqueID {
    init() { self.init(UUID()) }
    var description: String { uuid.uuidString }

    /// Raw 16 bytes. Used as HKDF salt, so it must stay stable and endian-free.
    var bytes: Data {
        withUnsafeBytes(of: uuid.uuid) { Data($0) }
    }

    init(from decoder: any Decoder) throws {
        self.init(try decoder.singleValueContainer().decode(UUID.self))
    }
    func encode(to encoder: any Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(uuid)
    }
}

public struct UserID:   OpaqueID { public let uuid: UUID; public init(_ u: UUID) { uuid = u } }
public struct DeviceID: OpaqueID { public let uuid: UUID; public init(_ u: UUID) { uuid = u } }
public struct GroupID:  OpaqueID { public let uuid: UUID; public init(_ u: UUID) { uuid = u } }
public struct BudgetID: OpaqueID { public let uuid: UUID; public init(_ u: UUID) { uuid = u } }
public struct RecordID: OpaqueID { public let uuid: UUID; public init(_ u: UUID) { uuid = u } }

public extension RecordID {
    /// The ID of one person's member profile in one group. It is worked out from
    /// the two, so a name set twice updates one record rather than making two,
    /// and so the server can check that a profile sits on its sender's own ID.
    static func memberProfile(group: GroupID, user: UserID) -> RecordID {
        var bytes = Array(SHA256.hash(data: group.bytes + user.bytes).prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x50   // version 5 style: name based
        bytes[8] = (bytes[8] & 0x3F) | 0x80   // RFC 4122 variant
        return RecordID(UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5],
                                    bytes[6], bytes[7], bytes[8], bytes[9], bytes[10], bytes[11],
                                    bytes[12], bytes[13], bytes[14], bytes[15])))
    }

    /// Whether this ID is worked out from names, as only a member profile's is.
    /// Every other record gets a random one.
    var isNameBased: Bool { uuid.uuid.6 >> 4 == 5 }
}

/// Bumped every time a group key is replaced, which happens on removal.
public struct Epoch: Hashable, Comparable, Codable, Sendable, CustomStringConvertible {
    public let value: UInt32
    public init(_ value: UInt32) { self.value = value }
    public static let initial = Epoch(0)
    public var next: Epoch { Epoch(value + 1) }
    public static func < (a: Epoch, b: Epoch) -> Bool { a.value < b.value }
    public var description: String { "epoch \(value)" }
}

/// Which key protects a record: the whole group, or one budget inside it.
///
/// Two scopes exist because a single budget has to be shareable on its own. If a
/// budget key were derived from the group key, handing someone one budget would
/// mean handing them the group.
public enum KeyScope: Hashable, Codable, Sendable {
    case group(GroupID)
    case budget(BudgetID)
}
