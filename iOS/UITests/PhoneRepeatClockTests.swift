import Foundation
import XCTest
import WellSpentAppCore
import WellSpentModel

/// A repeat's later months on a phone, on the test clock
/// (`Workspace.clockFileVariable`): a bill shows up each month (REPEAT-02),
/// after time away (REPEAT-03), and in a short month (REPEAT-04). Signed
/// out, in a group of its own. The Mac's twin is `RepeatTests`.
final class PhoneRepeatClockTests: XCTestCase {
    nonisolated(unsafe) private static var dataRootPath: String?
    private static let bill = "Phone bill"

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

    /// Utilities in Home on the test clock at `start`, with the $85.00 phone
    /// bill set to repeat that day.
    @MainActor
    private func repeating(from start: String) throws -> PhoneTestApp {
        let run = PhoneTestApp()
        Self.dataRootPath = run.dataRoot.path
        try run.setClock(start)
        run.launch()
        run.addGroup(named: "Home")
        run.addBudget(named: "Utilities", amount: "600", inGroup: "Home")
        run.addRepeat(merchant: Self.bill, amount: "85.00")
        return run
    }

    @MainActor
    func testItShowsUpEachMonth() throws {
        let run = try repeating(from: "2026-11-14T09:00:00")

        // Scenario REPEAT-02
        // 1. December 14 comes and the app is opened: a new $85.00 bill is in
        // Utilities, dated Dec 14, with Source reading Repeat.
        try run.reopen(on: "2026-12-14T09:00:00", budget: "Utilities")
        try run.expectOneBill(Self.bill, on: "2026-12-14T09:00:00", at: "$85.00", "on December 14")
        XCTAssertTrue(run.row(Self.bill, says: BudgetScreen.Words.repeatSource),
                      "Source does not say Repeat: \(run.rowLabel(Self.bill))")
    }

    /// Every month between getting its bill, once, is proven by RepeatsTests
    /// (`eachMonthThatHasComeGetsOneBill`): no screen shows an earlier
    /// month's bills without moving the date, and moving it makes the missing
    /// bill itself.
    @MainActor
    func testCatchingUpAfterTimeAway() throws {
        let run = try repeating(from: "2026-10-15T09:00:00")

        // Scenario REPEAT-03
        // 1. Opened again on December 20, after this month's 15th, Utilities
        // shows December's phone bill once, dated the 15th, at $85.00. The
        // clock only moves forward, so this read is the one that caught up.
        try run.reopen(on: "2026-12-20T09:00:00", budget: "Utilities")
        try run.expectOneBill(Self.bill, on: "2026-12-15T09:00:00", at: "$85.00", "December, after two months away")
    }

    @MainActor
    func testAShortMonth() throws {
        let run = try repeating(from: "2026-10-31T09:00:00")

        // Scenario REPEAT-04
        // 1. A bill that repeats on the 31st shows up in November on the 30th,
        // the month's last day.
        try run.reopen(on: "2026-11-30T09:00:00", budget: "Utilities")
        try run.expectOneBill(Self.bill, on: "2026-11-30T09:00:00", at: "$85.00", "in November")
    }
}
