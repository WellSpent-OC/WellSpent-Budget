import AppKit
import Foundation
import XCTest
import WellSpentAppCore

/// A new day in a window left open, signed out (LIFE-02), on the test clock
/// (`Workspace.clockFileVariable`): the test writes a date and time to a
/// file, and the app reads today from it, so a day and a month can begin
/// while the test runs. The budget's line under its name says which day of
/// which month it is, and the list shows that period's transactions.
///
/// No account is needed. The run's data folder holds the group and the clock
/// file, and goes in tearDown.
final class NewDayTests: XCTestCase {
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

    /// The app on the test clock, at `start`, with Groceries, $310.00 a
    /// month, in a group of its own, and $100.00 spent today.
    @MainActor
    private func started(at start: String, dayLine: String, announcing: Bool = true) throws -> TestApp {
        let run = try TestApp()
        Self.dataRootPath = run.dataRoot.path
        try run.setClock(start)
        if !announcing { run.app.launchEnvironment[Workspace.clockAnnouncesVariable] = "0" }
        run.launch()
        run.addGroup(named: "Home")
        run.addBudget(named: "Groceries", amount: "310", inGroup: "Home")
        run.addEntry(merchant: "Hilltop Grocery", amount: "100")
        run.expect(dayLine: dayLine, "on the clock's day")
        return run
    }

    /// Open and signed out, a new day moves the budget to it, and a new month
    /// starts a new period with nothing spent yet. Nothing is pressed.
    @MainActor
    func testANewDayAndANewMonthWhileOpen() throws {
        let run = try started(at: "2026-10-30T12:00:00", dayLine: "October \u{00B7} day 30 of 31")

        // Scenario LIFE-02
        // 1. The clock moves to the next day: the line says day 31, and the
        // money spent is still this period's.
        try run.setClock("2026-10-31T09:00:00")
        run.expect(dayLine: "October \u{00B7} day 31 of 31", "after the day began")
        XCTAssertTrue(run.listText("Hilltop Grocery").waitForExistence(timeout: 10),
                      "October's transaction left the list on October 31. On screen: \(run.visibleTexts())")
        // The wheel's words and figures, the expected amount among them, are
        // the new day's, as the shared code says for the same money.
        let lastDay = TodaysBudget(limit: 31_000, spent: 10_000, on: try TestApp.clockDate("2026-10-31T09:00:00"))
        run.expect(wheel: AccessibilityID.budgetWheel, reads: lastDay.wheel.spokenSummary, "on the 31st")
        run.expect(figures: lastDay.wheel.figures, "on the 31st")

        // Scenario LIFE-02
        // 2. The clock moves into November: a new period, so October's
        // transaction is no longer in the list.
        try run.setClock("2026-11-01T09:00:00")
        run.expect(dayLine: "November \u{00B7} day 1 of 30", "after the month began")
        let firstDay = TodaysBudget(limit: 31_000, spent: 0, on: try TestApp.clockDate("2026-11-01T09:00:00"))
        run.expect(wheel: AccessibilityID.budgetWheel, reads: firstDay.wheel.spokenSummary, "on November 1")
        run.expect(figures: firstDay.wheel.figures, "on November 1")
        XCTAssertTrue(run.rowIsGone("Hilltop Grocery", timeout: 10),
                      "October's transaction is still listed in November. On screen: \(run.visibleTexts())")
    }

    /// Back from a night away, the app checks the date itself as it comes to
    /// the front, and the group's page shows the new day (#209). A budget's
    /// page redraws on any read of the budgets, but a group's page only when
    /// its money or the day changes. The test clock's own notice of a new day
    /// is off, so only coming to the front can move it.
    @MainActor
    func testComingBackAfterTheNightChecksTheDate() throws {
        let run = try started(at: "2026-10-17T22:00:00", dayLine: "October \u{00B7} day 17 of 31", announcing: false)
        let evening = try XCTUnwrap(TodaysBudget.group("Home", [
            TodaysBudget(limit: 31_000, spent: 10_000, on: try TestApp.clockDate("2026-10-17T22:00:00")),
        ]))
        let morning = try XCTUnwrap(TodaysBudget.group("Home", [
            TodaysBudget(limit: 31_000, spent: 10_000, on: try TestApp.clockDate("2026-10-18T07:00:00")),
        ]))
        XCTAssertNotEqual(evening.wheel.figures, morning.wheel.figures, "the test's two days show the same figures")
        run.openGroupPage(named: "Home")
        run.expect(figures: evening.wheel.figures, "the group's page on the 17th")

        // Scenario LIFE-02
        // 1. Another app comes to the front, the night passes, and WellSpent
        // comes back: the group's page shows the 18th's figures.
        let finder = XCUIApplication(bundleIdentifier: "com.apple.finder")
        finder.activate()
        XCTAssertTrue(run.app.wait(for: .runningBackground, timeout: 10), "WellSpent never went to the back")
        try run.setClock("2026-10-18T07:00:00")
        // Longer than the test clock's watch takes, so a notice it wrongly
        // said would have landed by now.
        Thread.sleep(forTimeInterval: 3)
        run.app.activate()
        run.expect(figures: morning.wheel.figures, "the group's page after coming back the next morning")
    }
}

@MainActor
extension TestApp {
    /// The test clock's file, in the run's data folder, which the app can
    /// read. Named for `Workspace.clockFileVariable` at the first call.
    var clockFile: URL { dataRoot.appendingPathComponent("test-clock.txt") }

    /// Puts the app's clock at `text`, a local date and time such as
    /// `2026-12-14T09:00:00`. Before launch it also tells the app where the
    /// clock is. After launch the app reads the new time the next time it
    /// asks.
    func setClock(_ text: String) throws {
        try FileManager.default.createDirectory(at: dataRoot, withIntermediateDirectories: true)
        try text.write(to: clockFile, atomically: true, encoding: .utf8)
        app.launchEnvironment[Workspace.clockFileVariable] = clockFile.path
    }

    /// A test clock's text as the moment the app reads from it.
    static func clockDate(_ text: String) throws -> Date {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = AppLocale.calendar
        formatter.timeZone = AppLocale.calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        return try XCTUnwrap(formatter.date(from: text), "not a clock time: \(text)")
    }

    /// Waits for the line under the open budget's name to say `expected`.
    func expect(dayLine expected: String, _ what: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(wait(for: element(AccessibilityID.budgetDayLine), holds: expected, timeout: 15),
                      "\(what): the day line is not \(expected). On screen: \(visibleTexts())", file: file, line: line)
    }
}
