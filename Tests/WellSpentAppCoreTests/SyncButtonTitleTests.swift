import Testing
@testable import WellSpentAppCore

/// A Sync button with a spinner beside it keeps its label while a sync runs,
/// so a narrow sidebar never squeezes a longer word into one letter a line.
struct SyncButtonTitleTests {
    @Test func whileASyncRunsTheButtonStillSaysSync() {
        #expect(SyncWording.syncButtonTitle(for: .busy("Syncing")) == "Sync")
        #expect(SyncWording.syncButtonTitle(for: .busy("Signing in")) == "Sync")
    }

    @Test func otherwiseItSaysWhatTheSyncTitleSays() {
        for state: SyncCoordinator.State in [.signedOut, .signedIn(email: "a@example.com"), .failed("No network")] {
            #expect(SyncWording.syncButtonTitle(for: state) == SyncWording.syncTitle(for: state))
        }
    }
}
