// SwiftUI and ViewInspector exist only on Apple systems.
#if canImport(SwiftUI) && os(macOS)
import Testing
import Foundation
import SwiftUI
import ViewInspector
@testable import WellSpentAppCore
import WellSpentCrypto
import WellSpentModel
import WellSpentStore

/// The repeats on the Mac, drawn: the list, a repeat's sheet, and the rows on
/// the entry sheet.
@Suite("Repeats, drawn")
@MainActor
struct RepeatViewsTests {
    private let model: AppModel
    private let group: GroupID
    private let budget: BudgetID
    private let owner = UserID()

    private static func day(_ year: Int, _ month: Int, _ day: Int) -> Date {
        AppLocale.calendar.date(from: DateComponents(year: year, month: month, day: day, hour: 12))!
    }

    init() throws {
        model = AppModel(store: Store(database: try WellSpentDatabase.inMemory()), undoWindow: .seconds(3600))
        model.today = { Self.day(2026, 11, 14) }
        let me = owner
        model.me = { me }
        group = try #require(model.addGroup(named: "Home"))
        budget = try #require(model.addBudget(named: "Utilities", limit: Money(minorUnits: 60_000), in: group))
        model.selectedBudget = budget
        model.addRepeatingTransaction(merchant: "Phone", amount: Money(minorUnits: 8_500), date: Self.day(2026, 11, 14),
                                      note: "", budget: budget)
        model.reload()
    }

    private func texts<V: View>(_ view: V) throws -> [String] {
        try view.inspect().findAll(ViewType.Text.self).compactMap { try? $0.string() }
    }

    private func buttons<V: View>(_ view: V) throws -> [String] {
        try view.inspect().findAll(ViewType.Button.self).compactMap { try? $0.labelView().text().string() }
    }

    private var rule: RepeatRule { model.repeats(in: budget, group: group)[0] }

    // Scenario REPEAT-12
    @Test func theListShowsEachRepeat() throws {
        let sheet = RepeatsListSheet(budget: try #require(try model.store.budget(budget)), model: model)
        let words = try texts(sheet)
        #expect(words.contains("Repeats in Utilities"))
        #expect(words.contains("Phone"))
        #expect(words.contains("The 14th of each month"))
        #expect(words.contains("$85.00"))
    }

    @Test func aRepeatsSheetChangesLaterMonthsOrStops() throws {
        let sheet = RepeatRuleSheet(editor: try #require(RepeatEditor(model: model, rule: rule.id)))
        let words = try texts(sheet)
        #expect(words.contains(RepeatEditor.Words.note))
        #expect(words.contains("Repeats every month"))
        let labels = try buttons(sheet)
        #expect(labels.contains(RepeatEditor.Words.stop))
        #expect(labels.contains("Save"))
        #expect(labels.contains("Cancel"))
    }

    // Scenario REPEAT-11
    @Test func someoneElseOnlyReadsIt() throws {
        model.me = { UserID() }
        model.mayManageEntries = { _ in false }
        let sheet = RepeatRuleSheet(editor: try #require(RepeatEditor(model: model, rule: rule.id)))
        #expect(try buttons(sheet) == ["Close"])
        #expect(try texts(sheet).contains { $0.hasSuffix("or a manager can change this repeat.") })
    }

    // Scenario REPEAT-01
    @Test func addingOffersTheRowAndSaysTheDay() throws {
        let editor = EntryEditor(model: model, date: Self.day(2026, 11, 14))
        editor.repeats = true
        #expect(try texts(EntrySheet(editor: editor)).contains("Shows up on the 14th of each month. You can change any month."))
    }

    // Scenario REPEAT-06, REPEAT-07
    @Test func aMadeBillOffersWhichMonthsAndStop() throws {
        let made = try #require(try model.store.transactions(in: budget, period: nil).first)
        let editor = try #require(EntryEditor(model: model, entry: made.id))
        editor.amountText = "92.00"
        let sheet = EntrySheet(editor: editor)
        #expect(try texts(sheet).contains("November is $92.00. December goes back to $85.00."))
        #expect(try buttons(sheet).contains(RepeatEditor.Words.stop))
        let id = rule.id
        editor.stopRepeating()
        #expect(model.undoOffer?.stoppedRule == id)
    }

    @Test func aRuleEditorRefusesWhatIsntADay() throws {
        let editor = try #require(RepeatEditor(model: model, rule: rule.id))
        #expect(!editor.canSave, "nothing changed")
        editor.dayText = "32"
        #expect(!editor.canSave)
        editor.dayText = "20"
        #expect(editor.canSave)
        #expect(editor.save())
        #expect(rule.terms(in: "2026-11").day == 20)
        editor.stop()
        #expect(try #require(try model.store.repeatRule(editor.ruleID)).stopMonth == "2026-12")
    }

    @Test func aBudgetSaysHowManyRepeats() throws {
        let summary = try #require(model.summaries[group]?.first)
        #expect(BudgetScreen(summary: summary, model: model, me: owner).repeatsWords == "1 repeat")
    }

    // Scenario REPEAT-08
    @Test func aStoppedRepeatLeavesTheCountAtOnceAndUndoBringsItBack() throws {
        let id = rule.id
        let made = try #require(try model.store.transactions(in: budget, period: nil).first)
        let editor = try #require(EntryEditor(model: model, entry: made.id))
        editor.stopRepeating()
        model.reload()
        #expect(model.repeats(in: budget, group: group).isEmpty)
        let summary = try #require(model.summaries[group]?.first)
        #expect(BudgetScreen(summary: summary, model: model, me: owner).repeatsWords == nil)
        #expect(try model.store.transactions(in: budget, period: nil).contains { $0.id == made.id },
                "this month's bill stays")
        #expect(model.undoOffer?.stoppedRule == id)
        model.undoDelete()
        model.reload()
        #expect(model.repeats(in: budget, group: group).map(\.id) == [id])
    }

    @Test func wordsForEveryDay() {
        #expect(["1st", "2nd", "3rd", "4th", "11th", "12th", "13th", "21st", "22nd", "23rd", "31st"]
            == [1, 2, 3, 4, 11, 12, 13, 21, 22, 23, 31].map(RepeatsList.Words.ordinal))
    }
}
#endif
