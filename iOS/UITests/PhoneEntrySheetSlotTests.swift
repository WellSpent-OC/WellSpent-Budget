import Foundation
import XCTest
import WellSpentAppCore

/// What an extension adds to the entry sheet on a phone: a row linking an
/// entry to something of its own, and Add opened in a group, with Budget to
/// choose and a new budget when the group has none. The public repo's test
/// extension stands in for a real one (`TestExtensionSlots`). No account and
/// no server, so these run on every pull request, in light and in dark.
final class PhoneEntrySheetSlotTests: XCTestCase {
    /// Mid-month, before the last week of any month.
    private static let midMonth = 18

    nonisolated(unsafe) private static var dataRootPath: String?
    nonisolated(unsafe) private static var statementsPath: String?

    private typealias Words = EntryEditor.Words

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    override func tearDown() {
        let app = XCUIApplication()
        if app.state != .notRunning { app.terminate() }
        for path in [Self.dataRootPath, Self.statementsPath].compactMap({ $0 }) {
            try? FileManager.default.removeItem(atPath: path)
        }
        Self.dataRootPath = nil
        Self.statementsPath = nil
        super.tearDown()
    }

    @MainActor
    private func prepared(testExtension: Bool = true) -> PhoneTestApp {
        let run = PhoneTestApp()
        Self.dataRootPath = run.dataRoot.path
        if testExtension { run.app.launchEnvironment[TestExtensionSlots.environmentKey] = "1" }
        return run
    }

    @MainActor
    private func launched(testExtension: Bool = true) -> PhoneTestApp {
        let run = prepared(testExtension: testExtension)
        run.launch(pinnedDay: Self.midMonth)
        return run
    }

    // MARK: - With no extension

    @MainActor
    func testWithNoExtensionTheAddSheetIsAsItWas() throws {
        let run = launched(testExtension: false)
        run.addGroup(named: "Home")
        run.addBudget(named: "Groceries", amount: "100", inGroup: "Home")

        run.tap(AccessibilityID.budgetAdd)

        XCTAssertTrue(run.has(AccessibilityID.entryMerchant), "Add did not open")
        XCTAssertFalse(run.element(AccessibilityID.entryLink).exists, "no extension, no link row")
        XCTAssertFalse(run.element(AccessibilityID.entryBudget).exists, "Add from a budget offers no Budget")
    }

    // MARK: - The link row

    @MainActor
    func testTheLinkRowSavesAndGoesAwayOnMoneyIn() throws {
        let run = launched()
        run.addGroup(named: "Home")
        run.addBudget(named: "Groceries", amount: "100", inGroup: "Home")
        run.addEntry(merchant: "Water", amount: "12.00")

        // 1. Opened, the row shows None, and offers the extension's choice.
        run.openEntry("Water")
        XCTAssertTrue(run.linkShown().contains(Words.noLink), "the row reads: \(run.linkShown())")
        run.chooseLink(TestExtensionSlots.choice.name)
        run.tap(AccessibilityID.entrySave)
        run.expectNoSheet()

        // 2. Saved, it stays.
        run.openEntry("Water")
        XCTAssertTrue(run.linkShown().contains(TestExtensionSlots.choice.name), "the row reads: \(run.linkShown())")

        // 3. Money in can't be linked: the row goes as the switch goes on,
        // and comes back as it goes off, still holding the choice.
        run.flipMoneyIn()
        XCTAssertTrue(run.lacks(AccessibilityID.entryLink), "money in still offers the link")
        run.flipMoneyIn()
        XCTAssertTrue(run.linkShown().contains(TestExtensionSlots.choice.name), "the row reads: \(run.linkShown())")

        // 4. Saved as money in, the mark is cleared, so back as spending the
        // row reads None.
        run.flipMoneyIn()
        run.tap(AccessibilityID.entrySave)
        run.expectNoSheet()
        run.openEntry("Water")
        XCTAssertFalse(run.element(AccessibilityID.entryLink).exists, "money in offers the link")
        run.flipMoneyIn()
        XCTAssertTrue(run.linkShown().contains(Words.noLink), "the mark stayed: \(run.linkShown())")
    }

    @MainActor
    func testARefundFromAStatementCanBeLinked() throws {
        let bank = "AIRBNB PAYOUT"
        let folder = try StatementFolder()
        Self.statementsPath = folder.url.path
        let statement = try folder.write([(bank, "980.00", 0)])
        let run = prepared()
        run.launch(importing: statement)

        run.importStatement()
        run.chooseKind(Words.refund, for: bank)
        run.choose("Groceries", for: bank)
        run.tap(AccessibilityID.importConfirm)
        run.waitForTheReviewToClose()

        // A person can't type a refund, but one from a statement is a smaller
        // bill, so it takes a link.
        run.openEntry("Airbnb Payout")
        XCTAssertTrue(run.linkShown().contains(Words.noLink), "the row reads: \(run.linkShown())")
    }

    // MARK: - Add, opened in a group

    @MainActor
    func testAddInAGroupOffersThatGroupsBudgetsOnly() throws {
        let run = launched()
        // Another group's budget is the last one opened, which is what a
        // plain Add would file into.
        run.addGroup(named: "Trip")
        run.addBudget(named: "Food", amount: "50", inGroup: "Trip")
        run.goBack()
        run.addGroup(named: "Home")
        run.addBudget(named: "Groceries", amount: "100", inGroup: "Home")
        run.goBack()
        run.addBudget(named: "Bills", amount: "200", inGroup: "Home")
        run.goBack()
        run.openBudget(named: "Food")
        run.goBack()

        run.openGroupPage(named: "Home")
        run.tapTestAdd()

        // Budget offers Home's budgets and a new one, and not Trip's.
        run.tap(AccessibilityID.entryBudget)
        for budget in ["Groceries", "Bills", Words.newBudget] {
            XCTAssertTrue(run.menuItem(budget).waitForExistence(timeout: 5),
                          "Budget does not offer \(budget). On screen: \(run.visibleButtons())")
        }
        XCTAssertFalse(run.menuItem("Food").exists, "Budget offers a budget in another group")
        run.tapMenuItem("Bills")
        run.type("Power", into: AccessibilityID.entryMerchant)
        run.type("80.00", into: AccessibilityID.entryAmount)
        run.bringUpInSheet(AccessibilityID.entryLink)
        run.chooseLink(TestExtensionSlots.choice.name)
        run.tap(AccessibilityID.entryAdd)
        run.expectNoSheet()
        run.goBack()

        // It went where it was told, with its link.
        run.openBudget(named: "Bills")
        XCTAssertTrue(run.hasRow("Power"), "Power is not in Bills. On screen: \(run.visibleTexts())")
        run.openEntry("Power")
        XCTAssertTrue(run.linkShown().contains(TestExtensionSlots.choice.name), "the row reads: \(run.linkShown())")
        run.tap(AccessibilityID.entryCancel)
        run.expectNoSheet()
        run.goBack()
        run.openBudget(named: "Food")
        XCTAssertTrue(run.lacksRow("Power"), "Power went into the last budget opened")
    }

    @MainActor
    func testAGroupWithNoBudgetsMakesOneOnlyOnAdd() throws {
        let run = launched()
        run.addGroup(named: "Lake")

        // 1. Asked for, the new budget's fields show, and Add waits for them.
        run.openGroupPage(named: "Lake")
        run.tapTestAdd()
        run.type("Plumber", into: AccessibilityID.entryMerchant)
        run.type("90.00", into: AccessibilityID.entryAmount)
        XCTAssertTrue(run.has(AccessibilityID.entryNewBudgetName), "no new budget's name")
        XCTAssertTrue(run.has(AccessibilityID.entryNewBudgetAmount), "no new budget's amount")
        XCTAssertEqual(run.fieldText(AccessibilityID.entryNewBudgetName), "", "the name has a default")
        XCTAssertFalse(run.button(AccessibilityID.entryAdd).isEnabled, "Add is lit with no budget to file into")

        // 2. Cancelled, nothing was made.
        run.tap(AccessibilityID.entryCancel)
        run.expectNoSheet()
        run.goBack()
        XCTAssertTrue(run.lacks(AccessibilityID.sidebarBudget("Repairs")), "a budget was made")

        // 3. Added, both the budget and the bill are there.
        run.openGroupPage(named: "Lake")
        run.tapTestAdd()
        run.type("Plumber", into: AccessibilityID.entryMerchant)
        run.type("90.00", into: AccessibilityID.entryAmount)
        run.bringUpInSheet(AccessibilityID.entryNewBudgetName)
        run.type("Repairs", into: AccessibilityID.entryNewBudgetName)
        run.bringUpInSheet(AccessibilityID.entryNewBudgetAmount)
        run.type("200", into: AccessibilityID.entryNewBudgetAmount)
        XCTAssertTrue(run.wait(for: run.button(AccessibilityID.entryAdd), until: "isEnabled == true", timeout: 5),
                      "Add stays off with every field filled")
        run.tap(AccessibilityID.entryAdd)
        run.expectNoSheet()
        run.goBack()
        run.openBudget(named: "Repairs")
        XCTAssertTrue(run.hasRow("Plumber"), "Plumber is not in Repairs. On screen: \(run.visibleTexts())")
    }
}

private extension PhoneTestApp {
    /// The test extension's Test add, on the open group's page. The top line
    /// brings it onto the screen.
    func tapTestAdd() {
        tap(AccessibilityID.groupTopLine)
        let add = app.buttons[TestExtensionSlots.addWords].firstMatch
        XCTAssertTrue(add.waitForExistence(timeout: 10), "no Test add. On screen: \(visibleButtons())")
        waitUntilStill(add, TestExtensionSlots.addWords)
        add.tap()
        XCTAssertTrue(has(AccessibilityID.entryMerchant), "Test add opened no sheet. On screen: \(visibleTexts())")
    }

    /// The link row, as it reads.
    func linkShown() -> String {
        let row = element(AccessibilityID.entryLink)
        XCTAssertTrue(row.waitForExistence(timeout: 10), "no link row. On screen: \(visibleTexts())")
        return "\(row.label) \((row.value as? String) ?? "")"
    }

    func chooseLink(_ name: String) {
        bringUpInSheet(AccessibilityID.entryLink)
        tap(AccessibilityID.entryLink)
        tapMenuItem(name)
        XCTAssertTrue(wait(for: element(AccessibilityID.entryLink), until: "label CONTAINS '\(name)' OR value CONTAINS '\(name)'",
                           timeout: 5),
                      "\(name) was not chosen. The row reads: \(linkShown())")
    }

    /// Money in, on or off.
    func flipMoneyIn() {
        let moneyIn = element(AccessibilityID.entryMoneyIn)
        XCTAssertTrue(moneyIn.waitForExistence(timeout: 10), "no Money in")
        waitUntilHittable(moneyIn, AccessibilityID.entryMoneyIn)
        let control = moneyIn.switches.firstMatch.exists ? moneyIn.switches.firstMatch : moneyIn
        control.tap()
    }
}
