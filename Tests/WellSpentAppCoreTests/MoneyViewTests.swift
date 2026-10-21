// SwiftUI and ViewInspector exist only on Apple systems.
#if canImport(SwiftUI)
import Testing
import Foundation
import SwiftUI
import ViewInspector
@testable import WellSpentAppCore
import WellSpentCrypto
import WellSpentKeyStore
import WellSpentModel
import WellSpentStore
import WellSpentSync

/// The money wheel's desktop screens, drawn: a budget's row in the sidebar,
/// the wheel, figures and pace words at the top of a budget's page, and the
/// MONEY section of a group's page. The dates are fixed, in Denver.
@Suite("Money wheel views", .serialized)
@MainActor
struct MoneyViewTests {
    private let calendar = WheelCalendar.calendar
    private let october18 = WheelCalendar.date(2026, 10, 18)

    private func texts(_ view: some View) throws -> [String] {
        try view.inspect().findAll(ViewType.Text.self).map { try $0.string() }
    }

    private func emptyModel() throws -> AppModel {
        AppModel(store: Store(database: try WellSpentDatabase.inMemory()))
    }

    /// The top of the page for `name`, `limit` a month with `spent` spent, on
    /// the given day of October 2026. Cents.
    private func panel(_ name: String = "Groceries", limit: Int, spent: Int, october day: Int,
                       model: AppModel? = nil, editBudget: @escaping () -> Void = {}) throws -> BudgetWheelPanel {
        let model = try model ?? emptyModel()
        let now = WheelCalendar.date(2026, 10, day)
        let summary = WheelCalendar.summary(name, limit: limit, spent: spent, on: now)
        let screen = BudgetScreen(summary: summary, model: model, me: nil, now: now, calendar: calendar)
        return BudgetWheelPanel(screen: screen, editBudget: editBudget)
    }

    // MARK: - A budget's row

    // Scenario WHEEL-01
    /// The row draws the fill RowFill gives, and says what is left on top.
    @Test func aRowFillsAsFarAsItsMoneyIsUsedAndSaysWhatIsLeft() throws {
        let summary = WheelCalendar.summary(limit: 50_000, spent: 12_500, on: october18)
        let row = BudgetRow(summary: summary)
        #expect(try texts(row) == ["Groceries", "$375.00"])
        let fill = try row.inspect().find(RowFillBackground.self).actualView().fill
        #expect(fill == RowFill(summary))
        #expect(fill.share == 0.25)
    }

    // Scenario WHEEL-02
    @Test func anOverRowFillsAllTheWayAndSaysHowFarOver() throws {
        let summary = WheelCalendar.summary(limit: 10_000, spent: 11_500, on: october18)
        let row = BudgetRow(summary: summary)
        #expect(try texts(row) == ["Groceries", "$15.00 over"])
        let fill = try row.inspect().find(RowFillBackground.self).actualView().fill
        #expect(fill.isOver && fill.share == 1)
    }

    // Scenario WHEEL-03
    /// A click on a row opens its budget, and only the open budget's row is
    /// outlined. While a group's page shows, none is.
    @Test func theOutlineMarksTheOpenBudgetsRowOnly() throws {
        let model = try emptyModel()
        let household = try #require(model.addGroup(named: "Household"))
        let groceries = try #require(model.addBudget(named: "Groceries", limit: .dollars(500), in: household))
        let eatingOut = try #require(model.addBudget(named: "Eating out", limit: .dollars(200), in: household))
        let sync = SyncCoordinator(store: model.store, keyStore: InMemoryKeyStore(), defaults: isolatedDefaults())
        let screen = MainScreen(workspace: Workspace(model: model, sync: sync))
        let sidebar = SidebarView(screen: screen, editor: .constant(nil), showingAccount: .constant(false))
        func row(_ name: String) throws -> InspectableView<ViewType.Button> {
            try sidebar.inspect().find(ViewType.Button.self, where: {
                try $0.accessibilityIdentifier() == AccessibilityID.sidebarBudget(name)
            })
        }
        /// The budgets whose row draws the outline. Each row must be there.
        func outlined() throws -> [String] {
            try ["Groceries", "Eating out"].filter { name in
                let shown = try row(name)
                return (try? shown.find(PickedRowOutline.self)) != nil
            }
        }

        screen.selectedBudget = groceries
        #expect(try outlined() == ["Groceries"])

        try row("Eating out").tap()
        #expect(screen.selectedBudget == eatingOut)
        #expect(try outlined() == ["Eating out"])
        #expect(throws: Never.self, "Groceries keeps its fill") {
            _ = try row("Groceries").find(RowFillBackground.self)
        }

        screen.openPage(of: household)
        #expect(try outlined().isEmpty, "no budget is open while a group's page shows")
    }

    // Scenario WHEEL-03
    @Test func onlyAPickedRowIsOutlined() throws {
        let summary = WheelCalendar.summary(limit: 50_000, spent: 25_000, on: october18)
        #expect(throws: Never.self) {
            _ = try BudgetRow(summary: summary, isPicked: true).inspect().find(PickedRowOutline.self)
        }
        #expect((try? BudgetRow(summary: summary).inspect().find(PickedRowOutline.self)) == nil)
        #expect(throws: Never.self, "it keeps its fill") {
            _ = try BudgetRow(summary: summary, isPicked: true).inspect().find(RowFillBackground.self)
        }
    }

    // MARK: - A budget's page

    // Scenario WHEEL-05, WHEEL-07
    @Test func aBudgetsPageShowsItsDayItsWheelAndItsFigures() throws {
        let panel = try panel(limit: 100_000, spent: 55_536, october: 18)
        let shown = try texts(panel)
        for word in ["October · day 18 of 31", "Left", "$445", "of $1,000", "Spent", "$555.36", "$444.64",
                     "Expected left by today", "$419.35", panel.screen.countLine] {
            #expect(shown.contains(word), "missing \(word) in \(shown)")
        }
        #expect(throws: Never.self) {
            _ = try panel.inspect().find(viewWithAccessibilityIdentifier: AccessibilityID.budgetDayLine)
        }
        #expect(throws: Never.self, "one element, read as what its middle says") {
            _ = try panel.inspect().find(viewWithAccessibilityIdentifier: AccessibilityID.budgetWheel)
                .find(viewWithAccessibilityLabel: "Left $445 of $1,000")
        }
        #expect((try? panel.inspect().find(viewWithAccessibilityIdentifier: AccessibilityID.budgetPace)) == nil,
                "more is left than expected, and it is not the last week")
    }

    // Scenario WHEEL-06
    @Test func theWheelsMiddleSaysWhatIsLeftInWholeDollars() throws {
        #expect(try texts(panel(limit: 100_000, spent: 0, october: 10)).contains("$1,000"))
        #expect(try texts(panel(limit: 100_000, spent: 25_000, october: 10)).contains("$750"))
    }

    // Scenario WHEEL-08
    @Test func spendingFasterThanAnEvenPaceSaysWhenTheMoneyRunsOut() throws {
        var editing = false
        let gas = try panel("Gas", limit: 18_000, spent: 12_200, october: 18, editBudget: { editing = true })
        let words = "At this pace, Gas runs out around Oct 26, five days early."
        #expect(try texts(gas).contains(words))
        try gas.inspect().find(button: "Edit Budget\u{2026}").tap()
        #expect(editing, "Edit Budget\u{2026} opens the Edit Budget sheet")

        let model = try emptyModel()
        model.mayManageEntries = { _ in false }
        let atAdd = try panel("Gas", limit: 18_000, spent: 12_200, october: 18, model: model)
        #expect(try texts(atAdd).contains(words), "the same words")
        #expect((try? atAdd.inspect().find(button: "Edit Budget\u{2026}")) == nil, "with no button")
    }

    // Scenario WHEEL-09
    @Test func inTheLastWeekMoreLeftThanExpectedOffersToLowerTheBudget() throws {
        var editing = false
        let groceries = try panel(limit: 100_000, spent: 50_000, october: 26, editBudget: { editing = true })
        #expect(try texts(groceries).contains(
            "$339 more left than expected by today. Keep this budget, or lower it for next month?"))
        try groceries.inspect().find(button: "Edit Budget\u{2026}").tap()
        #expect(editing)

        let before = try panel(limit: 100_000, spent: 50_000, october: 24)
        #expect((try? before.inspect().find(viewWithAccessibilityIdentifier: AccessibilityID.budgetPace)) == nil,
                "nothing about the pace before the last week")
    }

    // Scenario WHEEL-10
    @Test func overItsLimitThePageSaysHowFarOverAndNothingAboutThePace() throws {
        let panel = try panel(limit: 10_000, spent: 11_500, october: 18)
        let shown = try texts(panel)
        for word in ["Over", "$15", "of $100", "Spent", "$115.00", "$15.00"] {
            #expect(shown.contains(word), "missing \(word) in \(shown)")
        }
        #expect(!shown.contains(MoneyWheel.Words.left), "Over in place of Left, in \(shown)")
        #expect(!shown.contains("Expected left by today"))
        #expect(throws: Never.self) {
            _ = try panel.inspect().find(viewWithAccessibilityLabel: "Over $15 of $100")
        }
        #expect((try? panel.inspect().find(viewWithAccessibilityIdentifier: AccessibilityID.budgetPace)) == nil)
    }

    /// A budget that never resets has no day of its period, and no tick or
    /// expected figure to show.
    @Test func aBudgetThatNeverResetsShowsNoDayLine() throws {
        let summary = BudgetSummary(
            budget: Budget(groupID: GroupID(), name: "Savings", limit: .dollars(500), reset: .never),
            period: ResetSchedule.never.period(containing: october18, calendar: calendar),
            spent: .dollars(100), transactionCount: 1)
        let screen = BudgetScreen(summary: summary, model: try emptyModel(), me: nil, now: october18,
                                  calendar: calendar)
        let panel = BudgetWheelPanel(screen: screen, editBudget: {})
        #expect((try? panel.inspect().find(viewWithAccessibilityIdentifier: AccessibilityID.budgetDayLine)) == nil)
        #expect(try !texts(panel).contains("Expected left by today"))
    }

    // MARK: - A group's page

    /// Household on October 18: Groceries, $1,000.00 with $555.36 spent,
    /// and Eating out, $300.00 with `eatingOutSpent` spent.
    private func household(eatingOutSpent: Int = 11_060) throws -> GroupMoney {
        let group = BudgetGroup(name: "Household")
        let summaries = [
            WheelCalendar.summary(limit: 100_000, spent: 55_536, on: october18, in: group.id),
            WheelCalendar.summary("Eating out", limit: 30_000, spent: eatingOutSpent, on: october18, in: group.id),
        ]
        return try #require(GroupMoney(group: group, summaries: summaries, now: october18, calendar: calendar))
    }

    // Scenario WHEEL-11
    @Test func aGroupsMoneyShowsItsWheelItsFiguresAndWhatItCounts() throws {
        let section = GroupMoneySection(money: try household())
        let shown = try texts(section)
        for word in ["MONEY", "Left this month", "$634", "of $1,300", "This month", "Spent", "$665.96", "Left",
                     "$634.04", "Expected left by today", "$545.16",
                     "Day 18 of 31. Every budget in Household, added up."] {
            #expect(shown.contains(word), "missing \(word) in \(shown)")
        }
        #expect(throws: Never.self) {
            _ = try section.inspect().find(viewWithAccessibilityIdentifier: AccessibilityID.groupMoney)
        }
        #expect(throws: Never.self) {
            _ = try section.inspect().find(viewWithAccessibilityIdentifier: AccessibilityID.groupWheel)
                .find(viewWithAccessibilityLabel: "Left this month $634 of $1,300")
        }
    }

    // Scenario WHEEL-12
    @Test func overTheMonthsBudgetsTheGroupsWheelSaysHowFarOver() throws {
        // $555.36 and $864.64 make $1,420.00 of $1,300.00.
        let section = GroupMoneySection(money: try household(eatingOutSpent: 86_464))
        let shown = try texts(section)
        for word in ["Over this month", "$120", "of $1,300", "Over", "$120.00"] {
            #expect(shown.contains(word), "missing \(word) in \(shown)")
        }
        #expect(!shown.contains("Expected left by today"))
        #expect(throws: Never.self) {
            _ = try section.inspect().find(viewWithAccessibilityLabel: "Over this month $120 of $1,300")
        }
    }

    // Scenario WHEEL-11
    /// The page shows MONEY above PEOPLE, and no MONEY for a group with no
    /// budgets.
    @Test func aGroupsPageShowsItsMoneyAboveItsPeople() async throws {
        let server = InMemoryReadableServer()
        let store = Store(database: try WellSpentDatabase.inMemory())
        let transport = StubReadableTransport(server: server)
        let sync = SyncCoordinator(store: store, keyStore: InMemoryKeyStore(), defaults: isolatedDefaults(),
                                   makeTransport: { _ in transport })
        let workspace = Workspace(model: AppModel(store: store), sync: sync)
        let main = MainScreen(workspace: workspace)
        try await sync.signUp(email: "robin@example.com", password: "a-long-password")
        try await sync.verifyEmail(code: try #require(server.lastCode(for: "robin@example.com", purpose: .verify)))
        let model = workspace.model
        let household = try #require(model.addGroup(named: "Household").flatMap(model.group(named:)))
        model.addBudget(named: "Groceries", limit: .dollars(500), in: household.id)
        let errands = try #require(model.addGroup(named: "Errands").flatMap(model.group(named:)))

        let page = try texts(GroupPage(sync: sync, group: household, main: main, showingAccount: .constant(false)))
        let money = try #require(page.firstIndex(of: "MONEY"), "no MONEY in \(page)")
        let people = try #require(page.firstIndex(of: "PEOPLE"), "no PEOPLE in \(page)")
        #expect(money < people)

        let empty = try texts(GroupPage(sync: sync, group: errands, main: main, showingAccount: .constant(false)))
        #expect(!empty.contains("MONEY"), "a group with no budgets shows no MONEY")
        #expect(empty.contains("PEOPLE"))
    }

    // MARK: - The wheel itself

    /// Home's small wheel on a phone says only the amount and one word.
    @Test func aCompactWheelSaysTheAmountAndOneWord() throws {
        let money = try household()
        let compact = MoneyWheelView(wheel: money.wheel, geometry: .homeCard, middle: .compact)
        #expect(try texts(compact) == ["$634", "left"])
        let full = MoneyWheelView(wheel: money.wheel, geometry: .groupDesktop, middle: .full(amountSize: 28))
        #expect(try texts(full) == ["Left this month", "$634", "of $1,300"])
    }
}

#endif
