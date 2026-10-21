#if os(macOS)
import Foundation
import Testing

/// `scripts/release-check.sh` holds each app to its export answer before it
/// uploads. App Store Connect asks each upload whether the app uses encryption
/// that export rules do not exempt, and holds the build until someone answers.
/// An app that does not answer no is stopped here instead. Each test makes a
/// bare app, its Info.plist and nothing else, so the check finds other problems
/// too. Only what it says about the export answer is read.
@Suite("A release answers the export question")
struct ReleaseCheckTests {
    enum Kind: CaseIterable {
        case mac, iPhone
    }

    @Test(arguments: Kind.allCases)
    func anAppWithNoAnswerIsStopped(kind: Kind) throws {
        let result = try Self.check(kind, answer: nil)
        #expect(result.status == 1)
        #expect(result.said.contains("ITSAppUsesNonExemptEncryption is \"\", not \"false\""), "\(result.said)")
    }

    @Test(arguments: Kind.allCases)
    func anAppThatAnswersYesIsStopped(kind: Kind) throws {
        let result = try Self.check(kind, answer: true)
        #expect(result.status == 1)
        #expect(result.said.contains("ITSAppUsesNonExemptEncryption is \"true\", not \"false\""), "\(result.said)")
    }

    @Test(arguments: Kind.allCases)
    func anAppThatAnswersNoPassesThisPoint(kind: Kind) throws {
        let result = try Self.check(kind, answer: false)
        #expect(!result.said.contains("ITSAppUsesNonExemptEncryption"), "\(result.said)")
    }

    // MARK: - Running the script

    /// The release check's verdict on a bare app of `kind` whose Info.plist
    /// gives `answer`, or gives none, and claims the invite link types in
    /// `links`, one group of types each, if any. An iPhone app keeps its
    /// Info.plist at the top, a Mac app in Contents, which is how the check
    /// tells them apart.
    static func check(_ kind: Kind, answer: Bool?, links: [[String]]? = nil) throws -> ScriptRun {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("release-check-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let app = folder.appendingPathComponent(kind == .mac ? "WellSpent.app" : "WellSpentPhone.app")
        let plist = app.appendingPathComponent(kind == .mac ? "Contents/Info.plist" : "Info.plist")
        var info: [String: Any] = ["CFBundleShortVersionString": "0.2.0", "CFBundleVersion": "1",
                                   "CFBundleIdentifier": "app.wellspent.mac", "WellSpentEnvironment": "live"]
        if let answer { info["ITSAppUsesNonExemptEncryption"] = answer }
        if let links { info["CFBundleURLTypes"] = links.map { ["CFBundleURLSchemes": $0] } }
        try FileManager.default.createDirectory(at: plist.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: plist)
        return try ScriptRun.run("release-check.sh", [app.path, "0.2.0", "1"])
    }
}

/// Each app takes live's invite links and no other type, so a staging link
/// never opens it. Only what the check says about link types is read.
@Suite("A release takes live's invite links only")
struct ReleaseLinkTypeTests {
    @Test(arguments: ReleaseCheckTests.Kind.allCases)
    func anAppTakingStagingLinksIsStopped(kind: ReleaseCheckTests.Kind) throws {
        let result = try ReleaseCheckTests.check(kind, answer: false, links: [["wellspent-staging"]])
        #expect(result.status == 1)
        #expect(result.said.contains("CFBundleURLSchemes:0 is \"wellspent-staging\", not \"wellspent\""),
                "\(result.said)")
    }

    @Test(arguments: ReleaseCheckTests.Kind.allCases)
    func anAppTakingBothTypesIsStopped(kind: ReleaseCheckTests.Kind) throws {
        let result = try ReleaseCheckTests.check(kind, answer: false, links: [["wellspent", "wellspent-staging"]])
        #expect(result.status == 1)
        #expect(result.said.contains("more than one invite link type"), "\(result.said)")
    }

    @Test(arguments: ReleaseCheckTests.Kind.allCases)
    func anAppWithASecondLinkGroupIsStopped(kind: ReleaseCheckTests.Kind) throws {
        let result = try ReleaseCheckTests.check(kind, answer: false, links: [["wellspent"], ["wellspent-staging"]])
        #expect(result.status == 1)
        #expect(result.said.contains("more than one link group"), "\(result.said)")
    }

    @Test(arguments: ReleaseCheckTests.Kind.allCases)
    func anAppTakingLivesLinksPassesThisPoint(kind: ReleaseCheckTests.Kind) throws {
        let result = try ReleaseCheckTests.check(kind, answer: false, links: [["wellspent"]])
        #expect(!result.said.contains("CFBundleURL"), "\(result.said)")
        #expect(!result.said.contains("link type"), "\(result.said)")
        #expect(!result.said.contains("link group"), "\(result.said)")
    }
}
#endif
