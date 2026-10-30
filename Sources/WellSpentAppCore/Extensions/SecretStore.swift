import Foundation
#if canImport(Security)
import Security
#endif

/// Where an extension keeps a secret a person gave it, such as their PriceLabs
/// key: on their own devices only, never on WellSpent's server.
public protocol SecretStore: AnyObject, Sendable {
    func secret(named name: String) -> String?
    func setSecret(_ value: String, named name: String) throws
    func removeSecret(named name: String)
}

/// For tests and a mock service: kept in memory, so no test ever touches a
/// real keychain.
public final class InMemorySecretStore: SecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: String] = [:]

    public init(_ values: [String: String] = [:]) { self.values = values }

    public func secret(named name: String) -> String? { lock.withLock { values[name] } }
    public func setSecret(_ value: String, named name: String) throws { lock.withLock { values[name] = value } }
    public func removeSecret(named name: String) { lock.withLock { values[name] = nil } }
}

#if canImport(Security)
/// iCloud Keychain on the Mac and the iPhone (Riley, 2026-10-30): a person
/// pastes a key once and their other Apple devices have it. It syncs through
/// Apple's end-to-end encrypted keychain, never through WellSpent's server.
/// Linux has no iCloud Keychain, so a Linux computer asks for its own paste.
public final class KeychainSecretStore: SecretStore, @unchecked Sendable {
    public static let service = "space.wellspent.extensions"
    private let service: String

    public init(service: String = KeychainSecretStore.service) { self.service = service }

    private func query(_ name: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: name,
         kSecAttrSynchronizable as String: kCFBooleanTrue as Any,
         kSecUseDataProtectionKeychain as String: true]
    }

    public func secret(named name: String) -> String? {
        var read = query(name)
        read[kSecReturnData as String] = true
        read[kSecMatchLimit as String] = kSecMatchLimitOne
        var found: AnyObject?
        guard SecItemCopyMatching(read as CFDictionary, &found) == errSecSuccess,
              let data = found as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public func setSecret(_ value: String, named name: String) throws {
        let data = Data(value.utf8)
        let status = SecItemUpdate(query(name) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var add = query(name)
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            let added = SecItemAdd(add as CFDictionary, nil)
            guard added == errSecSuccess else { throw SecretStoreError(status: added) }
        } else if status != errSecSuccess {
            throw SecretStoreError(status: status)
        }
    }

    public func removeSecret(named name: String) {
        SecItemDelete(query(name) as CFDictionary)
    }
}

public struct SecretStoreError: Error, Equatable {
    public let status: OSStatus
}
#endif
