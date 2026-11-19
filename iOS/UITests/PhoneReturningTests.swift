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
        // The delete's own sync is sent once and not looked at. This one is
        // sent again if the network drops, and fails with the server's words.
        // Robin is in this group, so a later test would find it on his Home.
        try await leslie.syncAll()
        await leslie.cleanUp()
    }

    // MARK: - A new day, signed out (LIFE-02)

    /// The phone on the test clock at `start`, with Groceries, $310.00 a
    /// month, in a group of its own, and $100.00 spent today.
    @MainActor
    private func started(at start: String, dayLine: String, announcing: Bool = true) throws -> PhoneTestApp {
        let run = PhoneTestApp()
        Self.dataRootPath = run.dataRoot.path
        try run.setClock(start)
        if !announcing { run.app.launchEnvironment[Workspace.clockAnnouncesVariable] = "0" }
        run.launch()
        run.addGroup(named: "Home")
        run.addBudget(named: "Groceries", amount: "310", inGroup: "Home")
        run.addEntry(merchant: "Hilltop Grocery", amount: "100")
        XCTAssertTrue(run.waitForLabel(AccessibilityID.budgetDayLine, toBe: dayLine, timeout: 15),
                      "the day line is not \(dayLine). On screen: \(run.visibleTexts())")
        return run
    }

    /// Open and signed out, a new day moves the budget to it, and a new month
    /// starts a new period with nothing spent yet. Nothing is pressed.
    @MainActor
    func testANewDayAndANewMonthWhileOpen() throws {
        let run = try started(at: "2026-10-30T12:00:00", dayLine: "October \u{00B7} day 30 of 31")

        // Scenario LIFE-02
        // 1. The clock moves to the next day: the line says day 31, the wheel
        // reads the 31st's words, and October's transaction is still listed.
        try run.setClock("2026-10-31T09:00:00")
        XCTAssertTrue(run.waitForLabel(AccessibilityID.budgetDayLine, toBe: "October \u{00B7} day 31 of 31", timeout: 15),
                      "the day line did not move to the 31st. On screen: \(run.visibleTexts())")
        let lastDay = TodaysBudget(limit: 31_000, spent: 10_000, on: try PhoneTestApp.clockDate("2026-10-31T09:00:00"))
        XCTAssertTrue(run.waitForLabel(AccessibilityID.budgetWheel, toBe: lastDay.wheel.spokenSummary),
                      "the wheel is not the 31st's: \(run.element(AccessibilityID.budgetWheel).label)")
        XCTAssertTrue(run.hasRow("Hilltop Grocery"), "October's transaction left on October 31")

        // Scenario LIFE-02
        // 2. The clock moves into November: a new period, so October's
        // transaction is no longer in the list, and nothing is spent.
        try run.setClock("2026-11-01T09:00:00")
        XCTAssertTrue(run.waitForLabel(AccessibilityID.budgetDayLine, toBe: "November \u{00B7} day 1 of 30", timeout: 15),
                      "the day line did not move to November. On screen: \(run.visibleTexts())")
        let firstDay = TodaysBudget(limit: 31_000, spent: 0, on: try PhoneTestApp.clockDate("2026-11-01T09:00:00"))
        XCTAssertTrue(run.waitForLabel(AccessibilityID.budgetWheel, toBe: firstDay.wheel.spokenSummary),
                      "the wheel is not November 1's: \(run.element(AccessibilityID.budgetWheel).label)")
        XCTAssertTrue(run.lacksRow("Hilltop Grocery", timeout: 10),
                      "October's transaction is still listed in November. On screen: \(run.visibleTexts())")
    }

    /// Back from a night away, the app checks the date itself as it comes to
    /// the front, and the group's page shows the new day's expected amount
    /// (#209). The test clock's own notice of a new day is off, so only
    /// coming to the front can move it.
    @MainActor
    func testComingBackAfterTheNightChecksTheDate() throws {
        let run = try started(at: "2026-10-17T22:00:00", dayLine: "October \u{00B7} day 17 of 31", announcing: false)
        let evening = try XCTUnwrap(TodaysBudget.group("Home", [
            TodaysBudget(limit: 31_000, spent: 10_000, on: try PhoneTestApp.clockDate("2026-10-17T22:00:00")),
        ]))
        let morning = try XCTUnwrap(TodaysBudget.group("Home", [
            TodaysBudget(limit: 31_000, spent: 10_000, on: try PhoneTestApp.clockDate("2026-10-18T07:00:00")),
        ]))
        let expected = { (money: GroupMoney) in money.wheel.figures.first { $0.label == MoneyWheel.Words.expectedLeft }?.amount }
        let before = try XCTUnwrap(expected(evening), "no expected figure on the 17th")
        let after = try XCTUnwrap(expected(morning), "no expected figure on the 18th")
        XCTAssertNotEqual(before, after, "the test's two days expect the same amount")
        run.goBack()
        run.openGroupPage(named: "Home")
        XCTAssertTrue(run.shows(before), "the group's page doesn't expect \(before) on the 17th. On screen: \(run.visibleTexts())")

        // Scenario LIFE-02
        // 1. The Home Screen, the night passes, and WellSpent comes back: the
        // group's page expects the 18th's amount.
        XCUIDevice.shared.press(.home)
        XCTAssertTrue(run.app.wait(for: .runningBackgroundSuspended, timeout: 15)
                      || run.app.state == .runningBackground, "WellSpent never went to the back")
        try run.setClock("2026-10-18T07:00:00")
        // Longer than the test clock's watch takes, so a notice it wrongly
        // said would have landed by now.
        Thread.sleep(forTimeInterval: 3)
        run.app.activate()
        XCTAssertTrue(run.shows(after, timeout: 15),
                      "the group's page didn't move to the 18th after coming back. On screen: \(run.visibleTexts())")
    }
}
