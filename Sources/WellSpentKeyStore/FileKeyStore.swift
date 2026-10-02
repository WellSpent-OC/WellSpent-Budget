import Foundation
import Crypto
import CryptoExtras

/// The Linux key store, shaped like ssh-agent on purpose.
///
/// A 0600 file, sealed with a key derived from a passphrase, unlocked once and
/// held in memory for the session. The alternative, asking for the passphrase on
/// every command, is the version you switch off within a week, and then the key is
/// sitting in a plain file. Design for the one that stays on.
///
/// Here scrypt is the right tool, unlike in the recovery code. The input really is
/// something a person chose and can be guessed, so making each guess expensive is
/// the whole defence.
public final class FileKeyStore: KeyStore, @unchecked Sendable {
    public struct Cost: Sendable {
        public let rounds: Int          // scrypt N
        public let blockSize: Int       // r
        public let parallelism: Int     // p

        /// Roughly 128 MiB and a noticeable pause. Right for a desktop unlock that
        /// happens once per session.
        public static let desktop = Cost(rounds: 1 << 17, blockSize: 8, parallelism: 1)
        /// For tests only. Do not ship this.
        public static let fast = Cost(rounds: 1 << 12, blockSize: 8, parallelism: 1)

        public init(rounds: Int, blockSize: Int, parallelism: Int) {
            self.rounds = rounds
            self.blockSize = blockSize
            self.parallelism = parallelism
        }
    }

    private struct Envelope: Codable {
        var version: Int
        var salt: Data
        var rounds: Int
        var blockSize: Int
        var parallelism: Int
        var nonce: Data
        var ciphertext: Data
    }

    private let url: URL
    private let cost: Cost
    private let lock = NSLock()
    private var unlocked: [KeyStoreItem: Data]?
    private var key: SymmetricKey?

    public init(url: URL? = nil, cost: Cost = .desktop) {
        self.url = url ?? FileKeyStore.defaultURL()
        self.cost = cost
    }

    /// `$XDG_DATA_HOME/wellspent/keys.bin`, falling back to the spec's default.
    public static func defaultURL() -> URL {
        let env = ProcessInfo.processInfo.environment
        let base: URL
        if let xdg = env["XDG_DATA_HOME"], !xdg.isEmpty {
            base = URL(fileURLWithPath: xdg)
        } else {
            base = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".local/share")
        }
        return base.appendingPathComponent("wellspent/keys.bin")
    }

    public var exists: Bool { FileManager.default.fileExists(atPath: url.path) }

    // MARK: - Locking

    public func create(passphrase: String) throws {
        lock.lock(); defer { lock.unlock() }
        let salt = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
        key = try derive(passphrase: passphrase, salt: salt)
        unlocked = [:]
        try writeLocked(salt: salt)
    }

    public func unlock(passphrase: String) throws {
        lock.lock(); defer { lock.unlock() }
        let envelope = try readEnvelope()
        let derived = try KDF.Scrypt.deriveKey(
            from: Array(passphrase.utf8), salt: envelope.salt, outputByteCount: 32,
            rounds: envelope.rounds, blockSize: envelope.blockSize, parallelism: envelope.parallelism
        )
        let box = try AES.GCM.SealedBox(combined: envelope.nonce + envelope.ciphertext)
        guard let plaintext = try? AES.GCM.open(box, using: derived) else {
            throw KeyStoreError.wrongPassphrase
        }
        let raw = try JSONDecoder().decode([String: Data].self, from: plaintext)
        var items: [KeyStoreItem: Data] = [:]
        for (name, value) in raw {
            if let item = KeyStoreItem(rawValue: name) { items[item] = value }
        }
        unlocked = items
        key = derived
    }

    public func lockNow() {
        lock.lock(); defer { lock.unlock() }
        unlocked = nil
        key = nil
    }

    public var isUnlocked: Bool {
        lock.lock(); defer { lock.unlock() }
        return unlocked != nil
    }

    // MARK: - KeyStore

    public func store(_ data: Data, for item: KeyStoreItem) throws {
        lock.lock(); defer { lock.unlock() }
        guard unlocked != nil else { throw KeyStoreError.locked }
        unlocked?[item] = data
        try writeLocked(salt: try readEnvelope().salt)
    }

    public func load(_ item: KeyStoreItem) throws -> Data? {
        lock.lock(); defer { lock.unlock() }
        guard let unlocked else { throw KeyStoreError.locked }
        return unlocked[item]
    }

    public func delete(_ item: KeyStoreItem) throws {
        lock.lock(); defer { lock.unlock() }
        guard unlocked != nil else { throw KeyStoreError.locked }
        unlocked?[item] = nil
        try writeLocked(salt: try readEnvelope().salt)
    }

    public func removeAll() throws {
        lock.lock(); defer { lock.unlock() }
        unlocked = [:]
        try? FileManager.default.removeItem(at: url)
        key = nil
    }

    // MARK: - Disk

    private func derive(passphrase: String, salt: Data) throws -> SymmetricKey {
        try KDF.Scrypt.deriveKey(
            from: Array(passphrase.utf8), salt: salt, outputByteCount: 32,
            rounds: cost.rounds, blockSize: cost.blockSize, parallelism: cost.parallelism
        )
    }

    private func readEnvelope() throws -> Envelope {
        guard let data = FileManager.default.contents(atPath: url.path) else {
            throw KeyStoreError.backendFailure("no key file at \(url.path)")
        }
        return try JSONDecoder().decode(Envelope.self, from: data)
    }

    private func writeLocked(salt: Data) throws {
        guard let key, let unlocked else { throw KeyStoreError.locked }
        var raw: [String: Data] = [:]
        for (item, value) in unlocked { raw[item.rawValue] = value }
        let plaintext = try JSONEncoder().encode(raw)
        let box = try AES.GCM.seal(plaintext, using: key, nonce: AES.GCM.Nonce())

        let envelope = Envelope(
            version: 1, salt: salt, rounds: cost.rounds, blockSize: cost.blockSize,
            parallelism: cost.parallelism, nonce: Data(box.nonce),
            ciphertext: box.ciphertext + box.tag
        )

        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        // Write to a sibling then move, so a crash mid-write cannot leave a
        // truncated key file, which would lose the identity key outright.
        let temporary = url.appendingPathExtension("tmp")
        try JSONEncoder().encode(envelope).write(to: temporary, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temporary.path)
        _ = try FileManager.default.replaceItemAt(url, withItemAt: temporary)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
