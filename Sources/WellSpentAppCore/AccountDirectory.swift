import Foundation
import Crypto
import WellSpentCrypto
import WellSpentKeyStore
import WellSpentStore

/// Where each account's database and keys live, so several WellSpent accounts
/// can share one Mac login without seeing each other's budgets.
///
/// - Signed out, the app uses "This Mac": a database of its own that never syncs.
/// - Each account gets its own database and its own keychain items, both named
///   after a hash of its email address.
/// - Before accounts had their own, everything lived in the "This Mac" places.
///   The first account that signs in with no keys of its own takes those over,
///   database and all, because that is whose they were.
@MainActor
public final class AccountDirectory {
    public typealias KeyStoreMaker = (_ namespace: String?) -> any KeyStore

    /// Nil keeps every database in memory, for tests.
    let root: URL?
    private let makeKeyStore: KeyStoreMaker
    let defaults: UserDefaults
    private var open: [String: WellSpentDatabase] = [:]
    private var keyStores: [String: any KeyStore] = [:]

    static let lastAccountKey = "WellSpentLastAccount"
    static let samplesSeededKey = "WellSpentSamplesSeeded"
    static let sampleGroupsKey = "WellSpentSampleGroups"

    /// The environment variable a UI test sets to keep a staging build's data
    /// out of Application Support and the keychain: every database goes under
    /// the folder it names, keys stay in memory, and settings go in the suite
    /// named by `testDefaultsSuiteName`. A live build never reads it.
    nonisolated public static let dataRootVariable = "WELLSPENT_DATA_ROOT"

    /// Where a build started with `dataRootVariable` keeps its settings.
    /// UserDefaults cannot be pointed at a folder, so a suite of its own is the
    /// nearest thing; the UI test wipes it before and after a run.
    nonisolated public static let testDefaultsSuiteName = "app.wellspent.uitest"

    public init(root: URL?, defaults: UserDefaults = .standard,
                makeKeyStore: @escaping KeyStoreMaker) {
        self.root = root
        self.defaults = defaults
        self.makeKeyStore = makeKeyStore
    }

    /// The real one: Application Support, the keychain and the settings, each
    /// named for this build. Live keeps the names it has always had, so its data
    /// never moves. Staging's are all different, so it never sees live's.
    ///
    /// A staging build started with `dataRootVariable` set uses that folder
    /// instead, for a UI test. `processEnvironment` is the process's own unless
    /// a test hands one in.
    public static func standard(for environment: AppEnvironment = .current,
                                processEnvironment: [String: String] = ProcessInfo.processInfo.environment)
        throws -> AccountDirectory {
        if let root = testRoot(for: environment, in: processEnvironment) {
            return testing(at: root)
        }
        let base = try FileManager.default.url(for: .applicationSupportDirectory,
                                               in: .userDomainMask,
                                               appropriateFor: nil, create: true)
        #if canImport(Security)
        return standard(for: environment, in: base) { service in KeychainKeyStore(service: service) }
        #else
        // Keys only in memory would vanish at quit, signing this device out at
        // every launch. The Linux app hands in its keyring instead, through
        // init(root:defaults:makeKeyStore:).
        throw AccountDirectoryError.noKeychainHere
        #endif
    }

    /// The folder `dataRootVariable` names, for a staging build. Nil when it
    /// is unset or empty, and always nil for a live build, so no variable can
    /// point the live app's budgets anywhere else.
    static func testRoot(for environment: AppEnvironment, in processEnvironment: [String: String]) -> URL? {
        guard environment == .staging, let path = processEnvironment[dataRootVariable], !path.isEmpty else {
            return nil
        }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    /// Everything under one folder, for a UI test. Keys in memory rather than
    /// in a file: a file store needs a passphrase first, and nothing here
    /// outlives the run anyway. No keychain means no password prompt can stop
    /// a run, and a relaunch asks to sign in again.
    ///
    /// A run's first launch into a folder starts with fresh settings, and
    /// marks the folder, so a relaunch within the same run keeps them. The
    /// mark tells the two apart, not the folder: the Mac's test makes its
    /// folder before the first launch, and neither the Mac's sandboxed runner
    /// nor a phone's test can reach the app's settings to wipe them.
    static func testing(at root: URL) -> AccountDirectory {
        guard let defaults = UserDefaults(suiteName: testDefaultsSuiteName) else {
            preconditionFailure("could not open the \(testDefaultsSuiteName) defaults")
        }
        let mark = root.appendingPathComponent(".settings-started")
        if !FileManager.default.fileExists(atPath: mark.path) {
            defaults.removePersistentDomain(forName: testDefaultsSuiteName)
            try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: mark.path, contents: nil)
        }
        return AccountDirectory(root: root, defaults: defaults) { _ in InMemoryKeyStore() }
    }

    /// The same, with Application Support and the keychain handed in, so a test
    /// can see which names each build uses without touching the real ones.
    static func standard(for environment: AppEnvironment, in applicationSupport: URL,
                         keychain: @escaping (_ service: String) -> any KeyStore) -> AccountDirectory {
        AccountDirectory(root: applicationSupport.appendingPathComponent(environment.dataFolderName),
                         defaults: environment.defaults) { namespace in
            keychain(environment.keychainService(for: namespace))
        }
    }

    /// A name for an account's files that does not put its email address on disk.
    public static func namespace(for email: String) -> String {
        let normal = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return SHA256.hash(data: Data(normal.utf8)).prefix(10)
            .map { String(format: "%02x", $0) }.joined()
    }

    /// Nil is "This Mac".
    public func database(for namespace: String?) throws -> WellSpentDatabase {
        let key = namespace ?? ""
        if let existing = open[key] { return existing }
        let database: WellSpentDatabase
        if let root {
            let url = namespace.map {
                root.appendingPathComponent("accounts/\($0)/budget.sqlite")
            } ?? root.appendingPathComponent("budget.sqlite")
            database = try WellSpentDatabase.open(at: url)
        } else {
            database = try WellSpentDatabase.inMemory()
        }
        open[key] = database
        return database
    }

    /// Nil is the keychain items from before accounts had their own.
    public func keyStore(for namespace: String?) -> any KeyStore {
        let key = namespace ?? ""
        if let existing = keyStores[key] { return existing }
        let store = makeKeyStore(namespace)
        keyStores[key] = store
        return store
    }

    /// Moves everything in "This Mac" into an account and leaves "This Mac"
    /// empty. Copying and then emptying, rather than moving the file, because
    /// the "This Mac" database is open while this runs. Sample groups nobody
    /// touched are removed first, so they never reach the account.
    public func moveThisMacData(into namespace: String) throws {
        let source = try database(for: nil)
        let target = try database(for: namespace)
        try removeUntouchedSamples(from: Store(database: source))
        try source.writer.backup(to: target.writer)
        try WellSpentDatabase.inMemory().writer.backup(to: source.writer)
        samplesSeeded = true
    }

    /// Notes which groups in "This Mac" are the samples, each with its change
    /// count as seeding left it. The count is the group's Lamport clock.
    /// Every saved change to the group, or to a budget or entry in it, adds
    /// one. It is a counter, not a time, so nothing here depends on the clock.
    func noteSamples(_ groups: [GroupID], in thisMac: Store) throws {
        var counts: [GroupID: UInt64] = [:]
        for group in groups { counts[group] = try thisMac.syncState(for: group).lamport }
        defaults.set(try JSONEncoder().encode(counts), forKey: Self.sampleGroupsKey)
        defaults.saveNow()
    }

    /// A sample whose count still reads as seeding left it was never touched,
    /// and is removed. One the person changed or added to is theirs, and moves
    /// with the rest. While signed out nothing else moves the count, because
    /// pulls and re-seals run only when signed in.
    ///
    /// An install seeded by an older build kept no note. Nothing is removed
    /// there, so its samples move with everything else, as they always did.
    /// A note that cannot be read is treated the same way. A group is never
    /// judged by its name. The note is cleared after every move.
    private func removeUntouchedSamples(from thisMac: Store) throws {
        var counts: [GroupID: UInt64] = [:]
        if let note = defaults.data(forKey: Self.sampleGroupsKey) {
            counts = (try? JSONDecoder().decode([GroupID: UInt64].self, from: note)) ?? [:]
        }
        for (group, count) in counts {
            if try thisMac.syncState(for: group).lamport == count {
                try thisMac.removeUnsentGroup(group)
            }
        }
        defaults.removeObject(forKey: Self.sampleGroupsKey)
        defaults.saveNow()
    }

    /// Hands the keys from before accounts had their own to this account, if it
    /// has none and they exist. True when it did, and then "This Mac"'s data is
    /// that account's too.
    public func claimOlderKeys(for namespace: String) throws -> Bool {
        let target = keyStore(for: namespace)
        guard (try? target.load(.identity)) == nil else { return false }
        let older = keyStore(for: nil)
        guard let identity = try older.load(.identity) else { return false }
        try target.store(identity, for: .identity)
        for item in KeyStoreItem.allCases where item != .identity {
            if let data = try older.load(item) { try target.store(data, for: item) }
        }
        try older.removeAll()
        return true
    }

    /// The account to reopen at launch.
    public var lastAccount: String? {
        get { defaults.string(forKey: Self.lastAccountKey) }
        set {
            defaults.set(newValue, forKey: Self.lastAccountKey)
            defaults.saveNow()
        }
    }

    /// The sample budgets go into "This Mac" once, on a fresh install, and never
    /// come back after "This Mac" has moved into an account.
    public var samplesSeeded: Bool {
        get { defaults.bool(forKey: Self.samplesSeededKey) }
        set {
            defaults.set(newValue, forKey: Self.samplesSeededKey)
            defaults.saveNow()
        }
    }
}

/// Why an account directory could not be made.
public enum AccountDirectoryError: Error, Equatable, Sendable {
    /// There is no system keychain on this platform; pass a key store in.
    case noKeychainHere
}

extension UserDefaults {
    /// Writes settings to disk now. Apple systems do this by themselves; Linux
    /// keeps them in memory until asked, so a quit forgot who was signed in.
    func saveNow() {
        #if !canImport(Darwin)
        synchronize()
        #endif
    }
}
