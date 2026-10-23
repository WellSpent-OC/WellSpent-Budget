import WellSpentAppCore
import WellSpentLinuxNative

/// GTK reports foreground changes and checks the wall clock every 30 seconds.
/// The shared workspace decides whether a new day needs new budget totals.
/// Sheets count as part of the app, so closing one does not start a sync.
@MainActor
enum LinuxLifecycle {
    private static weak var workspace: Workspace?

    static func watch(_ workspace: Workspace) {
        self.workspace = workspace
        wellspent_watch_lifecycle(workspace.environment.linuxAppIdentifier, 30) { cameToFront in
            Task { @MainActor in
                guard let workspace = LinuxLifecycle.workspace else { return }
                workspace.checkForNewDay()
                if cameToFront != 0 { await workspace.cameToFront() }
            }
        }
    }
}
