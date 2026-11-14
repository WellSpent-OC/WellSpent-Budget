import Foundation
import WellSpentAppCore
import WellSpentLinuxNative

/// GTK reports foreground changes and checks the wall clock every 30 seconds,
/// or every second on a test clock, which a test moves by a day at a time.
/// The shared workspace decides whether a new day needs new budget totals.
/// Sheets count as part of the app, so closing one does not start a sync.
@MainActor
enum LinuxLifecycle {
    private static weak var workspace: Workspace?
    /// The clock's check stands in for the Mac's "a new day began". A test
    /// clock set not to say so leaves only coming to the front to notice.
    /// Kept here, as the workspace is: GTK's callback can't capture anything.
    private static var checksTheClock = true

    static func watch(_ workspace: Workspace) {
        self.workspace = workspace
        checksTheClock = Workspace.clockAnnouncesDays(for: workspace.environment,
                                                      in: ProcessInfo.processInfo.environment)
        let seconds: UInt32 = workspace.clockIsPinned ? 1 : 30
        wellspent_watch_lifecycle(workspace.environment.linuxAppIdentifier, seconds) { cameToFront in
            Task { @MainActor in
                guard let workspace = LinuxLifecycle.workspace else { return }
                if cameToFront != 0 {
                    // Checks the date first, then syncs.
                    await workspace.cameToFront()
                } else if LinuxLifecycle.checksTheClock {
                    workspace.checkForNewDay()
                }
            }
        }
    }
}
