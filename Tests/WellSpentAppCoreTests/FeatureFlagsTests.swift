import Foundation
import Testing
import WellSpentAppCore

@Suite("Feature flags")
struct FeatureFlagsTests {
    @Test func flagsCoerceWarTableWhenExtensionsAreDisabled() {
        let disabled = FeatureFlags(areExtensionsEnabled: false, isWarTableEnabled: true)
        #expect(!disabled.areExtensionsEnabled)
        #expect(!disabled.isWarTableEnabled)

        let bothEnabled = FeatureFlags(areExtensionsEnabled: true, isWarTableEnabled: true)
        #expect(bothEnabled.areExtensionsEnabled)
        #expect(bothEnabled.isWarTableEnabled)

        let extensionsOnly = FeatureFlags(areExtensionsEnabled: true, isWarTableEnabled: false)
        #expect(extensionsOnly.areExtensionsEnabled)
        #expect(!extensionsOnly.isWarTableEnabled)
    }

    @Test func isTruthyParsesExpectedValues() {
        #expect(FeatureFlags.isTruthy("1"))
        #expect(FeatureFlags.isTruthy("true"))
        #expect(FeatureFlags.isTruthy("TRUE"))
        #expect(FeatureFlags.isTruthy("yes"))
        #expect(FeatureFlags.isTruthy("on"))
        #expect(FeatureFlags.isTruthy("  yes  "))

        #expect(!FeatureFlags.isTruthy("0"))
        #expect(!FeatureFlags.isTruthy("false"))
        #expect(!FeatureFlags.isTruthy("no"))
        #expect(!FeatureFlags.isTruthy("off"))
        #expect(!FeatureFlags.isTruthy(""))
        #expect(!FeatureFlags.isTruthy("unknown"))
    }

    @Test func liveEnvironmentDisablesUnreleasedFeaturesByDefault() {
        let withNilDefaults = FeatureFlags.resolve(for: .live, defaults: nil, processEnvironment: [:])
        #expect(!withNilDefaults.areExtensionsEnabled)
        #expect(!withNilDefaults.isWarTableEnabled)

        let suiteName = "test.flags.live.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            Issue.record("could not create test defaults")
            return
        }
        defer { UserDefaults.standard.removePersistentDomain(forName: suiteName) }

        let resolved = FeatureFlags.resolve(for: .live, defaults: defaults, processEnvironment: [:])
        #expect(!resolved.areExtensionsEnabled)
        #expect(!resolved.isWarTableEnabled)

        defaults.set(true, forKey: FeatureFlags.extensionsDefaultsKey)
        let withExtensions = FeatureFlags.resolve(for: .live, defaults: defaults, processEnvironment: [:])
        #expect(withExtensions.areExtensionsEnabled)
        #expect(!withExtensions.isWarTableEnabled)

        defaults.set(true, forKey: FeatureFlags.warTableDefaultsKey)
        let withBoth = FeatureFlags.resolve(for: .live, defaults: defaults, processEnvironment: [:])
        #expect(withBoth.areExtensionsEnabled)
        #expect(withBoth.isWarTableEnabled)
    }

    @Test func stagingEnvironmentEnablesFeaturesByDefault() {
        let resolved = FeatureFlags.resolve(for: .staging, defaults: nil, processEnvironment: [:])
        #expect(resolved.areExtensionsEnabled)
        #expect(resolved.isWarTableEnabled)
    }

    @Test func stagingEnvironmentRespectsEnvironmentVariables() {
        let disabled = FeatureFlags.resolve(
            for: .staging,
            defaults: nil,
            processEnvironment: [FeatureFlags.extensionsVariable: "0"]
        )
        #expect(!disabled.areExtensionsEnabled)
        #expect(!disabled.isWarTableEnabled)

        let warTableDisabled = FeatureFlags.resolve(
            for: .staging,
            defaults: nil,
            processEnvironment: [
                FeatureFlags.extensionsVariable: "1",
                FeatureFlags.warTableVariable: "0"
            ]
        )
        #expect(warTableDisabled.areExtensionsEnabled)
        #expect(!warTableDisabled.isWarTableEnabled)
    }

    @Test func stagingEnvironmentRespectsDefaults() {
        let suiteName = "test.flags.staging.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            Issue.record("could not create test defaults")
            return
        }
        defer { UserDefaults.standard.removePersistentDomain(forName: suiteName) }

        defaults.set(false, forKey: FeatureFlags.extensionsDefaultsKey)
        let resolved = FeatureFlags.resolve(for: .staging, defaults: defaults, processEnvironment: [:])
        #expect(!resolved.areExtensionsEnabled)
        #expect(!resolved.isWarTableEnabled)

        defaults.set(true, forKey: FeatureFlags.extensionsDefaultsKey)
        defaults.set(false, forKey: FeatureFlags.warTableDefaultsKey)
        let warTableOff = FeatureFlags.resolve(for: .staging, defaults: defaults, processEnvironment: [:])
        #expect(warTableOff.areExtensionsEnabled)
        #expect(!warTableOff.isWarTableEnabled)
    }

    @Test @MainActor func workspaceInitializesFeaturesFromLaunch() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let app = try Workspace.launch(processEnvironment: [
            AccountDirectory.dataRootVariable: root.path,
            FeatureFlags.extensionsVariable: "0"
        ])
        #expect(!app.features.areExtensionsEnabled)
        #expect(!app.features.isWarTableEnabled)
    }
}
