import Foundation
import Crypto

/// What happened to someone's access.
public enum MembershipAction: String, Codable, Sendable {
    case found          // the group's first entry, by its creator
    case add
    case changeLevel
    case remove
    case rotate         // key rotation with no membership change
    case addDevice
    case revokeDevice
    case rotateIdentity
}

/// One signed, chained entry in a group's access history.
///
/// This log is why the ladder above `read` means anything. Encryption enforces
/// read and nothing else, so write, manage and admin are enforced by the server
/// refusing a write and by honest clients rejecting records whose author was not
/// entitled. Both of those depend on knowing who held what level and when, so the
/// server must not be able to make that up. Each entry is signed by the author and
/// carries the hash of the one before it, and clients replay the chain themselves.
public struct MembershipLogEntry: Codable, Sendable, Equatable {
    public let scope: KeyScope
    public let sequence: UInt64
    public let previousHash: Data          // SHA-256 of the previous entry's signed bytes; 32 zero bytes at the root
    public let action: MembershipAction
    public let subjectUserID: UserID
    public let subjectKeys: IdentityPublicKeys?
    public let level: AccessLevel
    public let epochAfter: Epoch
    public let at: Date
    public let authorUserID: UserID
    /// Present on `.found`, `.addDevice` and `.revokeDevice`. A device signs every
    /// record it writes, so peers need to know which devices belong to whom, and
    /// which ones have been cut off.
    public let deviceID: DeviceID?
    public let devicePublicKey: Data?
    public let authorSignature: Data

    public static let rootHash = Data(repeating: 0, count: 32)

    public init(scope: KeyScope, sequence: UInt64, previousHash: Data, action: MembershipAction,
                subjectUserID: UserID, subjectKeys: IdentityPublicKeys?, level: AccessLevel,
                epochAfter: Epoch, at: Date, authorUserID: UserID, deviceID: DeviceID?,
                devicePublicKey: Data?, authorSignature: Data) {
        self.scope = scope
        self.sequence = sequence
        self.previousHash = previousHash
        self.action = action
        self.subjectUserID = subjectUserID
        self.subjectKeys = subjectKeys
        self.level = level
        self.epochAfter = epochAfter
        self.at = at
        self.authorUserID = authorUserID
        self.deviceID = deviceID
        self.devicePublicKey = devicePublicKey
        self.authorSignature = authorSignature
    }

    /// Everything except the signature.
    func signedBytes() -> Data {
        var w = CanonicalWriter()
        w.write(UInt8(1))                                  // format version
        switch scope {
        case .group(let id):  w.write(UInt8(1)); w.write(id)
        case .budget(let id): w.write(UInt8(2)); w.write(id)
        }
        w.write(sequence)
        w.write(previousHash)
        w.write(action.rawValue)
        w.write(subjectUserID)
        if let keys = subjectKeys {
            w.write(true); w.write(keys.signing); w.write(keys.kem)
        } else {
            w.write(false)
        }
        w.write(UInt32(level.rawValue))
        w.write(epochAfter.value)
        w.write(at)
        w.write(authorUserID)
        w.writeOptional(deviceID)
        if let devicePublicKey { w.write(true); w.write(devicePublicKey) } else { w.write(false) }
        return w.bytes
    }

    public var hash: Data { Data(SHA256.hash(data: signedBytes())) }

    public static func signed(
        scope: KeyScope,
        sequence: UInt64,
        previousHash: Data,
        action: MembershipAction,
        subjectUserID: UserID,
        subjectKeys: IdentityPublicKeys?,
        level: AccessLevel,
        epochAfter: Epoch,
        at: Date = Date(),
        deviceID: DeviceID? = nil,
        devicePublicKey: Data? = nil,
        author: IdentityKeyPair,
        authorUserID: UserID
    ) throws -> MembershipLogEntry {
        // Truncated here, once, so the value that gets signed is the same value
        // that comes back out of storage.
        let at = CanonicalTime.normalize(at)
        let unsigned = MembershipLogEntry(
            scope: scope, sequence: sequence, previousHash: previousHash, action: action,
            subjectUserID: subjectUserID, subjectKeys: subjectKeys, level: level,
            epochAfter: epochAfter, at: at, authorUserID: authorUserID,
            deviceID: deviceID, devicePublicKey: devicePublicKey, authorSignature: Data()
        )
        let signature = try author.signing.signature(for: unsigned.signedBytes())
        return MembershipLogEntry(
            scope: scope, sequence: sequence, previousHash: previousHash, action: action,
            subjectUserID: subjectUserID, subjectKeys: subjectKeys, level: level,
            epochAfter: epochAfter, at: at, authorUserID: authorUserID,
            deviceID: deviceID, devicePublicKey: devicePublicKey, authorSignature: signature
        )
    }

    public func verifySignature(by author: IdentityPublicKeys) -> Bool {
        guard let key = try? author.signingKey else { return false }
        return key.isValidSignature(authorSignature, for: signedBytes())
    }
}

public enum MembershipLogError: Error, Equatable, Sendable {
    case empty
    case firstEntryMustFound
    case sequenceOutOfOrder(expected: UInt64, got: UInt64)
    case chainBroken(atSequence: UInt64)
    case unknownAuthor(atSequence: UInt64)
    case badSignature(atSequence: UInt64)
    case authorNotEntitled(atSequence: UInt64, needed: AccessLevel)
    case scopeMismatch(atSequence: UInt64)
    case cannotRemoveFounder(atSequence: UInt64)
    case foundingEntryNotFirst(atSequence: UInt64)
    case unknownDevice(DeviceID)
    /// A person's keys, once the log holds them, change only by their own
    /// signed entry.
    case keysAlreadyEstablished(atSequence: UInt64)
    /// A device ID stays with whoever registered it.
    case deviceTaken(atSequence: UInt64)
    /// A device is revoked as its own owner's, or not at all.
    case notTheirDevice(atSequence: UInt64)
    /// The epoch moves one step at a time, and only by someone who can hand out
    /// the new keys. A group starts at the first epoch.
    case epochNotNext(atSequence: UInt64)
    /// A device is registered by an entry of its own, never inside an add or a
    /// level change.
    case deviceNotOnItsOwn(atSequence: UInt64)
}

/// The replayed result: who is in, at what level, and which epoch is current.
/// A device that is allowed to write, and who it belongs to.
public struct DeviceRegistration: Sendable, Equatable {
    public let userID: UserID
    public let publicKey: Data

    public var signingKey: Curve25519.Signing.PublicKey {
        get throws { try .init(rawRepresentation: publicKey) }
    }
}

/// A device as one person's.
///
/// A Mac uses one device ID in every group, and every member of each can read
/// it. Registered by the ID alone, a member could take someone else's ID in a
/// group that person had not joined yet, and they could never send anything
/// there. So a registration belongs to the person and the device together.
public struct DeviceSlot: Hashable, Sendable {
    public let user: UserID
    public let device: DeviceID

    public init(user: UserID, device: DeviceID) {
        self.user = user
        self.device = device
    }
}

public struct MembershipState: Sendable, Equatable {
    public internal(set) var levels: [UserID: AccessLevel] = [:]
    public internal(set) var keys: [UserID: IdentityPublicKeys] = [:]
    /// Only these devices can produce a record other people will accept. Revoking
    /// a stolen laptop takes its entry out of here.
    public internal(set) var devices: [DeviceSlot: DeviceRegistration] = [:]
    /// Everyone who has signed an entry in this log, which shows they hold the
    /// keys it has for them.
    public internal(set) var signers: Set<UserID> = []
    public internal(set) var epoch: Epoch = .initial
    public internal(set) var founder: UserID?
    public internal(set) var sequence: UInt64 = 0
    public internal(set) var head: Data = MembershipLogEntry.rootHash

    public func level(of user: UserID) -> AccessLevel { levels[user] ?? .none }
    /// `device` as `user`'s, if it is registered as theirs.
    public func device(_ device: DeviceID, of user: UserID) -> DeviceRegistration? {
        devices[DeviceSlot(user: user, device: device)]
    }
    public func allows(_ user: UserID, _ required: AccessLevel) -> Bool { level(of: user).allows(required) }
    public var members: [UserID] { levels.filter { $0.value > .none }.map(\.key) }

    /// Whether this person may delete the whole group for every member: the
    /// person who founded it, or anyone at admin. Below that, a delete stays on
    /// their own Mac. The app, every receiving app and the server all ask this
    /// one question, so the rule cannot drift between them.
    public func mayDeleteGroup(_ user: UserID) -> Bool {
        user == founder || allows(user, .admin)
    }
}

public enum MembershipLog {
    /// Replay a chain into a state, verifying as it goes.
    ///
    /// Every entry is checked four ways: the sequence runs without gaps, the
    /// previous hash matches, the signature verifies against keys already
    /// established by the chain itself, and the author held a high enough level at
    /// that point. A server that rewrites history fails at the hash, and a server
    /// that invents a member fails at the signature. Only the first entry may
    /// found the group, because a founding entry is the one that vouches for
    /// itself. What an entry changes is checked too (`checkWhatItChanges`):
    /// someone else's keys, someone else's device, and an epoch skipped or
    /// moved by someone who cannot hand out its keys.
    public static func replay(_ entries: [MembershipLogEntry], scope: KeyScope) throws -> MembershipState {
        guard let first = entries.first else { throw MembershipLogError.empty }
        guard first.action == .found, first.sequence == 0, first.previousHash == MembershipLogEntry.rootHash else {
            throw MembershipLogError.firstEntryMustFound
        }
        // Every group starts at the first epoch, as the app founds it. One
        // founded at the top of the range left no next epoch, and working one
        // out stopped the server process.
        guard first.epochAfter == .initial else { throw MembershipLogError.epochNotNext(atSequence: 0) }

        var state = MembershipState()

        for (offset, entry) in entries.enumerated() {
            let expectedSequence = UInt64(offset)
            guard entry.sequence == expectedSequence else {
                throw MembershipLogError.sequenceOutOfOrder(expected: expectedSequence, got: entry.sequence)
            }
            guard entry.scope == scope else { throw MembershipLogError.scopeMismatch(atSequence: entry.sequence) }
            guard entry.previousHash == state.head else {
                throw MembershipLogError.chainBroken(atSequence: entry.sequence)
            }

            // The founding entry establishes its own author's keys. Every later
            // entry must be signed by someone the chain already knows about.
            //
            // So a founding entry can only come first. One further down would
            // be checked against keys it carries itself, skip the level check,
            // and make whoever wrote it the founder and superadmin. Any member,
            // even one who can only view, could append one.
            let authorKeys: IdentityPublicKeys?
            if entry.action == .found {
                guard entry.sequence == 0 else {
                    throw MembershipLogError.foundingEntryNotFirst(atSequence: entry.sequence)
                }
                authorKeys = entry.subjectKeys
            } else {
                authorKeys = state.keys[entry.authorUserID]
            }
            guard let authorKeys else { throw MembershipLogError.unknownAuthor(atSequence: entry.sequence) }
            guard entry.verifySignature(by: authorKeys) else {
                throw MembershipLogError.badSignature(atSequence: entry.sequence)
            }

            if entry.action != .found {
                let needed = requiredLevel(for: entry, state: state)
                guard state.allows(entry.authorUserID, needed) else {
                    throw MembershipLogError.authorNotEntitled(atSequence: entry.sequence, needed: needed)
                }
                try checkWhatItChanges(entry, in: state)
            }

            try apply(entry, to: &state)
            state.signers.insert(entry.authorUserID)
            state.sequence = entry.sequence
            state.head = entry.hash
        }

        return state
    }

    /// Who is allowed to perform this action.
    ///
    /// Promoting or removing someone at `manage` or above needs `admin`. Everything
    /// else in the membership area needs `manage`. Keeping this in one function
    /// stops the rule drifting between the client and the server.
    static func requiredLevel(for entry: MembershipLogEntry, state: MembershipState) -> AccessLevel {
        switch entry.action {
        case .found:
            return .superadmin
        case .rotate, .rotateIdentity:
            // For a new identity, only your own: `checkWhatItChanges`
            // refuses anyone else's, at any level.
            return .manage
        case .addDevice, .revokeDevice:
            // Enrolling or cutting off your own device needs only the access you
            // already have. Touching someone else's needs admin.
            return entry.subjectUserID == entry.authorUserID ? .read : .admin
        case .add, .changeLevel:
            return max(entry.level, state.level(of: entry.subjectUserID)) >= .manage ? .admin : .manage
        case .remove:
            return state.level(of: entry.subjectUserID) >= .manage ? .admin : .manage
        }
    }

    /// What an entry may change, once its author holds the level it needs.
    ///
    /// A person's keys are their own. Once they have signed an entry with
    /// them, only that person's entry can replace them. A manager could put her
    /// own keys in the founder's place: every entry he signed after that was
    /// refused, and the keys for a new epoch were sealed to her instead of him.
    ///
    /// A device is registered by its owner's own entry, as theirs, and revoked
    /// only as theirs. Registering your own device takes only View, and every
    /// member can read every device ID in the log, so a member at View could
    /// take the founder's device, or cut it off, and every member then refused
    /// what it sent. A registration now belongs to the person and the device
    /// together (`DeviceSlot`).
    ///
    /// The epoch moves one step at a time, and only by a manager, who is the
    /// one who can hand out the new epoch's keys. An epoch nobody holds keys
    /// for left every member's edits queued for good.
    static func checkWhatItChanges(_ entry: MembershipLogEntry, in state: MembershipState) throws {
        let at = entry.sequence
        switch entry.action {
        case .rotateIdentity:
            guard entry.subjectUserID == entry.authorUserID else {
                throw MembershipLogError.keysAlreadyEstablished(atSequence: at)
            }
        case .add, .changeLevel:
            // Keys nobody has yet signed with may be replaced, so a manager who
            // put made-up keys on someone's ID before they joined cannot keep
            // them out for good.
            if let keys = entry.subjectKeys, let held = state.keys[entry.subjectUserID], held != keys,
               state.signers.contains(entry.subjectUserID) {
                throw MembershipLogError.keysAlreadyEstablished(atSequence: at)
            }
        default:
            break
        }

        switch entry.action {
        case .add, .changeLevel:
            // The app never sends a device with these. A manager could enrol
            // a device of her own under someone else's name, and sign records
            // as them.
            if entry.deviceID != nil || entry.devicePublicKey != nil {
                throw MembershipLogError.deviceNotOnItsOwn(atSequence: at)
            }
        case .addDevice:
            if let deviceID = entry.deviceID, let publicKey = entry.devicePublicKey,
               let held = state.device(deviceID, of: entry.subjectUserID),
               held.publicKey != publicKey {
                throw MembershipLogError.deviceTaken(atSequence: at)
            }
        case .revokeDevice:
            if let deviceID = entry.deviceID, state.device(deviceID, of: entry.subjectUserID) == nil {
                throw MembershipLogError.notTheirDevice(atSequence: at)
            }
        default:
            break
        }

        // Adding a device is the one action that leaves the epoch alone
        // whatever the entry says, so it is the one not checked. The next
        // epoch is worked out without adding past the top of the range.
        guard entry.action != .addDevice, entry.epochAfter != state.epoch else { return }
        guard state.epoch.value < UInt32.max, entry.epochAfter.value == state.epoch.value + 1 else {
            throw MembershipLogError.epochNotNext(atSequence: at)
        }
        guard state.allows(entry.authorUserID, .manage) else {
            throw MembershipLogError.authorNotEntitled(atSequence: at, needed: .manage)
        }
    }

    static func apply(_ entry: MembershipLogEntry, to state: inout MembershipState) throws {
        switch entry.action {
        case .found:
            state.founder = entry.subjectUserID
            state.levels[entry.subjectUserID] = .superadmin
            state.keys[entry.subjectUserID] = entry.subjectKeys
            if let deviceID = entry.deviceID, let publicKey = entry.devicePublicKey {
                state.devices[DeviceSlot(user: entry.subjectUserID, device: deviceID)] =
                    DeviceRegistration(userID: entry.subjectUserID, publicKey: publicKey)
            }
            state.epoch = entry.epochAfter

        case .add, .changeLevel:
            state.levels[entry.subjectUserID] = entry.level
            if let keys = entry.subjectKeys { state.keys[entry.subjectUserID] = keys }
            state.epoch = entry.epochAfter

        case .addDevice:
            guard let deviceID = entry.deviceID, let publicKey = entry.devicePublicKey else { break }
            state.devices[DeviceSlot(user: entry.subjectUserID, device: deviceID)] =
                DeviceRegistration(userID: entry.subjectUserID, publicKey: publicKey)

        case .remove:
            // The founder holds superadmin, which is an exact match rather than a
            // floor, so nobody else can ever reach it to remove them.
            guard entry.subjectUserID != state.founder else {
                throw MembershipLogError.cannotRemoveFounder(atSequence: entry.sequence)
            }
            state.levels[entry.subjectUserID] = AccessLevel.none
            // Their devices go too, so nothing they still hold can write.
            for slot in state.devices.keys where slot.user == entry.subjectUserID {
                state.devices[slot] = nil
            }
            // Keys they never signed with go as well, so made-up keys put on
            // their ID by someone else can be cleared by removing them.
            if !state.signers.contains(entry.subjectUserID) { state.keys[entry.subjectUserID] = nil }
            state.epoch = entry.epochAfter

        case .rotate:
            state.epoch = entry.epochAfter

        case .revokeDevice:
            if let deviceID = entry.deviceID {
                state.devices[DeviceSlot(user: entry.subjectUserID, device: deviceID)] = nil
            }
            state.epoch = entry.epochAfter

        case .rotateIdentity:
            if let keys = entry.subjectKeys { state.keys[entry.subjectUserID] = keys }
            state.epoch = entry.epochAfter
        }
    }

    /// Removal is the only action that forces a new key generation, because the
    /// person leaving held the old one.
    public static func requiresRotation(_ action: MembershipAction) -> Bool {
        action == .remove || action == .revokeDevice
    }

    /// Look up the key an incoming record must verify against.
    public static func signingKey(forDevice id: DeviceID, of user: UserID,
                                  in state: MembershipState) throws -> Curve25519.Signing.PublicKey {
        guard let registration = state.device(id, of: user) else { throw MembershipLogError.unknownDevice(id) }
        return try registration.signingKey
    }
}
