import Foundation
import XCTest
import WellSpentAppCore
import WellSpentModel

/// Coming back to the app brings in what changed elsewhere (LIFE-01), on a
/// phone. Robin is the phone, signed in, with the timed sync an hour away
/// (`Workspace.autoSyncIntervalVariable`), so only coming back can bring a
/// change in. Leslie is the second account, with no window: she makes the
/// group and its link, and Robin joins it.
///
/// Needs the WELLSPENT_UI_TEST_ variables (see UITestAccounts.swift) and
/// skips without them. The group is Leslie's, named with the time, and she
/// deletes it at the end.
final class PhoneReturningTests: XCTestCase {
    nonisolated(unsafe) private static var dataRootPath: String?

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    override func tearDown() {
        let app = XCUIApplication()
        if app.state != .notRunning { app.terminate() }
        if let path = Self.dataRootPath { try? FileManager.default.removeItem(atPath: path) }
        Self.dataRootPath = nil
        super.tearDown()
    }

    @MainActor
    func testReturningToTheAppBringsInSharedChanges() async throws {
        let accounts = try TestAccounts.fromEnvironment()
        let run = PhoneTestApp()
        Self.dataRootPath = run.dataRoot.path
        let stamp = PhoneTestApp.stamp()
        let groupName = "UI Phone \(stamp) shared", food = "Food \(stamp)"

        // 1. Leslie makes a group with Food and a link at Add. Robin, on the
        // phone, joins it and opens Food.
        let leslie = try SecondAccount(server: accounts.server)
        try await leslie.signIn(email: accounts.secondEmail, password: accounts.secondPassword)
        let link = try await leslie.shareNewGroup(groupName, budget: food, entry: "Rent share",
                                                  amount: Money(minorUnits: 10_000), myName: "Leslie", role: .add)
        run.app.launchEnvironment[Workspace.autoSyncIntervalVariable] = "3600"
        run.launch()
        try run.signIn(email: accounts.email, password: accounts.password, server: accounts.server)
        run.openAddMenu()
        run.tapMenuItem(MainScreen.Words.join)
        run.paste(link.url, into: AccessibilityID.joinLink)
        run.type("Robin", into: AccessibilityID.joinName)
        run.tap(AccessibilityID.joinJoin)
        XCTAssertTrue(run.wait(for: run.element(AccessibilityID.joinLink), until: "exists == false", timeout: 30),
                      "Join a Group stayed. On screen: \(run.visibleTexts())")
        run.openBudget(named: food)
        XCTAssertTrue(run.hasRow("Rent share", timeout: 20), "Leslie's group did not arrive. On screen: \(run.visibleTexts())")

        let hers = AppModel(store: leslie.sync.store)
        let group = try XCTUnwrap(hers.groups.first { $0.name == groupName }, "Leslie has no \(groupName)")
        hers.selectedBudget = try XCTUnwrap(hers.summaries[group.id]?.first { $0.budget.name == food }?.budget.id,
                                            "Leslie has no \(food)")
        func adds(_ merchant: String, _ cents: Int) async throws {
            hers.addTransaction(merchant: merchant, amount: Money(minorUnits: cents), date: Date(), note: "")
            XCTAssertNil(hers.errorMessage, "Leslie could not add \(merchant)")
            try await leslie.syncAll()
        }

        // Scenario LIFE-01
        // 2. Robin goes to the Home Screen. Leslie adds a transaction. He comes
        // back, and it's there, with nothing pressed.
        XCUIDevice.shared.press(.home)
        XCTAssertTrue(run.app.wait(for: .runningBackgroundSuspended, timeout: 15)
                      || run.app.state == .runningBackground, "WellSpent never went to the back")
        try await adds("Grocery delivery", 2_400)
        run.app.activate()
        XCTAssertTrue(run.hasRow("Grocery delivery", timeout: 20),
                      "Leslie's transaction did not arrive on coming back. On screen: \(run.visibleTexts())")

        // Scenario LIFE-01
        // 3. Opening and closing a sheet inside the app doesn't count as leaving
        // and coming back: Leslie's next one stays away, for as long as coming
        // back is given, until a sync brings it.
        try await adds("Corner bakery", 600)
        run.tap(AccessibilityID.budgetAdd)
        XCTAssertTrue(run.has(AccessibilityID.entryMerchant), "no New transaction sheet")
        run.tap(AccessibilityID.entryCancel)
        XCTAssertTrue(run.wait(for: run.element(AccessibilityID.entryMerchant), until: "exists == false", timeout: 10),
                      "the sheet stayed. On screen: \(run.visibleTexts())")
        try await Task.sleep(for: .seconds(20))
        XCTAssertFalse(run.hasRow("Corner bakery", timeout: 1), "a sheet opening and closing synced like coming back")
        // The sync is pulled from Home, where its line says it ended well.
        run.goBack()
        run.syncAndWait()
        run.openBudget(named: food)
        XCTAssertTrue(run.hasRow("Corner bakery", timeout: 20),
                      "Leslie's second transaction never reached the server. On screen: \(run.visibleTexts())")

        // 4. Tidy: Robin signs out, from Account at the foot of Home, and
        // Leslie deletes the group.
        run.goBack()
        run.signOut()
        await leslie.deleteGroup(named: groupName)
        await leslie.cleanUp()
    }
}
