import Foundation
import Crypto

/// What kind of record an envelope holds.
///
/// A name, not a closed list. An enum refused any name it did not know, which
/// made every new kind of record break every older app and server: decoding
/// one envelope failed, and with it the whole sync. As a name, an unknown type
/// travels and is stored untouched. The server never needs to understand it,
/// and an older app sets it aside until an update teaches it the type.
///
/// On the wire it is still a plain string, exactly as before.
public struct RecordType: RawRepresentable, Codable, Hashable, Sendable, CustomStringConvertible {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }

    public static let groupMeta = RecordType(rawValue: "groupMeta")
    public static let budget = RecordType(rawValue: "budget")
    public static let transaction = RecordType(rawValue: "transaction")
    public static let receipt = RecordType(rawValue: "receipt")
    public static let statement = RecordType(rawValue: "statement")
    public static let memberProfile = RecordType(rawValue: "memberProfile")

    /// Every type this build knows how to read.
    public static let known: Set<RecordType> = [
        .groupMeta, .budget, .transaction, .receipt, .statement, .memberProfile,
    ]

    public var isKnown: Bool { Self.known.contains(self) }
    public var description: String { rawValue }
}

/// Whole-record snapshot, or a change to one.
///
/// v1 only ever writes `.snapshot`. The field exists now, unused, because the
/// alternative is a format change later, and a format change means migrating
/// ciphertext that is already sitting on customers' devices. One byte today buys
/// the option to move to operation-level merging without that.
public enum PayloadKind: UInt8, Codable, Sendable {
    case snapshot = 1
    case operation = 2
}

/// What the server actually stores for one record.
///
/// The server can read every field here except `ciphertext`. It needs the ids to
/// route and authorize, and the signature and `membershipSequence` so it can
/// reject a write from someone who is no longer allowed to make one.
public struct RecordEnvelope: Codable, Sendable, Equatable {
    public let version: UInt8
    public let recordID: RecordID
    public let recordType: RecordType
    public let groupID: GroupID
    public let budgetID: BudgetID?
    public let keyEpoch: Epoch
    public let ciphersuite: CiphersuiteID
    public let payloadKind: PayloadKind
    public let nonce: Data
    public let ciphertext: Data
    public let lamport: UInt64
    public let authorUserID: UserID
    public let authorDeviceID: DeviceID
    public let membershipSequence: UInt64
    public let isDeleted: Bool
    public let signature: Data

    public static let currentVersion: UInt8 = 1

    public init(version: UInt8, recordID: RecordID, recordType: RecordType, groupID: GroupID,
                budgetID: BudgetID?, keyEpoch: Epoch, ciphersuite: CiphersuiteID,
                payloadKind: PayloadKind, nonce: Data, ciphertext: Data, lamport: UInt64,
                authorUserID: UserID, authorDeviceID: DeviceID, membershipSequence: UInt64,
                isDeleted: Bool, signature: Data) {
        self.version = version
        self.recordID = recordID
        self.recordType = recordType
        self.groupID = groupID
        self.budgetID = budgetID
        self.keyEpoch = keyEpoch
        self.ciphersuite = ciphersuite
        self.payloadKind = payloadKind
        self.nonce = nonce
        self.ciphertext = ciphertext
        self.lamport = lamport
        self.authorUserID = authorUserID
        self.authorDeviceID = authorDeviceID
        self.membershipSequence = membershipSequence
        self.isDeleted = isDeleted
        self.signature = signature
    }

    func signedBytes() -> Data {
        var w = CanonicalWriter()
        w.write(version)
        w.write(recordID)
        w.write(recordType.rawValue)
        w.write(groupID)
        w.writeOptional(budgetID)
        w.write(keyEpoch.value)
        w.write(ciphersuite.rawValue)
        w.write(payloadKind.rawValue)
        w.write(nonce)
        w.write(ciphertext)
        w.write(lamport)
        w.write(authorUserID)
        w.write(authorDeviceID)
        w.write(membershipSequence)
        w.write(isDeleted)
        return w.bytes
    }

    public func verifySignature(byDeviceKey key: Curve25519.Signing.PublicKey) -> Bool {
        key.isValidSignature(signature, for: signedBytes())
    }

    /// Whether this envelope replaces the stored version of the same record.
    ///
    /// Last write wins: the higher Lamport value, with the device id breaking a
    /// tie so the server and every device pick the same winner.
    ///
    /// A group's own record is the exception, because deleting a group is
    /// final. A delete replaces a live version whatever its Lamport value, and
    /// a live version never replaces a delete. Without this, a rename queued
    /// before the delete arrived could bring the group back for some members
    /// and not others.
    public func replaces(lamport stored: UInt64, device storedDevice: DeviceID,
                         isDeleted storedIsDeleted: Bool) -> Bool {
        if recordType == .groupMeta, isDeleted != storedIsDeleted { return isDeleted }
        return lamport != stored
            ? lamport > stored
            : authorDeviceID.uuid.uuidString > storedDevice.uuid.uuidString
    }

    /// The reason a server gives when it refuses an envelope that does not
    /// replace the version it holds. The app reads it: a row refused this way
    /// can never be taken, so it stops sending it. One string for every server
    /// and the app, so the two cannot drift apart.
    public static let olderVersionRefusal = "a newer version is already stored"

    /// The lowest Lamport value refused everywhere: by every server, and by
    /// the app when a server hands one over anyway.
    ///
    /// The value grows by one for each save, so an honest one never comes
    /// near this. The danger is a forged one. Every app's clock takes the
    /// highest value it has pulled and adds one per save, in a signed 64-bit
    /// integer. A value at that integer's top left the clock no room, and the
    /// next save crashed the app. Below this ceiling, which is a quarter of
    /// that integer's range, the clock has room for more saves than any
    /// device will ever make.
    public static let lamportCeiling: UInt64 = 1 << 62

    /// The reason a server gives when it refuses a value at or above the ceiling.
    public static let lamportTooLargeRefusal = "the Lamport value is too large"
}

public enum EnvelopeError: Error, Equatable, Sendable {
    case wrongScopeKey
    case unsupportedVersion(UInt8)
    case badSignature
    case authorNotEntitled(AccessLevel)
}

/// Sealing a record into an envelope, and opening one back out.
public enum RecordCodec {

    /// Seal, then sign. The signature covers the ciphertext and every routing
    /// field, so the server cannot move a record into another budget or relabel who
    /// wrote it without invalidating it.
    public static func seal<T: Encodable>(
        _ value: T,
        recordID: RecordID,
        recordType: RecordType,
        groupID: GroupID,
        budgetID: BudgetID?,
        scopeKey: ScopedKey,
        lamport: UInt64,
        author: UserID,
        device: DeviceKeyPair,
        membershipSequence: UInt64,
        isDeleted: Bool = false,
        encoder: JSONEncoder = RecordCodec.encoder
    ) throws -> RecordEnvelope {
        let plaintext = try encoder.encode(value)
        return try sealData(
            plaintext, recordID: recordID, recordType: recordType, groupID: groupID,
            budgetID: budgetID, scopeKey: scopeKey, lamport: lamport, author: author,
            device: device, membershipSequence: membershipSequence, isDeleted: isDeleted
        )
    }

    /// Same thing, for a payload that is already encoded.
    public static func sealData(
        _ plaintext: Data,
        recordID: RecordID,
        recordType: RecordType,
        groupID: GroupID,
        budgetID: BudgetID?,
        scopeKey: ScopedKey,
        lamport: UInt64,
        author: UserID,
        device: DeviceKeyPair,
        membershipSequence: UInt64,
        isDeleted: Bool = false
    ) throws -> RecordEnvelope {
        let sealed = try RecordSeal.seal(plaintext, scopeKey: scopeKey.material, recordID: recordID)

        let unsigned = RecordEnvelope(
            version: RecordEnvelope.currentVersion,
            recordID: recordID, recordType: recordType, groupID: groupID, budgetID: budgetID,
            keyEpoch: scopeKey.epoch, ciphersuite: .curve25519_chachaPoly_aesgcm256,
            payloadKind: .snapshot, nonce: sealed.nonce, ciphertext: sealed.ciphertext,
            lamport: lamport, authorUserID: author, authorDeviceID: device.id,
            membershipSequence: membershipSequence, isDeleted: isDeleted, signature: Data()
        )
        let signature = try device.signing.signature(for: unsigned.signedBytes())

        return RecordEnvelope(
            version: unsigned.version,
            recordID: recordID, recordType: recordType, groupID: groupID, budgetID: budgetID,
            keyEpoch: scopeKey.epoch, ciphersuite: unsigned.ciphersuite,
            payloadKind: .snapshot, nonce: sealed.nonce, ciphertext: sealed.ciphertext,
            lamport: lamport, authorUserID: author, authorDeviceID: device.id,
            membershipSequence: membershipSequence, isDeleted: isDeleted, signature: signature
        )
    }

    /// Open an envelope, checking who wrote it before trusting the contents.
    ///
    /// The level check is the second of the two non-cryptographic layers. A member
    /// demoted to read still holds the key and can still produce ciphertext that
    /// decrypts. What they cannot do is get an honest peer to accept it.
    public static func open<T: Decodable>(
        _ type: T.Type,
        from envelope: RecordEnvelope,
        scopeKey: ScopedKey,
        deviceKey: Curve25519.Signing.PublicKey,
        authorLevel: AccessLevel,
        decoder: JSONDecoder = RecordCodec.decoder
    ) throws -> T {
        guard envelope.version == RecordEnvelope.currentVersion else {
            throw EnvelopeError.unsupportedVersion(envelope.version)
        }
        guard envelope.keyEpoch == scopeKey.epoch else { throw EnvelopeError.wrongScopeKey }
        guard envelope.verifySignature(byDeviceKey: deviceKey) else { throw EnvelopeError.badSignature }
        guard authorLevel.allows(.write) else { throw EnvelopeError.authorNotEntitled(authorLevel) }

        return try decoder.decode(T.self, from: try openData(from: envelope, scopeKey: scopeKey,
                                                              deviceKey: deviceKey, authorLevel: authorLevel))
    }

    /// Same checks, returning the raw payload.
    public static func openData(
        from envelope: RecordEnvelope,
        scopeKey: ScopedKey,
        deviceKey: Curve25519.Signing.PublicKey,
        authorLevel: AccessLevel
    ) throws -> Data {
        guard envelope.version == RecordEnvelope.currentVersion else {
            throw EnvelopeError.unsupportedVersion(envelope.version)
        }
        guard envelope.keyEpoch == scopeKey.epoch else { throw EnvelopeError.wrongScopeKey }
        guard envelope.verifySignature(byDeviceKey: deviceKey) else { throw EnvelopeError.badSignature }
        guard authorLevel.allows(.write) else { throw EnvelopeError.authorNotEntitled(authorLevel) }

        let sealed = RecordSeal.Sealed(nonce: envelope.nonce, ciphertext: envelope.ciphertext)
        return try RecordSeal.open(sealed, scopeKey: scopeKey.material, recordID: envelope.recordID)
    }

    public static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    public static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
}

/// A Lamport clock, which is the whole of v1's conflict story.
///
/// Wall clocks disagree between machines, and the old API's `updated_at >= ?`
/// cursor lost records because of exactly that. A counter that only ever moves
/// forward, bumped past anything it has seen, gives a consistent order without
/// trusting anyone's clock. Ties break on device id so every device picks the same
/// winner.
public struct LamportClock: Sendable, Equatable {
    public private(set) var value: UInt64

    public init(value: UInt64 = 0) { self.value = value }

    public mutating func tick() -> UInt64 {
        value += 1
        return value
    }

    public mutating func witness(_ seen: UInt64) {
        value = Swift.max(value, seen)
    }

    /// Later wins. Same counter, higher device id wins. Deterministic everywhere.
    public static func wins(_ a: RecordEnvelope, over b: RecordEnvelope) -> Bool {
        if a.lamport != b.lamport { return a.lamport > b.lamport }
        return a.authorDeviceID.uuid.uuidString > b.authorDeviceID.uuid.uuidString
    }
}
