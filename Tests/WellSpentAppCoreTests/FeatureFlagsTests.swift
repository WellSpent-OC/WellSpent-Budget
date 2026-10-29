import Foundation
import Testing
import WellSpentAppCore

@Suite("Feature flags")
struct FeatureFlagsTests {
    @Test func flagsCoerceWarTableWhenExtensionsAreDisabled() {
        let disabled = FeatureFlags(areExtensionsEnabled: false, isWarTableEnabled: true, isPropertiesEnabled: true)
        #expect(!disabled.areExtensionsEnabled)
        #expect(!disabled.isWarTableEnabled)
        #expect(!disabled.isPropertiesEnabled)

        let bothEnabled = FeatureFlags(areExtensionsEnabled: true, isWarTableEnabled: true, isPropertiesEnabled: true)
        #expect(bothEnabled.areExtensionsEnabled)
        #expect(bothEnabled.isWarTableEnabled)
        #expect(bothEnabled.isPropertiesEnabled)

        let extensionsOnly = FeatureFlags(areExtensionsEnabled: true, isWarTableEnabled: false, isPropertiesEnabled: false)
        #expect(extensionsOnly.areExtensionsEnabled)
        #expect(!extensionsOnly.isWarTableEnabled)
        #expect(!extensionsOnly.isPropertiesEnabled)
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
        #expect(!withNilDefaults.isPropertiesEnabled)

        let suiteName = "test.flags.live.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            Issue.record("could not create test defaults")
            return
        }
        defer { UserDefaults.standard.removePersistentDomain(forName: suiteName) }

        let resolved = FeatureFlags.resolve(for: .live, defaults: defaults, processEnvironment: [:])
        #expect(!resolved.areExtensionsEnabled)
        #expect(!resolved.isWarTableEnabled)
        #expect(!resolved.isPropertiesEnabled)

        defaults.set(true, forKey: FeatureFlags.extensionsDefaultsKey)
        let withExtensions = FeatureFlags.resolve(for: .live, defaults: defaults, processEnvironment: [:])
        #expect(withExtensions.areExtensionsEnabled)
        #expect(!withExtensions.isWarTableEnabled)
        #expect(!withExtensions.isPropertiesEnabled)

        defaults.set(true, forKey: FeatureFlags.warTableDefaultsKey)
        defaults.set(true, forKey: FeatureFlags.propertiesDefaultsKey)
        let withAll = FeatureFlags.resolve(for: .live, defaults: defaults, processEnvironment: [:])
        #expect(withAll.areExtensionsEnabled)
        #expect(withAll.isWarTableEnabled)
        #expect(withAll.isPropertiesEnabled)
    }

    @Test func stagingEnvironmentDisablesFeaturesByDefault() {
        let resolved = FeatureFlags.resolve(for: .staging, defaults: nil, processEnvironment: [:])
        #expect(!resolved.areExtensionsEnabled)
        #expect(!resolved.isWarTableEnabled)
        #expect(!resolved.isPropertiesEnabled)
    }

    @Test func stagingEnvironmentEnablesFeaturesWithEnvironmentVariable() {
        let enabled = FeatureFlags.resolve(
            for: .staging,
            defaults: nil,
            processEnvironment: [
                FeatureFlags.extensionsVariable: "1",
                FeatureFlags.warTableVariable: "1",
                FeatureFlags.propertiesVariable: "1"
            ]
        )
        #expect(enabled.areExtensionsEnabled)
        #expect(enabled.isWarTableEnabled)
        #expect(enabled.isPropertiesEnabled)
    }

    @Test func stagingEnvironmentRespectsEnvironmentVariables() {
        let disabled = FeatureFlags.resolve(
            for: .staging,
            defaults: nil,
            processEnvironment: [FeatureFlags.extensionsVariable: "0"]
        )
        #expect(!disabled.areExtensionsEnabled)
        #expect(!disabled.isWarTableEnabled)
        #expect(!disabled.isPropertiesEnabled)

        let propertiesDisabled = FeatureFlags.resolve(
            for: .staging,
            defaults: nil,
            processEnvironment: [
                FeatureFlags.extensionsVariable: "1",
                FeatureFlags.warTableVariable: "1",
                FeatureFlags.propertiesVariable: "0"
            ]
        )
        #expect(propertiesDisabled.areExtensionsEnabled)
        #expect(propertiesDisabled.isWarTableEnabled)
        #expect(!propertiesDisabled.isPropertiesEnabled)
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
