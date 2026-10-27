import Foundation
import Testing
import WellSpentAppCore

@Suite("Feature flags")
struct FeatureFlagsTests {
    @Test func flagsCoerceWarTableWhenExtensionsAreDisabled() {
        let disabled = FeatureFlags(areExtensionsEnabled: false, isWarTableEnabled: true, isRunwayEnabled: true)
        #expect(!disabled.areExtensionsEnabled)
        #expect(!disabled.isWarTableEnabled)
        #expect(!disabled.isRunwayEnabled)

        let bothEnabled = FeatureFlags(areExtensionsEnabled: true, isWarTableEnabled: true, isRunwayEnabled: true)
        #expect(bothEnabled.areExtensionsEnabled)
        #expect(bothEnabled.isWarTableEnabled)
        #expect(bothEnabled.isRunwayEnabled)

        let extensionsOnly = FeatureFlags(areExtensionsEnabled: true, isWarTableEnabled: false, isRunwayEnabled: false)
        #expect(extensionsOnly.areExtensionsEnabled)
        #expect(!extensionsOnly.isWarTableEnabled)
        #expect(!extensionsOnly.isRunwayEnabled)
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
        #expect(!withNilDefaults.isRunwayEnabled)

        let suiteName = "test.flags.live.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            Issue.record("could not create test defaults")
            return
        }
        defer { UserDefaults.standard.removePersistentDomain(forName: suiteName) }

        let resolved = FeatureFlags.resolve(for: .live, defaults: defaults, processEnvironment: [:])
        #expect(!resolved.areExtensionsEnabled)
        #expect(!resolved.isWarTableEnabled)
        #expect(!resolved.isRunwayEnabled)

        defaults.set(true, forKey: FeatureFlags.extensionsDefaultsKey)
        let withExtensions = FeatureFlags.resolve(for: .live, defaults: defaults, processEnvironment: [:])
        #expect(withExtensions.areExtensionsEnabled)
        #expect(!withExtensions.isWarTableEnabled)
        #expect(!withExtensions.isRunwayEnabled)

        defaults.set(true, forKey: FeatureFlags.warTableDefaultsKey)
        defaults.set(true, forKey: FeatureFlags.runwayDefaultsKey)
        let withAll = FeatureFlags.resolve(for: .live, defaults: defaults, processEnvironment: [:])
        #expect(withAll.areExtensionsEnabled)
        #expect(withAll.isWarTableEnabled)
        #expect(withAll.isRunwayEnabled)
    }

    @Test func stagingEnvironmentEnablesFeaturesByDefault() {
        let resolved = FeatureFlags.resolve(for: .staging, defaults: nil, processEnvironment: [:])
        #expect(resolved.areExtensionsEnabled)
        #expect(resolved.isWarTableEnabled)
        #expect(resolved.isRunwayEnabled)
    }

    @Test func stagingEnvironmentRespectsEnvironmentVariables() {
        let disabled = FeatureFlags.resolve(
            for: .staging,
            defaults: nil,
            processEnvironment: [FeatureFlags.extensionsVariable: "0"]
        )
        #expect(!disabled.areExtensionsEnabled)
        #expect(!disabled.isWarTableEnabled)
        #expect(!disabled.isRunwayEnabled)

        let runwayDisabled = FeatureFlags.resolve(
            for: .staging,
            defaults: nil,
            processEnvironment: [
                FeatureFlags.extensionsVariable: "1",
                FeatureFlags.warTableVariable: "1",
                FeatureFlags.runwayVariable: "0"
            ]
        )
        #expect(runwayDisabled.areExtensionsEnabled)
        #expect(runwayDisabled.isWarTableEnabled)
        #expect(!runwayDisabled.isRunwayEnabled)
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
