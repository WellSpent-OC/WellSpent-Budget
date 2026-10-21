import Testing
import Foundation
@testable import WellSpentAppCore
import WellSpentCrypto
import WellSpentKeyStore
import WellSpentModel
import WellSpentStore
import WellSpentSync

/// The day the money wheel reads: the clock's, with the budgets read again
/// when a new day starts, or a day a staging UI test pins.
@Suite("The wheel's day")
@MainActor
struct WheelDayTests {
    /// A workspace over an empty database, signed out, with Groceries,
    /// $500.00 a month, in Household.
    private func household(pinnedDay: Int? = nil, notifications: NotificationCenter = NotificationCenter()) throws
        -> (workspace: Workspace, group: GroupID, groceries: BudgetID) {
        let store = Store(database: try WellSpentDatabase.inMemory())
        let sync = SyncCoordinator(store: store, keyStore: InMemoryKeyStore(), defaults: isolatedDefaults())
        let workspace = Workspace(model: AppModel(store: store), sync: sync, pinnedDay: pinnedDay,
                                  notifications: notifications)
        let group = try #require(workspace.model.addGroup(named: "Household"))
        let groceries = try #require(workspace.model.addBudget(named: "Groceries", limit: .dollars(500), in: group))
        return (workspace, group, groceries)
    }

    #if !os(Linux)
    /// A window left open past midnight, signed out, has no sync to read its
    /// budgets again. When the system says the day changed, the workspace
    /// reads them itself, so each wheel shows the new day's period and money.
    /// Only on Apple's systems, which say so. Linux never does.
    @Test func aNewDayReadsTheBudgetsAgain() throws {
        let days = NotificationCenter()
        let (workspace, group, groceries) = try household(notifications: days)
        // Saved past the model, so only a new read shows it.
        try workspace.model.store.save(Transaction(budgetID: groceries, groupID: group, date: Date(),
                                                   merchant: "Hilltop Grocery", amount: Money(minorUnits: -14_208)))
        #expect(workspace.model.summary(for: groceries)?.spent == Money(minorUnits: 0), "nothing has read it yet")

        days.post(name: .NSCalendarDayChanged, object: nil)
        #expect(workspace.model.summary(for: groceries)?.spent == Money(minorUnits: 14_208))
    }
    #endif

    /// A pinned day is that day of this month, at noon. A day past the
    /// month's end is its last day, and with no day pinned it is the clock.
    @Test func aPinnedDayIsThatDayOfThisMonth() {
        let calendar = WheelCalendar.calendar
        let october30 = WheelCalendar.date(2026, 10, 30)
        #expect(Workspace.today(pinnedTo: 18, now: october30, calendar: calendar) == WheelCalendar.date(2026, 10, 18))
        #expect(Workspace.today(pinnedTo: 1, now: october30, calendar: calendar) == WheelCalendar.date(2026, 10, 1))
        #expect(Workspace.today(pinnedTo: 31, now: WheelCalendar.date(2026, 9, 3), calendar: calendar)
                == WheelCalendar.date(2026, 9, 30), "September has 30 days")
        #expect(Workspace.today(pinnedTo: 30, now: WheelCalendar.date(2027, 2, 3), calendar: calendar)
                == WheelCalendar.date(2027, 2, 28))
        #expect(Workspace.today(pinnedTo: nil, now: october30, calendar: calendar) == october30)
    }

    /// Every wheel a screen builds reads the workspace's day: a budget's
    /// page, a group's MONEY and Home's card.
    @Test func aPinnedDayPutsEveryWheelOnIt() throws {
        let (workspace, group, groceries) = try household(pinnedDay: 18)
        #expect(workspace.model.today() == Workspace.today(pinnedTo: 18))
        let summary = try #require(workspace.model.summary(for: groceries))
        let page = BudgetScreen(summary: summary, model: workspace.model, me: nil)
        #expect(page.wheel.day?.day == 18)
        let main = MainScreen(workspace: workspace)
        #expect(main.money(of: group)?.wheel.day?.day == 18)
        #expect(main.homeMoney()?.wheel.day?.day == 18)
    }
}
