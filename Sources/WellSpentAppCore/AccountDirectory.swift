import Foundation
import Crypto
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

    public init(root: URL?, defaults: UserDefaults = .standard,
                makeKeyStore: @escaping KeyStoreMaker) {
        self.root = root
        self.defaults = defaults
        self.makeKeyStore = makeKeyStore
    }

    /// The real one: Application Support, the keychain and the settings, each
    /// named for this build. Live keeps the names it has always had, so its data
    /// never moves. Staging's are all different, so it never sees live's.
    public static func standard(for environment: AppEnvironment = .current) throws -> AccountDirectory {
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
    /// the "This Mac" database is open while this runs.
    public func moveThisMacData(into namespace: String) throws {
        let source = try database(for: nil)
        let target = try database(for: namespace)
        try source.writer.backup(to: target.writer)
        try WellSpentDatabase.inMemory().writer.backup(to: source.writer)
        samplesSeeded = true
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
    /// come back after someone has signed in and taken them with them.
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
