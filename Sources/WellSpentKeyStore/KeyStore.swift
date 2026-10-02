import Foundation
import Crypto
import CryptoExtras
import WellSpentCrypto

/// What a device keeps between launches.
public enum KeyStoreItem: String, Sendable, CaseIterable {
    /// The portable identity key pair. Travels to this person's other devices.
    case identity
    /// This device's signing key. Never leaves.
    case deviceSigning
    /// Unwrapped group and budget keys, cached so startup does not re-do the HPKE work.
    case scopedKeyCache
    /// The bearer token for the sync server. Not a secret that protects data.
    case serverToken
    /// Set once the person has confirmed their recovery code. A date, never the code.
    case recoveryConfirmedAt
}

public enum KeyStoreError: Error, Equatable, Sendable {
    case notFound(KeyStoreItem)
    case locked
    case backendFailure(String)
    case wrongPassphrase
}

/// One interface, two very different implementations underneath.
///
/// Keeping every Apple-only line behind this protocol is what lets the Linux
/// client share the rest of the codebase. If `Security.framework` leaks into the
/// sync engine or the model, the Linux build is finished.
public protocol KeyStore: Sendable {
    func store(_ data: Data, for item: KeyStoreItem) throws
    func load(_ item: KeyStoreItem) throws -> Data?
    func delete(_ item: KeyStoreItem) throws
    func removeAll() throws
}

public extension KeyStore {
    func require(_ item: KeyStoreItem) throws -> Data {
        guard let data = try load(item) else { throw KeyStoreError.notFound(item) }
        return data
    }

    func storeIdentity(_ identity: IdentityKeyPair) throws {
        try store(identity.escrowBytes, for: .identity)
    }

    func loadIdentity() throws -> IdentityKeyPair {
        try IdentityKeyPair(escrowBytes: try require(.identity))
    }

    func storeDevice(_ device: DeviceKeyPair) throws {
        var w = CanonicalWriter()
        w.write(device.id.bytes)
        w.write(device.signing.rawRepresentation)
        try store(w.bytes, for: .deviceSigning)
    }

    func loadDevice() throws -> DeviceKeyPair {
        let raw = try require(.deviceSigning)
        // Two length-prefixed fields: a 16 byte id, then a 32 byte key.
        guard raw.count == 4 + 16 + 4 + 32 else {
            throw KeyStoreError.backendFailure("device record is \(raw.count) bytes, expected 56")
        }
        let idBytes = raw.subdata(in: 4 ..< 20)
        let keyBytes = raw.subdata(in: 24 ..< 56)
        let uuid = idBytes.withUnsafeBytes { $0.loadUnaligned(as: uuid_t.self) }
        return DeviceKeyPair(id: DeviceID(UUID(uuid: uuid)),
                             signing: try Curve25519.Signing.PrivateKey(rawRepresentation: keyBytes))
    }
}

/// For tests, and for a first run before anything has been persisted.
public final class InMemoryKeyStore: KeyStore, @unchecked Sendable {
    private let lock = NSLock()
    private var items: [KeyStoreItem: Data] = [:]

    public init() {}

    public func store(_ data: Data, for item: KeyStoreItem) throws {
        lock.lock(); defer { lock.unlock() }
        items[item] = data
    }
    public func load(_ item: KeyStoreItem) throws -> Data? {
        lock.lock(); defer { lock.unlock() }
        return items[item]
    }
    public func delete(_ item: KeyStoreItem) throws {
        lock.lock(); defer { lock.unlock() }
        items[item] = nil
    }
    public func removeAll() throws {
        lock.lock(); defer { lock.unlock() }
        items.removeAll()
    }
}
