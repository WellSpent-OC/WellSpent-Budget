import Testing
import Foundation
@testable import WellSpentAppCore
import WellSpentCrypto
import WellSpentKeyStore
import WellSpentModel
import WellSpentStore
import WellSpentSync

/// One Mac login, in memory: databases, a keychain per account, and defaults.
@MainActor
private final class Mac {
    /// Its own, not the shared test suite's: other suites clear that one while
    /// these run, which wiped what this Mac remembers between launches.
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

    /// `opensFirstBudget` false launches it the way a phone launches.
    func launch(opensFirstBudget: Bool = true) throws -> Workspace {
        let transport = self.transport
        return try Workspace.launch(accounts: accounts, defaults: defaults,
                                    makeTransport: { _ in transport }, opensFirstBudget: opensFirstBudget)
    }
}

@Suite("Several accounts on one Mac", .serialized)
@MainActor
struct AccountsTests {

    @Test func eachAccountSeesOnlyItsOwnBudgets() async throws {
        let mac = Mac()
        let app = try mac.launch()
        #expect(app.sync.account == nil)
        #expect(!app.model.groups.isEmpty, "a fresh install starts with the samples")
        app.model.addGroup(named: "Robin's")

        // Robin signs up from "This Mac", taking his own budgets with him.
        try await app.sync.signUp(email: "robin@example.com", password: "a-long-password")
        let robins = app.model.groups.map(\.name)
        #expect(robins == ["Robin's"])

        // Signed out is "This Mac", now empty.
        await app.sync.signOut()
        #expect(app.model.groups.isEmpty, "his budgets left with him")

        // Leslie, on the same Mac login.
        try await app.sync.signUp(email: "leslie@example.com", password: "a-long-password")
        #expect(app.model.groups.isEmpty)
        app.model.addGroup(named: "Leslie's")
        await app.sync.signOut()

        // Back to Robin: his, not hers.
        try await app.sync.signIn(email: "robin@example.com", password: "a-long-password")
        #expect(app.model.groups.map(\.name) == robins)
    }

    /// A phone opens no budget by itself: not at launch with the samples, and
    /// not when signing in brings another account's budgets. The Mac opens one.
    @Test func aPhoneOpensNoBudgetByItselfBeforeOrAfterSigningIn() async throws {
        let mac = Mac()
        #expect(try mac.launch().model.selectedBudget != nil, "the Mac opens one beside the list")

        // Kept for the whole test: its account directory holds it unowned.
        let device = Mac()
        let phone = try device.launch(opensFirstBudget: false)
        #expect(!phone.model.groups.isEmpty, "a fresh install starts with the samples")
        #expect(phone.model.selectedBudget == nil)
        let trip = try #require(phone.model.addGroup(named: "Road trip"))
        phone.model.addBudget(named: "Fuel", limit: .dollars(300), in: trip)

        try await phone.sync.signUp(email: "robin@example.com", password: "a-long-password")
        #expect(phone.model.groups.map(\.id) == [trip], "the account's own budgets")
        #expect(!phone.model.opensFirstBudget)
        #expect(phone.model.selectedBudget == nil, "they open on the list too")
    }

    @Test func theLastAccountIsStillSignedInAfterAQuit() async throws {
        let mac = Mac()
        let first = try mac.launch()
        try await first.sync.signUp(email: "robin@example.com", password: "a-long-password")
        first.model.addGroup(named: "Household")

        let second = try mac.launch()
        #expect(second.sync.account == "robin@example.com")
        #expect(second.sync.isSignedIn)
        #expect(second.model.groups.map(\.name).contains("Household"))
        #expect(mac.transport.resumed != nil, "the saved session was used, not a new sign-in")

        await second.sync.signOut()
        let third = try mac.launch()
        #expect(third.sync.account == nil, "signing out is remembered too")
        #expect(third.model.groups.isEmpty, "and samples do not come back")
    }

    /// Keys from before accounts had their own belong to whoever signs in first,
    /// and only once the password is accepted.
    @Test func olderKeysMoveToTheFirstAccountThatSignsIn() async throws {
        let mac = Mac()
        let older = mac.accounts.keyStore(for: nil)
        let identity = IdentityKeyPair.generate()
        try older.storeIdentity(identity)
        let app = try mac.launch()
        app.model.addGroup(named: "From before")

        mac.transport.server.seedAccount(email: "robin@example.com", password: "a-long-password")
        mac.transport.refuseSignIn = .badCredentials
        await #expect(throws: (any Error).self) {
            try await app.sync.signIn(email: "robin@example.com", password: "wrong-password")
        }
        #expect(try older.load(.identity) != nil, "a refused sign-in takes nothing")
        #expect(app.model.groups.map(\.name).contains("From before"))

        mac.transport.refuseSignIn = nil
        try await app.sync.signIn(email: "robin@example.com", password: "a-long-password")
        #expect(try older.load(.identity) == nil)
        let mine = mac.accounts.keyStore(for: AccountDirectory.namespace(for: "robin@example.com"))
        #expect(try mine.loadIdentity().publicKeys == identity.publicKeys)
        #expect(app.model.groups.map(\.name).contains("From before"), "and the budgets came too")
    }

    @Test func aRefusedSignUpLeavesNothingBehind() async throws {
        let mac = Mac()
        let app = try mac.launch()
        mac.transport.refuseSignUp = .http(status: 409, reason: "that email already has an account")
        await #expect(throws: (any Error).self) {
            try await app.sync.signUp(email: "taken@example.com", password: "a-long-password")
        }
        let keys = mac.accounts.keyStore(for: AccountDirectory.namespace(for: "taken@example.com"))
        #expect(try keys.load(.session) == nil)
        #expect(app.sync.account == nil)
        #expect(!app.model.groups.isEmpty, "This Mac's budgets stay put")
    }

    /// The point of readable sync: an account made on one Mac signs in on
    /// another, with no keys to carry over, and finds its budgets there.
    @Test func anAccountSignsInOnASecondMacAndFindsItsBudgets() async throws {
        let laptop = Mac()
        let first = try laptop.launch()
        try await first.sync.signUp(email: "robin@example.com", password: "a-long-password")
        first.model.addGroup(named: "Holiday")
        let names = first.model.groups.map(\.name).sorted()
        #expect(names == ["Holiday"])
        await first.sync.syncAll()

        let desktop = Mac()
        let second = StubReadableTransport(server: laptop.transport.server)
        let app = try Workspace.launch(accounts: desktop.accounts, defaults: desktop.defaults,
                                       makeTransport: { _ in second })
        try await app.sync.signIn(email: "robin@example.com", password: "a-long-password")
        await app.sync.syncAll()
        #expect(app.sync.state == .signedIn(email: "robin@example.com"))
        #expect(app.model.groups.map(\.name).sorted() == names)
    }

    /// A confirmed address is still known as confirmed after a quit.
    @Test func aConfirmedAddressStaysConfirmedAfterAQuit() async throws {
        let mac = Mac()
        let first = try mac.launch()
        try await first.sync.signUp(email: "robin@example.com", password: "a-long-password")
        let code = try #require(mac.transport.server.lastCode(for: "robin@example.com", purpose: .verify))
        try await first.sync.verifyEmail(code: code)
        let second = try mac.launch()
        #expect(second.sync.emailVerified)
    }

    /// Signed out by the server, the next launch still says whose budgets
    /// these are and why to sign in.
    @Test func anEndedSessionAsksAgainAfterAQuit() async throws {
        let mac = Mac()
        let first = try mac.launch()
        try await first.sync.signUp(email: "robin@example.com", password: "a-long-password")
        mac.transport.server.endSessions(of: try #require(first.sync.userID))
        await first.sync.syncAll()
        let second = try mac.launch()
        #expect(second.sync.account == nil)
        #expect(second.sync.signInPrompt == SyncCoordinator.SignInPrompt(email: "robin@example.com",
                                                                          reason: SyncCoordinator.sessionEndedReason))
    }

    @Test func anAccountsFilesAreNamedWithoutItsEmail() {
        let name = AccountDirectory.namespace(for: "Robin@Example.com ")
        #expect(name == AccountDirectory.namespace(for: "robin@example.com"))
        #expect(!name.contains("robin"))
        #expect(name != AccountDirectory.namespace(for: "leslie@example.com"))
    }

    /// The real app keeps files, not memory. Moving "This Mac" into an account
    /// has to survive closing and reopening both.
    @Test func movingThisMacIntoAnAccountWorksOnDisk() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("wellspent-accounts-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let defaults = UserDefaults(suiteName: "app.wellspent.tests.\(UUID().uuidString)")!
        let namespace = AccountDirectory.namespace(for: "robin@example.com")

        do {
            let accounts = AccountDirectory(root: root, defaults: defaults) { _ in InMemoryKeyStore() }
            let thisMac = Store(database: try accounts.database(for: nil))
            try thisMac.save(BudgetGroup(name: "Household"))
            try accounts.moveThisMacData(into: namespace)
        }

        let reopened = AccountDirectory(root: root, defaults: defaults) { _ in InMemoryKeyStore() }
        #expect(try Store(database: try reopened.database(for: namespace)).groups().map(\.name) == ["Household"])
        #expect(try Store(database: try reopened.database(for: nil)).groups().isEmpty)
        #expect(FileManager.default.fileExists(
            atPath: root.appendingPathComponent("accounts/\(namespace)/budget.sqlite").path))
    }

    // MARK: - A folder of its own, for a UI test

    /// A staging build started with the variable keeps everything under the
    /// folder it names: databases there, keys in memory, settings in the test
    /// suite. Nothing reaches Application Support or the keychain.
    @Test func aStagingBuildKeepsItsDataWhereTheVariableSays() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("wellspent-data-root-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let suite = try #require(UserDefaults(suiteName: AccountDirectory.testDefaultsSuiteName))
        defer { suite.removePersistentDomain(forName: AccountDirectory.testDefaultsSuiteName) }
        let accounts = try AccountDirectory.standard(
            for: .staging, processEnvironment: [AccountDirectory.dataRootVariable: root.path])
        let namespace = AccountDirectory.namespace(for: "robin@example.com")

        _ = try accounts.database(for: nil)
        _ = try accounts.database(for: namespace)
        #expect(accounts.root?.path == root.path)
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("budget.sqlite").path))
        #expect(FileManager.default.fileExists(
            atPath: root.appendingPathComponent("accounts/\(namespace)/budget.sqlite").path))
        #expect(accounts.keyStore(for: nil) is InMemoryKeyStore)
        #expect(accounts.keyStore(for: namespace) is InMemoryKeyStore)

        // Its settings are the test suite's: what it writes is read back from
        // that suite by name, and never from live's standard defaults.
        #expect(accounts.defaults !== UserDefaults.standard)
        accounts.lastAccount = "robin@example.com"
        #expect(suite.string(forKey: AccountDirectory.lastAccountKey) == "robin@example.com")
    }

    /// Only a staging build reads the variable. Unset or empty, or on a live
    /// build whatever is set, the real places are used.
    @Test func onlyAStagingBuildReadsTheVariable() {
        let folder = "/tmp/wellspent-somewhere"
        let set = [AccountDirectory.dataRootVariable: folder]
        #expect(AccountDirectory.testRoot(for: .staging, in: set)?.path == folder)
        #expect(AccountDirectory.testRoot(for: .live, in: set) == nil, "no variable moves the live app's budgets")
        #expect(AccountDirectory.testRoot(for: .staging, in: [:]) == nil)
        #expect(AccountDirectory.testRoot(for: .staging, in: [AccountDirectory.dataRootVariable: ""]) == nil)
        // The UI test and the Makefile use these by name.
        #expect(AccountDirectory.dataRootVariable == "WELLSPENT_DATA_ROOT")
        #expect(AccountDirectory.testDefaultsSuiteName == "app.wellspent.uitest")
    }

    /// A test folder that does not exist yet is a new run, so its settings
    /// start afresh. On a phone the test cannot reach the app's settings to
    /// wipe them, as the Mac's test does. A folder that exists, as on a
    /// relaunch within the same run, keeps them.
    @Test func aNewTestFolderStartsWithFreshSettings() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("wellspent-fresh-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let suite = try #require(UserDefaults(suiteName: AccountDirectory.testDefaultsSuiteName))
        defer { suite.removePersistentDomain(forName: AccountDirectory.testDefaultsSuiteName) }

        suite.set(true, forKey: AccountDirectory.samplesSeededKey)
        #expect(!AccountDirectory.testing(at: root).samplesSeeded, "a new folder starts afresh")

        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        suite.set(true, forKey: AccountDirectory.samplesSeededKey)
        #expect(AccountDirectory.testing(at: root).samplesSeeded, "the same run keeps its settings")
    }

    /// The Mac's test makes its folder before the first launch, and its
    /// sandboxed runner can't reach the app's settings to wipe them. So a
    /// folder that exists must still start afresh on its first launch, and
    /// keep its settings only on a relaunch.
    @Test func aFolderMadeBeforeTheFirstLaunchStillStartsAfresh() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("wellspent-made-first-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let suite = try #require(UserDefaults(suiteName: AccountDirectory.testDefaultsSuiteName))
        defer { suite.removePersistentDomain(forName: AccountDirectory.testDefaultsSuiteName) }

        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        suite.set(true, forKey: AccountDirectory.samplesSeededKey)
        #expect(!AccountDirectory.testing(at: root).samplesSeeded, "the first launch starts afresh")

        suite.set(true, forKey: AccountDirectory.samplesSeededKey)
        #expect(AccountDirectory.testing(at: root).samplesSeeded, "a relaunch keeps its settings")
    }

    /// The app itself, launched the way main.swift launches it, with the
    /// variable set: its budgets land in the folder and its settings in the
    /// test suite, with nothing asked of the keychain.
    @Test func theAppLaunchesIntoTheFolderTheVariableNames() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("wellspent-data-root-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let suite = try #require(UserDefaults(suiteName: AccountDirectory.testDefaultsSuiteName))
        suite.removePersistentDomain(forName: AccountDirectory.testDefaultsSuiteName)
        defer { suite.removePersistentDomain(forName: AccountDirectory.testDefaultsSuiteName) }

        // `swift test` is a bare executable with no Info.plist, so a staging launch.
        let app = try Workspace.launch(processEnvironment: [AccountDirectory.dataRootVariable: root.path])
        #expect(app.environment == .staging)
        #expect(app.sync.account == nil)
        #expect(!app.model.groups.isEmpty, "a fresh folder starts with the samples")
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("budget.sqlite").path))
        #expect(suite.bool(forKey: AccountDirectory.samplesSeededKey), "its settings are the test suite's")
        #expect(app.sync.serverAddress == AppEnvironment.staging.defaultServerAddress)
    }

    // MARK: - A longer Undo bar, for a UI test

    /// A UI test deletes an entry and then clicks Undo, which a slow runner
    /// may not reach in 10 seconds. Only a staging build takes a longer
    /// window, in whole seconds above zero. Anything else keeps 10 seconds.
    @Test func onlyAStagingBuildReadsTheUndoWindow() {
        let set = [Workspace.undoWindowVariable: "120"]
        #expect(Workspace.undoWindow(for: .staging, in: set) == .seconds(120))
        #expect(Workspace.undoWindow(for: .live, in: set) == .seconds(10), "no variable changes the live app")
        for bad in ["", "soon", "0", "-5", "2.5"] {
            #expect(Workspace.undoWindow(for: .staging, in: [Workspace.undoWindowVariable: bad]) == .seconds(10),
                    "\(bad)")
        }
        #expect(Workspace.undoWindow(for: .staging, in: [:]) == .seconds(10))
        // The UI test sets it by this name.
        #expect(Workspace.undoWindowVariable == "WELLSPENT_UNDO_SECONDS")
    }

    /// Launched the way main.swift launches it, with both variables set, the
    /// bar keeps the longer window, and keeps it once an account signs in
    /// and its budgets take over the window.
    @Test func aStagingLaunchKeepsTheLongerUndoWindowThroughASignIn() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("wellspent-data-root-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let suite = try #require(UserDefaults(suiteName: AccountDirectory.testDefaultsSuiteName))
        suite.removePersistentDomain(forName: AccountDirectory.testDefaultsSuiteName)
        defer { suite.removePersistentDomain(forName: AccountDirectory.testDefaultsSuiteName) }

        let app = try Workspace.launch(processEnvironment: [AccountDirectory.dataRootVariable: root.path,
                                                            Workspace.undoWindowVariable: "120"])
        #expect(app.model.undoWindow == .seconds(120))

        let mac = Mac()
        let signingIn = try Workspace.launch(accounts: mac.accounts, defaults: mac.defaults,
                                             makeTransport: { [transport = mac.transport] _ in transport },
                                             undoWindow: .seconds(120))
        try await signingIn.sync.signUp(email: "robin@example.com", password: "a-long-password")
        #expect(signingIn.model.undoWindow == .seconds(120), "the signed-in account's budgets keep it")
    }

    // MARK: - A slower timed sync, for a UI test

    /// A UI test that needs the phone not to hear of a change for a moment
    /// stretches the timed sync. Only a staging build reads it, in whole
    /// seconds above zero. Anything else keeps every 2 minutes.
    @Test func onlyAStagingBuildReadsTheTimedSyncInterval() {
        let set = [Workspace.autoSyncIntervalVariable: "3600"]
        #expect(Workspace.autoSyncInterval(for: .staging, in: set) == .seconds(3600))
        #expect(Workspace.autoSyncInterval(for: .live, in: set) == AutoSync.defaultInterval,
                "no variable changes the live app")
        for bad in ["", "soon", "0", "-5", "2.5"] {
            #expect(Workspace.autoSyncInterval(for: .staging, in: [Workspace.autoSyncIntervalVariable: bad])
                    == AutoSync.defaultInterval, "\(bad)")
        }
        #expect(Workspace.autoSyncInterval(for: .staging, in: [:]) == AutoSync.defaultInterval)
        // The UI test sets it by this name.
        #expect(Workspace.autoSyncIntervalVariable == "WELLSPENT_AUTOSYNC_SECONDS")
    }

    /// Launched the way main.swift launches it, the timed sync takes the
    /// longer interval.
    @Test func aStagingLaunchTakesTheLongerTimedSync() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("wellspent-data-root-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let suite = try #require(UserDefaults(suiteName: AccountDirectory.testDefaultsSuiteName))
        suite.removePersistentDomain(forName: AccountDirectory.testDefaultsSuiteName)
        defer { suite.removePersistentDomain(forName: AccountDirectory.testDefaultsSuiteName) }

        let app = try Workspace.launch(processEnvironment: [AccountDirectory.dataRootVariable: root.path,
                                                            Workspace.autoSyncIntervalVariable: "3600"])
        #expect(app.autoSync.interval == .seconds(3600))
    }

    // MARK: - A pinned day, for a UI test

    /// A UI test puts the money wheel on one day of this month, so the pace
    /// words it checks show whatever day it runs. Only a staging build takes
    /// the day, and only a day a month can have.
    @Test func onlyAStagingBuildReadsThePinnedDay() {
        let set = [Workspace.pinnedDayVariable: "18"]
        #expect(Workspace.pinnedDay(for: .staging, in: set) == 18)
        #expect(Workspace.pinnedDay(for: .live, in: set) == nil, "no variable changes the live app")
        #expect(Workspace.pinnedDay(for: .staging, in: [Workspace.pinnedDayVariable: "1"]) == 1)
        #expect(Workspace.pinnedDay(for: .staging, in: [Workspace.pinnedDayVariable: "31"]) == 31)
        for bad in ["", "soon", "0", "-5", "2.5", "32"] {
            #expect(Workspace.pinnedDay(for: .staging, in: [Workspace.pinnedDayVariable: bad]) == nil, "\(bad)")
        }
        #expect(Workspace.pinnedDay(for: .staging, in: [:]) == nil)
        // The UI test sets it by this name.
        #expect(Workspace.pinnedDayVariable == "WELLSPENT_DAY_OF_MONTH")
    }

    /// Launched the way main.swift launches it, with the variable set, every
    /// wheel reads the pinned day, and still does once an account signs in
    /// and its budgets take over the window.
    @Test func aStagingLaunchKeepsThePinnedDayThroughASignIn() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("wellspent-data-root-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let suite = try #require(UserDefaults(suiteName: AccountDirectory.testDefaultsSuiteName))
        suite.removePersistentDomain(forName: AccountDirectory.testDefaultsSuiteName)
        defer { suite.removePersistentDomain(forName: AccountDirectory.testDefaultsSuiteName) }
        let pinned = Workspace.today(pinnedTo: 18)

        let app = try Workspace.launch(processEnvironment: [AccountDirectory.dataRootVariable: root.path,
                                                            Workspace.pinnedDayVariable: "18"])
        #expect(app.pinnedDay == 18)
        #expect(app.model.today() == pinned)
        let samples = try #require(app.model.groups.first, "a fresh folder starts with the samples")
        #expect(MainScreen(workspace: app).money(of: samples.id)?.wheel.day?.day == 18)

        let mac = Mac()
        let signingIn = try Workspace.launch(accounts: mac.accounts, defaults: mac.defaults,
                                             makeTransport: { [transport = mac.transport] _ in transport },
                                             pinnedDay: 18)
        let before = signingIn.model
        try await signingIn.sync.signUp(email: "robin@example.com", password: "a-long-password")
        #expect(signingIn.model !== before, "the account's budgets take over")
        #expect(signingIn.model.today() == pinned, "the signed-in account's budgets keep the day")
        let household = try #require(signingIn.model.addGroup(named: "Household"))
        signingIn.model.addBudget(named: "Groceries", limit: .dollars(500), in: household)
        #expect(MainScreen(workspace: signingIn).money(of: household)?.wheel.day?.day == 18)
    }
}

/// The sample budgets are something to look at before signing in. Nobody's
/// real account should start with made-up budgets, or hold two groups
/// called Household once they join a shared one.
@Suite("Sample budgets and a new account", .serialized)
@MainActor
struct SampleBudgetTests {

    @Test func aNewAccountStartsWithoutTheSampleBudgets() async throws {
        let mac = Mac()
        let app = try mac.launch()
        let samples = app.model.groups.map(\.id)
        #expect(samples.count == 2, "a fresh install starts with the samples")

        try await app.sync.signUp(email: "robin@example.com", password: "a-long-password")
        #expect(app.model.groups.isEmpty, "the samples stayed behind")

        await app.sync.syncAll()
        #expect(try await mac.transport.groups().isEmpty, "the server lists no group for him")
        for id in samples {
            #expect(mac.transport.server.records(in: id).isEmpty, "and holds nothing of the samples")
        }

        // His first entry takes the row a sample entry had. Search must find
        // it by its own name, and not by that sample's.
        let trip = try #require(app.model.addGroup(named: "Road trip"))
        app.model.addBudget(named: "Fuel", limit: .dollars(300), in: trip)
        app.model.addTransaction(merchant: "Gas station", amount: .dollars(45), date: Date(), note: "")
        #expect(try app.model.store.searchTransactions("Gas").map(\.merchant) == ["Gas station"])
        #expect(try app.model.store.searchTransactions("Hilltop").isEmpty)
    }

    /// The sign follows the kind, however the amount was typed: spending is
    /// stored negative, money in positive, and the kind is kept.
    @Test func anEntryAddedAsMoneyInIsStoredPositiveWithItsKind() throws {
        let mac = Mac()
        let app = try mac.launch()
        let trip = try #require(app.model.addGroup(named: "Pool House"))
        app.model.addBudget(named: "Bookings", limit: .dollars(2000), in: trip)
        app.model.addTransaction(merchant: "Airbnb", amount: .dollars(1310), date: Date(), note: "", kind: .income)
        app.model.addTransaction(merchant: "Cleaner", amount: .dollars(-120), date: Date(), note: "")
        app.model.addTransaction(merchant: "Refund", amount: .dollars(-25), date: Date(), note: "", kind: .refund)
        app.model.addTransaction(merchant: "Between accounts", amount: .dollars(-500), date: Date(), note: "", kind: .transfer)

        let bookings = try #require(try app.model.store.budgets(in: trip).first)
        let entries = try app.model.store.transactions(in: bookings.id)
        func entry(_ merchant: String) throws -> Transaction {
            try #require(entries.first { $0.merchant == merchant })
        }
        #expect(try entry("Airbnb").amount == .dollars(1310) && entry("Airbnb").kind == .income)
        #expect(try entry("Cleaner").amount == .dollars(-120) && entry("Cleaner").kind == .spending)
        #expect(try entry("Refund").amount == .dollars(25) && entry("Refund").kind == .refund)
        #expect(try entry("Between accounts").amount == .dollars(-500), "a transfer is left as typed")
        #expect(try entry("Between accounts").kind == .transfer)

        // A new amount takes its sign from the kind. A transfer keeps the sign it had.
        for merchant in ["Airbnb", "Cleaner", "Refund", "Between accounts"] {
            #expect(app.model.updateEntry(try entry(merchant).id, EntryChange(amount: .dollars(-7))) == .saved)
        }
        let after = try app.model.store.transactions(in: bookings.id)
        func now(_ merchant: String) -> Money? { after.first { $0.merchant == merchant }?.amount }
        #expect(now("Airbnb") == .dollars(7), "income stays money in")
        #expect(now("Cleaner") == .dollars(-7))
        #expect(now("Refund") == .dollars(7), "a refund stays a refund")
        #expect(now("Between accounts") == .dollars(-7), "a transfer keeps its sign")
    }

    @Test func aGroupMadeBeforeSigningUpComesAlongAndTheSamplesDoNot() async throws {
        let mac = Mac()
        let app = try mac.launch()
        let trip = try #require(app.model.addGroup(named: "Road trip"))
        app.model.addBudget(named: "Fuel", limit: .dollars(300), in: trip)
        app.model.addTransaction(merchant: "Gas station", amount: .dollars(45), date: Date(), note: "")

        try await app.sync.signUp(email: "robin@example.com", password: "a-long-password")
        #expect(app.model.groups.map(\.id) == [trip])

        await app.sync.syncAll()
        #expect(try await mac.transport.groups().map(\.id) == [trip], "only his own group reached the server")
        #expect(mac.transport.server.records(in: trip).contains { $0.type == .transaction }, "with its entry")
    }

    @Test func aSampleGroupGivenAnEntryComesAlongWithIt() async throws {
        let mac = Mac()
        let app = try mac.launch()
        let household = try #require(app.model.groups.first { $0.name == "Household" })
        app.model.selectedBudget = try #require(
            app.model.summaries[household.id]?.first { $0.budget.name == "Groceries" }?.budget.id)
        app.model.addTransaction(merchant: "Farmers market", amount: .dollars(25), date: Date(), note: "")
        let entry = try #require(app.model.transactions.first { $0.merchant == "Farmers market" })

        try await app.sync.signUp(email: "robin@example.com", password: "a-long-password")
        #expect(app.model.groups.map(\.id) == [household.id], "the untouched Side Business stayed behind")

        await app.sync.syncAll()
        #expect(try await mac.transport.groups().map(\.id) == [household.id])
        #expect(mac.transport.server.records(in: household.id).map(\.id).contains(entry.id))
    }

    @Test func aSampleGroupRenamedBeforeSigningUpComesAlong() async throws {
        let mac = Mac()
        let app = try mac.launch()
        let business = try #require(app.model.groups.first { $0.name == "Side Business" })
        app.model.renameGroup(business.id, to: "Pottery")

        try await app.sync.signUp(email: "robin@example.com", password: "a-long-password")
        #expect(app.model.groups.map(\.name) == ["Pottery"], "the untouched Household stayed behind")
    }
}
