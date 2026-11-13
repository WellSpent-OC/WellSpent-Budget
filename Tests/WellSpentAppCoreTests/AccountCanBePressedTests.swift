import Testing
@testable import WellSpentAppCore

/// #199: a sync turned Account off, so a tap that came as one started did
/// nothing. The app syncs on its own, so now and then a tap was lost.
struct AccountCanBePressedTests {
    @Test func whileASyncRunsAccountCanBePressed() {
        #expect(SyncWording.accountCanBePressed(for: .busy(SyncWording.syncing)))
    }

    @Test func whileSigningInOrMakingAnAccountItCannot() {
        #expect(!SyncWording.accountCanBePressed(for: .busy("Signing in")))
        #expect(!SyncWording.accountCanBePressed(for: .busy("Creating your account")))
        #expect(!SyncWording.accountCanBePressed(for: .busy("Setting a new password")))
    }

    @Test func otherwiseItCanBePressed() {
        for state: SyncCoordinator.State in [.signedOut, .signedIn(email: "a@example.com"), .failed("No network")] {
            #expect(SyncWording.accountCanBePressed(for: state))
        }
    }
}
