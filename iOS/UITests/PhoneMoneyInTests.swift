import Foundation
import XCTest
import WellSpentAppCore

/// Money coming in on a phone (card INC-B, the iPhone half): an entry marked
/// as money in shows in the list with a plus sign. How the wheel draws money
/// in is INC-C's, so no wheel is checked here. No account and no server, so
/// these run on every pull request. Each test starts the app on a fresh data
/// folder, on a set day of this month so the budget reads the same any day.
///
/// DRAFT, held until INC-A (`Transaction.kind`) merges. Until then nothing
/// here can pass: the switch does not exist yet.
final class PhoneMoneyInTests: XCTestCase {
    /// Mid-month, before the last week of any month.
    private static let midMonth = 18

    /// The run's data folder, for tearDown.
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
    private func launched(pinnedDay day: Int) -> PhoneTestApp {
        let run = PhoneTestApp()
        Self.dataRootPath = run.dataRoot.path
        run.launch(pinnedDay: day)
        return run
    }

    @MainActor
    func testAnEntryCanBeMoneyComingIn() throws {
        let day = Self.midMonth
        let run = launched(pinnedDay: day)

        // Scenario INC-01
        // Given: a group called Pool House with a budget called Bookings.
        // A spending entry sits beside it, so the plus sign can be seen to
        // mark only the money in.
        run.addGroup(named: "Pool House")
        run.addBudget(named: "Bookings", amount: "2000", inGroup: "Pool House")
        run.addEntry(merchant: "Cleaner", amount: "400.00")
        XCTAssertTrue(run.row("Cleaner", says: "$400.00"),
                      "the spending row does not say $400.00: \(run.rowLabel("Cleaner"))")

        // When: an entry of $1,310.00 is added and marked as money in.
        run.addMoneyIn(merchant: "Airbnb", amount: "1310.00")

        // Then: the entry shows in the list with a plus sign, and the
        // spending row still has none.
        XCTAssertTrue(run.row("Airbnb", says: "+$1310.00"),
                      "no plus sign on the money-in row: \(run.rowLabel("Airbnb"))")
        XCTAssertFalse(run.row("Cleaner", says: "+", timeout: 1),
                       "the spending row gained a plus sign: \(run.rowLabel("Cleaner"))")

        // Opened again, it is still marked as money in, and the top line
        // says so rather than Refund.
        run.openEntry("Airbnb")
        let moneyIn = run.element(MoneyInPlaceholder.entryMoneyIn)
        XCTAssertTrue(moneyIn.waitForExistence(timeout: 10), "no Money in switch on the opened entry")
        XCTAssertEqual(moneyIn.value as? String, "1", "the opened entry is not marked as money in")
        XCTAssertTrue(run.waitForLabel(AccessibilityID.entryTopLine, toContain: MoneyInPlaceholder.income),
                      "the top line does not say \(MoneyInPlaceholder.income): \(run.element(AccessibilityID.entryTopLine).label)")
        run.tap(AccessibilityID.entryCancel)
        run.expectNoSheet()
    }
}

/// Placeholders until INC-A lands and the words are settled. The
/// identifier moves to `AccessibilityID` in Sources/WellSpentAppCore
/// (the core's, by its own small pull request), and the words come from
/// `EntryEditor.Words` once they exist, so nothing here is typed in twice.
enum MoneyInPlaceholder {
    /// The Money in switch on an entry, new or opened.
    static let entryMoneyIn = "entry.moneyIn"
    static let moneyIn = "Money in"
    static let income = "Income"
    static let refund = "Refund"
}

/// The steps these tests take, beside the ones every iPhone test shares.
extension PhoneTestApp {
    /// Add, at the foot of the open budget, with the Money in switch turned
    /// on before Add.
    func addMoneyIn(merchant: String, amount: String) {
        tap(AccessibilityID.budgetAdd)
        type(merchant, into: AccessibilityID.entryMerchant)
        type(amount, into: AccessibilityID.entryAmount)
        let moneyIn = element(MoneyInPlaceholder.entryMoneyIn)
        XCTAssertTrue(moneyIn.waitForExistence(timeout: 10), "no Money in switch. On screen: \(visibleTexts())")
        // A SwiftUI Toggle reaches the test as a switch whose value is "0"
        // or "1". A tap on it flips it.
        if (moneyIn.value as? String) != "1" { moneyIn.tap() }
        XCTAssertTrue(wait(for: moneyIn, until: "value == '1'", timeout: 5), "Money in did not turn on")
        tap(AccessibilityID.entryAdd)
        XCTAssertTrue(element(AccessibilityID.entryRow(merchant)).waitForExistence(timeout: 10),
                      "\(merchant) is not in the list. On screen: \(visibleTexts())")
    }
}
