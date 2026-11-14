import AppKit
import Foundation
import XCTest
import WellSpentAppCore
import WellSpentModel

/// Coming back to the app brings in what changed elsewhere (LIFE-01). Robin
/// is the window, signed in, with the timed sync an hour away
/// (`Workspace.autoSyncIntervalVariable`), so only coming back can bring a
/// change in. Leslie is the second account, with no window, in a group of
/// Robin's she joined with his link.
final class ReturningTests: XCTestCase {
    nonisolated(unsafe) private static var dataRootPath: String?

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    override func tearDown() {
        let app = XCUIApplication()
        if app.state != .notRunning { app.terminate() }
        TestApp.wipeSettings()
        if let path = Self.dataRootPath { try? FileManager.default.removeItem(atPath: path) }
        Self.dataRootPath = nil
        super.tearDown()
    }

    @MainActor
    func testReturningToTheAppBringsInSharedChanges() async throws {
        let accounts = try TestAccounts.fromEnvironment()
        let run = try TestApp()
        Self.dataRootPath = run.dataRoot.path
        let stamp = Self.stamp()
        let groupName = "Shared \(stamp)", food = "Food \(stamp)"

        // 1. Robin shares a group with Leslie, and has Food open.
        run.app.launchEnvironment[Workspace.autoSyncIntervalVariable] = "3600"
        run.launch()
        try run.signIn(email: accounts.email, password: accounts.password, server: accounts.server)
        run.addGroup(named: groupName)
        run.addBudget(named: food, amount: "500", inGroup: groupName)
        run.syncNow()
        let link = try await run.legacyInvite(group: groupName, myName: "Robin", role: .add)
        let leslie = try SecondAccount(server: accounts.server)
        try await leslie.signIn(email: accounts.secondEmail, password: accounts.secondPassword)
        let hers = try await leslie.join(link, as: "Leslie")
        let group = try XCTUnwrap(hers.groups.first { $0.name == groupName }, "Leslie is not in \(groupName)")
        hers.selectedBudget = try XCTUnwrap(hers.summaries[group.id]?.first { $0.budget.name == food }?.budget.id,
                                            "Leslie has no \(food)")
        run.openBudget(named: food)
        run.syncNow()
        func adds(_ merchant: String, _ cents: Int) async throws {
            hers.addTransaction(merchant: merchant, amount: Money(minorUnits: cents), date: Date(), note: "")
            XCTAssertNil(hers.errorMessage, "Leslie could not add \(merchant)")
            try await leslie.syncAll()
        }

        // Scenario LIFE-01
        // 2. Robin goes to another app. Leslie adds a transaction, which isn't
        // on Robin's screen while he's away. He comes back, and it's there,
        // with nothing pressed.
        XCUIApplication(bundleIdentifier: "com.apple.finder").activate()
        XCTAssertTrue(run.app.wait(for: .runningBackground, timeout: 10), "WellSpent never went to the back")
        try await adds("Grocery delivery", 2_400)
        XCTAssertFalse(run.listText("Grocery delivery").exists, "it arrived before Robin came back")
        run.app.activate()
        XCTAssertTrue(run.listText("Grocery delivery").waitForExistence(timeout: 20),
                      "Leslie's transaction did not arrive on coming back. On screen: \(run.visibleTexts())")

        // Scenario LIFE-01
        // 3. Opening and closing a sheet inside the app doesn't count as leaving
        // and coming back: Leslie's next one stays away until a sync.
        try await adds("Corner bakery", 600)
        run.click(AccessibilityID.budgetAdd)
        XCTAssertTrue(run.element(AccessibilityID.entryMerchant).waitForExistence(timeout: 10), "no New transaction sheet")
        run.click(AccessibilityID.entryCancel)
        run.expectNoSheet()
        try await Task.sleep(for: .seconds(5))
        XCTAssertFalse(run.listText("Corner bakery").exists, "a sheet opening and closing synced like coming back")
        run.syncNow()
        XCTAssertTrue(run.listText("Corner bakery").waitForExistence(timeout: 20),
                      "Leslie's second transaction never reached the server. On screen: \(run.visibleTexts())")

        // 4. Tidy: Robin deletes the group for everyone, and both sign out.
        run.deleteGroup(named: groupName)
        run.signOut()
        await leslie.cleanUp()
    }

    /// Part of a group's name, so runs never share one.
    private static func stamp() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: Date())
    }
}
