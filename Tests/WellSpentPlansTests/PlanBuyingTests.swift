import Foundation
import Testing
import WellSpentPlans

// The purchases flag. These run in a test build, so the variable and the
// stored default are compiled in; the release rule, the list alone, is the
// `bundleFeatures` path every test here ends on.
struct PlanBuyingTests {
    @Test func offWithNothingSaying() {
        #expect(!PlanBuying.isOpen(processEnvironment: [:], defaults: nil, bundleFeatures: []))
        #expect(!PlanBuying.isOpen(processEnvironment: [:], defaults: nil, bundleFeatures: ["extensions"]),
                "only its own name turns it on")
    }

    @Test func aBuildsListTurnsItOn() {
        // A release build reads this alone.
        #expect(PlanBuying.isOpen(processEnvironment: [:], defaults: nil,
                                  bundleFeatures: BuildFeatures.parse("extensions, Purchases")))
    }

    @Test func aTestBuildsVariableComesFirst() {
        for on in ["1", "true", "on", "yes", "open", " ON "] {
            #expect(PlanBuying.isOpen(processEnvironment: [PlanBuying.variable: on], defaults: nil, bundleFeatures: []))
        }
        for off in ["0", "off", "no", "", "closed"] {
            #expect(!PlanBuying.isOpen(processEnvironment: [PlanBuying.variable: off], defaults: nil,
                                       bundleFeatures: ["purchases"]), "the variable wins over the list")
        }
    }

    @Test func aTestBuildsStoredDefaultComesBeforeTheList() throws {
        let suiteName = "test.purchases.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { UserDefaults.standard.removePersistentDomain(forName: suiteName) }
        #expect(!PlanBuying.isOpen(processEnvironment: [:], defaults: defaults, bundleFeatures: []),
                "nothing stored is the list's answer")
        defaults.set(true, forKey: PlanBuying.defaultsKey)
        #expect(PlanBuying.isOpen(processEnvironment: [:], defaults: defaults, bundleFeatures: []))
        defaults.set(false, forKey: PlanBuying.defaultsKey)
        #expect(!PlanBuying.isOpen(processEnvironment: [:], defaults: defaults, bundleFeatures: ["purchases"]))
        #expect(PlanBuying.isOpen(processEnvironment: [PlanBuying.variable: "on"], defaults: defaults,
                                  bundleFeatures: []), "the variable wins over the default")
    }

    @Test func theListIsReadLoosely() {
        #expect(BuildFeatures.parse(" Extensions , PURCHASES ,, ") == ["extensions", "purchases"])
        #expect(BuildFeatures.parse("purchases\n") == ["purchases"], "Linux's file ends in a new line")
        #expect(BuildFeatures.parse("") == [])
        #expect(BuildFeatures.parse(nil) == [], "no file, or no Info.plist key, is none")
        #expect(BuildFeatures.parse(["purchases"]) == [])
    }
}
