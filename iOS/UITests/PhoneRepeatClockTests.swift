import Foundation
import XCTest
import WellSpentAppCore
import WellSpentModel
import WellSpentSync

/// A repeat's later months on a phone, on the test clock
/// (`Workspace.clockFileVariable`): a bill shows up each month (REPEAT-02),
/// after time away (REPEAT-03), and in a short month (REPEAT-04). Signed
/// out, in a group of its own. The Mac's twin is `RepeatTests`.
final class PhoneRepeatClockTests: XCTestCase {
    nonisolated(unsafe) private static var dataRootPath: String?
    private static let bill = "Phone bill"

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    override func tearDown() {
        let app = XCUIApplication()
        if app.state != .notRunning { app.terminate() }
        if let path = Self.dataRootPath { try? FileManager.default.removeItem(atPath: path) }
        Self.dataRootPath = nil
        super.tearDown()
    }

    /// Utilities in Home on the test clock at `start`, with the $85.00 phone
    /// bill set to repeat that day.
    @MainActor
    private func repeating(from start: String) throws -> PhoneTestApp {
        let run = PhoneTestApp()
        Self.dataRootPath = run.dataRoot.path
        try run.setClock(start)
        run.launch()
        run.addGroup(named: "Home")
        run.addBudget(named: "Utilities", amount: "600", inGroup: "Home")
        run.addRepeat(merchant: Self.bill, amount: "85.00")
        return run
    }

    @MainActor
    func testItShowsUpEachMonth() throws {
        let run = try repeating(from: "2026-11-14T09:00:00")

        // Scenario REPEAT-02
        // 1. December 14 comes and the app is opened: a new $85.00 bill is in
        // Utilities, dated Dec 14, with Source reading Repeat.
        try run.reopen(on: "2026-12-14T09:00:00", budget: "Utilities")
        try run.expectOneBill(Self.bill, on: "2026-12-14T09:00:00", at: "$85.00", "on December 14")
        XCTAssertTrue(run.row(Self.bill, says: BudgetScreen.Words.repeatSource),
                      "Source does not say Repeat: \(run.rowLabel(Self.bill))")
    }

    /// Every month between getting its bill, once, is proven by RepeatsTests
    /// (`eachMonthThatHasComeGetsOneBill`): no screen shows an earlier
    /// month's bills without moving the date, and moving it makes the missing
    /// bill itself.
    @MainActor
    func testCatchingUpAfterTimeAway() throws {
        let run = try repeating(from: "2026-10-15T09:00:00")

        // Scenario REPEAT-03
        // 1. Opened again on December 20, after this month's 15th, Utilities
        // shows December's phone bill once, dated the 15th, at $85.00. The
        // clock only moves forward, so this read is the one that caught up.
        try run.reopen(on: "2026-12-20T09:00:00", budget: "Utilities")
        try run.expectOneBill(Self.bill, on: "2026-12-15T09:00:00", at: "$85.00", "December, after two months away")
    }

    @MainActor
    func testAShortMonth() throws {
        let run = try repeating(from: "2026-10-31T09:00:00")

        // Scenario REPEAT-04
        // 1. A bill that repeats on the 31st shows up in November on the 30th,
        // the month's last day.
        try run.reopen(on: "2026-11-30T09:00:00", budget: "Utilities")
        try run.expectOneBill(Self.bill, on: "2026-11-30T09:00:00", at: "$85.00", "in November")
    }

    // MARK: - Two devices

    /// Robin's iPhone, the app, and another device of his on the same account
    /// with no window, both hold the repeat set on December 10. Both are
    /// opened on January 12, and each makes January's bill. Once both have
    /// synced there is one January bill, on each. The phone is on the test
    /// clock; the other device reads its budgets with January 12 as today.
    @MainActor
    func testTwoDevicesMakeOneBill() async throws {
        let accounts = try TestAccounts.fromEnvironment()
        let run = PhoneTestApp()
        Self.dataRootPath = run.dataRoot.path
        let stamp = PhoneTestApp.stamp()
        let home = "UI Phone \(stamp) Repeats", utilities = "Utilities \(stamp)"
        let january = try PhoneTestApp.clockDate("2027-01-12T09:00:00")

        // 1. On the phone, signed in, on December 10: the phone bill repeats.
        try run.setClock("2026-12-10T09:00:00")
        run.launch()
        try run.signIn(email: accounts.email, password: accounts.password, server: accounts.server)
        run.addGroup(named: home)
        run.addBudget(named: utilities, amount: "600", inGroup: home)
        run.addRepeat(merchant: Self.bill, amount: "85.00")
        run.goBack()
        run.syncAndWait()

        // 2. The other device takes the repeat in, and is opened on January 12:
        // it makes January's bill.
        let other = try SecondAccount(server: accounts.server)
        try await other.signIn(email: accounts.email, password: accounts.password)
        try await other.syncAll()
        let onTheOther = AppModel(store: other.sync.store, today: { january })
        onTheOther.me = { [sync = other.sync] in sync.userID }
        onTheOther.reload()
        func januaryBills() throws -> [Transaction] {
            let group = try XCTUnwrap(onTheOther.groups.first { $0.name == home }, "the other device has no \(home)")
            let budget = try XCTUnwrap(onTheOther.summaries[group.id]?.first { $0.budget.name == utilities }?.budget.id,
                                       "the other device has no \(utilities)")
            return try onTheOther.store.transactions(in: budget)
                .filter { $0.merchant == Self.bill && $0.repeatMonth == "2027-01" && !$0.isDeleted }
        }
        XCTAssertEqual(try januaryBills().count, 1, "the other device did not make January's bill")

        // Scenario REPEAT-05
        // 3. The phone is opened on January 12 too, and makes its own. After
        // both sync, the phone shows one January bill, and so does the other.
        try run.setClock("2027-01-12T09:00:00")
        run.openBudget(named: utilities)
        XCTAssertTrue(run.hasRow(Self.bill, timeout: 20), "the phone did not make January's bill. On screen: \(run.visibleTexts())")
        try await other.syncAll()
        run.goBack()
        run.syncAndWait()
        try await other.syncAll()
        run.openBudget(named: utilities)
        // Dated the 10th, the repeat's day, though opened on the 12th.
        try run.expectOneBill(Self.bill, on: "2027-01-10T09:00:00", at: "$85.00", "on the phone in January")
        XCTAssertEqual(try januaryBills().count, 1, "not one January bill on the other device")

        // 4. Tidy: the group goes, for everyone, and both sign out.
        run.goBack()
        run.signOut()
        await other.deleteGroup(named: home)
        await other.cleanUp()
    }

    // MARK: - Who may change a repeat

    /// The phone joins a group with a link, typing the name to be known by.
    @MainActor
    private func join(_ run: PhoneTestApp, _ link: InviteLink, as name: String) {
        run.openAddMenu()
        run.tapMenuItem(MainScreen.Words.join)
        run.paste(link.url, into: AccessibilityID.joinLink)
        run.type(name, into: AccessibilityID.joinName)
        run.tap(AccessibilityID.joinJoin)
        XCTAssertTrue(run.wait(for: run.element(AccessibilityID.joinLink), until: "exists == false", timeout: 30),
                      "Join a Group stayed. On screen: \(run.visibleTexts())")
    }

    /// Robin sets the phone bill to repeat in Household, then invites Leslie
    /// at Add and Kim as a manager, with links. The phone is each of them in
    /// turn. Leslie's sheets show the bill and the repeat with nothing to
    /// change. Kim may change the bill and the repeat. Needs the third test
    /// account (`TestAccounts.third()`). The Mac's twin is `RepeatTests`.
    @MainActor
    func testOnlyTheOwnerOrAManagerChangesTheRule() async throws {
        let accounts = try TestAccounts.fromEnvironment()
        let kim = try accounts.third()
        let run = PhoneTestApp()
        Self.dataRootPath = run.dataRoot.path
        let stamp = PhoneTestApp.stamp()
        let household = "UI Phone \(stamp) Household", utilities = "Utilities \(stamp)"
        typealias Words = EntryEditor.Words

        // 1. Robin sets the repeat, and makes a link at Add for Leslie and one
        // at Manage for Kim.
        run.launch()
        try run.signIn(email: accounts.email, password: accounts.password, server: accounts.server)
        run.addGroup(named: household)
        run.addBudget(named: utilities, amount: "600", inGroup: household)
        run.addRepeat(merchant: Self.bill, amount: "85.00")
        let leslieLink = try await run.legacyInvite(household, as: "Robin", role: .add)
        let kimLink = try await run.legacyInvite(household, as: "Robin", role: .manage)
        run.goBack()
        run.signOut()

        // Scenario REPEAT-11
        // 2. Leslie, at Add, opens this month's phone bill: it opens read-only,
        // with no Which months? and no Stop repeating.
        try run.signIn(email: accounts.secondEmail, password: accounts.secondPassword, server: accounts.server)
        join(run, leslieLink, as: "Leslie")
        run.openBudget(named: utilities)
        XCTAssertTrue(run.hasRow(Self.bill, timeout: 20), "the bill did not arrive. On screen: \(run.visibleTexts())")
        _ = run.scrollTo(AccessibilityID.entryRow(Self.bill))
        run.tap(AccessibilityID.entryRow(Self.bill))
        XCTAssertTrue(run.has(AccessibilityID.entryDone), "the bill did not open read-only. On screen: \(run.visibleTexts())")
        XCTAssertTrue(run.lacks(AccessibilityID.entrySave), "Save on Leslie's read-only bill")
        XCTAssertTrue(run.lacks(AccessibilityID.entryWhichMonth(Words.thisMonthAndLater)), "This month and later for Leslie")
        XCTAssertTrue(run.lacks(AccessibilityID.entryStopRepeating), "Stop repeating for Leslie")
        run.tap(AccessibilityID.entryDone)
        XCTAssertTrue(run.wait(for: run.element(AccessibilityID.entryDone), until: "exists == false", timeout: 10),
                      "the read-only bill stayed open. On screen: \(run.visibleTexts())")

        // Scenario REPEAT-11
        // 3. She opens the repeat from Utilities' list of repeats: its sheet
        // says only Robin or a manager can change it, and has nothing to change.
        run.bringToMiddle(run.scrollTo(AccessibilityID.budgetRepeats))
        run.tap(AccessibilityID.budgetRepeats)
        run.tap(AccessibilityID.repeatRow(Self.bill))
        XCTAssertTrue(run.shows(RepeatEditor.Words.onlyOwner("Robin")),
                      "no line saying only Robin or a manager can change it. On screen: \(run.visibleTexts())")
        XCTAssertTrue(run.lacks(AccessibilityID.repeatSave), "Save on the repeat for Leslie")
        XCTAssertTrue(run.lacks(AccessibilityID.repeatStop), "Stop repeating on the repeat for Leslie")
        run.app.buttons[RepeatEditor.Words.close].firstMatch.tap()
        run.app.buttons[RepeatsList.Words.done].firstMatch.tap()
        XCTAssertTrue(run.wait(for: run.element(AccessibilityID.repeatRow(Self.bill)), until: "exists == false", timeout: 10),
                      "the list of repeats stayed open. On screen: \(run.visibleTexts())")
        run.goBack()
        run.signOut()

        // Scenario REPEAT-11
        // 4. Kim, a manager, opens the same bill and changes its amount: she's
        // offered This month only and This month and later under Which months?,
        // and Stop repeating.
        try run.signIn(email: kim.email, password: kim.password, server: accounts.server)
        join(run, kimLink, as: "Kim")
        run.openBudget(named: utilities)
        XCTAssertTrue(run.hasRow(Self.bill, timeout: 20), "the bill did not arrive for Kim. On screen: \(run.visibleTexts())")
        run.openEntry(Self.bill)
        run.type("92.00", into: AccessibilityID.entryAmount)
        run.bringUpInSheet(AccessibilityID.entryWhichMonth(Words.thisMonthAndLater))
        XCTAssertTrue(run.has(AccessibilityID.entryWhichMonth(Words.thisMonthOnly)), "This month only is not offered")
        XCTAssertTrue(run.has(AccessibilityID.entryWhichMonth(Words.thisMonthAndLater)), "This month and later is not offered")
        run.bringUpInSheet(AccessibilityID.entryStopRepeating)
        XCTAssertTrue(run.has(AccessibilityID.entryStopRepeating), "no Stop repeating for Kim")
        run.tap(AccessibilityID.entryCancel)
        run.expectNoSheet()

        // 5. Tidy: Kim signs out, and Robin deletes Household for everyone.
        run.goBack()
        run.signOut()
        let robin = try SecondAccount(server: accounts.server)
        try await robin.signIn(email: accounts.email, password: accounts.password)
        try await robin.syncAll()
        await robin.deleteGroup(named: household)
        await robin.cleanUp()
    }
}
