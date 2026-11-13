import Testing
import WellSpentAppCore
@testable import WellSpentLinux

/// The launcher picks its shell from the same flags the workspace gets.
struct LaunchFeaturesTests {
    @Test func theNativeShellFollowsItsFlag() {
        #expect(LinuxSetup.features(processEnvironment: [FeatureFlags.nativeShellVariable: "1"]).isNativeShellEnabled)
        #expect(!LinuxSetup.features(processEnvironment: [FeatureFlags.nativeShellVariable: "0"]).isNativeShellEnabled)
    }
}
