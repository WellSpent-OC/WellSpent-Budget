import Foundation
import XCTest
import WellSpentAppCore
import WellSpentCrypto
import WellSpentImport
import WellSpentModel

/// Importing a statement on a phone: ⋯, Import statement, the Files picker,
/// then the review. Most of these tests have a staging build read a statement
/// the test wrote, in place of the Files picker (`UITestStatement`), so a
/// statement is one tap away and can change between imports. The last two use
/// the Files picker itself. The app starts on Groceries, in the samples'
/// Household. No server and no account, so these run on every pull request,
/// in light and in dark.
final class PhoneImportTests: XCTestCase {
    nonisolated(unsafe) private static var dataRootPath: String?
    nonisolated(unsafe) private static var statementsPath: String?

    private typealias Words = ImportReviewScreen.Words

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

    /// A fresh app on Groceries, with Import statement reading this file.
    @MainActor
    private func launched(importing statement: URL) -> PhoneTestApp {
        let run = PhoneTestApp()
        Self.dataRootPath = run.dataRoot.path
        run.launch(importing: statement)
        return run
    }

    /// A folder for the test's statements, removed in tearDown.
    private func statements() throws -> StatementFolder {
        let folder = try StatementFolder()
        Self.statementsPath = folder.url.path
        return folder
    }

    // MARK: - Importing a statement

    @MainActor
    func testImportingAStatement() throws {
        let joes = "TRADER JOES #123", bakery = "CORNER BAKERY"
        let statement = try statements().write([(joes, "-54.20", 0), (bakery, "-12.00", 0)])
        let run = launched(importing: statement)
        let today = BudgetScreen.shortDate(Date())

        // Scenario IMPORT-01
        // 1. ⋯ then Import statement opens the review. The heading names the
        // group, with the file's name under it, then the four counts, a row
        // for each line and the note at the foot. Cancel and Import are in
        // the top bar.
        run.importStatement()
        XCTAssertTrue(run.shows(Words.title(into: "Household")), "no heading. On screen: \(run.visibleTexts())")
        XCTAssertTrue(run.shows("statement.csv"), "the file's name does not show. On screen: \(run.visibleTexts())")
        XCTAssertEqual(run.counts(), ["0", "0", "0", "2"], "Matched, To add, Already imported and Needs a budget")
        for bank in [joes, bakery] {
            XCTAssertTrue(run.element(AccessibilityID.importLine(bank)).exists, "no row for \(bank)")
        }
        XCTAssertTrue(run.shows(SyncWording.importNote(device: PhoneTestApp.device)),
                      "the note does not show. On screen: \(run.visibleTexts())")
        for button in [AccessibilityID.importCancel, AccessibilityID.importConfirm] {
            XCTAssertTrue(run.app.navigationBars.buttons.matching(identifier: button).firstMatch.exists,
                          "\(button) is not in the top bar")
        }

        // Scenario IMPORT-02
        // 2. Each line shows its date and cleaned-up name, the amount, the
        // bank's own words under them, and what will happen to it.
        run.expect(["\(today) · Trader Joes", "-$54.20", joes], on: AccessibilityID.importLine(joes))
        XCTAssertEqual(run.status(of: joes), Words.needsBudget)

        // Scenario IMPORT-01, IMPORT-12
        // 3. Nothing is added before Import. With Groceries chosen for Corner
        // Bakery, Cancel closes the review and Corner Bakery is not in
        // Groceries. Chosen again, then swiped down, it is still not there.
        // Imported again, the file offers the same lines, and Corner
        // Bakery's list is back at Choose.
        run.choose("Groceries", for: bakery)
        run.tap(AccessibilityID.importCancel)
        run.waitForTheReviewToClose()
        XCTAssertFalse(run.element(AccessibilityID.entryRow("Corner Bakery")).waitForExistence(timeout: 3),
                       "Cancel added Corner Bakery")
        run.importStatement()
        run.choose("Groceries", for: bakery)
        run.swipeTheReviewDown()
        XCTAssertFalse(run.element(AccessibilityID.entryRow("Corner Bakery")).waitForExistence(timeout: 3),
                       "swiping the review down added Corner Bakery")
        run.importStatement()
        XCTAssertEqual([run.status(of: joes), run.status(of: bakery)], [Words.needsBudget, Words.needsBudget])
        XCTAssertTrue(run.budgetList(bakery).hasSuffix(Words.choose),
                      "Groceries is still chosen for Corner Bakery: \(run.budgetList(bakery))")

        // Scenario IMPORT-05, IMPORT-06
        // 4. A new merchant's list starts at Choose and offers Household's
        // budgets only. Corner Bakery goes in Groceries. Trader Joes, left at
        // Choose, is not added.
        XCTAssertTrue(run.budgetList(bakery).hasSuffix(Words.choose),
                      "the list does not start at Choose: \(run.budgetList(bakery))")
        run.openBudgetList(bakery)
        for budget in ["Groceries", "Eating out", "Utilities"] {
            XCTAssertTrue(run.listOption(budget).exists, "the list does not offer \(budget). On screen: \(run.visibleButtons())")
        }
        XCTAssertFalse(run.listOption("Materials").exists, "the list offers another group's budget")
        run.listOption("Groceries").tap()
        XCTAssertEqual(run.count(Words.toAdd), "1")
        XCTAssertEqual(run.count(Words.needsBudget), "1")
        run.tap(AccessibilityID.importConfirm)
        run.waitForTheReviewToClose()
        XCTAssertTrue(run.element(AccessibilityID.entryRow("Corner Bakery")).waitForExistence(timeout: 10),
                      "Corner Bakery is not in Groceries. On screen: \(run.visibleTexts())")
        XCTAssertFalse(run.element(AccessibilityID.entryRow("Trader Joes")).exists, "a line left at Choose was added")

        // Scenario IMPORT-02
        // 5. Corner Bakery is in already. Trader Joes, given Groceries, shows
        // in it with its date and Statement, the bank's words, and the amount
        // spent.
        run.importStatement()
        XCTAssertEqual(run.status(of: bakery), Words.alreadyImported)
        run.choose("Groceries", for: joes)
        run.tap(AccessibilityID.importConfirm)
        run.waitForTheReviewToClose()
        XCTAssertTrue(run.element(AccessibilityID.entryRow("Trader Joes")).waitForExistence(timeout: 10),
                      "Trader Joes is not in Groceries. On screen: \(run.visibleTexts())")
        // A row is one element, so its words are read from its label.
        for words in ["Trader Joes", "\(today) · Statement", joes, "$54.20"] {
            XCTAssertTrue(run.row("Trader Joes", says: words),
                          "\(words) is not on Trader Joes' row. It says: \(run.rowLabel("Trader Joes"))")
        }

        // Scenario IMPORT-07
        // 6. Imported a third time, every line is in already, with no list,
        // and Import adds nothing twice.
        let rows = [run.entryRows("Trader Joes"), run.entryRows("Corner Bakery")]
        run.importStatement()
        for bank in [joes, bakery] {
            XCTAssertEqual(run.status(of: bank), Words.alreadyImported)
            XCTAssertFalse(run.element(AccessibilityID.importLineBudget(bank)).exists, "\(bank) offers a list")
        }
        XCTAssertEqual(run.count(Words.alreadyImported), "2")
        run.tap(AccessibilityID.importConfirm)
        run.waitForTheReviewToClose()
        XCTAssertEqual([run.entryRows("Trader Joes"), run.entryRows("Corner Bakery")], rows, "a line was added twice")

        // Scenario IMPORT-09
        // 7. With Groceries deleted, the lines need a budget again in the
        // next budget opened, and the lists offer the budgets left. Filed in
        // Eating out, they count as imported from then on.
        run.openBudgetMenu()
        run.tapMenuItem(MainScreen.Words.delete)
        let question = PendingDelete.budget(Budget(groupID: GroupID(), name: "Groceries", limit: .zero()), transactions: 0)
        try XCTUnwrap(run.questionButton(question.confirmLabel), "no \(question.confirmLabel) on the question").tap()
        XCTAssertTrue(run.element(AccessibilityID.sidebarGroup("Household")).waitForExistence(timeout: 10),
                      "not back on Home")
        run.openBudget(named: "Eating out")
        run.importStatement()
        XCTAssertEqual([run.status(of: joes), run.status(of: bakery)], [Words.needsBudget, Words.needsBudget])
        run.openBudgetList(joes)
        for budget in ["Eating out", "Utilities"] {
            XCTAssertTrue(run.listOption(budget).exists, "the list does not offer \(budget). On screen: \(run.visibleButtons())")
        }
        XCTAssertFalse(run.listOption("Groceries").exists, "the list offers the deleted budget")
        run.listOption("Eating out").tap()
        run.choose("Eating out", for: bakery)
        run.tap(AccessibilityID.importConfirm)
        run.waitForTheReviewToClose()
        XCTAssertFalse(run.app.alerts.firstMatch.waitForExistence(timeout: 3),
                       "the import stopped with an error. On screen: \(run.visibleTexts())")
        for merchant in ["Trader Joes", "Corner Bakery"] {
            XCTAssertTrue(run.element(AccessibilityID.entryRow(merchant)).waitForExistence(timeout: 10),
                          "\(merchant) is not in Eating out. On screen: \(run.visibleTexts())")
        }
        run.importStatement()
        XCTAssertEqual([run.status(of: joes), run.status(of: bakery)], [Words.alreadyImported, Words.alreadyImported])
        run.tap(AccessibilityID.importCancel)
        run.waitForTheReviewToClose()
    }

    // MARK: - Lines that match, lines known, and lines from before

    @MainActor
    func testMatchedKnownAndEarlierLines() throws {
        let costco = "COSTCO WHSE #0472", hilltop = "HILLTOP GROCERY #17", farm = "FARM STAND #9"
        let folder = try statements()
        let statement = try folder.write([(costco, "-286.31", 0), (hilltop, "-58.10", 0)])
        let run = launched(importing: statement)
        let today = BudgetScreen.shortDate(Date())

        // 1. Costco, typed into Groceries by hand.
        run.addEntry(merchant: "Costco", amount: "286.31")
        let counted = run.transactionCount()

        // Scenario IMPORT-03, IMPORT-04
        // 2. The Costco line matches the entry typed by hand. The Hilltop line
        // goes where Hilltop Grocery went before, so it has no list.
        run.importStatement()
        XCTAssertEqual(run.status(of: costco), Words.matchedEntry)
        XCTAssertEqual(run.count(Words.matched), "1")
        run.expect(["\(today) · Hilltop Grocery"], on: AccessibilityID.importLine(hilltop))
        XCTAssertEqual(run.status(of: hilltop), Words.willBeAdded)
        XCTAssertFalse(run.element(AccessibilityID.importLineBudget(hilltop)).exists, "Hilltop offers a list")
        XCTAssertEqual(run.count(Words.toAdd), "1")

        // Scenario IMPORT-03, IMPORT-04
        // 3. Import leaves the Costco typed by hand as the only one, and adds
        // Hilltop Grocery to Groceries.
        run.tap(AccessibilityID.importConfirm)
        run.waitForTheReviewToClose()
        // By the count line: one more, since the Costco line matched. The
        // wheel above the list can push a row below the bottom of the screen,
        // where a list draws nothing to count.
        let added = Date().addingTimeInterval(10)
        while run.transactionCount() != counted + 1, Date() < added { Thread.sleep(forTimeInterval: 0.5) }
        XCTAssertEqual(run.transactionCount(), counted + 1, "not one more transaction. The page says: "
                       + run.countLine())
        // And the one added is Hilltop Grocery's, at $58.10: the list is
        // scrolled until its row shows, then back to the top.
        var swipes = 0
        var hilltopAdded = run.row("Hilltop Grocery", says: "$58.10", timeout: 5)
        while !hilltopAdded, swipes < 6 {
            run.app.swipeUp()
            swipes += 1
            hilltopAdded = run.row("Hilltop Grocery", says: "$58.10", timeout: 2)
        }
        XCTAssertTrue(hilltopAdded, "Hilltop Grocery was not added at $58.10. On screen: \(run.visibleTexts())")
        for _ in 0..<swipes { run.app.swipeDown() }

        // Scenario IMPORT-11
        // 4. A line from before this period goes in, but the budget's page
        // still shows this period only.
        let countLine = run.countLine()
        try folder.write([(farm, "-20.00", 40)])
        run.importStatement()
        run.choose("Groceries", for: farm)
        run.tap(AccessibilityID.importConfirm)
        run.waitForTheReviewToClose()
        XCTAssertFalse(run.element(AccessibilityID.entryRow("Farm Stand")).waitForExistence(timeout: 3),
                       "a line from before this period shows")
        XCTAssertEqual(run.countLine(), countLine, "the count changed")
        run.importStatement()
        XCTAssertEqual(run.status(of: farm), Words.alreadyImported, "the line did not go in")
        run.tap(AccessibilityID.importCancel)
        run.waitForTheReviewToClose()
    }

    // MARK: - A file that is not a statement

    // MARK: - A line deleted after it was imported

    @MainActor
    func testADeletedLineStaysDeletedWhenItsStatementIsImportedAgain() throws {
        let joes = "TRADER JOES #123", bakery = "CORNER BAKERY"
        let statement = try statements().write([(joes, "-54.20", 0), (bakery, "-12.00", 0)])
        let run = launched(importing: statement)
        let counted = run.transactionCount()

        // Scenario IMPORT-08
        // 1. Both lines go into Groceries. Then Corner Bakery is deleted.
        run.importStatement()
        run.choose("Groceries", for: joes)
        run.choose("Groceries", for: bakery)
        run.tap(AccessibilityID.importConfirm)
        run.waitForTheReviewToClose()
        XCTAssertTrue(run.waitForTransactionCount(counted + 2), "both lines did not go in. The page says: \(run.countLine())")
        run.openEntry("Corner Bakery")
        run.tap(AccessibilityID.entryDelete)
        run.answer("Delete")
        run.expectNoSheet()
        XCTAssertTrue(run.waitForTransactionCount(counted + 1), "Corner Bakery was not deleted. The page says: \(run.countLine())")

        // Scenario IMPORT-08
        // 2. The same statement again: both lines say Already imported, and
        // Import finishes with no error. Corner Bakery stays deleted.
        run.importStatement()
        XCTAssertEqual([run.status(of: joes), run.status(of: bakery)], [Words.alreadyImported, Words.alreadyImported])
        run.tap(AccessibilityID.importConfirm)
        run.waitForTheReviewToClose()
        XCTAssertFalse(run.app.alerts.firstMatch.waitForExistence(timeout: 3),
                       "the import ended in an error. On screen: \(run.visibleTexts())")
        XCTAssertTrue(run.waitForTransactionCount(counted + 1, timeout: 5),
                      "Corner Bakery came back. The page says: \(run.countLine())")
        XCTAssertFalse(run.element(AccessibilityID.entryRow("Corner Bakery")).exists, "Corner Bakery is listed again")
    }

    @MainActor
    func testAFileThatIsNotAStatementIsExplained() throws {
        let folder = try statements()
        let files: [(name: String, contents: String, problem: ImportError)] = [
            ("notes.txt", "just some words", .unrecognisedFormat),
            ("header.csv", "Date,Description,Amount\n", .noRowsFound),
            ("columns.csv", "Date,Payee\n10/02/2026,HILLTOP", .malformedRow(line: 1, reason: "no amount column")),
        ]
        let run = PhoneTestApp()
        Self.dataRootPath = run.dataRoot.path

        // Scenario IMPORT-13
        // 1. Each file, in a launch of its own, is named and explained in
        // words on the window. OK closes it, and no review opens.
        for file in files {
            let url = try folder.write(raw: file.contents, to: file.name)
            run.launch(importing: url)
            run.openBudgetMenu()
            run.tapMenuItem(BudgetScreen.Words.importStatement)
            let alert = run.app.alerts[MainScreen.Words.errorTitle]
            XCTAssertTrue(alert.waitForExistence(timeout: 10), "nothing was said about \(file.name). On screen: \(run.visibleTexts())")
            let words = ImportWording.words(for: file.problem, file: file.name)
            XCTAssertTrue(alert.staticTexts[words].exists, "\(words) does not show. On screen: \(run.visibleTexts())")
            alert.buttons[MainScreen.Words.ok].tap()
            XCTAssertTrue(run.wait(for: alert, until: "exists == false", timeout: 10), "OK did not close it")
            XCTAssertFalse(run.element(AccessibilityID.importConfirm).exists, "a review opened for \(file.name)")
        }
    }

    // MARK: - The Files picker

    /// A live build shows the iPhone's own Files picker. Cancel there opens
    /// nothing. The picker runs outside the app, so the test finds its parts
    /// by their words.
    @MainActor
    func testImportStatementOpensTheFilesPicker() throws {
        let run = PhoneTestApp()
        Self.dataRootPath = run.dataRoot.path
        run.launch(startingOn: .budget)
        XCTAssertTrue(run.app.navigationBars["Groceries"].waitForExistence(timeout: 10), "Groceries did not open")

        // 1. Import statement opens the Files picker, and its Cancel opens
        // nothing.
        run.openFilesPicker()
        let cancel = run.app.buttons["Cancel"].firstMatch
        cancel.tap()
        XCTAssertTrue(run.wait(for: cancel, until: "exists == false", timeout: 10), "the Files picker did not close")
        XCTAssertFalse(run.element(AccessibilityID.importConfirm).waitForExistence(timeout: 3), "a review opened")
        XCTAssertFalse(run.app.alerts.firstMatch.exists, "something went wrong. On screen: \(run.visibleTexts())")
        XCTAssertTrue(run.app.navigationBars["Groceries"].exists, "Groceries is gone")
    }

    /// The way a person imports on a phone: a statement saved in Files, then
    /// picked there. The test puts it in On My iPhone itself, since a new
    /// simulator holds no files.
    @MainActor
    func testAStatementPickedInFilesOpensItsReview() throws {
        guard let folder = Self.onMyIPhone() else {
            throw XCTSkip("On My iPhone's folder was not found on this simulator, so nothing can be picked")
        }
        let run = PhoneTestApp()
        Self.dataRootPath = run.dataRoot.path
        run.launch(startingOn: .budget)
        XCTAssertTrue(run.app.navigationBars["Groceries"].waitForExistence(timeout: 10), "Groceries did not open")

        // Scenario IMPORT-01
        // 1. Import statement, then the file picked in Browse, On My iPhone,
        // opens the review of that file, into Household. The file is saved
        // once the picker is open: On My iPhone's folder may only be made
        // then.
        run.openFilesPicker()
        let today = StatementFolder.bankDate(daysAgo: 0)
        let file = try Self.save("Date,Description,Amount\n\(today),\"TRADER JOES #123\",-54.20",
                                 as: "picked.csv", in: folder)
        defer { try? FileManager.default.removeItem(at: file) }
        // Files lists a file written into its folder while the picker is open
        // a moment before it will hand it over. On CI's slow runners that
        // moment ran past two taps 10 seconds apart. So each try closes the
        // picker, opens it again with the file already there, and picks it,
        // three times at most.
        let review = run.element(AccessibilityID.importConfirm)
        var picked = run.app.cells.firstMatch
        for _ in 0..<3 where !review.exists {
            let cancel = run.app.buttons["Cancel"].firstMatch
            guard cancel.exists else { break }
            cancel.tap()
            XCTAssertTrue(run.wait(for: cancel, until: "exists == false", timeout: 15), "the Files picker did not close")
            run.openFilesPicker()
            picked = run.pickInOnMyIPhone("picked")
            _ = review.waitForExistence(timeout: 15)
        }
        XCTAssertTrue(review.waitForExistence(timeout: 15),
                      "the review did not open after three picks. The file's row was "
                      + "\(!picked.exists ? "gone" : picked.isEnabled ? "enabled" : "dimmed"). On screen: \(run.visibleTexts())")
        XCTAssertTrue(run.shows(Words.title(into: "Household")), "no heading. On screen: \(run.visibleTexts())")
        XCTAssertTrue(run.shows("picked.csv"), "the file's name does not show. On screen: \(run.visibleTexts())")
        XCTAssertEqual(run.status(of: "TRADER JOES #123"), Words.needsBudget)
        run.tap(AccessibilityID.importCancel)
        run.waitForTheReviewToClose()
    }

    /// Saves a file in On My iPhone. Its folder is made by the Files app's
    /// own service, a moment after the picker first opens, so this waits a
    /// while for it, then makes it if it is still not there.
    private static func save(_ contents: String, as name: String, in folder: URL) throws -> URL {
        let made = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            FileManager.default.fileExists(atPath: folder.path)
        }, object: nil)
        if XCTWaiter().wait(for: [made], timeout: 10) != .completed {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        let file = folder.appendingPathComponent(name)
        try contents.write(to: file, atomically: true, encoding: .utf8)
        return file
    }

    /// The folder the Files app shows as On My iPhone, on this simulator. The
    /// test runner's own folder is in the same tree, so it is found from
    /// there. Nil when it cannot be found.
    private static func onMyIPhone() -> URL? {
        var containers = FileManager.default.temporaryDirectory
        while containers.lastPathComponent != "Containers", containers.pathComponents.count > 2 {
            containers.deleteLastPathComponent()
        }
        let groups = containers.appendingPathComponent("Shared/AppGroup", isDirectory: true)
        let found = (try? FileManager.default.contentsOfDirectory(at: groups, includingPropertiesForKeys: nil)) ?? []
        for group in found {
            let about = group.appendingPathComponent(".com.apple.mobile_container_manager.metadata.plist")
            guard let data = try? Data(contentsOf: about),
                  let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
                  plist["MCMMetadataIdentifier"] as? String == "group.com.apple.FileProvider.LocalStorage" else { continue }
            return group.appendingPathComponent("File Provider Storage", isDirectory: true)
        }
        return nil
    }
}

// MARK: - The steps these tests take

/// Here, not in PhoneTestSupport.swift, so this file stands on its own. Not
/// private: the two-person tests import statements too
/// (PhoneSharedEntriesTests.swift).
@MainActor
extension PhoneTestApp {
    /// Launches on Groceries, with Import statement reading this file in
    /// place of showing the Files picker. A different file needs a new launch.
    func launch(importing statement: URL) {
        app.launchEnvironment[UITestStatement.variable] = statement.path
        launch(startingOn: .budget)
        XCTAssertTrue(app.navigationBars["Groceries"].waitForExistence(timeout: 10),
                      "Groceries did not open. On screen: \(visibleTexts())")
    }

    /// ⋯, then Import statement, then waits for the review.
    func importStatement() {
        openBudgetMenu()
        tapMenuItem(BudgetScreen.Words.importStatement)
        XCTAssertTrue(element(AccessibilityID.importConfirm).waitForExistence(timeout: 10),
                      "the review did not open. On screen: \(visibleTexts())")
    }

    /// ⋯, then Import statement, with no statement named: the Files picker
    /// opens, with its Cancel.
    func openFilesPicker() {
        openBudgetMenu()
        tapMenuItem(BudgetScreen.Words.importStatement)
        XCTAssertTrue(app.buttons["Cancel"].firstMatch.waitForExistence(timeout: 15),
                      "the Files picker did not open. On screen: \(visibleTexts())")
    }

    /// In the open Files picker: Browse, On My iPhone, then the file whose
    /// name starts with `name`, once it is ready to be picked. Returns its row.
    func pickInOnMyIPhone(_ name: String) -> XCUIElement {
        let browse = app.tabBars.buttons["Browse"].firstMatch
        XCTAssertTrue(browse.waitForExistence(timeout: 15), "no Browse in the Files picker. On screen: \(visibleButtons())")
        browse.tap()
        let onMyIPhone = app.staticTexts["On My iPhone"].firstMatch
        XCTAssertTrue(onMyIPhone.waitForExistence(timeout: 15), "no On My iPhone. On screen: \(visibleTexts())")
        onMyIPhone.tap()
        let row = app.cells.matching(NSPredicate(format: "label BEGINSWITH %@", name)).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 15), "\(name) is not in On My iPhone. On screen: \(visibleTexts())")
        // A file Files has not finished reading yet is listed dimmed, and a
        // tap on it picks nothing.
        wait(for: row, until: "enabled == true", timeout: 15)
        waitUntilHittable(row, name)
        row.tap()
        return row
    }

    func waitForTheReviewToClose() {
        XCTAssertTrue(wait(for: element(AccessibilityID.importConfirm), until: "exists == false", timeout: 10),
                      "the review did not close. On screen: \(visibleTexts())")
    }

    /// Drags the review down from its heading, as a person closes a sheet.
    func swipeTheReviewDown() {
        let heading = element(AccessibilityID.importCount(ImportReviewScreen.Words.matched))
        XCTAssertTrue(heading.waitForExistence(timeout: 10), "no review to swipe down")
        let start = heading.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        start.press(forDuration: 0.1, thenDragTo: start.withOffset(CGVector(dx: 0, dy: app.frame.height * 0.7)))
        waitForTheReviewToClose()
    }

    /// One count at the top of the review, by its label.
    func count(_ label: String) -> String? {
        let tile = element(AccessibilityID.importCount(label))
        XCTAssertTrue(tile.waitForExistence(timeout: 5), "no count called \(label). On screen: \(visibleTexts())")
        return tile.value as? String
    }

    /// The four counts, in the order the review shows them.
    func counts() -> [String?] {
        typealias Words = ImportReviewScreen.Words
        return [Words.matched, Words.toAdd, Words.alreadyImported, Words.needsBudget].map(count)
    }

    /// What a line says will happen to it.
    func status(of bank: String) -> String {
        let status = element(AccessibilityID.importLineStatus(bank))
        XCTAssertTrue(status.waitForExistence(timeout: 5), "no line for \(bank). On screen: \(visibleTexts())")
        return status.label
    }

    /// Checks that each of these words shows inside one element, such as a
    /// line of the review. An entry's row is one element, read with `row`.
    func expect(_ words: [String], on identifier: String) {
        let container = element(identifier)
        XCTAssertTrue(container.waitForExistence(timeout: 5), "nothing called \(identifier). On screen: \(visibleTexts())")
        let shown = container.staticTexts.allElementsBoundByIndex.map(\.label)
        for word in words {
            XCTAssertTrue(shown.contains(word), "\(word) is not on \(identifier). On it: \(shown)")
        }
    }

    /// What a line's budget list says, as VoiceOver reads it: "Budget", then
    /// the budget chosen, or Choose, which is the end of what it says.
    func budgetList(_ bank: String) -> String {
        let list = element(AccessibilityID.importLineBudget(bank))
        XCTAssertTrue(list.waitForExistence(timeout: 5), "\(bank) has no list. On screen: \(visibleTexts())")
        return list.label
    }

    /// Opens a line's budget list, and waits for its first choice, Choose.
    func openBudgetList(_ bank: String) {
        tap(AccessibilityID.importLineBudget(bank))
        XCTAssertTrue(listOption(ImportReviewScreen.Words.choose).waitForExistence(timeout: 5),
                      "\(bank)'s list did not open. On screen: \(visibleButtons())")
    }

    /// A choice in the list open on screen. A line's own list shows the name
    /// of the budget chosen for it too, so anything named for a line is
    /// skipped.
    func listOption(_ name: String) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label == %@ AND NOT (identifier BEGINSWITH %@)",
                                         name, "import.")).firstMatch
    }

    /// Chooses a budget for a line from its list.
    func choose(_ budget: String, for bank: String) {
        openBudgetList(bank)
        let option = listOption(budget)
        XCTAssertTrue(option.exists, "the list does not offer \(budget). On screen: \(visibleButtons())")
        option.tap()
        XCTAssertTrue(budgetList(bank).hasSuffix(budget), "\(budget) was not chosen for \(bank): \(budgetList(bank))")
    }

    /// How many elements carry an entry's row name. Compare counts with each
    /// other, never with a number of rows.
    func entryRows(_ merchant: String) -> Int {
        app.descendants(matching: .any).matching(identifier: AccessibilityID.entryRow(merchant)).count
    }

    /// Waits until the count `entryRows` gives for `merchant` passes `test`.
    func wait(forEntryRows merchant: String, timeout: TimeInterval, until test: @escaping (Int) -> Bool) -> Bool {
        let rows = app.descendants(matching: .any).matching(identifier: AccessibilityID.entryRow(merchant))
        let counted = NSPredicate { _, _ in test(rows.count) }
        let expectation = XCTNSPredicateExpectation(predicate: counted, object: nil)
        return XCTWaiter().wait(for: [expectation], timeout: timeout) == .completed
    }

    /// The open budget's count line, such as "3 transactions since Oct 1".
    func countLine() -> String {
        let line = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", " since ")).firstMatch
        XCTAssertTrue(line.waitForExistence(timeout: 5), "no count line. On screen: \(visibleTexts())")
        return line.label
    }

    /// Waits until the count line says the period holds this many
    /// transactions. A row can be below the bottom of the screen, where a
    /// list draws nothing to count, but the count line counts every one.
    func waitForTransactionCount(_ count: Int, timeout: TimeInterval = 10) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if transactionCount() == count { return true }
            Thread.sleep(forTimeInterval: 0.5)
        } while Date() < deadline
        return false
    }

    /// How many transactions the count line says the period holds: 3 in "3
    /// transactions since Oct 1". It counts every one, drawn or not.
    func transactionCount() -> Int {
        let line = countLine()
        let number = Int(line.prefix { $0.isNumber })
        XCTAssertNotNil(number, "the count line starts with no number: \(line)")
        return number ?? -1
    }
}

/// The test's statements: a folder of its own, since the app's data folder
/// must not exist before the first launch.
private struct StatementFolder {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("wellspent-phone-statements-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    /// statement.csv, with these lines: the bank's words, the amount, and
    /// how many days ago, dated as a bank writes it.
    @discardableResult
    func write(_ lines: [(bank: String, amount: String, daysAgo: Int)]) throws -> URL {
        let rows = lines.map { "\(Self.bankDate(daysAgo: $0.daysAgo)),\"\($0.bank)\",\($0.amount)" }
        return try write(raw: (["Date,Description,Amount"] + rows).joined(separator: "\n"), to: "statement.csv")
    }

    /// A day, as a bank writes it in a statement: 10/02/2026.
    static func bankDate(daysAgo: Int) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "MM/dd/yyyy"
        return formatter.string(from: Calendar.current.date(byAdding: .day, value: -daysAgo, to: Date()) ?? Date())
    }

    /// A file of any name, holding exactly these words.
    func write(raw contents: String, to name: String) throws -> URL {
        let file = url.appendingPathComponent(name)
        try contents.write(to: file, atomically: true, encoding: .utf8)
        return file
    }
}
