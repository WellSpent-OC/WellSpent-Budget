// What the Mac's and the iPhone's UI tests share: the staging accounts a run
// signs in with, and the second person, who has no window. Each platform's
// project compiles this folder into its own UI test bundle, beside that
// platform's own tests.
import Foundation
import XCTest
import WellSpentAppCore
import WellSpentCrypto
import WellSpentKeyStore
import WellSpentModel
import WellSpentStore
import WellSpentSync

/// The two staging accounts a run uses, read from the environment. `make
/// ui-test` passes them to xcodebuild as TEST_RUNNER_ variables, which reach
/// this process with the prefix removed, so they are never on a command line.
struct TestAccounts {
    static let serverVariable = "WELLSPENT_UI_TEST_SERVER"
    static let emailVariable = "WELLSPENT_UI_TEST_EMAIL"
    static let passwordVariable = "WELLSPENT_UI_TEST_PASSWORD"
    static let secondEmailVariable = "WELLSPENT_UI_TEST_EMAIL_2"
    static let secondPasswordVariable = "WELLSPENT_UI_TEST_PASSWORD_2"

    let server: String
    let email: String
    let password: String
    let secondEmail: String
    let secondPassword: String

    /// Skips the test when any of the four is missing, so a checkout without
    /// accounts, such as a pull request from a fork, passes with nothing run.
    static func fromEnvironment(_ environment: [String: String] = ProcessInfo.processInfo.environment)
        throws -> TestAccounts {
        func required(_ name: String) throws -> String {
            guard let value = environment[name], !value.isEmpty else {
                throw XCTSkip("\(name) is not set. The four WELLSPENT_UI_TEST_ variables name the two "
                              + "staging accounts this test signs in with; see the Makefile's ui-test target.")
            }
            return value
        }
        let server = environment[serverVariable].flatMap { $0.isEmpty ? nil : $0 }
        return TestAccounts(server: server ?? AppEnvironment.staging.defaultServerAddress,
                            email: try required(emailVariable),
                            password: try required(passwordVariable),
                            secondEmail: try required(secondEmailVariable),
                            secondPassword: try required(secondPasswordVariable))
    }
}

/// Something the test could not do, in words.
struct UITestError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

/// The second person, with no window: a coordinator of their own against the
/// same staging server, the way the two-person tests in WellSpentAppCoreTests
/// do it, but over real HTTP. Databases and keys in memory, settings in a
/// suite of its own.
@MainActor
final class SecondAccount {
    static let settingsSuite = "app.wellspent.uitest.second"
    /// Where this one keeps its settings: `settingsSuite` unless a test runs
    /// two of them at once.
    let suite: String
    let sync: SyncCoordinator

    init(server: String, settingsSuite suite: String = SecondAccount.settingsSuite) throws {
        self.suite = suite
        guard let defaults = UserDefaults(suiteName: suite) else {
            throw UITestError("could not open the \(suite) defaults")
        }
        defaults.removePersistentDomain(forName: suite)
        let accounts = AccountDirectory(root: nil, defaults: defaults) { _ in InMemoryKeyStore() }
        sync = try SyncCoordinator(accounts: accounts, defaults: defaults, serverAddress: server,
                                   environment: .staging)
    }

    /// Signs in and takes in everything the account has.
    func signIn(email: String, password: String) async throws {
        try await sync.signIn(email: email, password: password)
        await sync.syncAll()
        try checkSynced()
    }

    /// Joins with the link and takes the group in. The model is made after,
    /// because signing in switched the store underneath.
    func join(_ link: InviteLink, as name: String) async throws -> AppModel {
        try await sync.join(link, myName: name)
        await sync.syncAll()
        try checkSynced()
        return AppModel(store: sync.store)
    }

    /// Sends what was saved, and fails with the server's words if it did not go.
    func syncAll() async throws {
        await sync.syncAll()
        try checkSynced()
    }

    private func checkSynced() throws {
        if case .failed(let why) = sync.state { throw UITestError("the second account's sync failed: \(why)") }
    }

    /// A group of the second person's own, with one budget and one entry in
    /// it, shared with a link that invites at `role` and names them as
    /// `myName`. Everything is sent before the link comes back.
    func shareNewGroup(_ name: String, budget: String, entry merchant: String, amount: Money,
                       myName: String, role: InviteRole) async throws -> InviteLink {
        let model = AppModel(store: sync.store)
        guard let group = model.addGroup(named: name),
              let budgetID = model.addBudget(named: budget, limit: Money(minorUnits: 50_000), in: group) else {
            throw UITestError("the second account could not make its group: \(model.errorMessage ?? "")")
        }
        model.selectedBudget = budgetID
        model.addTransaction(merchant: merchant, amount: amount, date: Date(), note: "")
        if let problem = model.errorMessage { throw UITestError("the second account could not add \(merchant): \(problem)") }
        let link = try await sync.share(group: group, groupName: name, level: role.level, historyAccess: .all,
                                        myName: myName)
        try await syncAll()
        return link
    }

    /// Deletes a group of the second person's own, for everyone. Best effort.
    func deleteGroup(named name: String) async {
        let model = AppModel(store: sync.store)
        guard let group = model.groups.first(where: { $0.name == name }) else { return }
        model.deleteGroup(group.id, reach: sync.deleteReach(of: group.id))
        await sync.syncAll()
    }

    /// Ends the session on the server. Best effort.
    func cleanUp() async {
        if sync.account != nil { await sync.signOut() }
        UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
    }
}
