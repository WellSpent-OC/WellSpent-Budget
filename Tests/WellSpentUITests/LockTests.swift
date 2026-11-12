import AppKit
import Foundation
import XCTest
import WellSpentAppCore
import WellSpentModel
import WellSpentSync

/// Locks on the Mac: the lock card in place of a locked group, Locked in the
/// sidebar, and Pick what stays open. The app reads its plan from a file this
/// test writes (`Workspace.pinnedPlanVariable`), read again each time the app
/// comes to the front, so the test can end a paid plan and lock a group
/// without the server doing it. The groups themselves are real ones on staging.
///
/// Needs the four WELLSPENT_UI_TEST_ variables, for accounts on a paid plan
/// (scripts/fresh-test-accounts.py gives them one), since Robin makes two
/// groups and joins a third.
///
/// What these tests don't prove: with the plan pinned, saving a pick answers
/// with the pinned file again, so Keep These Open and Skip are checked only
/// as far as the sheet closing. That the server stores the pick is covered by
/// the server's PlanLocksTests.
final class LockTests: XCTestCase {
    nonisolated(unsafe) private static var dataRootPath: String?
    nonisolated(unsafe) private static var planFile: URL?

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    override func tearDown() {
        let app = XCUIApplication()
        if app.state != .notRunning { app.terminate() }
        if let path = Self.dataRootPath { try? FileManager.default.removeItem(atPath: path) }
        Self.dataRootPath = nil
        Self.planFile = nil
        super.tearDown()
    }

    /// Robin's own groups: his paid plan ends with "Beach" locked and "Home" open.
    @MainActor
    func testWhenAPaidPlanEndsTheGroupsPastItLock() async throws {
        let run = try signedIn()
        // Robin's other device deletes Home and Beach from staging after the
        // test, even when an assertion stops it. The run's accounts are shared
        // by every class in it, so groups left here would show in the next
        // class's tests.
        let accounts = try TestAccounts.fromEnvironment()
        let elsewhere = try SecondAccount(server: accounts.server)
        try await elsewhere.signIn(email: accounts.email, password: accounts.password)
        addTeardownBlock { @MainActor in
            // It deletes only what it holds, so it takes in the groups first.
            await elsewhere.sync.syncAll()
            await elsewhere.deleteGroup(named: "Home")
            await elsewhere.deleteGroup(named: "Beach")
            await elsewhere.cleanUp()
        }
        run.addGroup(named: "Home")
        run.addGroup(named: "Beach")
        let ids = try groupIDs(run, ["Home", "Beach"])
        let home = try XCTUnwrap(ids["Home"]), beach = try XCTUnwrap(ids["Beach"])

        // Scenario LOCK-05
        // The plan ends with Beach locked: the pick shows once, on its own,
        // and says what Skip keeps.
        try show(run, Self.answer(lastPlan: true, locked: [beach], open: home))
        let sheet = run.element(AccessibilityID.pickSheet)
        XCTAssertTrue(sheet.waitForExistence(timeout: 30), "the pick didn't show. On screen: \(run.visibleTexts())")
        XCTAssertTrue(run.visibleTexts().contains("Skip keeps Home open."),
                      "it doesn't say what Skip keeps. On screen: \(run.visibleTexts())")
        run.click(AccessibilityID.pickSkip)
        XCTAssertTrue(sheet.waitForNonExistence(timeout: 15), "Skip didn't close the pick")

        // Scenario LOCK-03
        XCTAssertTrue(run.wait(for: run.element(AccessibilityID.sidebarGroup("Beach")), until: "value == 'Locked'",
                               timeout: 15), "Beach doesn't say Locked")
        XCTAssertNotEqual(run.element(AccessibilityID.sidebarGroup("Home")).value as? String, "Locked",
                          "Home says Locked")

        // Scenario LOCK-01
        run.click(AccessibilityID.sidebarGroup("Beach"))
        expectCard(run, title: "This group is locked",
                   lines: ["Your free plan keeps 1 group open: Home.", "The people in this group can't see it either."],
                   actions: [.changeWhatsOpen, .seePlans])

        // Scenario LOCK-04
        // Change what stays open lists his groups, Home picked; he picks Beach.
        openPickFromAccount(run)
        XCTAssertTrue(run.element(AccessibilityID.pickGroup(home)).isSelected, "Home isn't the picked group")
        run.click(AccessibilityID.pickGroup(beach))
        XCTAssertTrue(run.wait(for: run.element(AccessibilityID.pickGroup(beach)), until: "selected == true",
                               timeout: 5), "Beach didn't become the picked group")
        run.click(AccessibilityID.pickKeep)
        XCTAssertTrue(sheet.waitForNonExistence(timeout: 15), "Keep These Open didn't close the pick")

        // Scenario LOCK-07
        // He changed the open group 10 days ago: the date it can change again
        // shows, and picking another group changes nothing.
        let changed = Self.day(in: -10)
        try show(run, Self.answer(lastPlan: true, locked: [beach], open: home, groupChangedAt: changed))
        openPickFromAccount(run)
        let next = PlanWording.day(Calendar.current.date(byAdding: .day, value: 30, to: changed)!, now: Date(),
                                   calendar: AppLocale.calendar)
        XCTAssertTrue(run.visibleTexts().contains("You can change the open group on \(next)."),
                      "no date it can change. On screen: \(run.visibleTexts())")
        run.element(AccessibilityID.pickGroup(beach)).click()
        XCTAssertTrue(run.element(AccessibilityID.pickGroup(home)).isSelected, "the open group changed anyway")
        XCTAssertFalse(run.element(AccessibilityID.pickGroup(beach)).isSelected, "Beach became the picked group")
        run.click(AccessibilityID.pickSkip)
        XCTAssertTrue(sheet.waitForNonExistence(timeout: 15), "Skip didn't close the pick")
    }

    /// Leslie pays for Cabin, which Robin joined, and her paid plan has ended
    /// with Cabin locked.
    @MainActor
    func testAMemberIsAskedToPayForALockedGroup() async throws {
        let accounts = try TestAccounts.fromEnvironment()
        let leslie = try SecondAccount(server: accounts.server)
        try await leslie.signIn(email: accounts.secondEmail, password: accounts.secondPassword)
        let name = "Cabin \(Self.stamp())"
        let link = try await leslie.shareNewGroup(name, budget: "Groceries", entry: "Market",
                                                  amount: Money(minorUnits: 1250), myName: "Leslie", role: .add)
        // Runs even when an assertion stops the test, so Cabin never stays on staging.
        addTeardownBlock { @MainActor in
            await leslie.deleteGroup(named: name)
            await leslie.cleanUp()
        }
        let cabin = try XCTUnwrap(AppModel(store: leslie.sync.store).groups.first { $0.name == name }?.id.uuid,
                                  "Leslie's group has no id")

        let run = try signedIn()
        try run.open(link: link.url)
        XCTAssertTrue(run.element(AccessibilityID.invitationJoin).waitForExistence(timeout: 30),
                      "no Join. On screen: \(run.visibleTexts())")
        run.pasteAndCheck("Robin", into: AccessibilityID.invitationName)
        run.click(AccessibilityID.invitationJoin)
        XCTAssertTrue(run.element(AccessibilityID.groupSummary).waitForExistence(timeout: 60),
                      "the group's page did not open. On screen: \(run.visibleTexts())")

        // Scenario LOCK-02
        try show(run, Self.answer(locked: [cabin]))
        XCTAssertTrue(run.element(AccessibilityID.lockedCard).waitForExistence(timeout: 30),
                      "Cabin's page stayed open. On screen: \(run.visibleTexts())")
        expectCard(run, title: "This group needs a paid plan",
                   lines: ["Leslie's plan doesn't cover it right now.",
                           "Paying opens it for everyone in it. Nobody else is charged."],
                   actions: [.payForThisGroup])
        run.click(AccessibilityID.lockedAction(.payForThisGroup))
        XCTAssertTrue(run.element(AccessibilityID.planChoices).waitForExistence(timeout: 10),
                      "Pay for This Group didn't open Choose a plan")
        run.click(AccessibilityID.planNotNow)
        run.signOut()
    }

    // MARK: - Steps

    /// Signed in, on the free plan with nothing locked.
    @MainActor
    private func signedIn() throws -> TestApp {
        let accounts = try TestAccounts.fromEnvironment()
        let run = try TestApp()
        Self.dataRootPath = run.dataRoot.path
        let file = run.dataRoot.appendingPathComponent("plan.json")
        Self.planFile = file
        try Self.write(Self.answer(), to: file)
        run.app.launchEnvironment[Workspace.pinnedPlanVariable] = file.path
        run.launch()
        try run.signIn(email: accounts.email, password: accounts.password, server: accounts.server)
        return run
    }

    /// The groups' ids, by name. The server sends ids only, and the pick
    /// sheet names each row by its group's id, so the test reads them there:
    /// with a paid plan ended and nothing locked yet, Change what stays open
    /// lists Robin's groups. Skip then closes it, changing nothing.
    @MainActor
    private func groupIDs(_ run: TestApp, _ names: [String]) throws -> [String: UUID] {
        try show(run, Self.answer(lastPlan: true))
        openPickFromAccount(run)
        let rows = run.app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'pick.group.'")).allElementsBoundByIndex
        var ids: [String: UUID] = [:]
        for row in rows {
            guard let id = UUID(uuidString: String(row.identifier.dropFirst("pick.group.".count))),
                  let name = names.first(where: { row.label.contains($0) }) else { continue }
            ids[name] = id
        }
        XCTAssertEqual(Set(ids.keys), Set(names), "the pick doesn't list every group: \(rows.map(\.label))")
        run.click(AccessibilityID.pickSkip)
        XCTAssertTrue(run.element(AccessibilityID.pickSheet).waitForNonExistence(timeout: 15),
                      "Skip didn't close the pick")
        return ids
    }

    /// Account, then Change what stays open, then the pick.
    @MainActor
    private func openPickFromAccount(_ run: TestApp) {
        let account = run.element(AccessibilityID.toolbarAccount)
        XCTAssertTrue(run.wait(for: account, until: "enabled == true", timeout: 60), "Account stayed disabled")
        run.click(AccessibilityID.toolbarAccount)
        run.click(AccessibilityID.planChangeWhatStaysOpen, timeout: 15)
        XCTAssertTrue(run.element(AccessibilityID.pickSheet).waitForExistence(timeout: 15),
                      "Change what stays open didn't open the pick. On screen: \(run.visibleTexts())")
    }

    /// Rewrites the pinned answer, then sends the app to the back and brings
    /// it forward, which asks for the plan again.
    @MainActor
    private func show(_ run: TestApp, _ json: String) throws {
        try Self.write(json, to: try XCTUnwrap(Self.planFile))
        let finder = XCUIApplication(bundleIdentifier: "com.apple.finder")
        finder.activate()
        _ = run.app.wait(for: .runningBackground, timeout: 5)
        run.app.activate()
        XCTAssertTrue(run.app.wait(for: .runningForeground, timeout: 10), "the app didn't come back to the front")
    }

    @MainActor
    private func expectCard(_ run: TestApp, title: String, lines: [String], actions: [LockedScreen.Action],
                            file: StaticString = #filePath, line: UInt = #line) {
        let shown = run.element(AccessibilityID.lockedTitle)
        // On the Mac a Text with an identifier may hold its words in its
        // value, not its label, so read both.
        XCTAssertTrue(run.wait(for: shown, holds: title, timeout: 15),
                      "the card says \(run.text(of: shown)), not \(title)", file: file, line: line)
        let card = run.element(AccessibilityID.lockedCard)
        for wanted in lines {
            XCTAssertTrue(card.staticTexts[wanted].firstMatch.exists, "no line \"\(wanted)\" on the card",
                          file: file, line: line)
        }
        for action in [LockedScreen.Action.switchWhichIsOpen, .changeWhatsOpen, .seePlans, .payForThisGroup] {
            XCTAssertEqual(run.element(AccessibilityID.lockedAction(action)).exists, actions.contains(action),
                           "\(action.title) \(actions.contains(action) ? "is missing" : "shouldn't be there")",
                           file: file, line: line)
        }
    }

    // MARK: - Answers, in the server's shape

    /// When the Growth plan ended. One date for the whole run: a new date
    /// would be a plan that ended again, and the pick would show on its own.
    private static let ended = day(in: -2)

    /// The free plan. `lastPlan` says a Growth plan ended two days ago.
    private static func answer(lastPlan: Bool = false, locked: [UUID] = [], open: UUID? = nil,
                               groupChangedAt: Date? = nil) -> String {
        let date = ISO8601DateFormatter()
        var fields = [
            #""tier":"free""#, #""period":"none""#, #""state":"free""#, #""source":"none""#,
            #""paidUntil":null"#, #""renews":false"#, #""nextTier":null"#,
            #""limits":{"properties":1,"groups":1,"invitedPerGroup":1}"#,
            #""used":{"properties":0,"groups":\#(locked.count + (open == nil ? 0 : 1))}"#,
            #""extensionsOpen":[]"#, #""canSyncPriceLabs":false"#, #""refreshMinutes":60"#,
            #""appleAccountToken":"\#(UUID())""#
        ]
        if lastPlan {
            fields.append(#""lastPlan":{"tier":"growth","endedOn":"\#(date.string(from: ended))","reason":"ended"}"#)
        }
        if !locked.isEmpty {
            let ids = locked.map { "\"\($0.uuidString)\"" }.joined(separator: ",")
            fields.append(#""locked":{"groupIDs":[\#(ids)],"people":[],"houseIDs":[]}"#)
        }
        if let open {
            let changed = groupChangedAt.map { "\"\(date.string(from: $0))\"" } ?? "null"
            fields.append(#""open":{"groupID":"\#(open.uuidString)","person":null,"houseIDs":[],"groupChangedAt":\#(changed)}"#)
        }
        return "{" + fields.joined(separator: ",") + "}"
    }

    /// Whole, never half written: the app may read it at any moment.
    private static func write(_ json: String, to file: URL) throws {
        let temporary = file.deletingLastPathComponent().appendingPathComponent("plan-\(UUID()).json")
        try Data(json.utf8).write(to: temporary)
        if FileManager.default.fileExists(atPath: file.path) {
            _ = try FileManager.default.replaceItemAt(file, withItemAt: temporary)
        } else {
            try FileManager.default.moveItem(at: temporary, to: file)
        }
    }

    private static func day(in days: Int) -> Date {
        Calendar.current.date(byAdding: .day, value: days, to: Date())!
    }

    private static func stamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: Date())
    }
}
