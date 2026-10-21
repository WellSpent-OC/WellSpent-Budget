import AppKit
import Foundation
import XCTest
import WellSpentAppCore
import WellSpentImport
import WellSpentModel

/// Importing a statement in the real window: Import statement in the budget's
/// toolbar, the file chosen in the open panel by its path, then the review.
/// Each test makes a group of its own, named with the time, and imports into
/// its Groceries. The statements are written into the run's data folder.
///
/// - Importing a statement: the review, a line's row, Cancel, a line left at
///   Choose, and the same statement imported again, and again.
/// - Lines that match an entry typed by hand, a merchant filed before, and
///   lines from before this period.
/// - Files that are not a statement, explained in words.
///
/// The review's counts and rows are read the way a person reads them: the
/// number under each count's name, and the words in line with what a row
/// says will happen to it. Whether a row is faded is read from a picture of
/// its date.
///
/// No account is needed. The run's data folder holds the groups and the
/// statements, and goes in tearDown.
final class ImportGapTests: XCTestCase {
    /// The run's data folder, for tearDown.
    nonisolated(unsafe) private static var dataRootPath: String?

    private typealias Words = ImportReviewScreen.Words

    /// The Source column's words for a line imported from a statement, and
    /// for an entry typed by hand.
    private static let statementSource = TransactionSource.statement.rawValue.capitalized
    private static let manualSource = TransactionSource.manual.rawValue.capitalized

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    /// Closes the app and leaves nothing of the run on this Mac.
    override func tearDown() {
        let app = XCUIApplication()
        if app.state != .notRunning { app.terminate() }
        TestApp.wipeSettings()
        if let path = Self.dataRootPath { try? FileManager.default.removeItem(atPath: path) }
        Self.dataRootPath = nil
        super.tearDown()
    }

    // MARK: - Importing a statement

    @MainActor
    func testImportingAStatement() throws {
        let run = try TestApp()
        Self.dataRootPath = run.dataRoot.path
        let stamp = Self.stamp()
        let household = "Household \(stamp)"
        let groceries = "Groceries \(stamp)", eatingOut = "Eating out \(stamp)"
        let joes = "TRADER JOES #123", bakery = "CORNER BAKERY"
        let statement = try run.writeStatement([(joes, "-54.20"), (bakery, "-12.00")])
        // The day the statement's lines are dated. It is fixed when the file
        // is written, so it is built then too.
        let today = BudgetScreen.shortDate(Date())
        // What Groceries shows with nothing spent, built anew for each check,
        // so a run that crosses midnight expects the day the app shows by then.
        func untouched() -> TodaysBudget { TodaysBudget(limit: 50_000, spent: 0) }

        // 1. A group with two budgets. Saving a budget opens it, so Groceries
        // is made last, and stays open.
        run.launch()
        run.addGroup(named: household)
        run.addBudget(named: eatingOut, amount: "200", inGroup: household)
        run.addBudget(named: groceries, amount: "500", inGroup: household)

        // Scenario IMPORT-01
        // 2. Import statement, then the file picked, opens the review. Its
        // title names the group, with the file's name beside it. The four
        // counts sit across the top, each line has a row, and the note sits
        // at the foot beside Cancel and Import. Nothing is in Groceries yet.
        run.expect(button: AccessibilityID.budgetImport, says: BudgetScreen.Words.importStatement)
        run.importStatement(at: statement)
        run.expectTitle(Words.title(into: household), beside: statement.lastPathComponent)
        for bank in [joes, bakery] {
            XCTAssertTrue(run.element(AccessibilityID.importLineStatus(bank)).waitForExistence(timeout: 10),
                          "no row for \(bank). On screen: \(run.visibleTexts())")
        }
        run.expectCountsAcrossTheTop(above: [joes, bakery])
        run.expect(counts: [0, 0, 0, 2], "two lines from merchants not filed before")
        run.expectNoteAtTheFoot(below: [joes, bakery])
        for merchant in ["Trader Joes", "Corner Bakery"] {
            XCTAssertFalse(run.element(AccessibilityID.entryRow(merchant)).exists,
                           "\(merchant) is in Groceries before Import")
        }
        run.expect(wheel: AccessibilityID.budgetWheel, reads: untouched().wheel.spokenSummary,
                   "Groceries, with the review open")

        // Scenario IMPORT-02
        // 3. Trader Joes' row shows the date, the cleaned-up name with the
        // bank's own words under it, and the amount, and says what will
        // happen to the line.
        run.expect(line: joes, shows: [today, "Trader Joes", joes, "-$54.20"])
        run.expect(joes, under: "Trader Joes", onLine: joes)
        XCTAssertEqual(run.status(of: joes), Words.needsBudget)
        // How far each line's date stands out while its row will do
        // something, for step 7 to compare.
        let unfaded = [joes, bakery].map { run.contrast(ofDate: today, onLine: $0) }

        // Scenario IMPORT-12
        // 4. Cancel closes the review and adds nothing, though Corner Bakery
        // was given Groceries. Imported again, the file offers the same
        // lines as before, with Corner Bakery back at Choose.
        run.choose(groceries, in: AccessibilityID.importLineBudget(bakery))
        run.click(AccessibilityID.importCancel)
        run.waitForTheReviewToClose()
        XCTAssertFalse(run.element(AccessibilityID.entryRow("Corner Bakery")).waitForExistence(timeout: 3),
                       "Cancel added Corner Bakery")
        XCTAssertFalse(run.element(AccessibilityID.entryRow("Trader Joes")).exists, "Cancel added Trader Joes")
        run.expect(wheel: AccessibilityID.budgetWheel, reads: untouched().wheel.spokenSummary,
                   "Groceries, after Cancel")
        run.importStatement(at: statement)
        XCTAssertEqual([run.status(of: joes), run.status(of: bakery)], [Words.needsBudget, Words.needsBudget])
        run.expect(list: bakery, shows: Words.choose)
        run.expect(counts: [0, 0, 0, 2], "the same file, after Cancel")

        // Scenario IMPORT-06
        // 5. Corner Bakery given Groceries, Trader Joes left at Choose, then
        // Import: only Corner Bakery is added. Imported again, Trader Joes
        // still needs a budget, so it went into none of the group's budgets:
        // a line added to any of them says Already imported.
        run.choose(groceries, in: AccessibilityID.importLineBudget(bakery))
        run.click(AccessibilityID.importConfirm)
        run.waitForTheReviewToClose()
        XCTAssertTrue(run.element(AccessibilityID.entryRow("Corner Bakery")).waitForExistence(timeout: 10),
                      "Corner Bakery is not in Groceries. On screen: \(run.visibleTexts())")
        XCTAssertFalse(run.element(AccessibilityID.entryRow("Trader Joes")).waitForExistence(timeout: 3),
                       "a line left at Choose was added")
        let bakeryOnly = TodaysBudget(limit: 50_000, spent: 1_200)
        run.expect(wheel: AccessibilityID.budgetWheel, reads: bakeryOnly.wheel.spokenSummary,
                   "Groceries, with Corner Bakery")
        run.expect(figures: bakeryOnly.wheel.figures, "Groceries, with Corner Bakery")
        run.importStatement(at: statement)
        XCTAssertEqual(run.status(of: joes), Words.needsBudget, "a line left at Choose went into a budget")

        // Scenario IMPORT-02
        // 6. Trader Joes is given Groceries. Once imported, it shows in
        // Groceries as Trader Joes, with the bank's words under it,
        // Statement under Source, and $54.20.
        run.choose(groceries, in: AccessibilityID.importLineBudget(joes))
        run.click(AccessibilityID.importConfirm)
        run.waitForTheReviewToClose()
        XCTAssertTrue(run.element(AccessibilityID.entryRow("Trader Joes")).waitForExistence(timeout: 10),
                      "Trader Joes is not in Groceries. On screen: \(run.visibleTexts())")
        run.expect(entry: "Trader Joes", shows: [joes, Self.statementSource, "$54.20"])
        run.expect(joes, under: "Trader Joes", inEntry: "Trader Joes")
        run.expect(Self.statementSource, underColumn: BudgetScreen.Words.source, onEntry: "Trader Joes")

        // Scenario IMPORT-07
        // 7. Imported a third time, every line says Already imported, with
        // no budget list, and its row is faded: its date stands out less
        // than in step 3. Already imported counts every line. Import then
        // adds nothing twice.
        let rows = [run.entryRows("Trader Joes"), run.entryRows("Corner Bakery")]
        run.importStatement(at: statement)
        for (bank, before) in zip([joes, bakery], unfaded) {
            XCTAssertEqual(run.status(of: bank), Words.alreadyImported, "\(bank) does not count as imported")
            XCTAssertFalse(run.element(AccessibilityID.importLineBudget(bank)).exists, "\(bank) offers a budget list")
            let now = run.contrast(ofDate: today, onLine: bank)
            XCTAssertLessThan(now, before * 0.8, "\(bank)'s row is not faded: its date stands out \(now), and \(before) "
                              + "before")
        }
        run.expect(counts: [0, 0, 2, 0], "a statement imported already")
        run.click(AccessibilityID.importConfirm)
        run.waitForTheReviewToClose()
        XCTAssertFalse(run.app.staticTexts[MainScreen.Words.errorTitle].waitForExistence(timeout: 3),
                       "the import stopped with an error. On screen: \(run.visibleTexts())")
        XCTAssertEqual([run.entryRows("Trader Joes"), run.entryRows("Corner Bakery")], rows, "a line was added twice")
        let both = TodaysBudget(limit: 50_000, spent: 6_620)
        run.expect(wheel: AccessibilityID.budgetWheel, reads: both.wheel.spokenSummary,
                   "Groceries, after the third import")
        run.expect(figures: both.wheel.figures, "Groceries, after the third import")

        // 8. Tidy: the group goes, with its budgets.
        run.deleteGroup(named: household)
    }

    // MARK: - Lines that match, a merchant filed before, and lines from before

    @MainActor
    func testMatchedKnownAndEarlierLines() throws {
        let run = try TestApp()
        Self.dataRootPath = run.dataRoot.path
        let stamp = Self.stamp()
        let household = "Household \(stamp)"
        let groceries = "Groceries \(stamp)", eatingOut = "Eating out \(stamp)"
        let costco = "COSTCO WHSE #0472", hilltop = "HILLTOP GROCERY #17", bakery = "CORNER BAKERY"
        let farm = "FARM STAND #9", orchard = "APPLE ORCHARD #2"
        // The Costco line is dated the day before Costco is typed. The rule
        // counts the days between them either way.
        let statement = try run.writeStatement(named: "statement.csv", [(costco, "-286.31", 1), (hilltop, "-58.10", 0)])
        // The name the review gives the Costco line, made by the app's own
        // tidying of the bank's words, which drops the store number.
        let costcoName = StatementLine(date: Date(), rawDescription: costco, amount: Money(minorUnits: -28_631))
            .cleanedDescription
        // What Eating out and Groceries show, built anew for each check, so a
        // run that crosses midnight expects the day the app shows by then.
        func eatingOutUntouched() -> TodaysBudget { TodaysBudget(limit: 20_000, spent: 0) }
        func filed() -> TodaysBudget { TodaysBudget(limit: 50_000, spent: 38_641) }

        // 1. A group with two budgets, and in Groceries, Hilltop Grocery,
        // $42.00, and Costco, $286.31, typed by hand. Then Eating out is
        // opened, so the open budget is not where Hilltop Grocery went.
        run.launch()
        run.addGroup(named: household)
        run.addBudget(named: eatingOut, amount: "200", inGroup: household)
        run.addBudget(named: groceries, amount: "500", inGroup: household)
        run.addEntry(merchant: "Hilltop Grocery", amount: "42.00")
        run.addEntry(merchant: "Costco", amount: "286.31")
        let typed = (costco: run.entryRows("Costco"), hilltop: run.entryRows("Hilltop Grocery"))
        run.click(AccessibilityID.sidebarBudget(eatingOut))
        run.expect(wheel: AccessibilityID.budgetWheel, reads: eatingOutUntouched().wheel.spokenSummary,
                   "Eating out, opened")

        // Scenario IMPORT-03, IMPORT-04
        // 2. The statement goes into Household, Eating out's group. The
        // Costco line, a day from Costco typed by hand, matches it, and
        // Matched counts it. The Hilltop line shows Hilltop Grocery and will
        // be added, with no budget list, and To add counts it.
        run.importStatement(at: statement)
        run.expect(line: costco, shows: [costcoName])
        XCTAssertEqual(run.status(of: costco), Words.matchedEntry)
        run.expect(line: hilltop, shows: ["Hilltop Grocery"])
        XCTAssertEqual(run.status(of: hilltop), Words.willBeAdded)
        XCTAssertFalse(run.element(AccessibilityID.importLineBudget(hilltop)).exists,
                       "the Hilltop line offers a budget list")
        run.expect(counts: [1, 1, 0, 0], "one line matched and one to add")

        // Scenario IMPORT-03, IMPORT-04
        // 3. Import: the Hilltop line goes where Hilltop Grocery went before,
        // not into Eating out, which is open. Groceries holds a second
        // Hilltop Grocery, $58.10, and still one Costco, the one typed by
        // hand, with no row for the Costco line. Only $58.10 more is spent.
        run.click(AccessibilityID.importConfirm)
        run.waitForTheReviewToClose()
        XCTAssertFalse(run.element(AccessibilityID.entryRow("Hilltop Grocery")).waitForExistence(timeout: 3),
                       "the Hilltop line went into Eating out, the open budget")
        run.expect(wheel: AccessibilityID.budgetWheel, reads: eatingOutUntouched().wheel.spokenSummary,
                   "Eating out, after Import")
        run.click(AccessibilityID.sidebarBudget(groceries))
        XCTAssertTrue(run.wait(forEntryRows: "Hilltop Grocery", timeout: 10) { $0 == typed.hilltop * 2 },
                      "no second Hilltop Grocery. On screen: \(run.visibleTexts())")
        run.expect(entry: "Hilltop Grocery", shows: ["$58.10"])
        XCTAssertFalse(run.element(AccessibilityID.entryRow(costcoName)).waitForExistence(timeout: 3),
                       "the Costco line was added, as \(costcoName)")
        XCTAssertEqual(run.entryRows("Costco"), typed.costco, "a second Costco shows")
        run.expect(entry: "Costco", shows: [Self.manualSource, "$286.31"])
        run.expect(wheel: AccessibilityID.budgetWheel, reads: filed().wheel.spokenSummary,
                   "Groceries, with the Hilltop line")
        run.expect(figures: filed().wheel.figures, "Groceries, with the Hilltop line")

        // Scenario IMPORT-03
        // 4. A line matches only an entry typed by hand, with the same
        // amount, dated within 4 days of it. So none of these match: Costco's
        // amount dated 6 days before Costco was typed, Hilltop Grocery's
        // amount one cent off, and the amount of the Hilltop line, which
        // came from a statement. Then Cancel.
        let nearly = try run.writeStatement(named: "nearly.csv",
                                            [(costco, "-286.31", 6), (hilltop, "-42.01", 0), (bakery, "-58.10", 0)])
        run.importStatement(at: nearly)
        for bank in [costco, hilltop, bakery] {
            XCTAssertNotEqual(run.status(of: bank), Words.matchedEntry, "\(bank) matched an entry")
        }
        XCTAssertEqual(run.count(Words.matched), "0", "Matched counts a line that matches nothing")
        run.click(AccessibilityID.importCancel)
        run.waitForTheReviewToClose()

        // Scenario IMPORT-11
        // 5. Two lines from before this period, filed in Groceries, go in,
        // but Groceries' list and total leave them out. Imported again, they
        // are Already imported.
        let earlier = try run.writeStatement(named: "earlier.csv", [(farm, "-20.00", 40), (orchard, "-15.00", 41)])
        run.importStatement(at: earlier)
        for bank in [farm, orchard] {
            run.choose(groceries, in: AccessibilityID.importLineBudget(bank))
        }
        run.click(AccessibilityID.importConfirm)
        run.waitForTheReviewToClose()
        for merchant in ["Farm Stand", "Apple Orchard"] {
            XCTAssertFalse(run.element(AccessibilityID.entryRow(merchant)).waitForExistence(timeout: 3),
                           "\(merchant), from before this period, is in Groceries' list")
        }
        run.expect(wheel: AccessibilityID.budgetWheel, reads: filed().wheel.spokenSummary,
                   "Groceries, after lines from before this period")
        run.expect(figures: filed().wheel.figures, "Groceries, after lines from before this period")
        run.importStatement(at: earlier)
        XCTAssertEqual([run.status(of: farm), run.status(of: orchard)], [Words.alreadyImported, Words.alreadyImported],
                       "the lines from before this period did not go in")
        run.click(AccessibilityID.importCancel)
        run.waitForTheReviewToClose()

        // 6. Tidy: the group goes, with its budgets.
        run.deleteGroup(named: household)
    }

    // MARK: - A file that is not a statement

    @MainActor
    func testAFileThatIsNotAStatementIsExplained() throws {
        let run = try TestApp()
        Self.dataRootPath = run.dataRoot.path
        let stamp = Self.stamp()
        let household = "Household \(stamp)", groceries = "Groceries \(stamp)"
        let files: [(name: String, contents: String, problem: ImportError)] = [
            ("notes.txt", "Pick up bread and milk", .unrecognisedFormat),
            ("header.csv", "Date,Description,Amount\n", .noRowsFound),
            ("columns.csv", "Date,Payee\n10/02/2026,HILLTOP", .malformedRow(line: 1, reason: "no amount column")),
        ]

        // 1. A group with a budget, which saving opens.
        run.launch()
        run.addGroup(named: household)
        run.addBudget(named: groceries, amount: "500", inGroup: household)

        // Scenario IMPORT-13
        // 2. Each file, picked in the open panel, is named and explained in
        // words on the window, and no review opens. OK puts the words away.
        for file in files {
            let url = try run.writeFile(named: file.name, holding: file.contents)
            run.pickStatement(at: url)
            let words = ImportWording.words(for: file.problem, file: file.name)
            XCTAssertTrue(run.app.staticTexts[words].waitForExistence(timeout: 10),
                          "nothing was said about \(file.name). On screen: \(run.visibleTexts())")
            XCTAssertFalse(run.element(AccessibilityID.importConfirm).exists, "a review opened for \(file.name)")
            try XCTUnwrap(run.dialogButton(MainScreen.Words.ok), "no \(MainScreen.Words.ok) under the words").click()
            XCTAssertTrue(run.wait(for: run.app.staticTexts[words], until: "exists == false", timeout: 10),
                          "\(MainScreen.Words.ok) did not put the words away")
            XCTAssertFalse(run.element(AccessibilityID.importConfirm).waitForExistence(timeout: 2),
                           "a review opened for \(file.name)")
        }

        // 3. Tidy: the group goes, with its budget.
        run.deleteGroup(named: household)
    }

    /// Part of each name, so runs never share one.
    private static func stamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: Date())
    }
}

// MARK: - The steps these tests take

/// A line of words on screen: what it says, its name, and where it is.
private struct ShownText {
    let words: String
    let identifier: String
    let frame: CGRect
}

/// Here, not in UITestSupport.swift, so this file stands on its own.
@MainActor
private extension TestApp {
    // MARK: Statements

    /// A statement in the run's folder, under this name: each line's bank
    /// words and amount, dated `daysAgo` days before today, the way a bank
    /// writes a date. Removed with the folder.
    func writeStatement(named name: String, _ lines: [(bank: String, amount: String, daysAgo: Int)]) throws -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "MM/dd/yyyy"
        let rows = lines.map { line in
            let day = Calendar.current.date(byAdding: .day, value: -line.daysAgo, to: Date()) ?? Date()
            return "\(formatter.string(from: day)),\"\(line.bank)\",\(line.amount)"
        }
        return try writeFile(named: name, holding: (["Date,Description,Amount"] + rows).joined(separator: "\n"))
    }

    /// A file of any name in the run's folder, holding exactly these words.
    func writeFile(named name: String, holding contents: String) throws -> URL {
        let url = dataRoot.appendingPathComponent(name)
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    /// Import statement, with the file chosen in the open panel by its path,
    /// as `importStatement(at:)` chooses it, for a file the app explains in
    /// words in place of a review. Returns once the panel has closed.
    func pickStatement(at url: URL) {
        click(AccessibilityID.budgetImport)
        let open = app.windows.buttons["Open"].firstMatch
        XCTAssertTrue(open.waitForExistence(timeout: 10), "the open panel did not show. On screen: \(visibleTexts())")
        app.typeKey("g", modifierFlags: [.command, .shift])
        let goTo = app.descendants(matching: .any).matching(NSPredicate(
            format: "hasKeyboardFocus == true AND (elementType == %d OR elementType == %d)",
            XCUIElement.ElementType.textField.rawValue, XCUIElement.ElementType.comboBox.rawValue)).firstMatch
        XCTAssertTrue(goTo.waitForExistence(timeout: 10),
                      "the open panel's Go to field never took the keyboard. On screen: \(visibleTexts())")
        app.typeText(url.path)
        app.typeKey(.return, modifierFlags: [])
        if !wait(for: open, until: "exists == false", timeout: 3) {
            XCTAssertTrue(wait(for: open, until: "isEnabled == true", timeout: 10),
                          "the panel did not pick \(url.lastPathComponent). On screen: \(visibleTexts())")
            open.click()
        }
        XCTAssertTrue(wait(for: open, until: "exists == false", timeout: 10),
                      "the open panel did not close. On screen: \(visibleTexts())")
    }

    // MARK: Reading the screen

    /// The words under `root`, read from one snapshot, and the frames of the
    /// elements named `identifier`, when one is given.
    func look(in root: XCUIElement, for identifier: String? = nil) -> (texts: [ShownText], frames: [CGRect]) {
        guard let snapshot = try? root.snapshot() else { return ([], []) }
        var texts: [ShownText] = []
        var frames: [CGRect] = []
        var waiting = [snapshot]
        while let node = waiting.popLast() {
            if let identifier, node.identifier == identifier { frames.append(node.frame) }
            if node.elementType == .staticText {
                let words = node.label.isEmpty ? (node.value as? String ?? "") : node.label
                if !words.isEmpty { texts.append(ShownText(words: words, identifier: node.identifier, frame: node.frame)) }
            }
            waiting.append(contentsOf: node.children)
        }
        return (texts, frames)
    }

    /// Checks `lower` shows under `upper`, starting where it starts, among
    /// these words.
    func expect(_ lower: String, under upper: String, among texts: [ShownText], _ place: String,
                file: StaticString, line: UInt) {
        guard let top = texts.first(where: { $0.words == upper }), let below = texts.first(where: { $0.words == lower })
        else {
            XCTFail("\(upper) and \(lower) are not both \(place). It shows: \(texts.map(\.words))", file: file, line: line)
            return
        }
        XCTAssertGreaterThanOrEqual(below.frame.minY, top.frame.midY, "\(lower) is not under \(upper) \(place)",
                                    file: file, line: line)
        XCTAssertLessThan(abs(below.frame.minX - top.frame.minX), 4, "\(lower) does not start where \(upper) does \(place)",
                          file: file, line: line)
    }

    /// Checks a button says these words, as its title or as its name, which
    /// is what a toolbar button that shows only its picture says.
    func expect(button identifier: String, says words: String, file: StaticString = #filePath, line: UInt = #line) {
        let button = element(identifier)
        XCTAssertTrue(button.waitForExistence(timeout: 10), "no \(words) button. On screen: \(visibleTexts())",
                      file: file, line: line)
        XCTAssertTrue([button.title, button.label].contains(words),
                      "\(identifier) says \(button.title) \(button.label), not \(words)", file: file, line: line)
    }

    // MARK: The review

    /// The review, while it is open: the sheet with Import on it.
    var review: XCUIElement {
        app.sheets.containing(.any, identifier: AccessibilityID.importConfirm).firstMatch
    }

    func waitForTheReviewToClose(file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(wait(for: element(AccessibilityID.importConfirm), until: "exists == false", timeout: 10),
                      "the review did not close. On screen: \(visibleTexts())", file: file, line: line)
    }

    /// What a line says will happen to it.
    func status(of bank: String) -> String {
        let status = element(AccessibilityID.importLineStatus(bank))
        XCTAssertTrue(status.waitForExistence(timeout: 5), "no row for \(bank). On screen: \(visibleTexts())")
        return text(of: status)
    }

    /// The names of the counts at the top, in the order the review shows them.
    static var countNames: [String] {
        typealias Words = ImportReviewScreen.Words
        return [Words.matched, Words.toAdd, Words.alreadyImported, Words.needsBudget]
    }

    /// A count's name at the top of the review. What a line says will happen
    /// to it can be the same words, so those are left out.
    func countName(_ name: String, in texts: [ShownText]) -> ShownText? {
        texts.first { $0.words == name && !$0.identifier.hasPrefix(AccessibilityID.importLineStatus("")) }
    }

    /// One count at the top of the review, as it reads: the number under its
    /// name.
    func count(_ name: String, in texts: [ShownText]) -> String {
        guard let label = countName(name, in: texts) else { return "no count called \(name)" }
        let under: [ShownText] = texts.filter { (text: ShownText) -> Bool in
            let sameColumn: Bool = abs(text.frame.minX - label.frame.minX) < 4
            let justBelow: Bool = text.frame.minY >= label.frame.midY && text.frame.minY - label.frame.maxY < 24
            return text.words.allSatisfy(\.isNumber) && sameColumn && justBelow
        }
        return under.min { $0.frame.minY < $1.frame.minY }?.words ?? "no number under \(name)"
    }

    func count(_ name: String) -> String {
        count(name, in: look(in: review).texts)
    }

    /// The four counts, in the order the review shows them, from one look.
    func counts() -> [String] {
        let texts = look(in: review).texts
        return Self.countNames.map { count($0, in: texts) }
    }

    /// Waits for the four counts to read `expected`: Matched, To add, Already
    /// imported and Needs a budget.
    func expect(counts expected: [Int], _ what: String, file: StaticString = #filePath, line: UInt = #line) {
        let wanted = expected.map(String.init)
        let read = NSPredicate { _, _ in self.counts() == wanted }
        let found = XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: read, object: nil)], timeout: 5)
        XCTAssertEqual(found, .completed, "\(what): \(Self.countNames) read \(counts()), not \(wanted)",
                       file: file, line: line)
    }

    /// Checks the four counts' names sit in one line, in the review's order,
    /// above every line's row.
    func expectCountsAcrossTheTop(above lines: [String], file: StaticString = #filePath, line: UInt = #line) {
        let texts = look(in: review).texts
        let names = Self.countNames.compactMap { countName($0, in: texts) }
        XCTAssertEqual(names.map(\.words), Self.countNames, "not every count shows. The review shows: \(texts.map(\.words))",
                       file: file, line: line)
        guard let first = names.first else { return }
        for name in names {
            XCTAssertLessThan(abs(name.frame.midY - first.frame.midY), 3, "\(name.words) is not in line with \(first.words)",
                              file: file, line: line)
        }
        XCTAssertEqual(names.map(\.frame.minX), names.map(\.frame.minX).sorted(),
                       "the counts are not in the order \(Self.countNames)", file: file, line: line)
        let bottom = names.map(\.frame.maxY).max() ?? 0
        for bank in lines {
            XCTAssertGreaterThan(element(AccessibilityID.importLineStatus(bank)).frame.minY, bottom,
                                 "\(bank)'s row is not below the counts", file: file, line: line)
        }
    }

    /// Checks the review's title, with the file's name beside it, after it.
    func expectTitle(_ title: String, beside name: String, file: StaticString = #filePath, line: UInt = #line) {
        let texts = look(in: review).texts
        guard let heading = texts.first(where: { $0.words == title }) else {
            XCTFail("no title \(title). The review shows: \(texts.map(\.words))", file: file, line: line)
            return
        }
        guard let filename = texts.first(where: { $0.words == name }) else {
            XCTFail("the file's name, \(name), does not show. The review shows: \(texts.map(\.words))", file: file, line: line)
            return
        }
        XCTAssertLessThan(abs(filename.frame.midY - heading.frame.midY), 8, "\(name) is not beside the title",
                          file: file, line: line)
        XCTAssertGreaterThanOrEqual(filename.frame.minX, heading.frame.maxX, "\(name) is not after the title",
                                    file: file, line: line)
    }

    /// Checks the note sits at the review's foot, in line with Cancel and
    /// Import, after it, and below every line's row.
    func expectNoteAtTheFoot(below lines: [String], file: StaticString = #filePath, line: UInt = #line) {
        let texts = look(in: review).texts
        guard let note = texts.first(where: { $0.words == SyncWording.importNote }) else {
            XCTFail("no note saying \(SyncWording.importNote) The review shows: \(texts.map(\.words))", file: file, line: line)
            return
        }
        let buttons = [(AccessibilityID.importCancel, ImportReviewScreen.Words.cancel),
                       (AccessibilityID.importConfirm, ImportReviewScreen.Words.importButton)]
        for (identifier, title) in buttons {
            let button = element(identifier)
            XCTAssertTrue(button.exists, "no \(title)", file: file, line: line)
            XCTAssertTrue([button.title, button.label].contains(title),
                          "\(identifier) says \(button.title) \(button.label), not \(title)", file: file, line: line)
            XCTAssertLessThan(abs(button.frame.midY - note.frame.midY), 8, "\(title) is not beside the note",
                              file: file, line: line)
            XCTAssertGreaterThan(button.frame.minX, note.frame.maxX, "\(title) is not after the note", file: file, line: line)
        }
        for bank in lines {
            XCTAssertLessThan(element(AccessibilityID.importLineStatus(bank)).frame.maxY, note.frame.minY,
                              "the note is not below \(bank)'s row", file: file, line: line)
        }
    }

    /// The words on a line's row of the review: those in line with what it
    /// says will happen to it.
    func texts(onLine bank: String, file: StaticString = #filePath, line: UInt = #line) -> [ShownText] {
        let status = element(AccessibilityID.importLineStatus(bank))
        XCTAssertTrue(status.waitForExistence(timeout: 5), "no row for \(bank). On screen: \(visibleTexts())",
                      file: file, line: line)
        let middle = status.frame.midY
        return look(in: review).texts.filter { abs($0.frame.midY - middle) <= 16 }
    }

    /// Checks each of these words shows on a line's row of the review.
    func expect(line bank: String, shows words: [String], file: StaticString = #filePath, line: UInt = #line) {
        let row = texts(onLine: bank, file: file, line: line)
        for word in words {
            XCTAssertTrue(row.contains { $0.words == word }, "\(word) is not on \(bank)'s row. It shows: \(row.map(\.words))",
                          file: file, line: line)
        }
    }

    /// Checks `lower` shows under `upper` on a line's row of the review.
    func expect(_ lower: String, under upper: String, onLine bank: String,
                file: StaticString = #filePath, line: UInt = #line) {
        expect(lower, under: upper, among: texts(onLine: bank, file: file, line: line), "on \(bank)'s row",
               file: file, line: line)
    }

    /// A line's budget list in the review.
    func budgetList(_ bank: String) -> XCUIElement {
        let identifier = AccessibilityID.importLineBudget(bank)
        let found = element(identifier)
        XCTAssertTrue(found.waitForExistence(timeout: 5), "\(bank) has no budget list. On screen: \(visibleTexts())")
        return [app.popUpButtons[identifier].firstMatch, found.popUpButtons.firstMatch].first { $0.exists } ?? found
    }

    /// Checks a line's budget list shows this choice.
    func expect(list bank: String, shows choice: String, file: StaticString = #filePath, line: UInt = #line) {
        let list = budgetList(bank)
        XCTAssertTrue(wait(for: list, holds: choice, timeout: 5), "\(bank)'s budget list shows \(text(of: list)), not \(choice)",
                      file: file, line: line)
    }

    /// How far a line's date stands out from the review behind it, as a
    /// person sees it, from 0 to 1: the most any point of its picture
    /// differs in brightness from the picture's most common brightness. The
    /// accessibility tree does not say whether a row is faded, but its
    /// picture shows it. A faded row's date stands out less than the same
    /// date did before.
    func contrast(ofDate date: String, onLine bank: String, file: StaticString = #filePath, line: UInt = #line)
        -> Double {
        let status = element(AccessibilityID.importLineStatus(bank))
        XCTAssertTrue(status.waitForExistence(timeout: 5), "no row for \(bank). On screen: \(visibleTexts())",
                      file: file, line: line)
        let dates = review.staticTexts.matching(NSPredicate(format: "value == %@ OR label == %@", date, date))
        guard let shown = dates.allElementsBoundByIndex.first(where: { abs($0.frame.midY - status.frame.midY) <= 16 }),
              let picture = self.picture(of: shown) else {
            XCTFail("no picture of \(bank)'s date, \(date)", file: file, line: line)
            return 0
        }
        let width = picture.width, height = picture.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = pixels.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(picture, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else {
            XCTFail("the picture of \(bank)'s date could not be read", file: file, line: line)
            return 0
        }
        let brightness: [Double] = stride(from: 0, to: pixels.count, by: 4).map { (at: Int) -> Double in
            let red = 0.2126 * Double(pixels[at])
            let green = 0.7152 * Double(pixels[at + 1])
            let blue = 0.0722 * Double(pixels[at + 2])
            return (red + green + blue) / 255
        }
        // The background: the brightness most points have, in steps of 1/64.
        let steps: [Int: [Double]] = Dictionary(grouping: brightness) { (value: Double) -> Int in
            Int((value * 64).rounded())
        }
        let commonest: Int = steps.max { $0.value.count < $1.value.count }?.key ?? 0
        let background: Double = Double(commonest) / 64
        let distances: [Double] = brightness.map { (value: Double) -> Double in abs(value - background) }
        return distances.max() ?? 0
    }

    /// A picture of an element as it shows, cut from a picture of the screen
    /// it is on. A picture of the element itself fails on a screen other than
    /// the main one ("Image creation failed", seen 2026-10-21 with screens
    /// above the main one), though a picture of that whole screen works. Each
    /// screen knows its display, and the display's bounds share the element
    /// frame's points, so the element's frame says where to cut.
    func picture(of element: XCUIElement) -> CGImage? {
        let frame = element.frame
        let middle = CGPoint(x: frame.midX, y: frame.midY)
        let displayID = NSSelectorFromString("displayID")
        for screen in XCUIScreen.screens {
            let display: CGDirectDisplayID
            if screen.responds(to: displayID), let number = screen.value(forKey: "displayID") as? NSNumber {
                display = number.uint32Value
            } else if XCUIScreen.screens.count == 1 {
                display = CGMainDisplayID()
            } else {
                continue
            }
            let bounds = CGDisplayBounds(display)
            guard bounds.contains(middle), bounds.width > 0,
                  let whole = screen.screenshot().image.cgImage(forProposedRect: nil, context: nil, hints: nil)
            else { continue }
            let scale = CGFloat(whole.width) / bounds.width
            let cut = CGRect(x: (frame.minX - bounds.minX) * scale, y: (frame.minY - bounds.minY) * scale,
                             width: frame.width * scale, height: frame.height * scale).integral
            return whole.cropping(to: cut)
        }
        return nil
    }

    // MARK: The budget's list

    /// How many elements carry an entry's row name. Compare counts with each
    /// other, never with a number of rows.
    func entryRows(_ merchant: String) -> Int {
        app.descendants(matching: .any).matching(identifier: AccessibilityID.entryRow(merchant)).count
    }

    /// Waits until the count `entryRows` gives for `merchant` passes `test`.
    func wait(forEntryRows merchant: String, timeout: TimeInterval, until test: @escaping (Int) -> Bool) -> Bool {
        let rows = app.descendants(matching: .any).matching(identifier: AccessibilityID.entryRow(merchant))
        let counted = NSPredicate { _, _ in test(rows.count) }
        return XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: counted, object: nil)], timeout: timeout)
            == .completed
    }

    /// Each row of the open budget's list with this merchant: its Description
    /// cell, and the words in line with it there and in the columns to its
    /// right.
    func entryLines(_ merchant: String) -> [(cell: CGRect, texts: [ShownText])] {
        let seen = look(in: app.windows.firstMatch, for: AccessibilityID.entryRow(merchant))
        return seen.frames.map { (cell: CGRect) -> (cell: CGRect, texts: [ShownText]) in
            let top: CGFloat = cell.minY - 6, bottom: CGFloat = cell.maxY + 6, left: CGFloat = cell.minX - 2
            let inLine: [ShownText] = seen.texts.filter { (text: ShownText) -> Bool in
                text.frame.midY >= top && text.frame.midY <= bottom && text.frame.minX >= left
            }
            return (cell, inLine)
        }
    }

    /// Checks one of this merchant's rows in the open budget's list shows
    /// each of these words.
    func expect(entry merchant: String, shows words: [String], file: StaticString = #filePath, line: UInt = #line) {
        let rows = entryLines(merchant)
        let shown = rows.contains { row in words.allSatisfy { word in row.texts.contains { $0.words == word } } }
        XCTAssertTrue(shown, "no \(merchant) row shows \(words). The rows show: \(rows.map { $0.texts.map(\.words) })",
                      file: file, line: line)
    }

    /// Checks `lower` shows under `upper` in the Description cell of one of
    /// this merchant's rows.
    func expect(_ lower: String, under upper: String, inEntry merchant: String,
                file: StaticString = #filePath, line: UInt = #line) {
        let cells = entryLines(merchant).map { row in
            row.texts.filter { row.cell.contains(CGPoint(x: $0.frame.midX, y: $0.frame.midY)) }
        }
        let cell = cells.first { cell in cell.contains { $0.words == upper } && cell.contains { $0.words == lower } }
        expect(lower, under: upper, among: cell ?? cells.first ?? [], "in \(merchant)'s row", file: file, line: line)
    }

    /// Checks `words` show in the column headed `header`, in one of this
    /// merchant's rows.
    func expect(_ words: String, underColumn header: String, onEntry merchant: String,
                file: StaticString = #filePath, line: UInt = #line) {
        let heading = app.windows.firstMatch.descendants(matching: .any)
            .matching(NSPredicate(format: "label == %@ OR title == %@", header, header)).firstMatch
        XCTAssertTrue(heading.waitForExistence(timeout: 5), "no column headed \(header). On screen: \(visibleTexts())",
                      file: file, line: line)
        let column = heading.frame
        let rows = entryLines(merchant)
        let found = rows.contains { row in
            row.texts.contains { text in
                text.words == words && text.frame.midX >= column.minX && text.frame.midX <= column.maxX
                    && text.frame.midY > column.minY
            }
        }
        XCTAssertTrue(found, "\(words) is not under \(header), at \(column), in a \(merchant) row. The rows show: "
                      + "\(rows.map { $0.texts.map { "\($0.words) at \($0.frame)" } })", file: file, line: line)
    }
}
