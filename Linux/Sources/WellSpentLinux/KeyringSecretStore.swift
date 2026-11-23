import Foundation
import WellSpentExtensionKit
import WellSpentLinuxNative

/// Where an extension keeps a secret a person gave it, such as a key for
/// another service, on Linux: the desktop keyring, as the Mac keeps it in the
/// Keychain. One service per build, not per account, as the Mac's is one per
/// device. It never reaches WellSpent's server.
final class KeyringSecretStore: SecretStore, @unchecked Sendable {
    let service: String

    init(service: String) { self.service = service }

    /// The store, or nil when no desktop keyring answers (no Secret Service
    /// running). Then the key is kept in memory, and the key sheet doesn't
    /// say it stays.
    static func reachable(service: String) -> KeyringSecretStore? {
        var failed: Int32 = 0
        let value = wellspent_keyring_lookup(service, "reachable", &failed)
        if let value { wellspent_keyring_free(value) }
        return failed == 0 ? KeyringSecretStore(service: service) : nil
    }

    func secret(named name: String) -> String? {
        var failed: Int32 = 0
        guard let value = wellspent_keyring_lookup(service, name, &failed) else { return nil }
        defer { wellspent_keyring_free(value) }
        return String(cString: value)
    }

    func setSecret(_ value: String, named name: String) throws {
        guard wellspent_keyring_store(service, name, value) == 1 else {
            throw KeyringSecretStoreError.refused(name)
        }
    }

    func removeSecret(named name: String) {
        _ = wellspent_keyring_clear(service, name)
    }
}

enum KeyringSecretStoreError: Error, Equatable {
    /// The keyring refused to store the named secret: locked, or no keyring.
    case refused(String)
}
