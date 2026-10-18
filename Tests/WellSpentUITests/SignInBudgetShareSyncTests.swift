import Foundation
import XCTest
import WellSpentAppCore
import WellSpentModel
import WellSpentSync

/// The whole round, in the real window: sign in, make a group and a budget,
/// add two entries, share the group, and see an entry a second person adds
/// arrive after a sync. Then the group's page, with both people on it, the
/// second person removed from it, and the delete question with its count.
/// The second person has no window: they are a coordinator inside this
/// process, against the same staging server.
///
/// Needs the four WELLSPENT_UI_TEST_ variables (see UITestSupport.swift) and
/// skips without them. Both accounts must exist on staging with their
/// addresses confirmed, since joining a group needs a confirmed address.
/// Every run makes a group of its own, named with the time, and deletes it
/// at the end for everyone.
final class SignInBudgetShareSyncTests: XCTestCase {
    /// The run's data folder, for tearDown.
    nonisolated(unsafe) private static var dataRootPath: String?

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    /// Runs after the test, passed or halted, with no await in it: on the
    /// first real run an awaiting teardown block never finished after the
    /// test halted. The app is closed and nothing of the run stays on this
    /// Mac. The staging side (the run's group, the sessions) is tidied at
    /// the end of the test itself, so a halted run can leave a group named
    /// "UI Test <time>" on staging.
    override func tearDown() {
        let app = XCUIApplication()
        if app.state != .notRunning { app.terminate() }
        TestApp.wipeSettings()
        if let path = Self.dataRootPath { try? FileManager.default.removeItem(atPath: path) }
        Self.dataRootPath = nil
        super.tearDown()
    }

    @MainActor
    func testSignInBudgetShareSync() async throws {
        let accounts = try TestAccounts.fromEnvironment()
        let run = try TestApp()
        Self.dataRootPath = run.dataRoot.path
        let second = try SecondAccount(server: accounts.server)
        let groupName = "UI Test \(Self.stamp())"

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

        // 9. A click on the group's name opens its page, with both people on
        // it, and Invite Someone… opens the Share sheet.
        run.openGroupPage(named: groupName)
        let summary = MembersScreen.Words.line([MembersScreen.Words.shared, MembersScreen.Words.peopleCount(2),
                                                MembersScreen.Words.madeByYou])
        XCTAssertTrue(run.wait(for: run.element(AccessibilityID.groupSummary), holds: summary, timeout: 15),
                      "the page's line is not \(summary). On screen: \(run.visibleTexts())")
        XCTAssertTrue(run.listText(MembersScreen.Words.you("Robin")).waitForExistence(timeout: 15),
                      "the page does not list this account. On screen: \(run.visibleTexts())")
        XCTAssertTrue(run.listText("Leslie").waitForExistence(timeout: 15),
                      "the page does not list the second person. On screen: \(run.visibleTexts())")
        run.click(AccessibilityID.groupInvite)
        XCTAssertTrue(run.element(AccessibilityID.shareName).waitForExistence(timeout: 10),
                      "Invite Someone\u{2026} did not open the Share sheet. On screen: \(run.visibleTexts())")
        run.click(AccessibilityID.shareCancel)
        XCTAssertTrue(run.wait(for: run.element(AccessibilityID.shareName), until: "exists == false", timeout: 10),
                      "the Share sheet did not close")

        // 10. The arrow beside the name hides the group's budgets and shows
        // them again. Its words say what the next click does. The page stays.
        let fold = run.element(AccessibilityID.sidebarGroupFold(groupName))
        run.click(AccessibilityID.sidebarGroupFold(groupName))
        XCTAssertTrue(run.wait(for: fold, holds: MainScreen.Words.showBudgets, timeout: 10),
                      "the arrow did not hide the budgets")
        run.click(AccessibilityID.sidebarGroupFold(groupName))
        XCTAssertTrue(run.wait(for: fold, holds: MainScreen.Words.hideBudgets, timeout: 10),
                      "the arrow did not show the budgets again")
        XCTAssertTrue(run.element(AccessibilityID.groupSummary).exists, "the arrow closed the page")

        // 11. A click on a budget opens it in place of the page, and People…
        // in the group's menu opens the page again.
        run.openBudget(named: "Groceries")
        XCTAssertTrue(run.wait(for: run.element(AccessibilityID.groupSummary), until: "exists == false", timeout: 10),
                      "the page stayed over the budget. On screen: \(run.visibleTexts())")
        XCTAssertTrue(run.element(AccessibilityID.budgetAdd).waitForExistence(timeout: 10), "Groceries did not open")
        run.openGroupPageFromMenu(named: groupName)

        // 12. Remove… on Leslie's row asks first. Remove takes her row away,
        // a quiet line says so, and the line under the name says nobody else
        // is in the group.
        run.removeFromGroup("Leslie")
        XCTAssertTrue(run.listText(MembersScreen.Words.removed("Leslie")).waitForExistence(timeout: 30),
                      "no line saying she was removed. On screen: \(run.visibleTexts())")
        XCTAssertTrue(run.wait(for: run.listText("Leslie"), until: "exists == false", timeout: 15),
                      "her row is still on the page. On screen: \(run.visibleTexts())")
        let alone = MembersScreen.Words.line([MembersScreen.Words.notShared, MembersScreen.Words.peopleCount(1),
                                              MembersScreen.Words.madeByYou])
        XCTAssertTrue(run.wait(for: run.element(AccessibilityID.groupSummary), holds: alone, timeout: 15),
                      "the page's line is not \(alone). On screen: \(run.visibleTexts())")

        // 13. Delete… asks first, naming the group and how many go with it:
        // the budget and all 3 entries, Leslie's too. Cancel keeps it.
        let question = PendingDelete.group(BudgetGroup(name: groupName), budgets: 1, transactions: 3,
                                           reach: .justYou)
        run.element(AccessibilityID.sidebarGroup(groupName)).rightClick()
        run.clickMenuItem(MainScreen.Words.delete)
        XCTAssertTrue(run.app.staticTexts[question.title].waitForExistence(timeout: 5),
                      "no question. On screen: \(run.visibleTexts())")
        XCTAssertTrue(run.app.staticTexts[question.message].waitForExistence(timeout: 5),
                      "the question does not say \(question.message) On screen: \(run.visibleTexts())")
        try XCTUnwrap(run.dialogButton(MainScreen.Words.cancel), "no Cancel on the question").click()
        XCTAssertTrue(run.element(AccessibilityID.groupSummary).waitForExistence(timeout: 5),
                      "Cancel did not keep the group and its page")

        // 14. Tidy: the group goes for everyone, both sessions end.
        run.deleteGroup(named: groupName)
        run.signOut()
        await second.cleanUp()
    }

    /// Part of the group's name, so runs never share one.
    private static func stamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: Date())
    }
}
