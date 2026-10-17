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
