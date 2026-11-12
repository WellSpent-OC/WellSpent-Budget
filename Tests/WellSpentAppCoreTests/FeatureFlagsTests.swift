import Foundation
import Testing
import WellSpentAppCore
import WellSpentPlans

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

    @Test func aBuildCarriesItsFlagsInItsInfoPlist() {
        // A TestFlight build is a live build that lists the flags it carries,
        // so testers reach extensions with no switch.
        let testFlight = FeatureFlags.bundleFeatures(from: "extensions,properties")
        let live = FeatureFlags.resolve(for: .live, defaults: nil, processEnvironment: [:],
                                        bundleFeatures: testFlight)
        #expect(live.areExtensionsEnabled && live.isPropertiesEnabled)
        #expect(!live.isWarTableEnabled, "only the flags named")

        // An App Store build, made without the list, has none, in either
        // environment's name.
        for environment in AppEnvironment.allCases {
            let bare = FeatureFlags.resolve(for: environment, defaults: nil, processEnvironment: [:],
                                            bundleFeatures: [])
            #expect(!bare.areExtensionsEnabled && !bare.isWarTableEnabled && !bare.isPropertiesEnabled)
        }

        // The list is read loosely: spaces and case are ignored, and anything
        // but a string is none.
        #expect(FeatureFlags.bundleFeatures(from: " Extensions , PROPERTIES ,, ") == ["extensions", "properties"])
        #expect(FeatureFlags.bundleFeatures(from: "") == [])
        #expect(FeatureFlags.bundleFeatures(from: nil) == [])
        #expect(FeatureFlags.bundleFeatures(from: ["extensions"]) == [])
        #expect(FeatureFlags.bundleFeatures(in: Bundle(for: BundleMarker.self)) == [],
                "the test bundle carries no flags")
    }

    @Test func theEnvironmentAndTheDefaultsOutrankTheInfoPlist() {
        let carried = FeatureFlags.bundleFeatures(from: "extensions,properties")
        let offByVariable = FeatureFlags.resolve(for: .live, defaults: nil,
                                                 processEnvironment: [FeatureFlags.propertiesVariable: "0"],
                                                 bundleFeatures: carried)
        #expect(offByVariable.areExtensionsEnabled && !offByVariable.isPropertiesEnabled)

        let suiteName = "test.flags.bundle.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            Issue.record("could not create test defaults")
            return
        }
        defer { UserDefaults.standard.removePersistentDomain(forName: suiteName) }
        defaults.set(false, forKey: FeatureFlags.extensionsDefaultsKey)
        let offByDefault = FeatureFlags.resolve(for: .live, defaults: defaults, processEnvironment: [:],
                                                bundleFeatures: carried)
        #expect(!offByDefault.areExtensionsEnabled && !offByDefault.isPropertiesEnabled,
                "a stored default wins over the list, and extensions off takes Properties with it")
    }

    @Test func purchasesIsOffUntilAReleaseListsIt() {
        for environment in AppEnvironment.allCases {
            #expect(!FeatureFlags.resolve(for: environment, defaults: nil, processEnvironment: [:],
                                          bundleFeatures: []).isPurchasingEnabled)
            #expect(FeatureFlags.resolve(for: environment, defaults: nil, processEnvironment: [:],
                                         bundleFeatures: ["purchases"]).isPurchasingEnabled)
        }
        #expect(!FeatureFlags.resolve(for: .live, defaults: nil, processEnvironment: [:],
                                      bundleFeatures: ["extensions"]).isPurchasingEnabled,
                "extensions don't bring purchases with them")
        #expect(FeatureFlags(isPurchasingEnabled: true).isPurchasingEnabled,
                "purchases doesn't need extensions")
    }

    @Test func purchasesReadsATestBuildsVariableAndStoredDefault() throws {
        let on = FeatureFlags.resolve(for: .staging, defaults: nil,
                                      processEnvironment: [PlanBuying.variable: "1"], bundleFeatures: [])
        #expect(on.isPurchasingEnabled)

        let suiteName = "test.flags.purchases.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { UserDefaults.standard.removePersistentDomain(forName: suiteName) }
        defaults.set(true, forKey: PlanBuying.defaultsKey)
        #expect(FeatureFlags.resolve(for: .staging, defaults: defaults, processEnvironment: [:],
                                     bundleFeatures: []).isPurchasingEnabled)
    }

    @Test func thePurchasesFlagAndTheScreensAgreeWithNothingStored() throws {
        // The screens ask PlanBuying with no stored settings; the app's flags
        // pass its suite. With nothing stored, the two must agree.
        let suiteName = "test.flags.agree.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { UserDefaults.standard.removePersistentDomain(forName: suiteName) }
        let cases: [([String: String], Set<String>)] = [
            ([:], []), ([:], ["purchases"]), ([PlanBuying.variable: "on"], []), ([PlanBuying.variable: "off"], ["purchases"]),
        ]
        for (environment, list) in cases {
            let flags = FeatureFlags.resolve(for: .staging, defaults: defaults, processEnvironment: environment,
                                             bundleFeatures: list)
            #expect(flags.isPurchasingEnabled == PlanBuying.isOpen(processEnvironment: environment, bundleFeatures: list))
        }
    }

    @Test func theNativeShellIsOffUntilSomethingTurnsItOn() throws {
        for environment in AppEnvironment.allCases {
            #expect(!FeatureFlags.resolve(for: environment, defaults: nil, processEnvironment: [:],
                                          bundleFeatures: []).isNativeShellEnabled)
        }
        #expect(FeatureFlags.resolve(for: .staging, defaults: nil,
                                     processEnvironment: [FeatureFlags.nativeShellVariable: "1"],
                                     bundleFeatures: []).isNativeShellEnabled)
        #expect(FeatureFlags.resolve(for: .live, defaults: nil, processEnvironment: [:],
                                     bundleFeatures: ["native"]).isNativeShellEnabled)
        #expect(!FeatureFlags.resolve(for: .live, defaults: nil,
                                      processEnvironment: [FeatureFlags.nativeShellVariable: "0"],
                                      bundleFeatures: ["native"]).isNativeShellEnabled,
                "the variable outranks the list")
        #expect(!FeatureFlags.resolve(for: .live, defaults: nil, processEnvironment: [:],
                                      bundleFeatures: ["extensions"]).isNativeShellEnabled,
                "extensions don't bring the native shell with them")
        #expect(FeatureFlags(isNativeShellEnabled: true).isNativeShellEnabled,
                "the native shell doesn't need extensions")

        let suiteName = "test.flags.native.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { UserDefaults.standard.removePersistentDomain(forName: suiteName) }
        defaults.set(true, forKey: FeatureFlags.nativeShellDefaultsKey)
        #expect(FeatureFlags.resolve(for: .staging, defaults: defaults, processEnvironment: [:],
                                     bundleFeatures: []).isNativeShellEnabled)
        defaults.set(false, forKey: FeatureFlags.nativeShellDefaultsKey)
        #expect(!FeatureFlags.resolve(for: .staging, defaults: defaults, processEnvironment: [:],
                                      bundleFeatures: ["native"]).isNativeShellEnabled,
                "a stored default outranks the list")
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

/// Names the test bundle for the Info.plist read.
private final class BundleMarker {}
