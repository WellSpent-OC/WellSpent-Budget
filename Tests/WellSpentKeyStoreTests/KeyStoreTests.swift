import Testing
import Foundation
import Crypto
@testable import WellSpentKeyStore
import WellSpentCrypto

@Suite("In-memory key store")
struct InMemoryKeyStoreTests {
    @Test func identityRoundTrip() throws {
        let store = InMemoryKeyStore()
        let identity = IdentityKeyPair.generate()
        try store.storeIdentity(identity)
        #expect(try store.loadIdentity().publicKeys == identity.publicKeys)
    }

    @Test func deviceRoundTripKeepsTheIdentifier() throws {
        let store = InMemoryKeyStore()
        let device = DeviceKeyPair()
        try store.storeDevice(device)
        let restored = try store.loadDevice()
        #expect(restored.id == device.id)
        #expect(restored.publicKey == device.publicKey)
    }

    @Test func missingItemIsNamed() {
        let store = InMemoryKeyStore()
        #expect(throws: KeyStoreError.notFound(.identity)) { try store.require(.identity) }
    }

    @Test func deleteAndRemoveAll() throws {
        let store = InMemoryKeyStore()
        try store.store(Data("token".utf8), for: .serverToken)
        try store.delete(.serverToken)
        #expect(try store.load(.serverToken) == nil)

        try store.store(Data("again".utf8), for: .serverToken)
        try store.removeAll()
        #expect(try store.load(.serverToken) == nil)
    }
}

@Suite("File key store")
struct FileKeyStoreTests {
    private func temporaryURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("wellspent-tests-\(UUID().uuidString)")
            .appendingPathComponent("keys.bin")
    }

    @Test func createUnlockRoundTrip() throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let identity = IdentityKeyPair.generate()
        let store = FileKeyStore(url: url, cost: .fast)
        try store.create(passphrase: "correct horse battery staple")
        try store.storeIdentity(identity)
        #expect(store.isUnlocked)

        // A fresh handle, as though the process restarted.
        let reopened = FileKeyStore(url: url, cost: .fast)
        #expect(reopened.exists)
        try reopened.unlock(passphrase: "correct horse battery staple")
        #expect(try reopened.loadIdentity().publicKeys == identity.publicKeys)
    }

    @Test func wrongPassphraseIsRefused() throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let store = FileKeyStore(url: url, cost: .fast)
        try store.create(passphrase: "the right one")
        try store.storeIdentity(IdentityKeyPair.generate())

        let attacker = FileKeyStore(url: url, cost: .fast)
        #expect(throws: KeyStoreError.wrongPassphrase) {
            try attacker.unlock(passphrase: "the wrong one")
        }
    }

    @Test func lockedStoreRefusesReads() throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let store = FileKeyStore(url: url, cost: .fast)
        try store.create(passphrase: "open sesame")
        try store.storeIdentity(IdentityKeyPair.generate())
        store.lockNow()

        #expect(!store.isUnlocked)
        #expect(throws: KeyStoreError.locked) { _ = try store.load(.identity) }
    }

    /// The file must never be readable by other users on a shared Linux box.
    @Test func fileIsOwnerOnly() throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let store = FileKeyStore(url: url, cost: .fast)
        try store.create(passphrase: "x")
        try store.storeIdentity(IdentityKeyPair.generate())

        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let permissions = try #require(attributes[.posixPermissions] as? NSNumber)
        #expect(permissions.intValue == 0o600, "key file is \(String(permissions.intValue, radix: 8))")
    }

    /// Nothing recognisable may sit in the file. This is what an attacker who
    /// copies the laptop's disk actually gets.
    @Test func fileContainsNoPlaintextKeyMaterial() throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let identity = IdentityKeyPair.generate()
        let store = FileKeyStore(url: url, cost: .fast)
        try store.create(passphrase: "x")
        try store.storeIdentity(identity)

        let onDisk = try #require(FileManager.default.contents(atPath: url.path))
        #expect(onDisk.range(of: identity.escrowBytes) == nil,
                "identity bytes appear in the key file in the clear")
        #expect(onDisk.range(of: identity.signing.rawRepresentation) == nil)
        #expect(onDisk.range(of: identity.kem.rawRepresentation) == nil)
    }

    @Test func xdgPathIsHonoured() {
        let url = FileKeyStore.defaultURL()
        #expect(url.lastPathComponent == "keys.bin")
        #expect(url.deletingLastPathComponent().lastPathComponent == "wellspent")
    }
}

#if canImport(Security)
import Security

/// A keychain that behaves like macOS does for a signed or an unsigned build:
/// unsigned, a data protection add or delete answers -34018, but a read answers
/// "not found". Checked against the real thing on macOS 26.
private final class FakeKeychain: @unchecked Sendable {
    let signed: Bool
    private let lock = NSLock()
    private var items: [String: Data] = [:]
    private(set) var queries: [[String: Any]] = []

    init(signed: Bool) { self.signed = signed }

    private func key(_ q: [String: Any]) -> String {
        "\(q[kSecUseDataProtectionKeychain as String] as? Bool ?? false)/\(q[kSecAttrAccount as String] as? String ?? "")"
    }
    private func refused(_ q: [String: Any]) -> Bool {
        !signed && (q[kSecUseDataProtectionKeychain as String] as? Bool ?? false)
    }

    var backend: KeychainBackend {
        KeychainBackend(
            add: { q in self.lock.withLock {
                self.queries.append(q)
                if self.refused(q) { return errSecMissingEntitlement }
                if self.items[self.key(q)] != nil { return errSecDuplicateItem }
                self.items[self.key(q)] = q[kSecValueData as String] as? Data
                return errSecSuccess
            } },
            copy: { q in self.lock.withLock {
                self.queries.append(q)
                if self.refused(q) { return (errSecItemNotFound, nil) }
                guard let d = self.items[self.key(q)] else { return (errSecItemNotFound, nil) }
                return (errSecSuccess, d)
            } },
            delete: { q in self.lock.withLock {
                self.queries.append(q)
                if self.refused(q) { return errSecMissingEntitlement }
                return self.items.removeValue(forKey: self.key(q)) == nil ? errSecItemNotFound : errSecSuccess
            } }
        )
    }
}

@Suite("Keychain key store fallback")
struct KeychainFallbackTests {
    private func store(_ fake: FakeKeychain, biometry: Bool = false) -> KeychainKeyStore {
        KeychainKeyStore(service: "test", accessGroup: nil, requireBiometry: biometry,
                         backend: fake.backend)
    }

    @Test func unsignedBuildFallsBackAndRoundTrips() throws {
        let fake = FakeKeychain(signed: false)
        let keys = store(fake)
        let identity = IdentityKeyPair.generate()
        try keys.storeIdentity(identity)
        #expect(keys.usingLegacyKeychain)
        #expect(try keys.loadIdentity().publicKeys == identity.publicKeys)
    }

    /// The bug this caught: the app restarted, read the modern keychain, was told
    /// "not found", and decided this Mac had no key.
    @Test func unsignedBuildFindsItsKeysAfterARestart() throws {
        let fake = FakeKeychain(signed: false)
        let identity = IdentityKeyPair.generate()
        try store(fake).storeIdentity(identity)

        let afterRestart = store(fake)
        #expect(try afterRestart.loadIdentity().publicKeys == identity.publicKeys)
    }

    @Test func signedBuildNeverFallsBack() throws {
        let fake = FakeKeychain(signed: true)
        let keys = store(fake)
        try keys.store(Data("token".utf8), for: .serverToken)
        #expect(try keys.load(.serverToken) == Data("token".utf8))
        #expect(!keys.usingLegacyKeychain)
        #expect(fake.queries.allSatisfy { $0[kSecUseDataProtectionKeychain as String] as? Bool == true })
    }

    @Test func legacyQueriesCarryNoAccessControl() throws {
        let fake = FakeKeychain(signed: false)
        let keys = store(fake, biometry: true)
        try keys.storeIdentity(IdentityKeyPair.generate())
        let legacyAdds = fake.queries.filter {
            $0[kSecValueData as String] != nil && $0[kSecUseDataProtectionKeychain as String] as? Bool == false
        }
        #expect(legacyAdds.count == 1)
        #expect(legacyAdds[0][kSecAttrAccessControl as String] == nil)
        #expect(legacyAdds[0][kSecAttrAccessible as String] == nil)
    }

    @Test func deleteAndRemoveAllWorkAfterFallback() throws {
        let keys = store(FakeKeychain(signed: false))
        try keys.store(Data("token".utf8), for: .serverToken)
        try keys.delete(.serverToken)
        #expect(try keys.load(.serverToken) == nil)
        try keys.store(Data("again".utf8), for: .serverToken)
        try keys.removeAll()
        #expect(try keys.load(.serverToken) == nil)
    }
}

/// Against the real login keychain. Off by default so CI never meets a keychain
/// prompt: `WELLSPENT_REAL_KEYCHAIN=1 make test` on a Mac.
@Suite("Real keychain", .enabled(if: ProcessInfo.processInfo.environment["WELLSPENT_REAL_KEYCHAIN"] == "1"))
struct RealKeychainTests {
    @Test func unsignedTestBinaryRoundTrips() throws {
        let keys = KeychainKeyStore(service: "app.wellspent.keys.test-\(UUID().uuidString)")
        defer { try? keys.removeAll() }
        try keys.store(Data("token".utf8), for: .serverToken)
        #expect(try keys.load(.serverToken) == Data("token".utf8))
    }

    @Test func unsignedTestBinaryReadsBackAfterARestart() throws {
        let service = "app.wellspent.keys.test-\(UUID().uuidString)"
        let keys = KeychainKeyStore(service: service)
        defer { try? keys.removeAll() }
        try keys.store(Data("token".utf8), for: .serverToken)
        #expect(try KeychainKeyStore(service: service).load(.serverToken) == Data("token".utf8))
    }
}
#endif
