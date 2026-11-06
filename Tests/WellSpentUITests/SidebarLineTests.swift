import AppKit
import Foundation
import XCTest
import WellSpentAppCore

/// A group's line in the sidebar works like a folder in Finder, and a selected
/// row's words can be read. No account.
final class SidebarLineTests: XCTestCase {
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
    private func started() throws -> TestApp {
        let run = try TestApp()
        Self.dataRootPath = run.dataRoot.path
        run.launch()
        run.addGroup(named: "Home")
        run.addBudget(named: "Utilities", amount: "600", inGroup: "Home")
        return run
    }

    @MainActor
    func testTheArrowInFrontHidesAndTheNameOpens() throws {
        let run = try started()
        let line = run.element(AccessibilityID.sidebarGroup("Home"))
        XCTAssertTrue(line.waitForExistence(timeout: 10), "no Home")
        let summary = run.element(AccessibilityID.groupSummary)
        let shown = run.sidebarBudgetCount("Utilities")
        XCTAssertGreaterThan(shown, 0)

        // Scenario PAGE-05
        // A click on the arrow in front of the name hides the budgets. It opens
        // no page.
        run.clickGroupArrow("Home")
        XCTAssertTrue(run.wait(forBudgetRows: "Utilities", timeout: 5) { $0 < shown }, "the click in front of the name did not hide the budgets")
        XCTAssertFalse(summary.exists, "the arrow opened the group's page")

        // Scenario PAGE-05
        // A click on the name opens the page and leaves them hidden.
        line.click()
        XCTAssertTrue(summary.waitForExistence(timeout: 10), "the name did not open the page")
        XCTAssertFalse(run.wait(forBudgetRows: "Utilities", timeout: 2) { $0 == shown }, "the name showed the budgets")

        // Scenario PAGE-05
        // The arrow shows them again, and the page stays.
        run.clickGroupArrow("Home")
        XCTAssertTrue(run.wait(forBudgetRows: "Utilities", timeout: 5) { $0 == shown }, "the arrow did not show the budgets")
        XCTAssertTrue(summary.exists, "the arrow closed the group's page")

        // Scenario PAGE-05
        // And the name, clicked with the budgets showing, leaves them showing.
        line.click()
        XCTAssertFalse(run.wait(forBudgetRows: "Utilities", timeout: 2) { $0 < shown }, "the name hid the budgets")
    }

    /// One arrow only. With the pointer on the line, nothing shows at its right
    /// end: not an arrow of ours, nor the one a sidebar's list adds on hover.
    @MainActor
    func testNoSecondArrowWithThePointerOnTheLine() throws {
        let run = try started()
        let line = run.element(AccessibilityID.sidebarGroup("Home"))
        XCTAssertTrue(line.waitForExistence(timeout: 10), "no Home")

        // Scenario PAGE-05
        line.hover()
        Thread.sleep(forTimeInterval: 1)
        let picture = line.screenshot().image
        let attachment = XCTAttachment(image: picture)
        attachment.name = "line"
        attachment.lifetime = .keepAlways
        add(attachment)
        XCTAssertLessThan(try run.contrastAtRightEnd(of: picture), 1.2, "something shows at the right end of the line")
    }

    // Scenario ENTRY-14
    @MainActor
    func testASelectedRowStaysReadable() throws {
        let run = try started()
        run.addEntry(merchant: "Water", amount: "40.00")
        let texts = try run.selectedRowTexts(after: "Water")
        XCTAssertGreaterThanOrEqual(texts.count, 3, "the row's words were not found")
        for text in texts {
            let name = text.label.isEmpty ? String(describing: text.value) : text.label
            let contrast = try run.contrast(of: text)
            print("contrast \(name): \(contrast)")
            XCTAssertGreaterThanOrEqual(contrast, 3, "\(name) can't be read on the selected row")
        }
    }
}
