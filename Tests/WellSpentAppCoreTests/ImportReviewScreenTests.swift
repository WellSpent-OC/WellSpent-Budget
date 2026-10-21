import Foundation
import Testing
#if canImport(UniformTypeIdentifiers)
import UniformTypeIdentifiers
#endif
// Not @testable: these check only what every app's screens can reach.
import WellSpentAppCore
import WellSpentCrypto
import WellSpentImport
import WellSpentModel
import WellSpentStore

/// The import review's parts that live in shared code: the colours the Mac
/// and the iPhone draw, the words beside them, the line a phone shows, and
/// what the file picker hands back.
@Suite("Import review, shared by every app", .serialized)
@MainActor
struct ImportReviewScreenTests {
    private typealias Words = ImportReviewScreen.Words

    /// Household, with Groceries, and Groceries open.
    @MainActor
    private struct Household {
        let model: AppModel
        let groceries: BudgetID

        init() throws {
            model = AppModel(store: Store(database: try WellSpentDatabase.inMemory()))
            let group = try #require(model.addGroup(named: "Household"))
            groceries = try #require(model.addBudget(named: "Groceries", limit: .dollars(500), in: group))
            model.selectedBudget = groceries
        }
    }

    /// A statement file of its own, removed by the caller.
    private func statement(_ lines: String, named name: String = "statement.csv") throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("wellspent-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent(name)
        try "Date,Description,Amount\n\(lines)".write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func remove(_ url: URL) {
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
    }

    // MARK: - Colours, and the words beside them

    @Test func eachToneHasItsOwnColourFromThePalette() {
        #expect(ImportReviewScreen.Tone.matched.color == PaletteValues.accent)
        #expect(ImportReviewScreen.Tone.toAdd.color == PaletteValues.blue)
        #expect(ImportReviewScreen.Tone.alreadyImported.color == PaletteValues.muted)
        #expect(ImportReviewScreen.Tone.needsBudget.color == PaletteValues.warning)
    }

    /// Colour is never the only sign: every count has its own label, every
    /// status its own words, and two lines of different colours never say
    /// the same thing.
    @Test func eachCountAndEachStatusIsItsOwnWords() throws {
        #expect(Set([Words.matched, Words.toAdd, Words.alreadyImported, Words.needsBudget]).count == 4)
        #expect(Set([Words.matchedReceipt, Words.matchedEntry, Words.willBeAdded, Words.alreadyImported,
                     Words.needsBudget]).count == 5)

        // A statement with a line of each kind: one typed by hand already,
        // one from a merchant filed before, one new, then one imported before.
        let home = try Household()
        home.model.addTransaction(merchant: "Costco", amount: .dollars(-286.31), date: Date(), note: "")
        home.model.addTransaction(merchant: "Hilltop Grocery", amount: .dollars(-42), date: Date(), note: "")
        let today = Self.statementDate(Date())
        let first = try statement("\(today),\"TRADER JOES #123\",-54.20")
        defer { remove(first) }
        let screen = ImportReviewScreen(model: home.model)
        screen.open(.success([first]))
        screen.choose(home.groceries, for: 0)
        screen.commit()

        let url = try statement("""
        \(today),"COSTCO WHSE #0472",-286.31
        \(today),"HILLTOP GROCERY #17",-58.10
        \(today),"CORNER BAKERY",-12.00
        \(today),"TRADER JOES #123",-54.20
        """)
        defer { remove(url) }
        screen.open(.success([url]))
        #expect(screen.rows.map(\.tone) == [.matched, .toAdd, .needsBudget, .alreadyImported])
        #expect(screen.tiles.map(\.tone) == [.matched, .toAdd, .alreadyImported, .needsBudget])
        var wordsByTone: [ImportReviewScreen.Tone: Set<String>] = [:]
        for row in screen.rows { wordsByTone[row.tone, default: []].insert(row.status) }
        let allWords = wordsByTone.values.flatMap { $0 }
        #expect(Set(allWords).count == allWords.count, "two colours share words: \(wordsByTone)")
        screen.cancel()
    }

    // MARK: - The line a phone shows

    @Test func aPhonesLineGivesTheShortDateThenTheCleanedUpName() throws {
        let home = try Household()
        let url = try statement("10/02/2026,\"TRADER JOES #123\",-54.20")
        defer { remove(url) }
        let screen = ImportReviewScreen(model: home.model)
        screen.open(.success([url]))

        let row = try #require(screen.rows.first)
        // Built from the same short date the budget's own rows use, so the
        // test holds in any language or region.
        #expect(row.dateAndName == "\(BudgetScreen.shortDate(row.date)) · Trader Joes")
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
        let day = utc.dateComponents([.year, .month, .day], from: row.date)
        #expect([day.year, day.month, day.day] == [2026, 10, 2])
        #expect(row.bankDescription == "TRADER JOES #123")
        #expect(row.amount == "-$54.20")
        screen.cancel()
    }

    // MARK: - What the file picker hands back

    @Test func aPickedFileOpensItsReview() throws {
        let home = try Household()
        let url = try statement("10/02/2026,\"TRADER JOES #123\",-54.20")
        defer { remove(url) }
        let screen = ImportReviewScreen(model: home.model)

        screen.open(.success([url]))
        #expect(screen.isOpen)
        #expect(screen.filename == "statement.csv")
        #expect(screen.title == Words.title(into: "Household"))
        #expect(home.model.errorMessage == nil)
        screen.cancel()
        #expect(!screen.isOpen)
    }

    @Test func onlyTheFirstOfSeveralFilesIsRead() throws {
        let home = try Household()
        let first = try statement("10/02/2026,\"TRADER JOES #123\",-54.20", named: "first.csv")
        let second = try statement("10/03/2026,\"CORNER BAKERY\",-12.00", named: "second.csv")
        defer { remove(first); remove(second) }
        let screen = ImportReviewScreen(model: home.model)

        screen.open(.success([first, second]))
        #expect(screen.filename == "first.csv")
        #expect(screen.rows.map(\.bankDescription) == ["TRADER JOES #123"])
        screen.cancel()
    }

    @Test func nothingPickedDoesNothing() throws {
        let home = try Household()
        let screen = ImportReviewScreen(model: home.model)

        screen.open(.success([]))
        #expect(!screen.isOpen)
        #expect(home.model.errorMessage == nil)
    }

    @Test func aPickerThatFailedSaysWhyAndOpensNoReview() throws {
        let home = try Household()
        let screen = ImportReviewScreen(model: home.model)
        let failure = CocoaError(.fileReadNoPermission)

        screen.open(.failure(failure))
        #expect(!screen.isOpen)
        #expect(home.model.errorMessage == failure.localizedDescription)
    }

    @Test func aPickedFileThatIsNotAStatementIsExplainedInWords() throws {
        let home = try Household()
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("wellspent-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("notes.txt")
        try "just some words".write(to: url, atomically: true, encoding: .utf8)
        let screen = ImportReviewScreen(model: home.model)

        screen.open(.success([url]))
        #expect(!screen.isOpen)
        #expect(home.model.errorMessage == ImportWording.words(for: ImportError.unrecognisedFormat, file: "notes.txt"))
    }

    // MARK: - The files the picker offers

    #if canImport(UniformTypeIdentifiers)
    @Test func thePickerOffersCSVTextAndEveryOtherFile() throws {
        #expect(ImportReviewScreen.fileTypes == [.commaSeparatedText, .plainText, .data])
        // OFX and QFX have no type of their own everywhere, so they are
        // picked as any other file.
        for name in ["csv", "txt", "ofx", "qfx"] {
            let type = try #require(UTType(filenameExtension: name), "no type for .\(name)")
            #expect(ImportReviewScreen.fileTypes.contains { type.conforms(to: $0) }, ".\(name) cannot be picked")
        }
    }
    #endif

    // MARK: - The names UI tests find the review's parts by

    #if canImport(SwiftUI)
    /// A line's row, its status and its budget list each have a name of their
    /// own, and every name in the review starts with "import.", so a test can
    /// tell a line's list from an option of the same name in the list it opens.
    @Test func eachPartOfTheReviewHasANameOfItsOwn() {
        let bank = "TRADER JOES #123"
        let names = [AccessibilityID.importLine(bank), AccessibilityID.importLineStatus(bank),
                     AccessibilityID.importLineBudget(bank), AccessibilityID.importCount(Words.toAdd),
                     AccessibilityID.importConfirm, AccessibilityID.importCancel]
        #expect(Set(names).count == names.count)
        #expect(names.allSatisfy { $0.hasPrefix("import.") }, "\(names)")
        #expect(AccessibilityID.importLine(bank) != AccessibilityID.importLine("CORNER BAKERY"))
        #expect(AccessibilityID.importCount(Words.toAdd) != AccessibilityID.importCount(Words.needsBudget))
    }
    #endif

    // MARK: - The statement a UI test hands a staging build

    @Test func onlyAStagingBuildReadsTheStatementATestNames() {
        let named = [UITestStatement.variable: "/tmp/statement.csv"]
        #expect(UITestStatement.requested(in: named, environment: .staging) == URL(fileURLWithPath: "/tmp/statement.csv"))
        #expect(UITestStatement.requested(in: named, environment: .live) == nil, "never a live build")
        #expect(UITestStatement.requested(in: [UITestStatement.variable: ""], environment: .staging) == nil)
        #expect(UITestStatement.requested(in: [:], environment: .staging) == nil)
        // The iPhone's UI tests set it by name.
        #expect(UITestStatement.variable == "WELLSPENT_UI_TEST_STATEMENT")
    }

    /// A statement's date, as a bank writes it.
    private static func statementDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "MM/dd/yyyy"
        return formatter.string(from: date)
    }
}
