#if os(macOS)
import Foundation
import Testing

/// `scripts/profile-fit.sh`, which the release check runs on the exact app it
/// is about to upload. Each test hands it the pieces it would take out of a
/// signed app: a profile that fits, with one thing changed. A profile that
/// does not fit is the usual reason a TestFlight build will not open.
@Suite("A release's provisioning profile fits its app")
struct ProfileFitTests {
    static let team = "TEAM123456"
    static let appID = "\(team).app.wellspent.mac"
    static let certificate = Data("the certificate that signed the app".utf8)
    static let now = "2026-10-19T17:00:00Z"

    @Test func aProfileThatFitsPasses() throws {
        // The app's sandbox keys are not in the profile, and need not be.
        let result = try Self.check()
        #expect(result.status == 0, "\(result.said)")
    }

    @Test func aProfileForAnotherTeamIsRefused() throws {
        let result = try Self.check(profile: { $0["TeamIdentifier"] = ["OTHER12345"] })
        #expect(result.status == 1)
        #expect(result.said.contains("team \"OTHER12345\""), "\(result.said)")
    }

    @Test func aProfileForAnotherAppIsRefused() throws {
        let result = try Self.check(profile: { $0[allows: "com.apple.application-identifier"] = "\(Self.team).app.other" })
        #expect(result.status == 1)
        #expect(result.said.contains("com.apple.application-identifier"), "\(result.said)")
    }

    @Test func aProfileForEveryAppOfTheTeamFits() throws {
        let result = try Self.check(profile: { $0[allows: "com.apple.application-identifier"] = "\(Self.team).*" })
        #expect(result.status == 0, "\(result.said)")
    }

    @Test func aPermissionTheProfileDoesNotAllowIsRefused() throws {
        let result = try Self.check(claims: { $0["com.apple.developer.icloud-services"] = ["CloudKit"] })
        #expect(result.status == 1)
        #expect(result.said.contains("does not allow com.apple.developer.icloud-services"), "\(result.said)")
    }

    @Test func eachItemOfAListIsCheckedOnItsOwn() throws {
        let ours = try Self.check(claims: { $0["keychain-access-groups"] = [Self.appID] })
        #expect(ours.status == 0, "\(ours.said)")
        let another = try Self.check(claims: { $0["keychain-access-groups"] = [Self.appID, "OTHER12345.shared"] })
        #expect(another.status == 1)
        #expect(another.said.contains("keychain-access-groups"), "\(another.said)")
    }

    @Test func theIPhoneAppsKeyForItsAppIDIsCheckedToo() throws {
        let fits = try Self.check(profile: { $0[allows: "application-identifier"] = Self.appID },
                                  claims: { $0["application-identifier"] = Self.appID })
        #expect(fits.status == 0, "\(fits.said)")
        let other = try Self.check(profile: { $0[allows: "application-identifier"] = "\(Self.team).app.other" },
                                   claims: { $0["application-identifier"] = Self.appID })
        #expect(other.status == 1)
    }

    @Test func anAppThatClaimsNoAppIDIsRefused() throws {
        let result = try Self.check(claims: { $0["com.apple.application-identifier"] = nil })
        #expect(result.status == 1)
        #expect(result.said.contains("claims no app ID"), "\(result.said)")
    }

    @Test func aDevelopmentProfileIsRefused() throws {
        let result = try Self.check(profile: { $0["ProvisionedDevices"] = ["00008103-000A1B2C3D4E5F60"] })
        #expect(result.status == 1)
        #expect(result.said.contains("for development"), "\(result.said)")
    }

    @Test func aProfileWithoutTheSigningCertificateIsRefused() throws {
        let result = try Self.check(signedBy: Data("another certificate".utf8))
        #expect(result.status == 1)
        #expect(result.said.contains("certificate"), "\(result.said)")
    }

    @Test func anExpiredProfileIsRefused() throws {
        let result = try Self.check(profile: { $0["ExpirationDate"] = Self.date("2026-10-01T00:00:00Z") })
        #expect(result.status == 1)
        #expect(result.said.contains("ended"), "\(result.said)")
    }

    // MARK: - Running the script

    struct Result {
        let status: Int32
        let said: String
    }

    /// As Apple writes a Mac App Store profile.
    static func fittingProfile() -> [String: Any] {
        [
            "TeamIdentifier": [team],
            "ExpirationDate": date("2027-10-13T16:47:05Z"),
            "DeveloperCertificates": [certificate],
            "Entitlements": [
                "com.apple.application-identifier": appID,
                "com.apple.developer.team-identifier": team,
                "keychain-access-groups": ["\(team).*"],
            ] as [String: Any],
        ]
    }

    /// What the Mac app's signature claims, as make-app.sh signs it.
    static func fittingClaims() -> [String: Any] {
        [
            "com.apple.security.app-sandbox": true,
            "com.apple.security.network.client": true,
            "com.apple.security.files.user-selected.read-only": true,
            "com.apple.application-identifier": appID,
            "com.apple.developer.team-identifier": team,
        ]
    }

    static func check(profile changeProfile: (inout [String: Any]) -> Void = { _ in },
                      claims changeClaims: (inout [String: Any]) -> Void = { _ in },
                      signedBy signer: Data = certificate) throws -> Result {
        var profile = fittingProfile()
        changeProfile(&profile)
        var claims = fittingClaims()
        changeClaims(&claims)

        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("profile-fit-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let profileFile = folder.appendingPathComponent("profile.plist")
        let claimsFile = folder.appendingPathComponent("entitlements.plist")
        let certificateFile = folder.appendingPathComponent("certificate.der")
        try PropertyListSerialization.data(fromPropertyList: profile, format: .xml, options: 0).write(to: profileFile)
        try PropertyListSerialization.data(fromPropertyList: claims, format: .xml, options: 0).write(to: claimsFile)
        try signer.write(to: certificateFile)

        let script = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("scripts/profile-fit.sh")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [script.path, "--parts", profileFile.path, claimsFile.path, team,
                             certificateFile.path, now]
        let errors = Pipe()
        process.standardError = errors
        process.standardOutput = Pipe()
        try process.run()
        let said = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        return Result(status: process.terminationStatus, said: said)
    }

    static func date(_ text: String) -> Date {
        ISO8601DateFormatter().date(from: text) ?? .distantPast
    }
}

private extension Dictionary where Key == String, Value == Any {
    /// One permission in a profile's Entitlements.
    subscript(allows key: String) -> Any? {
        get { (self["Entitlements"] as? [String: Any])?[key] }
        set {
            var allowed = self["Entitlements"] as? [String: Any] ?? [:]
            allowed[key] = newValue
            self["Entitlements"] = allowed
        }
    }
}
#endif
