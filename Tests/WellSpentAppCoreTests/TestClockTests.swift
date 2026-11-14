import Testing
import Foundation
import Observation
@testable import WellSpentAppCore
import WellSpentCrypto
import WellSpentKeyStore
import WellSpentModel
import WellSpentStore
import WellSpentSync

/// A clock a test moves by hand, for the workspace to read.
private final class HandClock: @unchecked Sendable {
    var date: Date
    init(_ date: Date) { self.date = date }
    var clock: AppClock { AppClock(isPinned: true) { [self] in date } }
}

/// The clock a staging UI test moves (`Workspace.clockFileVariable`): the
/// whole date, read on every ask, and a new day noticed the way a real
/// build notices one.
@Suite("The test clock")
@MainActor
struct TestClockTests {
    /// A workspace over an empty database, signed out, with Groceries in
    /// Household, on `clock`.
    private func household(on clock: AppClock, announcesDays: Bool = true,
                           notifications: NotificationCenter = NotificationCenter()) throws
        -> (workspace: Workspace, groceries: BudgetID, group: GroupID) {
        let store = Store(database: try WellSpentDatabase.inMemory())
        let sync = SyncCoordinator(store: store, keyStore: InMemoryKeyStore(), defaults: isolatedDefaults())
        let workspace = Workspace(model: AppModel(store: store), sync: sync, clock: clock,
                                  announcesDays: announcesDays, notifications: notifications)
        let group = try #require(workspace.model.addGroup(named: "Household"))
        let groceries = try #require(workspace.model.addBudget(named: "Groceries", limit: .dollars(500), in: group))
        return (workspace, groceries, group)
    }

    private func file(holding text: String?) throws -> String {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("clock-\(UUID().uuidString)").path
        if let text { try text.write(toFile: path, atomically: true, encoding: .utf8) }
        return path
    }

    @Test func theFileClockReadsTheWholeDateEachTime() throws {
        let path = try file(holding: "2026-12-14T09:00:00")
        defer { try? FileManager.default.removeItem(atPath: path) }
        let clock = AppClock.file(path, calendar: WheelCalendar.calendar)
        #expect(clock.isPinned)
        let first = WheelCalendar.calendar.dateComponents([.year, .month, .day, .hour], from: clock.now())
        #expect(first == DateComponents(year: 2026, month: 12, day: 14, hour: 9))

        try "2027-01-02T08:30:00".write(toFile: path, atomically: true, encoding: .utf8)
        let moved = WheelCalendar.calendar.dateComponents([.year, .month, .day], from: clock.now())
        #expect(moved == DateComponents(year: 2027, month: 1, day: 2), "moving the file moves the clock, with no relaunch")
    }

    @Test func aMissingOrUnreadableFileIsTheSystemClock() throws {
        let missing = try file(holding: nil)
        let garbled = try file(holding: "not a date")
        defer { try? FileManager.default.removeItem(atPath: garbled) }
        for path in [missing, garbled] {
            let read = AppClock.file(path).now()
            #expect(abs(read.timeIntervalSinceNow) < 5)
        }
    }

    @Test func theClockIsWrittenAsItIsRead() throws {
        let date = WheelCalendar.date(2026, 12, 14)
        let text = AppClock.text(for: date, calendar: WheelCalendar.calendar)
        #expect(AppClock.parse(text, calendar: WheelCalendar.calendar) == date)
    }

    @Test func onlyAStagingTestBuildReadsTheVariables() {
        let asked = [Workspace.clockFileVariable: "/tmp/clock", Workspace.clockAnnouncesVariable: "0"]
        #expect(Workspace.clock(for: .staging, in: asked).isPinned)
        #expect(!Workspace.clock(for: .live, in: asked).isPinned, "a live build never reads it")
        #expect(!Workspace.clock(for: .staging, in: [:]).isPinned)
        #expect(!Workspace.clockAnnouncesDays(for: .staging, in: asked))
        #expect(Workspace.clockAnnouncesDays(for: .live, in: asked))
        #expect(Workspace.clockAnnouncesDays(for: .staging, in: [:]))
    }

    @Test func todayIsTheClocksDay() throws {
        let hand = HandClock(WheelCalendar.date(2026, 12, 14))
        let (workspace, _, _) = try household(on: hand.clock)
        #expect(workspace.clockIsPinned)
        #expect(WheelCalendar.calendar.isDate(workspace.model.today(), inSameDayAs: WheelCalendar.date(2026, 12, 14)))
        hand.date = WheelCalendar.date(2027, 1, 2)
        #expect(WheelCalendar.calendar.isDate(workspace.model.today(), inSameDayAs: WheelCalendar.date(2027, 1, 2)))
    }

    /// Linux's timer asks with no date, so it follows the clock.
    @Test func aCheckWithNoDateReadsTheClock() async throws {
        let hand = HandClock(WheelCalendar.date(2026, 10, 18))
        let (workspace, groceries, _) = try household(on: hand.clock)
        let summary = try #require(workspace.model.summary(for: groceries))
        hand.date = WheelCalendar.date(2026, 10, 19)
        await confirmation("a new day on the clock redraws the wheel") { redraw in
            withObservationTracking {
                _ = BudgetScreen(summary: summary, model: workspace.model, me: nil).wheel
            } onChange: {
                redraw()
            }
            workspace.checkForNewDay(calendar: WheelCalendar.calendar)
        }
    }

    /// Back after a night away, coming to the front checks the date itself
    /// and redraws the group page's wheel, though no money changed and
    /// nothing said a day began (#209). A budget's page redraws on any read
    /// of the budgets (`AppModel.revision`). A group's page reads only its
    /// money and today, so it kept yesterday's day until the system said a
    /// day began. Linux checks on focus already. The Mac and iPhone didn't.
    @Test(.disabled("Diag branch only: its UI twin is proved failing on GitHub here")) func comingToTheFrontOnANewDayRedrawsTheGroupsWheel() async throws {
        let hand = HandClock(WheelCalendar.date(2026, 10, 18))
        let (workspace, _, group) = try household(on: hand.clock, announcesDays: false)
        let screen = MainScreen(workspace: workspace)
        hand.date = WheelCalendar.date(2026, 10, 19)
        await confirmation("coming to the front on a new day redraws the group's wheel") { redraw in
            withObservationTracking {
                _ = screen.money(of: group)?.wheel
            } onChange: {
                redraw()
            }
            await workspace.cameToFront()
        }
    }

    #if !os(Linux)
    /// On the Mac and iPhone the system says when a day begins. With the test
    /// clock, the workspace says it in the same words, to the same watcher,
    /// when the clock's day changes.
    @Test func theClocksNewDayIsSaidTheWayTheSystemSaysIt() async throws {
        let hand = HandClock(WheelCalendar.date(2026, 10, 18))
        let days = NotificationCenter()
        let (workspace, _, _) = try household(on: hand.clock, notifications: days)
        let said = NotificationCounter(days)
        hand.date = WheelCalendar.date(2026, 10, 19)
        try await Task.sleep(for: .milliseconds(2_500))
        #expect(said.count == 1, "the clock's new day was said \(said.count) times")
        _ = workspace
    }

    @Test func withAnnouncingOffNothingIsSaid() async throws {
        let hand = HandClock(WheelCalendar.date(2026, 10, 18))
        let days = NotificationCenter()
        let (workspace, _, _) = try household(on: hand.clock, announcesDays: false, notifications: days)
        let said = NotificationCounter(days)
        hand.date = WheelCalendar.date(2026, 10, 19)
        try await Task.sleep(for: .milliseconds(2_500))
        #expect(said.count == 0)
        _ = workspace
    }
    #endif
}

/// Counts the system's day-changed notices on one center.
@MainActor
private final class NotificationCounter {
    private(set) var count = 0
    private var token: (any NSObjectProtocol)?
    init(_ center: NotificationCenter) {
        token = center.addObserver(forName: .NSCalendarDayChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.count += 1 }
        }
    }
}
