import Foundation

/// Which extensions a person has turned on, kept on this device, per account.
/// Turning one on is a choice about this computer, not a record that syncs:
/// a live build on another device stays as it was. Signed out, the choice is
/// kept under no account, so it does not leak into the next person's sign-in.
@MainActor
public struct ExtensionSwitches {
    private let defaults: UserDefaults
    private let account: () -> String?

    /// `account` is read on every call, because signing in or out replaces it.
    public init(defaults: UserDefaults, account: @escaping () -> String?) {
        self.defaults = defaults
        self.account = account
    }

    /// The defaults key for an extension on the current account.
    public func key(for extensionID: String) -> String {
        if let account = account() {
            return "extension.\(extensionID).on.\(account)"
        }
        return "extension.\(extensionID).on"
    }

    public func isOn(_ extensionID: String) -> Bool {
        defaults.bool(forKey: key(for: extensionID))
    }

    public func set(_ extensionID: String, on: Bool) {
        if on {
            defaults.set(true, forKey: key(for: extensionID))
        } else {
            defaults.removeObject(forKey: key(for: extensionID))
        }
    }
}
