import Testing
@testable import WellSpentLinux

/// The release the packaging step writes, as `wellspent --version` says it.
struct VersionTests {
    @Test func theVersionFileIsReadTrimmed() {
        #expect(LinuxSetup.version(in: "0.4.0\n") == "0.4.0")
    }

    @Test func noVersionFileIsADevelopmentBuild() {
        #expect(LinuxSetup.version(in: nil) == "0.0.0-dev")
        #expect(LinuxSetup.version(in: "  \n") == "0.0.0-dev")
    }
}
