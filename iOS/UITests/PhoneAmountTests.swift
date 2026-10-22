import Foundation
import XCTest
import WellSpentAppCore
import WellSpentCrypto
import WellSpentModel

/// How the iPhone reads what a person types for money and dates: every amount
/// is money spent, a region that writes decimals with a comma is read its own
/// way, an amount that can't be read clearly is refused rather than guessed,
/// and a date before the period keeps an entry out of it. No account and no
/// server, so these run on every pull request. Each test starts the app on a
/// fresh data folder, in a region of its own.
final class PhoneAmountTests: XCTestCase {
    nonisolated(unsafe) private static var dataRootPath: String?

    static let unitedStates = Locale(identifier: "en_US")
    static let germany = Locale(identifier: "de_DE")

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

    /// The app, in a region that decides how numbers are written. Its words
    /// stay English.
    @MainActor
    private func launched(in region: Locale) -> PhoneTestApp {
        let run = PhoneTestApp()
        Self.dataRootPath = run.dataRoot.path
        run.app.launchArguments += ["-AppleLocale", region.identifier, "-AppleLanguages", "(en)"]
        run.launch()
        return run
    }

    @MainActor
    func testEveryAmountIsMoneySpentHoweverItIsTyped() throws {
        let run = launched(in: Self.unitedStates)
        run.addBudget(named: "Probe", amount: "1000", inGroup: "Household")

        // Scenario ENTRY-03
        // 1. Four amounts, typed as 42.50, -42.50, (42.50) and $42.50, each
        // show as $42.50, and together they are $170.00 spent.
        for (merchant, typed) in [("Plain", "42.50"), ("Minus", "-42.50"), ("Brackets", "(42.50)"), ("Dollar", "$42.50")] {
            run.addEntry(merchant: merchant, pastingAmount: typed)
            XCTAssertTrue(run.row(merchant, says: "$42.50"),
                          "\(typed) does not show as $42.50. The row says: \(run.rowLabel(merchant))")
        }
        XCTAssertTrue(run.figure(MoneyWheel.Words.spent, is: "$170.00"),
                      "Spent is not $170.00. On screen: \(run.visibleTexts())")

        // Scenario ENTRY-03
        // 2. An amount typed with a thousands mark, $1,234.56, shows as
        // $1234.56.
        run.addEntry(merchant: "Large", pastingAmount: "$1,234.56")
        XCTAssertTrue(run.row("Large", says: "$1234.56"),
                      "$1,234.56 does not show as $1234.56. The row says: \(run.rowLabel("Large"))")
    }

    @MainActor
    func testAnAmountThatCannotBeReadClearlyIsRefused() throws {
        let run = launched(in: Self.unitedStates)
        run.addBudget(named: "Probe", amount: "1000", inGroup: "Household")

        // Scenario ENTRY-13
        // 1. Where a dot marks decimals, 12,50 is refused, with the way to
        // type it, and Add stays dimmed. 12.50 takes the line away and lights
        // Add.
        run.tap(AccessibilityID.budgetAdd)
        run.type("Hilltop Grocery", into: AccessibilityID.entryMerchant)
        run.paste("12,50", into: AccessibilityID.entryAmount)
        let refusal = TypedAmount.Words.unclear(locale: Self.unitedStates)
        XCTAssertTrue(run.text(refusal).waitForExistence(timeout: 5), "no refusal. On screen: \(run.visibleTexts())")
        XCTAssertTrue(refusal.hasSuffix("Type it like 12.50."), "the refusal's example: \(refusal)")
        XCTAssertFalse(run.button(AccessibilityID.entryAdd).isEnabled, "Add lit for 12,50")
        run.paste("12.50", into: AccessibilityID.entryAmount)
        XCTAssertTrue(run.wait(for: run.text(refusal), until: "exists == false", timeout: 5), "the refusal stayed")
        XCTAssertTrue(run.wait(for: run.button(AccessibilityID.entryAdd), until: "isEnabled == true", timeout: 5),
                      "Add stayed dimmed for 12.50")
        run.tap(AccessibilityID.entryCancel)
    }

    @MainActor
    func testWhereACommaMarksDecimalsAmountsAreReadThatWay() throws {
        let run = launched(in: Self.germany)

        // Scenario BUDGET-16
        // 1. New Budget's amount shows its example the region's way, 500,00.
        run.openAddMenu()
        run.tapMenuItem(MainScreen.Words.addBudget)
        let amount = run.element(AccessibilityID.budgetEditorAmount)
        XCTAssertTrue(amount.waitForExistence(timeout: 10), "no New Budget. On screen: \(run.visibleTexts())")
        XCTAssertEqual(amount.placeholderValue, TypedAmount.text(Money(minorUnits: 50_000), locale: Self.germany))
        XCTAssertEqual(amount.placeholderValue, "500,00")

        // Scenario BUDGET-16
        // 2. 1.500,00 lights Add. 500.00 dims it and says how to type it.
        // Added, the budget is $1,500.00 a month.
        run.type("Groceries DE", into: AccessibilityID.budgetEditorName)
        run.paste("1.500,00", into: AccessibilityID.budgetEditorAmount)
        let save = run.button(AccessibilityID.budgetEditorSave)
        XCTAssertTrue(run.wait(for: save, until: "isEnabled == true", timeout: 5), "Add stayed dimmed for 1.500,00")
        run.paste("500.00", into: AccessibilityID.budgetEditorAmount)
        XCTAssertTrue(run.wait(for: save, until: "isEnabled == false", timeout: 5), "Add lit for 500.00")
        let refusal = TypedAmount.Words.unclear(locale: Self.germany)
        XCTAssertTrue(refusal.hasSuffix("Type it like 12,50."), "the refusal's example: \(refusal)")
        XCTAssertTrue(run.text(refusal).waitForExistence(timeout: 5), "no refusal. On screen: \(run.visibleTexts())")
        run.paste("1.500,00", into: AccessibilityID.budgetEditorAmount)
        run.tap(AccessibilityID.budgetEditorSave)
        XCTAssertTrue(run.app.navigationBars["Groceries DE"].waitForExistence(timeout: 10), "the budget did not open")
        XCTAssertTrue(run.waitForLabel(AccessibilityID.budgetWheel, toBe: "Left $1,500 of $1,500"),
                      "the budget is not $1,500.00 a month. On screen: \(run.visibleTexts())")

        // Scenario ENTRY-12
        // 3. 12,50 is twelve fifty: the row shows $12.50, and opened again
        // the amount reads 12,50.
        run.addEntry(merchant: "Hilltop Grocery", pastingAmount: "12,50")
        XCTAssertTrue(run.row("Hilltop Grocery", says: "$12.50"),
                      "12,50 does not show as $12.50. The row says: \(run.rowLabel("Hilltop Grocery"))")
        run.openEntry("Hilltop Grocery")
        XCTAssertEqual(run.fieldText(AccessibilityID.entryAmount), "12,50")
        run.tap(AccessibilityID.entryCancel)
        run.expectNoSheet()
    }

    @MainActor
    func testADateBeforeThisPeriodKeepsAnEntryOutOfIt() throws {
        let run = launched(in: Self.unitedStates)
        let budget = "Probe Dates"
        run.addBudget(named: budget, amount: "1000", inGroup: "Household")

        // Scenario ENTRY-06
        // 1. Hilltop, 42.00, dated the 28th of last month, is not listed:
        // the budget still says $0.00 spent and 0 transactions this period.
        let calendar = Calendar.current
        let today = Date()
        let lastMonth = try XCTUnwrap(calendar.date(byAdding: .month, value: -1, to: today))
        var parts = calendar.dateComponents([.year, .month], from: lastMonth)
        parts.day = 28
        let earlier = try XCTUnwrap(calendar.date(from: parts))
        run.tap(AccessibilityID.budgetAdd)
        run.type("Hilltop", into: AccessibilityID.entryMerchant)
        run.type("42.00", into: AccessibilityID.entryAmount)
        run.pickDate(earlier, showing: today)
        run.tap(AccessibilityID.entryAdd)
        XCTAssertTrue(run.wait(for: run.element(AccessibilityID.entryAmount), until: "exists == false", timeout: 10),
                      "the sheet did not close. On screen: \(run.visibleTexts())")
        XCTAssertFalse(run.element(AccessibilityID.entryRow("Hilltop")).waitForExistence(timeout: 3),
                       "an entry from last month is listed")
        XCTAssertTrue(run.figure(MoneyWheel.Words.spent, is: "$0.00"), "Spent is not $0.00. On screen: \(run.visibleTexts())")
        let start = calendar.date(from: calendar.dateComponents([.year, .month], from: today)) ?? today
        let none = "0 transactions since \(start.formatted(.dateTime.day().month(.abbreviated)))"
        XCTAssertTrue(run.shows(none), "no \"\(none)\". On screen: \(run.visibleTexts())")

        // Scenario ENTRY-06
        // 2. It is kept all the same: deleting the budget says its 1
        // transaction goes with it.
        run.openBudgetMenu()
        run.tapMenuItem(MainScreen.Words.delete)
        let question = PendingDelete.budget(Budget(groupID: GroupID(), name: budget, limit: .zero()), transactions: 1)
        XCTAssertTrue(run.text(question.title).waitForExistence(timeout: 5), "no question. On screen: \(run.visibleTexts())")
        XCTAssertTrue(run.text(question.message).exists,
                      "the question does not count the transaction. On screen: \(run.visibleTexts())")
        XCTAssertTrue(question.message.contains("Its 1 transaction will be deleted too."), question.message)
        run.cancelQuestion()
    }
}

/// The steps these tests take, beside the ones every iPhone test shares.
extension PhoneTestApp {
    /// Add, at the foot of the open budget, with the amount pasted rather
    /// than typed: the amount's keyboard has digits and one decimal mark, and
    /// people bring amounts like (42.50) or $1,234.56 from somewhere else.
    func addEntry(merchant: String, pastingAmount amount: String) {
        tap(AccessibilityID.budgetAdd)
        type(merchant, into: AccessibilityID.entryMerchant)
        paste(amount, into: AccessibilityID.entryAmount)
        tap(AccessibilityID.entryAdd)
        XCTAssertTrue(element(AccessibilityID.entryRow(merchant)).waitForExistence(timeout: 10),
                      "\(merchant) is not in the list. On screen: \(visibleTexts())")
    }

    /// Whether the figure with this label, under a budget's wheel, shows
    /// this amount within the time given. A figure is its label beside its
    /// amount, two plain texts on one row.
    func figure(_ label: String, is amount: String, timeout: TimeInterval = 10) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            let name = app.staticTexts[label].firstMatch
            if name.exists {
                let row = app.staticTexts.matching(NSPredicate(format: "label == %@", amount))
                    .allElementsBoundByIndex.first { abs($0.frame.midY - name.frame.midY) < 4 }
                if row != nil { return true }
            }
            Thread.sleep(forTimeInterval: 0.25)
        } while Date() < deadline
        return false
    }
}
