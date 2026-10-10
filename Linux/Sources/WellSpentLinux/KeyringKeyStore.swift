import Foundation
import WellSpentKeyStore
import WellSpentLinuxNative

/// The desktop keyring (Secret Service: GNOME Keyring, KWallet and the like),
/// the Linux counterpart of the Mac's Keychain. One entry per item, named by
/// `service`, the same per-build, per-account name the Mac app uses.
final class KeyringKeyStore: KeyStore, @unchecked Sendable {
    let service: String

    init(service: String) { self.service = service }

    func store(_ data: Data, for item: KeyStoreItem) throws {
        guard wellspent_keyring_store(service, item.rawValue, data.base64EncodedString()) == 1 else {
            throw KeyStoreError.backendFailure("the keyring refused to store \(item.rawValue)")
        }
    }

    func load(_ item: KeyStoreItem) throws -> Data? {
        var failed: Int32 = 0
        guard let value = wellspent_keyring_lookup(service, item.rawValue, &failed) else {
            // Nothing stored is nil; a keyring that is locked or refused is an
            // error, so a refusal is never taken for "never signed in".
            if failed != 0 { throw KeyStoreError.locked }
            return nil
        }
        defer { wellspent_keyring_free(value) }
        return Data(base64Encoded: String(cString: value))
    }

    func delete(_ item: KeyStoreItem) throws {
        guard wellspent_keyring_clear(service, item.rawValue) == 1 else {
            throw KeyStoreError.backendFailure("the keyring refused to clear \(item.rawValue)")
        }
    }

    func removeAll() throws { for item in KeyStoreItem.allCases { try delete(item) } }
}
