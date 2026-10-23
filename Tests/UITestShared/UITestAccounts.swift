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
        try await retryingDrops { try await self.sync.signIn(email: email, password: password) }
        try await syncAll()
    }

    /// Joins with the link and takes the group in. The model is made after,
    /// because signing in switched the store underneath. When a drop lost the
    /// server's reply, the join may have gone through anyway, and the next try
    /// is then told the account is already in the group, or that the invite is
    /// used. Either counts, and the sync after it and the test's own checks
    /// show whether the group really came.
    func join(_ link: InviteLink, as name: String) async throws -> AppModel {
        try await retryingDrops({ _ = try await self.sync.join(link, myName: name) },
                                doneAfterDrop: { error in
                                    let words = String(describing: error)
                                    return ["already in that group", "already been used", "can no longer be used"]
                                        .contains { words.contains($0) }
                                })
        try await syncAll()
        return AppModel(store: sync.store)
    }

    /// Sends what was saved, and fails with the server's words if it did not go.
    func syncAll() async throws {
        try await retryingDrops {
            await self.sync.syncAll()
            try self.checkSynced()
        }
    }

    private func checkSynced() throws {
        if case .failed(let why) = sync.state { throw UITestError("the second account's sync failed: \(why)") }
    }

    /// Runs a step against staging again when it failed only because the
    /// network dropped, every five seconds until a minute has passed since the
    /// first drop. A CI runner's network, or the server's, can drop for a few
    /// seconds, and the server's Wi-Fi once went quiet for about forty. The
    /// app then fails the call in its own words for that, as it should. Any
    /// other failure ends the test at once. `doneAfterDrop` names a failure
    /// that, on a try after a drop, means the lost try went through after all.
    func retryingDrops(_ step: () async throws -> Void,
                       doneAfterDrop: (any Error) -> Bool = { _ in false }) async throws {
        var firstDrop: Date?
        while true {
            do {
                try await step()
                return
            } catch let error where firstDrop != nil && doneAfterDrop(error) {
                return
            } catch let error where Self.isDrop(error) && Date().timeIntervalSince(firstDrop ?? Date()) < 60 {
                if firstDrop == nil { firstDrop = Date() }
                try await Task.sleep(for: .seconds(5))
            }
        }
    }

    /// The app's words for a network that dropped, from AccountWording: not
    /// connected, a server it could not reach, or a server not answering.
    static func isDrop(_ error: any Error) -> Bool {
        let words = String(describing: error)
        return ["is not connected to the internet", "Could not reach the server",
                "The server is not answering right now"].contains { words.contains($0) }
    }

    /// A group of the second person's own, with one budget and one entry in
    /// it, shared with a link that invites at `role`, shows `history`, and
    /// names them as `myName`. Everything is sent before the link comes back.
    func shareNewGroup(_ name: String, budget: String, entry merchant: String, amount: Money,
                       myName: String, role: InviteRole, history: HistoryAccess = .all) async throws -> InviteLink {
        let model = AppModel(store: sync.store)
        guard let group = model.addGroup(named: name),
              let budgetID = model.addBudget(named: budget, limit: Money(minorUnits: 50_000), in: group) else {
            throw UITestError("the second account could not make its group: \(model.errorMessage ?? "")")
        }
        model.selectedBudget = budgetID
        model.addTransaction(merchant: merchant, amount: amount, date: Date(), note: "")
        if let problem = model.errorMessage { throw UITestError("the second account could not add \(merchant): \(problem)") }
        // A share whose reply was lost leaves an unused invite behind. The next
        // try makes another, which is harmless.
        var shared: InviteLink?
        try await retryingDrops {
            shared = try await self.sync.share(group: group, groupName: name, level: role.level,
                                               historyAccess: history, myName: myName)
        }
        guard let link = shared else { throw UITestError("the second account could not share \(name)") }
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
