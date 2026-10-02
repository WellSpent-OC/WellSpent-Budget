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
    let server = InMemoryTransport()
    let transport: StubAccountTransport

    init() {
        transport = StubAccountTransport(inner: server)
        transport.idsFromEmail = true
    }

    func launch() throws -> Workspace {
        let transport = self.transport
        return try Workspace.launch(accounts: accounts, defaults: defaults,
                                    makeTransport: { _ in transport })
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

        // Robin signs up from "This Mac", taking its budgets with him.
        try await app.sync.signUp(email: "robin@example.com", password: "a-long-password")
        let robins = app.model.groups.map(\.name)
        #expect(!robins.isEmpty)

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
        #expect(app.sync.hasIdentity(for: "leslie@example.com"))
        #expect(app.sync.hasIdentity(for: "robin@example.com"))
        #expect(!app.sync.hasIdentity(for: "nobody@example.com"))
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

        mac.transport.refuseSignIn = .http(status: 401, reason: "email or password is wrong")
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

    @Test func aRefusedSignUpLeavesNoKeysBehind() async throws {
        let mac = Mac()
        let app = try mac.launch()
        mac.transport.refuseSignUp = .http(status: 409, reason: "that email already has an account")
        await #expect(throws: (any Error).self) {
            try await app.sync.signUp(email: "taken@example.com", password: "a-long-password")
        }
        #expect(!app.sync.hasIdentity(for: "taken@example.com"))
        #expect(!app.model.groups.isEmpty, "This Mac's budgets stay put")
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
}
