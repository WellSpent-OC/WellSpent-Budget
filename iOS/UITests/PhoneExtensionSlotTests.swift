import Foundation
import XCTest
import WellSpentAppCore

/// What an extension adds to a group's page on a phone: a section below the
/// money, and a line at the top that scrolls to it. The public repo's test
/// extension stands in for a real one (`TestExtensionSlots`). No account and
/// no server, so these run on every pull request, in light and in dark.
final class PhoneExtensionSlotTests: XCTestCase {
    /// Mid-month, before the last week of any month.
    private static let midMonth = 18

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

    /// A group called Home with one budget and its money wheel, on Home.
    @MainActor
    private func launchedWithHome(testExtension: Bool) -> PhoneTestApp {
        let run = PhoneTestApp()
        Self.dataRootPath = run.dataRoot.path
        if testExtension { run.app.launchEnvironment[TestExtensionSlots.environmentKey] = "1" }
        run.launch(pinnedDay: Self.midMonth)
        run.addGroup(named: "Home")
        run.addBudget(named: "Groceries", amount: "100", inGroup: "Home")
        run.goBack()
        return run
    }

    @MainActor
    func testWithNoExtensionTheGroupPageIsAsItWas() throws {
        let run = launchedWithHome(testExtension: false)

        run.openGroupPage(named: "Home")

        XCTAssertTrue(run.drawsTitle("Home"), "the page's title is not drawn")
        XCTAssertTrue(run.has(AccessibilityID.groupWheel), "the money wheel stays")
        XCTAssertTrue(run.lacks(AccessibilityID.groupTopLine), "no extension, no top line")
        XCTAssertFalse(run.text(TestExtensionSlots.sectionWords).exists, "no extension, no section")
    }

    @MainActor
    func testTheTopLineScrollsToTheSectionBelowTheMoney() throws {
        let run = launchedWithHome(testExtension: true)

        run.openGroupPage(named: "Home")

        // The line shows the extension's words and amount, above the money.
        let line = run.element(AccessibilityID.groupTopLine)
        XCTAssertTrue(line.waitForExistence(timeout: 10), "no top line. On screen: \(run.visibleTexts())")
        XCTAssertTrue(line.label.contains("Test question"), "the line says: \(line.label)")
        XCTAssertTrue(line.label.contains("$1"), "the line says: \(line.label)")
        let wheel = run.element(AccessibilityID.groupWheel)
        XCTAssertTrue(run.has(AccessibilityID.groupWheel), "the money wheel stays")
        XCTAssertLessThan(line.frame.maxY, wheel.frame.minY, "the line is above the money")

        run.tap(AccessibilityID.groupTopLine)

        // The page moved: the section's first row is near the top, and the
        // line has gone off the top of the screen.
        let section = run.text(TestExtensionSlots.sectionWords)
        XCTAssertTrue(section.waitForExistence(timeout: 10), "no section. On screen: \(run.visibleTexts())")
        run.waitUntilStill(section, TestExtensionSlots.sectionWords)
        XCTAssertTrue(section.isHittable, "the section's first row is on screen")
        XCTAssertFalse(line.isHittable, "the page scrolled past the line")
    }
}
