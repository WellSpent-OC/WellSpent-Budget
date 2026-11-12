import AppKit
import Foundation
import XCTest
import WellSpentAppCore

/// The plan card on the Mac, in every state the server can answer, and Choose
/// a plan. The app shows the answer in a file this test writes
/// (`Workspace.pinnedPlanVariable`), read again each time the app comes to the
/// front. So the test signs in once, then for each state rewrites the file,
/// sends the app to the back and brings it forward again.
final class PlanTests: XCTestCase {
    nonisolated(unsafe) private static var dataRootPath: String?
    nonisolated(unsafe) private static var planFile: URL?
    /// PlanBuying.variable, which this bundle doesn't link.
    private static let buyingVariable = "WELLSPENT_PLAN_BUYING"

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    override func tearDown() {
        let app = XCUIApplication()
        if app.state != .notRunning { app.terminate() }
        if let path = Self.dataRootPath { try? FileManager.default.removeItem(atPath: path) }
        Self.dataRootPath = nil
        Self.planFile = nil
        super.tearDown()
    }

    /// Signed in on the free plan, the account sheet closed. Buying is open
    /// (`PlanBuying.variable`) unless a test asks for build A's closed store.
    @MainActor
    private func signedIn(buyingIsOpen: Bool = true) throws -> TestApp {
        let accounts = try TestAccounts.fromEnvironment()
        let run = try TestApp()
        Self.dataRootPath = run.dataRoot.path
        let file = run.dataRoot.appendingPathComponent("plan.json")
        Self.planFile = file
        try Self.write(Self.answer(), to: file)
        run.app.launchEnvironment[Workspace.pinnedPlanVariable] = file.path
        if buyingIsOpen { run.app.launchEnvironment[Self.buyingVariable] = "open" }
        run.launch()
        try run.signIn(email: accounts.email, password: accounts.password, server: accounts.server)
        return run
    }

    @MainActor
    func testTheCardInEachPlanState() throws {
        let run = try signedIn()
        let renews = Self.day(in: 30)

        // Scenario PLAN-01
        openAccount(run)
        expectCard(run, title: "Free plan", lines: ["1 property, sync on every device, and 1 group shared with 1 person.",
                                                   "Free forever. No card, no end date."], action: "See Plans")
        closeAccount(run)

        // Scenario PLAN-14
        // The plan changed elsewhere; coming back to the front shows it.
        try show(run, Self.answer(tier: "growth", state: "active", paidUntil: renews, properties: 3))
        // Scenario PLAN-06
        openAccount(run)
        expectCard(run, title: "Growth · $49 a month", lines: ["Up to 5 properties. You have 3."],
                   action: "Change Plan")
        XCTAssertTrue(run.visibleTexts().contains { $0.hasPrefix("Renews ") && $0.hasSuffix("Bought through Apple.") },
                      "it doesn't say when it renews. On screen: \(run.visibleTexts())")
        closeAccount(run)

        // Scenario PLAN-07
        try show(run, Self.answer(tier: "growth", state: "active", period: "yearly", paidUntil: renews))
        openAccount(run)
        expectCard(run, title: "Growth · $490 a year", action: "Change Plan")
        closeAccount(run)

        // Scenario PLAN-08
        try show(run, Self.answer(tier: "growth", state: "grace", paidUntil: Self.day(in: -1)))
        openAccount(run)
        expectCard(run, title: "Apple couldn't renew your plan", badge: "Growth", action: "Open Apple Settings")
        XCTAssertTrue(run.visibleTexts().contains { $0.hasPrefix("Everything keeps working for 16 days, until ") },
                      "no 16 days. On screen: \(run.visibleTexts())")
        closeAccount(run)

        // Scenario PLAN-09
        try show(run, Self.answer(tier: "growth", state: "billingProblem", paidUntil: Self.day(in: -20),
                                  locked: Self.twoPropertiesLocked))
        openAccount(run)
        expectCard(run, title: "Growth is paused", badge: "Free",
                   lines: ["2 properties are locked until the payment goes through. Nothing was deleted."])
        closeAccount(run)

        // Scenario PLAN-10
        try show(run, Self.answer(tier: "growth", state: "canceled", paidUntil: renews))
        openAccount(run)
        expectCard(run, title: "Growth · ends \(Self.shown(renews))", action: "Keep My Plan")
        closeAccount(run)

        // Scenario PLAN-11
        try show(run, Self.answer(locked: Self.twoPropertiesLocked, lastPlan: "ended"))
        openAccount(run)
        expectCard(run, title: "Free plan", badge: "Free",
                   lines: ["2 properties are locked until you pick a plan. Nothing was deleted."], action: "See Plans")
        XCTAssertTrue(run.element(AccessibilityID.planChangeWhatStaysOpen).exists, "no Change what stays open")
        closeAccount(run)

        // Scenario PLAN-12
        try show(run, Self.answer(locked: Self.twoPropertiesLocked, lastPlan: "refunded"))
        openAccount(run)
        expectCard(run, title: "Refunded", badge: "Free")
        closeAccount(run)

        // Scenario PLAN-13
        try show(run, Self.answer(tier: "growth", state: "active", source: "paddle", paidUntil: renews))
        openAccount(run)
        expectCard(run, title: "Growth · $49 a month", action: "Manage on wellspent.space")
        XCTAssertTrue(run.visibleTexts().contains { $0.hasSuffix("Bought on wellspent.space.") },
                      "it doesn't say where it was bought. On screen: \(run.visibleTexts())")
        closeAccount(run)
    }

    @MainActor
    func testChoosingAPlan() throws {
        let run = try signedIn()
        openAccount(run)

        // Scenario PLAN-02
        run.click(AccessibilityID.planCardAction)
        XCTAssertTrue(run.element(AccessibilityID.planChoices).waitForExistence(timeout: 10), "Choose a plan didn't open")
        for (tier, price) in [("starter", "$19"), ("growth", "$49"), ("portfolio", "$99")] {
            XCTAssertTrue(run.element("plan.row.\(tier)").exists, "no \(tier) row")
            XCTAssertTrue(priceShows(run, tier, price), "no \(price). On screen: \(run.visibleTexts())")
        }
        XCTAssertTrue(run.element("plan.row.starter").isSelected, "Starter, the plan that fits, isn't picked")
        XCTAssertTrue(run.visibleTexts().contains("Subscribe for $19 a Month")
                        || run.element(AccessibilityID.planBuy).label == "Subscribe for $19 a Month",
                      "the button doesn't name the price")

        // Scenario PLAN-03
        run.click(AccessibilityID.planYearly)
        for (tier, price) in [("starter", "$190"), ("growth", "$490"), ("portfolio", "$990")] {
            XCTAssertTrue(priceShows(run, tier, price, timeout: 5),
                          "no \(price) yearly. On screen: \(run.visibleTexts())")
        }
        XCTAssertTrue(run.visibleTexts().contains { $0.contains("2 months free") }, "Yearly doesn't say 2 months free")

        run.click(AccessibilityID.planNotNow)
        XCTAssertTrue(run.element(AccessibilityID.planChoices).waitForNonExistence(timeout: 5), "Not Now didn't close it")
    }

    // Scenario PLAN-17
    /// Build A: the plans show, and nothing can be bought or restored.
    @MainActor
    func testComingSoonBeforeTheStoreSellsPlans() throws {
        let run = try signedIn(buyingIsOpen: false)
        openAccount(run)
        XCTAssertFalse(run.element(AccessibilityID.planRestore).exists, "Restore Purchases under the card")
        run.click(AccessibilityID.planCardAction)
        XCTAssertTrue(run.element(AccessibilityID.planChoices).waitForExistence(timeout: 10), "Choose a plan didn't open")
        for (tier, price) in [("starter", "$19"), ("growth", "$49"), ("portfolio", "$99")] {
            XCTAssertTrue(priceShows(run, tier, price), "no \(price). On screen: \(run.visibleTexts())")
        }
        let buy = run.element(AccessibilityID.planBuy)
        XCTAssertTrue(buy.exists, "no button in Subscribe's place")
        XCTAssertEqual(buy.label, "Coming soon")
        XCTAssertFalse(buy.isEnabled, "Coming soon can be pressed")
        XCTAssertFalse(run.element(AccessibilityID.planRestore).exists, "Restore Purchases in Choose a plan")
        run.click(AccessibilityID.planNotNow)
        XCTAssertTrue(run.element(AccessibilityID.planChoices).waitForNonExistence(timeout: 5), "Not Now didn't close it")
    }

    // MARK: - Steps

    /// Rewrites the pinned answer, then sends the app to the back and brings
    /// it forward, which asks for the plan again.
    @MainActor
    private func show(_ run: TestApp, _ json: String) throws {
        try Self.write(json, to: try XCTUnwrap(Self.planFile))
        let finder = XCUIApplication(bundleIdentifier: "com.apple.finder")
        finder.activate()
        _ = run.app.wait(for: .runningBackground, timeout: 5)
        run.app.activate()
        XCTAssertTrue(run.app.wait(for: .runningForeground, timeout: 10), "the app didn't come back to the front")
    }

    /// Whether a plan's row shows its price. On the Mac each row is one
    /// button, so its price is in the row's own label or value, not a text
    /// of its own.
    @MainActor
    private func priceShows(_ run: TestApp, _ tier: String, _ price: String, timeout: TimeInterval = 0) -> Bool {
        let row = run.element("plan.row.\(tier)")
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if row.label.contains(price) || run.text(of: row).contains(price) || run.visibleTexts().contains(price) {
                return true
            }
            if Date() < deadline { Thread.sleep(forTimeInterval: 0.5) }
        } while Date() < deadline
        return false
    }

    @MainActor
    private func openAccount(_ run: TestApp) {
        // Coming to the front syncs, and Account waits until it's done.
        let account = run.element(AccessibilityID.toolbarAccount)
        XCTAssertTrue(run.wait(for: account, until: "enabled == true", timeout: 60), "Account stayed disabled")
        run.click(AccessibilityID.toolbarAccount)
        XCTAssertTrue(run.element(AccessibilityID.planCard).waitForExistence(timeout: 15),
                      "no plan card. On screen: \(run.visibleTexts())")
    }

    @MainActor
    private func closeAccount(_ run: TestApp) {
        run.click(AccessibilityID.accountClose)
        XCTAssertTrue(run.element(AccessibilityID.planCard).waitForNonExistence(timeout: 5), "the sheet didn't close")
    }

    @MainActor
    private func expectCard(_ run: TestApp, title: String, badge: String? = nil, lines: [String] = [],
                            action: String? = nil, file: StaticString = #filePath, line: UInt = #line) {
        let shown = run.element(AccessibilityID.planCardTitle)
        // On the Mac a Text with an identifier may hold its words in its
        // value, not its label, so read both.
        XCTAssertTrue(run.wait(for: shown, holds: title, timeout: 15),
                      "the card says \(run.text(of: shown)), not \(title)", file: file, line: line)
        let texts = run.visibleTexts()
        if let badge { XCTAssertTrue(texts.contains(badge), "no \(badge) badge. On screen: \(texts)", file: file, line: line) }
        for wanted in lines {
            XCTAssertTrue(texts.contains(wanted), "no line \"\(wanted)\". On screen: \(texts)", file: file, line: line)
        }
        if let action {
            XCTAssertEqual(run.element(AccessibilityID.planCardAction).label, action, file: file, line: line)
        }
    }

    // MARK: - Answers, in the server's shape

    private static let twoPropertiesLocked = #"{"groupIDs":[],"people":[],"houseIDs":["\#(UUID())","\#(UUID())"]}"#

    private static func answer(tier: String = "free", state: String = "free", period: String = "monthly",
                               source: String = "apple", paidUntil: Date? = nil, properties: Int = 1,
                               locked: String? = nil, lastPlan: String? = nil) -> String {
        let free = tier == "free"
        let limit = ["free": 1, "starter": 2, "growth": 5, "portfolio": 15][tier] ?? 1
        let date = ISO8601DateFormatter()
        var fields = [
            #""tier":"\#(tier)""#, #""period":"\#(free ? "none" : period)""#, #""state":"\#(state)""#,
            #""source":"\#(free ? "none" : source)""#,
            #""paidUntil":\#(paidUntil.map { "\"\(date.string(from: $0))\"" } ?? "null")"#,
            #""renews":\#(state == "active")"#, #""nextTier":null"#,
            #""limits":{"properties":\#(limit)}"#, #""used":{"properties":\#(properties)}"#,
            #""extensionsOpen":[]"#, #""canSyncPriceLabs":false"#, #""refreshMinutes":60"#,
            #""appleAccountToken":"\#(UUID())""#
        ]
        if let locked { fields.append(#""locked":\#(locked)"#) }
        if let lastPlan {
            fields.append(#""lastPlan":{"tier":"growth","endedOn":"\#(date.string(from: day(in: -2)))","reason":"\#(lastPlan)"}"#)
        }
        return "{" + fields.joined(separator: ",") + "}"
    }

    /// Whole, never half written: the app may read it at any moment.
    private static func write(_ json: String, to file: URL) throws {
        let temporary = file.deletingLastPathComponent().appendingPathComponent("plan-\(UUID()).json")
        try Data(json.utf8).write(to: temporary)
        if FileManager.default.fileExists(atPath: file.path) {
            _ = try FileManager.default.replaceItemAt(file, withItemAt: temporary)
        } else {
            try FileManager.default.moveItem(at: temporary, to: file)
        }
    }

    private static func day(in days: Int) -> Date {
        Calendar.current.date(byAdding: .day, value: days, to: Date())!
    }

    /// The day as the card says it: "Dec 9", or with the year when it isn't this one.
    private static func shown(_ date: Date) -> String {
        PlanWording.day(date, now: Date(), calendar: AppLocale.calendar)
    }
}
