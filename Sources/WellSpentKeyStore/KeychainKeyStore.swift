#if canImport(Security)
import Foundation
import Security

/// The Apple key store. Every `Security.framework` call in the whole codebase
/// lives in this file, so the Linux build never has to think about it.
///
/// Deliberately not the Secure Enclave. The two things worth protecting most, the
/// identity key and the group keys, have to reach this person's other devices, and
/// nothing in the Enclave can be exported. What is worth taking from Apple here is
/// the access control: with `requireBiometry`, the item is gated behind Touch ID
/// after a restart. That is a lock on the door, not a different safe.
///
/// **Unsigned builds fall back to the older, file-based keychain.** The data
/// protection keychain needs a signed app with an application identifier, and a
/// plain `swift run` build has neither, so macOS answers every call with
/// `errSecMissingEntitlement` (-34018). The first time that happens this store
/// switches to the legacy login keychain for the rest of its life. A signed
/// release build never sees -34018, so it never switches. The cost while
/// unsigned: no Touch ID gate and no "this device only" flag, because the legacy
/// keychain supports neither.
public final class KeychainKeyStore: KeyStore, @unchecked Sendable {
    private let service: String
    private let accessGroup: String?
    private let requireBiometry: Bool
    private let backend: KeychainBackend
    private let lock = NSLock()
    private var legacy = false

    public convenience init(service: String = "app.wellspent.keys",
                accessGroup: String? = nil,
                requireBiometry: Bool = false) {
        self.init(service: service, accessGroup: accessGroup,
                  requireBiometry: requireBiometry, backend: .system)
    }

    init(service: String, accessGroup: String?, requireBiometry: Bool,
         backend: KeychainBackend) {
        self.service = service
        self.accessGroup = accessGroup
        self.requireBiometry = requireBiometry
        self.backend = backend
    }

    /// True once this store has fallen back to the legacy keychain.
    public var usingLegacyKeychain: Bool { lock.withLock { legacy } }

    private struct MissingEntitlement: Error {}

    /// Runs `body` against the data protection keychain, and once more against the
    /// legacy one if macOS refuses for want of an entitlement.
    private func withFallback<T>(_ body: () throws -> T) throws -> T {
        do {
            return try body()
        } catch is MissingEntitlement {
            let switched: Bool = lock.withLock {
                if legacy { return false }
                legacy = true
                return true
            }
            guard switched else {
                throw KeyStoreError.backendFailure("\(errSecMissingEntitlement) even in the legacy keychain")
            }
            do {
                return try body()
            } catch is MissingEntitlement {
                throw KeyStoreError.backendFailure("\(errSecMissingEntitlement) even in the legacy keychain")
            }
        }
    }

    private func check(_ status: OSStatus) throws {
        if status == errSecMissingEntitlement { throw MissingEntitlement() }
    }

    private func baseQuery(_ item: KeyStoreItem, legacy: Bool? = nil) -> [String: Any] {
        var q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: item.rawValue,
            // The modern keychain, not the file-based one inherited from macOS 10,
            // unless this build is unsigned. See the type's comment.
            kSecUseDataProtectionKeychain as String: !(legacy ?? usingLegacyKeychain),
        ]
        if let accessGroup { q[kSecAttrAccessGroup as String] = accessGroup }
        return q
    }

    public func store(_ data: Data, for item: KeyStoreItem) throws {
        try withFallback { try storeOnce(data, for: item) }
    }

    private func storeOnce(_ data: Data, for item: KeyStoreItem) throws {
        try deleteOnce(item)

        var query = baseQuery(item)
        query[kSecValueData as String] = data

        if usingLegacyKeychain {
            // The legacy keychain ignores both access control and accessibility.
        } else if requireBiometry, item == .identity {
            var error: Unmanaged<CFError>?
            guard let access = SecAccessControlCreateWithFlags(
                nil,
                // "ThisDeviceOnly" keeps it out of an iCloud or iTunes backup. The
                // escrow blob is the recovery path, not a backup of the keychain.
                kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
                .userPresence,
                &error
            ) else {
                throw KeyStoreError.backendFailure("access control: \(String(describing: error?.takeRetainedValue()))")
            }
            query[kSecAttrAccessControl as String] = access
        } else {
            // After first unlock, so a background sync on iOS can still run.
            query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        }

        let status = backend.add(query)
        try check(status)
        guard status == errSecSuccess else {
            throw KeyStoreError.backendFailure("SecItemAdd \(status) for \(item.rawValue)")
        }
    }

    public func load(_ item: KeyStoreItem) throws -> Data? {
        if let data = try withFallback({ try loadOnce(item) }) { return data }
        // Reads are the exception to -34018: an unsigned build reading the data
        // protection keychain is told "not found", not refused, so the fallback
        // never fires on a read. After a restart, the keys an unsigned build saved
        // are in the legacy keychain, so look there before calling them missing.
        guard !usingLegacyKeychain else { return nil }
        return try loadOnce(item, legacy: true)
    }

    private func loadOnce(_ item: KeyStoreItem, legacy: Bool? = nil) throws -> Data? {
        var query = baseQuery(item, legacy: legacy)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        let (status, result) = backend.copy(query)
        try check(status)
        switch status {
        case errSecSuccess:
            return result
        case errSecItemNotFound:
            return nil
        case errSecUserCanceled, errSecAuthFailed:
            throw KeyStoreError.locked
        default:
            throw KeyStoreError.backendFailure("SecItemCopyMatching \(status) for \(item.rawValue)")
        }
    }

    public func delete(_ item: KeyStoreItem) throws {
        try withFallback { try deleteOnce(item) }
    }

    private func deleteOnce(_ item: KeyStoreItem) throws {
        let status = backend.delete(baseQuery(item))
        try check(status)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeyStoreError.backendFailure("SecItemDelete \(status) for \(item.rawValue)")
        }
    }

    public func removeAll() throws {
        for item in KeyStoreItem.allCases { try delete(item) }
    }
}

/// The three `SecItem` calls, behind a seam so the fallback can be tested without
/// a real keychain.
struct KeychainBackend: Sendable {
    var add: @Sendable ([String: Any]) -> OSStatus
    var copy: @Sendable ([String: Any]) -> (OSStatus, Data?)
    var delete: @Sendable ([String: Any]) -> OSStatus

    static let system = KeychainBackend(
        add: { SecItemAdd($0 as CFDictionary, nil) },
        copy: { query in
            var result: CFTypeRef?
            let status = SecItemCopyMatching(query as CFDictionary, &result)
            return (status, result as? Data)
        },
        delete: { SecItemDelete($0 as CFDictionary) }
    )
}
#endif
