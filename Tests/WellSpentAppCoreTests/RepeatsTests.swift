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
        #expect(editor.showsWhichMonths && editor.showsRepeatRow && editor.repeats)
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

    /// An entry already there, with what a person sees on it.
    private func aWaterBill(on date: Date? = nil) throws -> Transaction {
        let me = UserID()
        model.me = { me }
        model.addTransaction(merchant: "Water", amount: Money(minorUnits: 4_000), date: date ?? Self.day(2026, 11, 5),
                             note: "Meter 12", budget: budget, link: RecordID())
        return try #require(try bills().first { $0.merchant == "Water" })
    }

    private func turnOn(_ id: RecordID) throws {
        let editor = try #require(EntryEditor(model: model, entry: id))
        #expect(!editor.repeats)
        #expect(editor.showsRepeatRow)
        editor.repeats = true
        #expect(editor.save())
    }

    private func water() throws -> [Transaction] { try bills().filter { $0.merchant == "Water" } }

    // Scenario REPEAT-17
    @Test func turningItOnMakesTheEntryTheRulesFirstBill() throws {
        let entry = try aWaterBill()
        try turnOn(entry.id)
        model.reload()

        let bill = try #require(try water().first)
        #expect(try water().count == 1, "one bill this month")
        #expect(bill.idIsRight)
        #expect(bill.repeatMonth == "2026-11")
        #expect(bill.date == entry.date && bill.note == entry.note && bill.createdBy == entry.createdBy)
        #expect(bill.createdAt == entry.createdAt && bill.extensionLink == entry.extensionLink && bill.amount == entry.amount)
        #expect(try model.store.transaction(entry.id)?.isDeleted == true, "the old row is gone")

        let reopened = try #require(EntryEditor(model: model, entry: bill.id))
        #expect(reopened.showsRepeatRow && reopened.repeats && reopened.repeatRowIsEnabled, "it reads as on")
        #expect(model.repeats(in: budget, group: group).count == 1, "the count line finds it")
        let open = try #require(model.summaries.values.flatMap { $0 }.first { $0.budget.id == budget })
        let row = try #require(BudgetScreen(summary: open, model: model, me: model.me()).rows.first { $0.merchant == "Water" })
        #expect(row.source == BudgetScreen.Words.repeatSource)
    }

    // Scenario REPEAT-17
    @Test func nothingIsMadeTwice() throws {
        let entry = try aWaterBill()
        try turnOn(entry.id)
        model.makeDueRepeats()
        #expect(try water().count == 1, "this month keeps one bill")

        model.today = { Self.day(2026, 12, 14) }
        model.makeDueRepeats()
        #expect(try water().map(\.repeatMonth) == ["2026-11", "2026-12"], "next month makes one")
        #expect(try model.store.repeatRules(in: group).count == 1)
    }

    /// A build before this left the entry as it was and started the rule next
    /// month. Turned on again, that rule is used, not a second one.
    @Test func aRuleFromAnEarlierBuildIsUsedAgain() throws {
        let entry = try aWaterBill()
        let old = RepeatRule(groupID: group, budgetID: budget, name: "Water", amount: Money(minorUnits: -4_000), day: 5,
                             extensionLink: entry.extensionLink, firstMonth: "2026-12", createdBy: model.me())
        try model.store.save(old)
        try turnOn(entry.id)

        let rules = try model.store.repeatRules(in: group)
        #expect(rules.map(\.id) == [old.id])
        #expect(rules.first?.firstMonth == "2026-11")
        #expect(try water().first?.repeatRuleID == old.id)
        model.today = { Self.day(2026, 12, 14) }
        model.makeDueRepeats()
        #expect(try water().map(\.repeatMonth) == ["2026-11", "2026-12"])
    }

    /// Two same-day bills of one name at different amounts are two bills.
    @Test func aRuleAtAnotherAmountStaysSeparate() throws {
        let entry = try aWaterBill()
        let other = RepeatRule(groupID: group, budgetID: budget, name: "Water", amount: Money(minorUnits: -9_900), day: 5,
                               firstMonth: "2026-12", createdBy: model.me())
        try model.store.save(other)
        try turnOn(entry.id)

        let rules = try model.store.repeatRules(in: group)
        #expect(rules.count == 2)
        #expect(rules.first { $0.id == other.id }?.firstMonth == "2026-12", "that rule isn't touched")
    }

    /// A line from a statement stays imported, so the same file doesn't add it again.
    @Test func aStatementLineStaysImportedAfterTurningOn() throws {
        var entry = try aWaterBill()
        entry.importFingerprint = "line-1"
        try model.store.save(entry)
        try turnOn(entry.id)
        #expect(try model.store.existingFingerprints(["line-1"], in: group) == ["line-1"])
    }

    private func giveIt(_ entry: Transaction, _ owner: UserID) throws {
        var owned = entry
        owned.createdBy = owner
        try model.store.save(owned)
    }

    @Test func someoneWhoMayNotChangeTheEntryCannotTurnItOn() throws {
        let entry = try aWaterBill()
        try giveIt(entry, UserID())
        model.mayManageEntries = { _ in false }
        model.startRepeating(from: entry.id)
        #expect(try model.store.repeatRules(in: group).isEmpty)
        #expect(try model.store.transaction(entry.id)?.isDeleted == false)
    }

    private func reopen(_ id: RecordID) throws -> EntryEditor { try #require(EntryEditor(model: model, entry: id)) }

    /// Turned on, off and on again, it's one repeat all the way through.
    @Test func theSwitchTellsTheTruthAndThereIsOneRepeat() throws {
        let entry = try aWaterBill()
        try turnOn(entry.id)
        let id = try #require(try water().first?.id)
        #expect(try reopen(id).repeats, "reads on")
        #expect(try !reopen(id).canSave, "nothing changed yet")

        let off = try reopen(id)
        off.repeats = false
        #expect(off.canSave)
        #expect(off.save())
        #expect(try !reopen(id).repeats, "reads off")
        #expect(model.repeats(in: budget, group: group).isEmpty, "it leaves the count")
        #expect(try water().map(\.id) == [id], "the bill stays")

        let on = try reopen(id)
        on.repeats = true
        #expect(on.save())
        #expect(try reopen(id).repeats, "reads on again")
        #expect(try model.store.repeatRules(in: group).count == 1, "the same repeat")
        #expect(model.repeats(in: budget, group: group).count == 1)
    }

    /// Every bill a repeat made opens with the switch on, in any month.
    @Test func everyMadeBillOpensOn() throws {
        addPhone()
        model.today = { Self.day(2026, 12, 14) }
        model.makeDueRepeats()
        for bill in try bills() { #expect(try reopen(bill.id).repeats) }
    }

    /// Stopped in November, started again in February: December and January
    /// aren't made after the fact, and February is.
    @Test func startingAgainDoesNotMakeTheMonthsItWasStopped() throws {
        addPhone()
        let id = try #require(try bills().first?.id)
        let off = try reopen(id)
        off.repeats = false
        #expect(off.save())

        model.today = { Self.day(2027, 2, 14) }
        model.makeDueRepeats()
        #expect(try bills().count == 1, "stopped, so nothing is made")
        let on = try reopen(id)
        on.repeats = true
        #expect(on.save())
        model.makeDueRepeats()
        #expect(try bills().map(\.repeatMonth) == ["2026-11", "2027-02"])
    }

    /// Stopping leaves a bill already made for a later month where it is.
    @Test func stoppingLeavesALaterBill() throws {
        model.addRepeatingTransaction(merchant: "Phone", amount: Money(minorUnits: 8_500), date: Self.day(2026, 12, 14),
                                      note: "", budget: budget)
        let rule = try #require(try model.store.repeatRules(in: group).first)
        model.stopRepeating(rule.id)
        #expect(try bills().map(\.repeatMonth) == ["2026-12"])
    }

    /// A repeat's bill made by its owner, read by someone else.
    private func aBillMadeBySomeoneElse(owner: UserID) throws -> RecordID {
        model.me = { owner }
        addPhone()
        let id = try #require(try bills().first?.id)
        try giveIt(try #require(try model.store.transaction(id)), owner)
        return id
    }

    private func repeatDetail(_ editor: EntryEditor) -> String? {
        editor.details.first { $0.label == EntryEditor.Words.repeatsRow }?.value
    }

    // Scenario REPEAT-18
    /// May not change the bill: a read-only sheet says so in a plain row.
    @Test func aReadOnlySheetSaysTheBillRepeatsInAPlainRow() throws {
        let id = try aBillMadeBySomeoneElse(owner: UserID())
        model.me = { UserID() }
        model.mayManageEntries = { _ in false }
        let editor = try reopen(id)
        #expect(editor.isReadOnly)
        #expect(repeatDetail(editor) == "On")
        #expect(!editor.showsRepeatRow, "no switch on a read-only sheet")

        model.mayManageEntries = { _ in true }
        model.stopRepeating(try #require(try model.store.repeatRules(in: group).first).id)
        model.mayManageEntries = { _ in false }
        #expect(repeatDetail(try reopen(id)) == "Off")
    }

    /// An entry that isn't a repeat's bill has no such row.
    @Test func aPlainEntryHasNoRepeatRowInItsDetails() throws {
        let entry = try aWaterBill()
        #expect(repeatDetail(try reopen(entry.id)) == nil)
    }

    // Scenario REPEAT-11
    /// May change the bill, not the repeat: the switch is on and dimmed.
    @Test func someoneWhoMayChangeTheBillButNotTheRepeatSeesItDimmed() throws {
        let id = try aBillMadeBySomeoneElse(owner: UserID())
        let me = UserID()
        model.me = { me }
        try giveIt(try #require(try model.store.transaction(id)), me)
        model.mayManageEntries = { _ in false }
        let editor = try reopen(id)
        #expect(!editor.isReadOnly)
        #expect(editor.showsRepeatRow && editor.repeats && !editor.repeatRowIsEnabled)
    }
}
