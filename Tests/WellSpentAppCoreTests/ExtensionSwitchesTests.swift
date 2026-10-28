import Foundation
import Testing
@testable import WellSpentAppCore

@Suite("Extension switches")
@MainActor
struct ExtensionSwitchesTests {
    private func freshDefaults() -> UserDefaults {
        let name = "ExtensionSwitchesTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    @Test func offUntilTurnedOnAndKeptPerAccount() {
        let defaults = freshDefaults()
        let a = ExtensionSwitches(defaults: defaults, account: { "account-a" })
        let b = ExtensionSwitches(defaults: defaults, account: { "account-b" })
        let nobody = ExtensionSwitches(defaults: defaults, account: { nil })
        #expect(!a.isOn("wellspent.properties"))

        a.set("wellspent.properties", on: true)
        #expect(a.isOn("wellspent.properties"))
        #expect(!b.isOn("wellspent.properties"))
        #expect(!nobody.isOn("wellspent.properties"))

        a.set("wellspent.properties", on: false)
        #expect(!a.isOn("wellspent.properties"))
        #expect(defaults.object(forKey: a.key(for: "wellspent.properties")) == nil)
    }

    @Test func followsTheAccountAsItChanges() {
        let defaults = freshDefaults()
        let box = AccountBox()
        let switches = ExtensionSwitches(defaults: defaults, account: { box.current })
        switches.set("wellspent.properties", on: true)
        #expect(switches.key(for: "wellspent.properties") == "extension.wellspent.properties.on")
        box.current = "account-a"
        #expect(switches.key(for: "wellspent.properties") == "extension.wellspent.properties.on.account-a")
        #expect(!switches.isOn("wellspent.properties"))
    }
}

@MainActor
private final class AccountBox {
    var current: String?
}
