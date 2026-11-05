import Foundation
#if canImport(SwiftUI)
import SwiftUI
#endif
import WellSpentExtensionKit

/// An extension with no feature of its own, so the public repo's tests can
/// reach the slots with no paid package linked. `WELLSPENT_TEST_EXTENSION=1`
/// turns it on in a staging build, and nothing turns it on in a release.
@MainActor
public final class TestExtensionSlots: ExtensionSlots {
    public static let environmentKey = "WELLSPENT_TEST_EXTENSION"
    public static let label = "Test link"
    public static let sectionWords = "Test extension section"
    /// The same every run, so a UI test can find it.
    public static let choice = HostLinkChoices.Choice(id: "6F0C0B52-0F8D-4C55-9D1A-2B1C3E4F5A6B", name: "Test choice")

    public init() {}

    public static func isOn(environment: AppEnvironment = .current,
                            processEnvironment: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        environment == .staging && processEnvironment[environmentKey] == "1"
    }

    public func linkChoices(in group: String) -> HostLinkChoices? {
        HostLinkChoices(label: Self.label, choices: [Self.choice])
    }

    public func groupPageTopLine(for group: String) -> HostTopLine? {
        HostTopLine(text: "Test question", amount: "$1", isWarning: false)
    }

    #if canImport(SwiftUI)
    public func groupPageSection(for group: String) -> AnyView? {
        AnyView(Text(Self.sectionWords).id(HostScrollID.groupPageSection))
    }
    #endif
}
