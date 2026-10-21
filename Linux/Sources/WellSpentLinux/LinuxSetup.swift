import Foundation
import WellSpentAppCore
import WellSpentKeyStore

/// Which build this is, where it keeps its files and settings, and its keyring.
/// Everything else starts up exactly as on the Mac, through Workspace.launch.
enum LinuxSetup {
    /// From the file the packaging step writes. Only the exact word "live" is
    /// live, so a build nobody marked is staging and can never reach real data.
    static let environment: AppEnvironment = {
        let url = Bundle.module.url(forResource: "environment", withExtension: nil)
        let text = url.flatMap { try? String(contentsOf: $0, encoding: .utf8) }?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return AppEnvironment(infoPlistValue: text)
    }()

    /// $XDG_DATA_HOME, else ~/.local/share, then the build's own folder: "WellSpent"
    /// or "WellSpent Staging", as on the Mac. From $HOME, not the account record,
    /// which can differ.
    static var dataRoot: URL {
        let env = ProcessInfo.processInfo.environment
        let base: URL
        if let xdg = env["XDG_DATA_HOME"], !xdg.isEmpty {
            base = URL(fileURLWithPath: xdg)
        } else {
            base = URL(fileURLWithPath: env["HOME"] ?? NSHomeDirectory()).appendingPathComponent(".local/share")
        }
        return base.appendingPathComponent(environment.dataFolderName)
    }

    /// Settings, kept apart per build like the Mac's.
    static var defaults: UserDefaults {
        UserDefaults(suiteName: environment.defaultsSuiteName ?? "app.wellspent")!
    }

    @MainActor
    static func launch() throws -> Workspace {
        let defaults = self.defaults
        let environment = self.environment
        let accounts = AccountDirectory(root: dataRoot, defaults: defaults, makeKeyStore: { namespace in
            KeyringKeyStore(service: environment.keychainService(for: namespace))
        })
        // A staging build takes the same two test settings as the Mac's: how
        // long Undo stays, and a pinned day of the month for the money wheel.
        // A live build ignores both.
        let process = ProcessInfo.processInfo.environment
        return try Workspace.launch(accounts: accounts, defaults: defaults, environment: environment,
                                    undoWindow: Workspace.undoWindow(for: environment, in: process),
                                    pinnedDay: Workspace.pinnedDay(for: environment, in: process))
    }
}
