import Foundation
import XCTest
import WellSpentAppCore
import WellSpentModel
import WellSpentSync

/// The whole round, in the real window: sign in, make a group and a budget,
/// add two entries, share the group, and see an entry a second person adds
/// arrive after a sync. The second person has no window: they are a
/// coordinator inside this process, against the same staging server.
///
/// Needs the four WELLSPENT_UI_TEST_ variables (see UITestSupport.swift) and
/// skips without them. Both accounts must exist on staging with their
/// addresses confirmed, since joining a group needs a confirmed address.
/// Every run makes a group of its own, named with the time, and deletes it
/// at the end for everyone.
final class SignInBudgetShareSyncTests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testSignInBudgetShareSync() async throws {
        let accounts = try TestAccounts.fromEnvironment()
        let run = try TestApp()
        let second = try SecondAccount(server: accounts.server)
        let groupName = "UI Test \(Self.stamp())"
        // Whatever happened: the group goes, both sessions end, and nothing of
        // the run stays on this Mac. Each step gives up quietly if it cannot.
        addTeardownBlock {
            await run.deleteGroup(named: groupName)
            await run.signOut()
            await second.cleanUp()
            await run.cleanUp()
        }

        // 1. A staging build, signed out.
        run.launch()

        // 2. Signed in as the first account.
        try run.signIn(email: accounts.email, password: accounts.password, server: accounts.server)

        // 3 and 4. A group of this run's own, with one budget.
        run.addGroup(named: groupName)
        run.addBudget(named: "Groceries", amount: "500", inGroup: groupName)

        // 5. Two entries, both in the table.
        run.addEntry(merchant: "Hilltop", amount: "42.00")
        run.addEntry(merchant: "Market", amount: "9.50")

        // 6. Shared, with a link that reads back.
        let link = try run.share(group: groupName, myName: "Robin", role: .add)
        XCTAssertEqual(link.groupName, groupName)
        XCTAssertEqual(link.inviterName, "Robin")

        // 7. The second person joins, sees both entries, and adds one.
        try await second.signIn(email: accounts.secondEmail, password: accounts.secondPassword)
        let model = try await second.join(link, as: "Leslie")
        let group = try XCTUnwrap(model.groups.first { $0.name == groupName },
                                  "the group did not reach the second account: \(model.groups.map(\.name))")
        let groceries = try XCTUnwrap(model.summaries[group.id]?.first { $0.budget.name == "Groceries" },
                                      "the budget did not reach the second account")
        let merchants = try model.store.transactions(in: groceries.budget.id).map(\.merchant)
        XCTAssertEqual(Set(merchants), ["Hilltop", "Market"], "both entries arrived")
        model.selectedBudget = groceries.budget.id
        model.addTransaction(merchant: "Costco", amount: Money(minorUnits: 9900), date: Date(), note: "")
        XCTAssertNil(model.errorMessage)
        try await second.syncAll()

        // 8. Back in the window, a sync brings it in, added by Leslie.
        run.syncNow()
        XCTAssertTrue(run.app.staticTexts["Costco"].waitForExistence(timeout: 30),
                      "the second person's entry did not arrive. On screen: \(run.visibleTexts())")
        XCTAssertTrue(run.app.staticTexts["Leslie"].waitForExistence(timeout: 15),
                      "the Added by column does not name her")
    }

    /// Part of the group's name, so runs never share one.
    private static func stamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: Date())
    }
}
