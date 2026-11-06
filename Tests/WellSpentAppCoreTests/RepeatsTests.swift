import Foundation
import Testing
@testable import WellSpentAppCore
import WellSpentCrypto
import WellSpentModel
import WellSpentStore

@Suite("Repeat expenses")
@MainActor
struct RepeatsTests {
    private let group: GroupID
    private let budget: BudgetID
    private let model: AppModel


    private static func day(_ year: Int, _ month: Int, _ day: Int) -> Date {
        AppLocale.calendar.date(from: DateComponents(year: year, month: month, day: day, hour: 12))!
    }

    init() throws {
        model = AppModel(store: Store(database: try WellSpentDatabase.inMemory()))
        model.today = { Self.day(2026, 11, 14) }
        group = try #require(model.addGroup(named: "Home"))
        budget = try #require(model.addBudget(named: "Utilities", limit: Money(minorUnits: 60_000), in: group))
    }

    private func bills() throws -> [Transaction] {
        try model.store.transactions(in: budget, period: nil).filter { !$0.isDeleted }.sorted { $0.date < $1.date }
    }

    private func addPhone() {
        model.addRepeatingTransaction(merchant: "Phone", amount: Money(minorUnits: 8_500), date: Self.day(2026, 11, 14),
                                      note: "", budget: budget)
    }

    // Scenario REPEAT-01
    @Test func addingMakesOneBillThisMonth() throws {
        addPhone()
        model.reload()
        #expect(try bills().count == 1, "the typed bill is this month's, so there's no second")
        #expect(try bills()[0].amount.minorUnits == -8_500)
        #expect(try bills()[0].repeatMonth == "2026-11")
    }

    // Scenario REPEAT-02, REPEAT-03
    @Test func eachMonthThatHasComeGetsOneBill() throws {
        addPhone()
        model.today = { Self.day(2027, 1, 20) }
        model.reload()
        model.reload()
        #expect(try bills().map(\.repeatMonth) == ["2026-11", "2026-12", "2027-01"])
    }

    @Test func aMonthWaitsForItsDay() throws {
        addPhone()
        model.today = { Self.day(2026, 12, 13) }
        model.reload()
        #expect(try bills().count == 1)
        model.today = { Self.day(2026, 12, 14) }
        model.reload()
        #expect(try bills().count == 2)
    }

    // Scenario REPEAT-04
    @Test func aShortMonthUsesItsLastDay() {
        let rule = RepeatRule(groupID: group, budgetID: budget, name: "Rent", amount: Money(minorUnits: -1), day: 31,
                              firstMonth: "2026-10")
        #expect(rule.dayOfMonth("2026-11") == 30)
        #expect(rule.dayOfMonth("2027-02") == 28)
        #expect(rule.dayOfMonth("2026-12") == 31)
    }

    // Scenario REPEAT-06
    @Test func thisMonthOnlyLeavesLaterMonths() throws {
        addPhone()
        model.today = { Self.day(2026, 12, 14) }
        model.reload()
        let december = try bills()[1]
        model.updateMadeEntry(december.id, EntryChange(amount: Money(minorUnits: 9_200)), reach: .thisMonthOnly)
        model.today = { Self.day(2027, 1, 14) }
        model.reload()
        #expect(try bills().map(\.amount.minorUnits) == [-8_500, -9_200, -8_500])
    }

    // Scenario REPEAT-07
    @Test func thisMonthAndLaterChangesTheRuleFromThere() throws {
        addPhone()
        model.today = { Self.day(2026, 12, 14) }
        model.reload()
        let december = try bills()[1]
        model.updateMadeEntry(december.id, EntryChange(amount: Money(minorUnits: 9_200)), reach: .thisMonthAndLater)
        model.today = { Self.day(2027, 1, 14) }
        model.reload()
        #expect(try bills().map(\.amount.minorUnits) == [-8_500, -9_200, -9_200])
    }

    // Scenario REPEAT-08, REPEAT-10
    @Test func stoppingMakesNoLaterMonthAndUndoCarriesOn() throws {
        addPhone()
        let rule = try #require(model.repeats(in: budget, group: group).first)
        model.stopRepeating(rule.id)
        model.today = { Self.day(2026, 12, 14) }
        model.reload()
        #expect(try bills().count == 1, "months already made stay")
        #expect(model.undoOffer?.stoppedRule == rule.id)
        model.undoDelete()
        model.reload()
        #expect(try bills().count == 2, "it carries on")
    }

    // Scenario REPEAT-09, REPEAT-10
    @Test func deleteAndStopBringsBothBackOnUndo() throws {
        addPhone()
        model.today = { Self.day(2026, 12, 14) }
        model.reload()
        let december = try bills()[1]
        model.deleteAndStopRepeating(december.id)
        model.today = { Self.day(2027, 1, 14) }
        model.reload()
        #expect(try bills().count == 1, "this month goes, no later month is made, and earlier ones stay")
        model.undoDelete()
        model.reload()
        #expect(try bills().map(\.repeatMonth) == ["2026-11", "2026-12", "2027-01"])
    }

    @Test func deletingThisMonthOnlyDoesntComeBack() throws {
        addPhone()
        model.today = { Self.day(2026, 12, 14) }
        model.reload()
        model.deleteEntry(try bills()[1].id)
        model.today = { Self.day(2027, 1, 14) }
        model.reload()
        #expect(try bills().map(\.repeatMonth) == ["2026-11", "2027-01"])
    }

    // Scenario REPEAT-11
    @Test func onlyTheOwnerOrAManagerChangesTheRule() throws {
        let owner = UserID()
        model.me = { owner }
        addPhone()
        let rule = try #require(model.repeats(in: budget, group: group).first)
        #expect(model.mayChangeRule(rule))
        model.me = { UserID() }
        model.mayManageEntries = { _ in false }
        #expect(!model.mayChangeRule(rule))
        let opened = try #require(RepeatEditor(model: model, rule: rule.id))
        #expect(!opened.mayChange && !opened.canSave)
        #expect(opened.readOnlyLine?.contains("or a manager") == true)
        let entry = try #require(EntryEditor(model: model, entry: try bills()[0].id))
        #expect(!entry.showsWhichMonths && !entry.offersStopRepeating)
        model.mayManageEntries = { _ in true }
        #expect(model.mayChangeRule(rule))
    }

    /// A rule with no owner, as one from before the server stamped it, is made
    /// by nobody signed in: a member's device would make, be refused and drop
    /// the bill, over and over. Signed out, a person's own repeats have no owner
    /// yet, and still come.
    @Test func aRuleWithNoOwnerIsMadeOnlySignedOut() throws {
        model.me = { nil }
        addPhone()
        let rule = try #require(model.repeats(in: budget, group: group).first)
        #expect(rule.createdBy == nil)
        let countNow = try bills().count

        model.me = { UserID() }
        model.today = { Self.day(2026, 12, 20) }
        #expect(!model.makeDueRepeats(), "signed in, a rule with no owner is not this device's to make")
        #expect(try bills().count == countNow)

        model.me = { nil }
        #expect(model.makeDueRepeats(), "signed out, it is this person's own")
        #expect(try bills().count == countNow + 1)
    }

    @Test func aDeviceThatIsntTheOwnersMakesNothing() throws {
        let owner = UserID()
        model.me = { owner }
        addPhone()
        model.me = { UserID() }
        model.today = { Self.day(2026, 12, 14) }
        model.reload()
        #expect(try bills().count == 1)
    }

    // Scenario REPEAT-12
    @Test func theListSaysHowManyAndOpensEach() throws {
        let screen = model.summaries[group]?.first?.budget
        let empty = RepeatsList(budget: try #require(screen), model: model)
        #expect(empty.countWords == nil)
        addPhone()
        let list = RepeatsList(budget: try #require(screen), model: model)
        #expect(list.title == "Repeats in Utilities")
        #expect(list.countWords == "1 repeat")
        #expect(list.rows.map(\.line) == ["The 14th of each month"])
        let editor = try #require(RepeatEditor(model: model, rule: list.rows[0].id))
        editor.amountText = "92.00"
        #expect(editor.save())
        model.today = { Self.day(2026, 12, 14) }
        model.reload()
        #expect(try bills().last?.amount.minorUnits == -9_200)
    }

    // Scenario REPEAT-13
    @Test func moneyInHasNoRepeatRow() throws {
        model.selectedBudget = budget
        let editor = EntryEditor(model: model)
        #expect(editor.showsRepeatRow)
        editor.isMoneyIn = true
        #expect(!editor.showsRepeatRow)
    }

    // Scenario REPEAT-16
    @Test func aHousesRepeatMarksEachBill() throws {
        let house = RecordID()
        model.addRepeatingTransaction(merchant: "Power", amount: Money(minorUnits: 100), date: Self.day(2026, 11, 3), note: "",
                                      budget: budget, link: house)
        model.today = { Self.day(2026, 12, 14) }
        model.reload()
        #expect(try bills().allSatisfy { $0.extensionLink == house })
    }

    @Test func theSheetAndDeleteQuestionUseTheDesignsWords() throws {
        addPhone()
        let made = try bills()[0]
        let editor = try #require(EntryEditor(model: model, entry: made.id))
        #expect(editor.showsWhichMonths && !editor.showsRepeatRow)
        editor.amountText = "92.00"
        #expect(editor.whichMonthsLine(.thisMonthOnly)?.hasPrefix("November is $92.00. December goes back to $85.00") == true,
                "\(String(describing: editor.whichMonthsLine(.thisMonthOnly)))")
        #expect(editor.whichMonthsLine(.thisMonthAndLater)?.hasPrefix("November and every month after are $92.00") == true)
        #expect(editor.topLine?.contains("Repeat") == true)
        let question = try #require(model.deleteQuestion(for: made.id))
        #expect(question.title == "Delete November's Phone?", "\(question.title)")
        #expect(question.confirmLabel == "Delete This Month Only")
        #expect(question.offersStop(model: model))
    }

    @Test func turningTheRowOnForAnOldEntryStartsNextMonth() throws {
        model.addTransaction(merchant: "Gym", amount: Money(minorUnits: 3_000), date: Self.day(2026, 11, 2), note: "", budget: budget)
        let editor = try #require(EntryEditor(model: model, entry: try bills()[0].id))
        editor.repeats = true
        #expect(editor.repeatLine == "Shows up on the 2nd of each month. You can change any month.")
        #expect(editor.save())
        model.today = { Self.day(2026, 12, 2) }
        model.reload()
        #expect(try bills().count == 2)
        #expect(try bills()[0].repeatRuleID == nil)
    }
}
