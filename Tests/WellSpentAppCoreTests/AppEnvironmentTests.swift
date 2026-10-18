import Testing
import Foundation
@testable import WellSpentAppCore
import WellSpentCrypto
import WellSpentKeyStore
import WellSpentModel
import WellSpentStore
import WellSpentSync

/// One Mac login for one build, in memory: databases, a keychain per account,
/// and defaults of its own.
@MainActor
private final class Build {
    let environment: AppEnvironment
    let defaults = UserDefaults(suiteName: "app.wellspent.tests.\(UUID().uuidString)")!
    var keychains: [String: InMemoryKeyStore] = [:]
    lazy var accounts = AccountDirectory(root: nil, defaults: defaults) { [unowned self] namespace in
        let key = namespace ?? "older"
        if let existing = keychains[key] { return existing }
        let store = InMemoryKeyStore()
        keychains[key] = store
        return store
    }
    let transport = StubReadableTransport()

    init(_ environment: AppEnvironment, serverSays: String?) {
        self.environment = environment
        transport.serverEnvironment = serverSays
    }

    func launch(server: String? = nil) throws -> Workspace {
        if let server { defaults.set(server, forKey: SyncCoordinator.serverAddressKey) }
        let transport = self.transport
        return try Workspace.launch(accounts: accounts, defaults: defaults, environment: environment,
                                    makeTransport: { _ in transport })
    }

    func keys(of email: String) -> any KeyStore {
        accounts.keyStore(for: AccountDirectory.namespace(for: email))
    }
}

/// Records the keychain services a directory asks for, and keeps nothing in the
/// real keychain.
@MainActor
private final class KeychainNames {
    var asked: [String] = []
    func make(_ service: String) -> any KeyStore {
        asked.append(service)
        return InMemoryKeyStore()
    }
}

private func temporaryFolder() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("wellspent-environments-\(UUID().uuidString)")
}

/// Every file under `root`, as paths relative to it.
private func files(under root: URL) -> [String] {
    let found = FileManager.default.enumerator(atPath: root.path)?.allObjects as? [String] ?? []
    return found.filter { path in
        var isFolder: ObjCBool = false
        FileManager.default.fileExists(atPath: root.appendingPathComponent(path).path,
                                       isDirectory: &isFolder)
        return !isFolder.boolValue
    }.sorted()
}

@Suite("Live and staging builds", .serialized)
@MainActor
struct AppEnvironmentTests {

    // MARK: - Names

    /// The live app's real budgets sit under these names on people's Macs. If any
    /// one of them changes, the live app opens an empty budget, or a different
    /// one, and the real data looks lost. So each is pinned to the exact string.
    @Test func theLiveBuildKeepsTodaysNames() {
        let live = AppEnvironment.live
        #expect(live.dataFolderName == "WellSpent")
        #expect(live.keychainService == "app.wellspent.keys")
        #expect(live.keychainService(for: nil) == "app.wellspent.keys")
        #expect(live.keychainService(for: "f05d39646dbce98985a5") == "app.wellspent.keys.f05d39646dbce98985a5")
        #expect(live.defaultsSuiteName == nil)
        #expect(live.defaults === UserDefaults.standard, "live keeps the standard settings")
        #expect(live.bundleIdentifier == "app.wellspent.mac")
        #expect(live.appName == "WellSpent")
        #expect(live.defaultServerAddress == "https://sync.wellspent.space")

        // The keys inside those settings, and the account folder names, are
        // shared by both builds. The suite keeps them apart.
        #expect(SyncCoordinator.serverAddressKey == "WellSpentServerAddress")
        #expect(AccountDirectory.lastAccountKey == "WellSpentLastAccount")
        #expect(AccountDirectory.samplesSeededKey == "WellSpentSamplesSeeded")
        #expect(AccountDirectory.namespace(for: "robin@example.com") == "f05d39646dbce98985a5",
                "an account's files and keychain items are found by this name")
        #expect(AppEnvironment.infoPlistKey == "WellSpentEnvironment")
    }

    @Test func stagingDiffersFromLiveOnEveryPoint() {
        let live = AppEnvironment.live, staging = AppEnvironment.staging
        #expect(staging.dataFolderName == "WellSpent Staging")
        #expect(staging.keychainService == "app.wellspent.staging.keys")
        #expect(staging.defaultsSuiteName == "app.wellspent.staging")
        #expect(staging.bundleIdentifier == "app.wellspent.mac.staging")
        #expect(staging.appName == "WellSpent Staging")
        #expect(staging.defaultServerAddress == "https://staging.wellspent.space")

        #expect(staging.dataFolderName != live.dataFolderName)
        #expect(staging.defaultsSuiteName != live.defaultsSuiteName)
        #expect(staging.defaults !== UserDefaults.standard)
        #expect(staging.bundleIdentifier != live.bundleIdentifier)
        #expect(staging.appName != live.appName)
        #expect(staging.defaultServerAddress != live.defaultServerAddress)
        // Neither name starts with the other, so no staging item can be mistaken
        // for a live one by its name, or the reverse.
        for namespace in [nil, "f05d39646dbce98985a5"] {
            let ours = staging.keychainService(for: namespace)
            #expect(!ours.hasPrefix(live.keychainService))
            #expect(!live.keychainService(for: namespace).hasPrefix(staging.keychainService))
        }
        // macOS will not use a suite named after the app's own bundle ID.
        #expect(staging.defaultsSuiteName != staging.bundleIdentifier)
    }

    /// Anything not marked live counts as staging, because the dangerous mistake
    /// is a test build that thinks it is live.
    @Test func onlyExactlyLiveIsLive() {
        #expect(AppEnvironment(infoPlistValue: "live") == .live)
        let others: [Any?] = [nil, "", "staging", "Live", "LIVE", " live", "live ", "production", 1, true]
        for value in others {
            #expect(AppEnvironment(infoPlistValue: value) == .staging, "\(String(describing: value))")
        }
        // `swift test`, like `make run`, is a bare executable with no Info.plist.
        #expect(AppEnvironment.current == .staging)
    }

    /// The beta workflow checks the Info.plist key the build script writes. Both
    /// must be the key the app reads, or a live beta would quietly run as staging.
    @Test func theBuildScriptWritesWhatTheAppReads() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let script = try String(contentsOf: root.appendingPathComponent("scripts/make-app.sh"), encoding: .utf8)
        let workflow = try String(contentsOf: root.appendingPathComponent(".github/workflows/beta.yml"),
                                  encoding: .utf8)
        #expect(script.contains("<key>\(AppEnvironment.infoPlistKey)</key>"))
        #expect(workflow.contains(":\(AppEnvironment.infoPlistKey)"))
        for environment in AppEnvironment.allCases {
            #expect(script.contains("\"\(environment.bundleIdentifier)\""))
            #expect(script.contains("\"\(environment.appName)\""))
        }
        #expect(workflow.contains(AppEnvironment.live.bundleIdentifier))

        // The App Store build is sandboxed, so macOS must move the live data folder
        // into the app's container on the first launch, or the app opens empty.
        #expect(script.contains("<key>com.apple.security.app-sandbox</key><true/>"))
        #expect(script.contains("container-migration.plist"))
        #expect(script.contains("{ApplicationSupport}/\(AppEnvironment.live.dataFolderName)</string>"))
    }

    /// macOS opens an app for a click on a link only if its Info.plist says it
    /// takes that link type. Each build claims its own, so a click opens the
    /// build whose server made the invite. The script writes one Info.plist
    /// for both signings, ad hoc and App Store, so it is read here as the
    /// script writes it, for each build with the values that build's case
    /// sets. The UI test's host app is a staging build and claims staging's,
    /// so the test can open a link with it.
    @Test func eachBuildTakesItsOwnInviteLinks() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let script = try String(contentsOf: root.appendingPathComponent("scripts/make-app.sh"), encoding: .utf8)
        let start = try #require(script.range(of: "cat > \"$APP/Contents/Info.plist\" <<EOF\n"))
        let end = try #require(script.range(of: "\nEOF\n", range: start.upperBound..<script.endIndex))
        let written = String(script[start.upperBound..<end.lowerBound])
        for environment in AppEnvironment.allCases {
            let sets = Self.values(setFor: environment, in: script)
            var values = ["$VERSION": "0.1.0", "$BUILD": "1", "$WELLSPENT_ENV": environment.rawValue]
            for name in ["NAME", "BUNDLE_ID", "LINK_SCHEME"] {
                values["$" + name] = try #require(sets[name], "the \(environment) case sets no \(name)")
            }
            var plist = written
            for (name, value) in values { plist = plist.replacingOccurrences(of: name, with: value) }
            let info = try #require(try PropertyListSerialization.propertyList(from: Data(plist.utf8), format: nil)
                                        as? [String: Any])
            #expect(info["CFBundleIdentifier"] as? String == environment.bundleIdentifier)
            let types = try #require(info["CFBundleURLTypes"] as? [[String: Any]], "no link types in \(info.keys)")
            #expect(types.flatMap { $0["CFBundleURLSchemes"] as? [String] ?? [] } == [environment.inviteScheme],
                    "\(environment)")
        }
        let appStoreOnly = try #require(script.range(of: "if [ \"$SIGN\" = appstore ]; then\n    plist="))
        #expect(appStoreOnly.lowerBound > end.upperBound, "the Info.plist is written before the signings part ways")

        let host = try String(contentsOf: root.appendingPathComponent("Xcode/project.yml"), encoding: .utf8)
        let lines = host.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        let schemes = try #require(lines.firstIndex(of: "CFBundleURLSchemes:"), "the UI test host takes no links")
        #expect(lines[schemes + 1] == "- \(AppEnvironment.staging.inviteScheme)")
    }

    /// The NAME="value" lines in the build script's case for `environment`.
    private static func values(setFor environment: AppEnvironment, in script: String) -> [String: String] {
        let lines = script.components(separatedBy: "\n")
        guard let start = lines.firstIndex(of: "    \(environment.rawValue))") else { return [:] }
        var values: [String: String] = [:]
        for line in lines[(start + 1)...] {
            let text = line.trimmingCharacters(in: .whitespaces)
            if text == ";;" { break }
            let parts = text.split(separator: "=", maxSplits: 1).map(String.init)
            guard parts.count == 2, parts[1].count >= 2, parts[1].hasPrefix("\""), parts[1].hasSuffix("\"") else {
                continue
            }
            values[parts[0]] = String(parts[1].dropFirst().dropLast())
        }
        return values
    }

    /// Each build makes and reads only its own invite links. Live's type is
    /// the one links have always had, so links people already sent still
    /// open the live app.
    @Test func eachBuildReadsOnlyItsOwnInviteLinks() {
        #expect(AppEnvironment.live.inviteScheme == "wellspent")
        #expect(AppEnvironment.staging.inviteScheme == "wellspent-staging")
        for build in AppEnvironment.allCases {
            let other: AppEnvironment = build == .live ? .staging : .live
            let link = InviteLink(secret: Data(repeating: 7, count: 32), groupName: "Household",
                                  inviterName: "Robin", scheme: build.inviteScheme)
            #expect(build.invite(from: link.url) == link, "\(build)")
            #expect(build.invite(from: "  \(link.url)\n") == link, "pasted, in \(build)")
            #expect(other.invite(from: link.url) == nil, "\(build)'s link, in \(other)")
        }
    }

    // MARK: - Refusals

    @Test func eachBuildRefusesTheOtherServerByAddress() throws {
        let stagingServer = ["https://staging.wellspent.space", "https://STAGING.wellspent.space/",
                             "http://staging.wellspent.space.:443/api/v1"]
        let liveServer = ["https://sync.wellspent.space", "https://Sync.WellSpent.space/",
                          "http://sync.wellspent.space.:8080"]
        for address in stagingServer {
            let url = try #require(URL(string: address))
            #expect(AppEnvironment.live.refusal(ofServerAt: url) != nil, "\(address)")
            #expect(AppEnvironment.staging.refusal(ofServerAt: url) == nil, "\(address)")
        }
        for address in liveServer {
            let url = try #require(URL(string: address))
            #expect(AppEnvironment.staging.refusal(ofServerAt: url) != nil, "\(address)")
            #expect(AppEnvironment.live.refusal(ofServerAt: url) == nil, "\(address)")
        }
        // A name the address check does not know is left to the health check.
        let local = try #require(URL(string: "http://127.0.0.1:8080"))
        #expect(AppEnvironment.staging.refusal(ofServerAt: local) == nil)
        #expect(AppEnvironment.live.refusal(ofServerAt: local) == nil)
    }

    /// Live accepts a server that names no environment, because the live server
    /// predates the field. Staging never does, because that is what the live
    /// server looks like until it is updated.
    @Test func eachBuildRefusesTheOtherServerByWhatItSays() {
        let live = AppEnvironment.live, staging = AppEnvironment.staging
        #expect(live.refusal(ofServerSaying: "live") == nil)
        #expect(live.refusal(ofServerSaying: nil) == nil, "today's live server says nothing")
        for said in ["staging", "development", "", "Live", "production"] {
            #expect(live.refusal(ofServerSaying: said) != nil, "\(said)")
        }

        #expect(staging.refusal(ofServerSaying: "staging") == nil)
        #expect(staging.refusal(ofServerSaying: "development") == nil, "a server on this Mac")
        #expect(staging.refusal(ofServerSaying: nil) != nil, "says nothing, so it may be live")
        for said in ["live", "", "Staging", "production"] {
            #expect(staging.refusal(ofServerSaying: said) != nil, "\(said)")
        }
    }

    /// The address check comes before anything is sent, so the other build's
    /// server never even hears from this one.
    @Test func neitherBuildContactsTheOtherBuildsServer() async throws {
        let cases: [(AppEnvironment, String)] = [(.live, "https://staging.wellspent.space"),
                                                 (.staging, "https://sync.wellspent.space")]
        for (environment, server) in cases {
            let build = Build(environment, serverSays: environment.rawValue)
            let app = try build.launch(server: server)

            await #expect(throws: SyncCoordinator.Failure.self) {
                try await app.sync.signUp(email: "robin@example.com", password: "a-long-password")
            }
            await #expect(throws: SyncCoordinator.Failure.self) {
                try await app.sync.signIn(email: "robin@example.com", password: "a-long-password")
            }
            #expect(build.transport.healthChecks == 0, "\(environment): nothing went to \(server)")
            #expect(build.transport.signUps == 0)
            #expect(build.transport.signIns == 0)
            #expect(!app.sync.isSignedIn)
            #expect(try build.keys(of: "robin@example.com").load(.session) == nil,
                    "nothing saved for an account that was never created")
            let url = try #require(URL(string: server))
            #expect(app.sync.state == .failed(try #require(environment.refusal(ofServerAt: url))),
                    "the reason is shown")
        }
    }

    /// Another name for the other build's server gets past the address check.
    /// What the server says about itself stops it, before a password goes out.
    @Test func eachBuildRefusesAServerThatSaysItIsTheOtherOne() async throws {
        let cases: [(AppEnvironment, String?)] = [(.live, "staging"), (.live, "development"),
                                                  (.staging, "live"), (.staging, nil)]
        for (environment, said) in cases {
            let build = Build(environment, serverSays: said)
            let app = try build.launch(server: "http://127.0.0.1:8080")

            await #expect(throws: SyncCoordinator.Failure.self) {
                try await app.sync.signUp(email: "robin@example.com", password: "a-long-password")
            }
            #expect(build.transport.healthChecks == 1)
            #expect(build.transport.signUps == 0, "\(environment) signed up to a server saying \(String(describing: said))")
            #expect(try build.keys(of: "robin@example.com").load(.session) == nil)

            await #expect(throws: SyncCoordinator.Failure.self) {
                try await app.sync.signIn(email: "robin@example.com", password: "a-long-password")
            }
            #expect(build.transport.signIns == 0)
            guard case .failed(let why) = app.sync.state else {
                Issue.record("expected a failed state, got \(app.sync.state)")
                continue
            }
            #expect(why.contains("signs in only to"), "the reason is shown: \(why)")
            #expect(!app.sync.isSignedIn)
        }
    }

    @Test func eachBuildSignsInToItsOwnServer() async throws {
        let cases: [(AppEnvironment, String?)] = [(.live, "live"), (.live, nil),
                                                  (.staging, "staging"), (.staging, "development")]
        for (environment, said) in cases {
            let build = Build(environment, serverSays: said)
            let app = try build.launch()
            #expect(app.sync.serverAddress == environment.defaultServerAddress)
            try await app.sync.signUp(email: "robin@example.com", password: "a-long-password")
            #expect(app.sync.isSignedIn, "\(environment) with a server saying \(String(describing: said))")
        }
    }

    // MARK: - The saved sign-in

    /// A token is a password for the server that issued it. Resumed against
    /// another server, it would be handed to that server.
    @Test func aSavedSignInResumesOnlyAgainstItsOwnServer() async throws {
        let build = Build(.staging, serverSays: "development")
        let first = try build.launch(server: "http://localhost:8080")
        try await first.sync.signUp(email: "robin@example.com", password: "a-long-password")
        first.model.addGroup(named: "Household")

        // The same server, spelled differently, still resumes.
        let again = try build.launch(server: "http://LocalHost:8080/")
        #expect(again.sync.isSignedIn)
        #expect(build.transport.resumed != nil)

        let resumedBefore = build.transport.resumed
        let moved = try build.launch(server: "http://localhost:9090")
        #expect(!moved.sync.isSignedIn)
        #expect(moved.sync.account == nil)
        #expect(build.transport.resumed == resumedBefore, "the session went nowhere")
        #expect(try build.keys(of: "robin@example.com").load(.session) == nil,
                "signed out on this Mac")
        #expect(build.accounts.lastAccount == nil)
        guard case .failed(let why) = moved.sync.state else {
            Issue.record("expected the reason to be shown, got \(moved.sync.state)")
            return
        }
        #expect(why.contains("Your budgets are still here"))

        // The budgets stayed, and signing in again brings them back.
        try await moved.sync.signIn(email: "robin@example.com", password: "a-long-password")
        #expect(moved.model.groups.map(\.name).contains("Household"))
    }

    /// A session saved by the sealed app is not resumed: readable sync has
    /// sessions of its own. The account waits for one sign-in, which says
    /// why, and nothing else is touched.
    @Test func aSealedSessionAsksForOneSignIn() throws {
        let build = Build(.live, serverSays: nil)
        let email = "robin@example.com"
        try build.keys(of: email).store(Data("a sealed session".utf8), for: .serverToken)
        build.accounts.lastAccount = email

        let app = try build.launch()
        #expect(!app.sync.isSignedIn)
        #expect(build.transport.resumed == nil)
        #expect(app.sync.signInPrompt == SyncCoordinator.SignInPrompt(email: email,
                                                                       reason: SyncCoordinator.updatedReason))
        #expect(app.sync.state == .failed(SyncCoordinator.updatedReason))
        #expect(try build.keys(of: email).load(.serverToken) != nil, "the sealed app's sign-in is left as it was")
    }

    /// Each reason for being signed out says the budgets are safe, and names
    /// no kind of computer.
    @Test func theSignedOutReasonsSayTheBudgetsAreSafe() {
        for reason in [SyncCoordinator.signedOutReason, SyncCoordinator.updatedReason,
                       SyncCoordinator.sessionEndedReason] {
            #expect(reason.contains("budgets"))
            #expect(!reason.contains("Mac"))
        }
        #expect(SyncCoordinator.signedOutReason.contains("different server"))
    }

    /// A server that cannot be reached stops sign-up before anything is sent,
    /// and says why in words a person can read.
    @Test func anUnreachableServerStopsSignUpAndSaysWhy() async throws {
        let build = Build(.staging, serverSays: "staging")
        build.transport.healthError = URLError(.cannotConnectToHost)
        let app = try build.launch(server: "https://staging.wellspent.space")

        await #expect(throws: SyncCoordinator.Failure.self) {
            try await app.sync.signUp(email: "robin@example.com", password: "a-long-password")
        }
        #expect(build.transport.healthChecks == 1)
        #expect(build.transport.signUps == 0, "nothing sent to a server that was not confirmed")
        guard case .failed(let why) = app.sync.state else {
            Issue.record("expected a failure, got \(app.sync.state)")
            return
        }
        #expect(why == "Could not reach the server. Check its address and your connection.")
    }

    // MARK: - Settings from a bare run

    /// Today's live app is a bare `make run`, whose settings sit under its
    /// process name. The live app takes them once, so it opens signed in and
    /// seeds no sample budgets beside real ones.
    /// Two settings stores of their own, removed when the test ends.
    private func twoFreshDefaults() -> (UserDefaults, UserDefaults, () -> Void) {
        let names = ["app.wellspent.tests.\(UUID().uuidString)", "app.wellspent.tests.\(UUID().uuidString)"]
        let stores = names.map { UserDefaults(suiteName: $0)! }
        return (stores[0], stores[1], { for (store, name) in zip(stores, names) { store.removePersistentDomain(forName: name) } })
    }

    @Test func theLiveAppTakesABareRunsSettingsOnce() {
        let (bareRun, live, cleanUp) = twoFreshDefaults()
        defer { cleanUp() }
        bareRun.set("robin@example.com", forKey: AccountDirectory.lastAccountKey)
        bareRun.set(true, forKey: AccountDirectory.samplesSeededKey)
        bareRun.set("https://sync.wellspent.space", forKey: SyncCoordinator.serverAddressKey)
        bareRun.set("group-1", forKey: "sidebar.collapsedGroups")

        #expect(AppEnvironment.carryOver(from: bareRun, into: live))
        for key in AppEnvironment.carriedKeys {
            #expect(live.object(forKey: key) != nil, "\(key) carried")
        }
        #expect(live.string(forKey: AccountDirectory.lastAccountKey) == "robin@example.com")
        #expect(live.bool(forKey: AccountDirectory.samplesSeededKey))

        // Signing out removes the last account here. A later launch must not
        // bring back the old one from the bare run.
        live.removeObject(forKey: AccountDirectory.lastAccountKey)
        #expect(!AppEnvironment.carryOver(from: bareRun, into: live), "only once")
        #expect(live.string(forKey: AccountDirectory.lastAccountKey) == nil)
    }

    @Test func theCarryOverNeverReplacesASettingAlreadyThere() {
        let (bareRun, live, cleanUp) = twoFreshDefaults()
        defer { cleanUp() }
        bareRun.set("https://old.example.com", forKey: SyncCoordinator.serverAddressKey)
        live.set("https://sync.wellspent.space", forKey: SyncCoordinator.serverAddressKey)

        AppEnvironment.carryOver(from: bareRun, into: live)

        #expect(live.string(forKey: SyncCoordinator.serverAddressKey) == "https://sync.wellspent.space")
    }

    @Test func aFreshInstallHasNothingToTake() {
        let (bareRun, live, cleanUp) = twoFreshDefaults()
        defer { cleanUp() }
        #expect(!AppEnvironment.carryOver(from: bareRun, into: live))
    }

    // MARK: - Files, keychain and settings

    @Test func theLiveAccountDirectoryKeepsTodaysLayout() throws {
        let base = temporaryFolder()
        defer { try? FileManager.default.removeItem(at: base) }
        let names = KeychainNames()
        let accounts = AccountDirectory.standard(for: .live, in: base, keychain: names.make)
        let namespace = AccountDirectory.namespace(for: "robin@example.com")

        _ = try accounts.database(for: nil)
        _ = try accounts.database(for: namespace)
        _ = accounts.keyStore(for: nil)
        _ = accounts.keyStore(for: namespace)

        #expect(accounts.root?.path == base.appendingPathComponent("WellSpent").path)
        #expect(files(under: base).filter { $0.hasSuffix(".sqlite") }
                == ["WellSpent/accounts/f05d39646dbce98985a5/budget.sqlite", "WellSpent/budget.sqlite"])
        #expect(names.asked == ["app.wellspent.keys", "app.wellspent.keys.f05d39646dbce98985a5"])
        #expect(accounts.defaults === UserDefaults.standard)
    }

    /// A staging build signed in with the same email as a live one must not land
    /// on any of live's files or keychain items.
    @Test func theStagingAccountDirectoryNeverTouchesLivesNames() throws {
        let base = temporaryFolder()
        defer { try? FileManager.default.removeItem(at: base) }
        let names = KeychainNames()
        let accounts = AccountDirectory.standard(for: .staging, in: base, keychain: names.make)
        let namespace = AccountDirectory.namespace(for: "robin@example.com")

        _ = try accounts.database(for: nil)
        _ = try accounts.database(for: namespace)
        _ = accounts.keyStore(for: nil)
        _ = accounts.keyStore(for: namespace)

        let written = files(under: base)
        #expect(!written.isEmpty)
        #expect(written.allSatisfy { $0.hasPrefix("WellSpent Staging/") }, "\(written)")
        #expect(!FileManager.default.fileExists(atPath: base.appendingPathComponent("WellSpent").path))
        #expect(names.asked == ["app.wellspent.staging.keys",
                                "app.wellspent.staging.keys.f05d39646dbce98985a5"])
        #expect(names.asked.allSatisfy { !$0.hasPrefix(AppEnvironment.live.keychainService) })
        #expect(accounts.defaults !== UserDefaults.standard)
    }

    /// With no settings handed in, each build uses its own, never live's for a
    /// staging build. Only read here: writing would leave a file on this Mac.
    @Test func eachBuildUsesItsOwnSettings() throws {
        let store = Store(database: try WellSpentDatabase.inMemory())
        let live = SyncCoordinator(store: store, keyStore: InMemoryKeyStore(), environment: .live)
        let staging = SyncCoordinator(store: store, keyStore: InMemoryKeyStore(), environment: .staging)
        #expect(live.defaults === UserDefaults.standard)
        #expect(staging.defaults !== UserDefaults.standard)
    }
}
