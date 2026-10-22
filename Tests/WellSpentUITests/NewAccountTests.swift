import AppKit
import Foundation
import XCTest
import WellSpentAppCore
import WellSpentModel
import WellSpentSync

/// Making an account in the real window, and what comes into it. A sample
/// group nobody changed stays out, and one that was changed or renamed comes
/// along. A group made before signing up comes along, and the samples come
/// only once. An invitation page asks for the email to be confirmed before
/// Join, and stays up while its reader makes an account and confirms the email.
///
/// Each test starts on a fresh install and makes its accounts at new
/// example.com addresses (StagingMailbox.freshAddress), with a password made
/// in the run and never printed. Staging has no way to delete an account, so
/// each one stays there, and example.com is nobody's. The code staging emails
/// at sign-up is read back from its test mailbox when a step needs it, and no
/// test asks for another one. The second test account is only signed in to:
/// it makes the group and the link Robin sends. Someone's "other device" is a
/// coordinator with no window, signed in to the new account, the way
/// SecondAccount stands in for the second person.
///
/// SAMP-03 and SAMP-04 share one sign-up. SAMP-05 has one of its own, since
/// it checks that Household stays out when nobody changed it.
///
/// One run of the class makes 4 accounts, so staging sends 4 code emails, and
/// 2 of the codes are typed. It signs in 4 times with no window: twice to a
/// new account, and twice to the second test account. The window signs up
/// but never signs in.
///
/// Needs WELLSPENT_UI_TEST_MAILBOX_TOKEN, and skips without it. The two tests
/// with a link need the four WELLSPENT_UI_TEST_ variables too. tearDown signs
/// out of everything the test signed in to, deletes the link's group, closes
/// the app and removes the run's folder, whether the test passed or halted.
final class NewAccountTests: XCTestCase {
    /// What tearDown tidies, set as the test goes: the run's data folder, the
    /// window, everyone signed in with no window, and the second test
    /// account's group, if it made one.
    nonisolated(unsafe) private static var dataRootPath: String?
    nonisolated(unsafe) private static var window: TestApp?
    nonisolated(unsafe) private static var windowless: [SecondAccount] = []
    nonisolated(unsafe) private static var sharedGroup: (owner: SecondAccount, name: String)?

    /// Where a new account's other device keeps its settings, apart from the
    /// second test account's, since both can be signed in at once.
    private static let otherDeviceSuite = "app.wellspent.uitest.other-device"

    /// The sample group Household as a fresh install makes it: its budgets,
    /// each with its sample entries by merchant, as SAMP-01 lists them.
    private static let household: [String: Set<String>] = [
        "Groceries": ["Hilltop Grocery", "Costco", "Sunny's"],
        "Eating out": ["Sunrise Cafe", "Riverside Grill"],
        "Utilities": ["Regional Power"],
    ]

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    /// Runs after each test, passed or halted. The window signs out through
    /// its own Account button, if it can be reached. The second test account
    /// deletes its group, and every session with no window ends. The app is
    /// closed, and nothing of the run stays on this Mac, the clipboard
    /// included. A step that goes wrong here does not stop the rest.
    override func tearDown() {
        continueAfterFailure = true
        // XCTest calls tearDown on the main thread, where the window's steps
        // must run.
        if Thread.isMainThread {
            MainActor.assumeIsolated {
                Self.signOutOfEverything()
                let app = XCUIApplication()
                if app.state != .notRunning { app.terminate() }
            }
        }
        TestApp.wipeSettings()
        if let path = Self.dataRootPath { try? FileManager.default.removeItem(atPath: path) }
        Self.dataRootPath = nil
        NSPasteboard.general.clearContents()
        super.tearDown()
    }

    // MARK: - Only looking, and the samples come only once

    @MainActor
    func testSamplesOnlyLookedAtStayOutAndComeOnlyOnce() async throws {
        let mailbox = try StagingMailbox.fromEnvironment()
        let accounts = try TestAccounts.fromEnvironment()
        let run = try start()
        let robin = StagingMailbox.freshAddress("mac", for: "robin")
        let leslie = StagingMailbox.freshAddress("mac", for: "leslie")
        let robinsPassword = Self.newPassword(), lesliesPassword = Self.newPassword()

        // 1. A fresh install, with the two sample groups.
        run.expectTheSamples()

        // 2. Robin only looks at them: he opens each of their budgets, and
        // hides and shows each group's budgets.
        run.lookAtTheSamples()

        // 3. He creates an account, and leaves the code for later.
        run.click(AccessibilityID.sidebarSignIn)
        try run.createAccount(email: robin, password: robinsPassword, server: mailbox.server)
        run.closeAccountSheet()

        // Scenario SAMP-02
        // 4. His account starts with no groups: the list is empty, and the
        // right side says how to start.
        run.expectNoBudgets("Robin's new account")

        // 5. In his account, he makes a group with a budget, which opens.
        run.addGroup(named: "Holiday")
        run.addBudget(named: "Flights", amount: "800", inGroup: "Holiday")

        // Scenario SAMP-02
        // 6. His other device, signed in to the account, gets Holiday, so it
        // has what the window sent after signing up. It has no sample group.
        let robinsOtherDevice = try Self.otherDevice(server: mailbox.server)
        try await robinsOtherDevice.signIn(email: robin, password: robinsPassword)
        let held = try await robinsOtherDevice.waitForHoldings { (held: SecondAccount.Holdings) -> Bool in
            held["Holiday"]?["Flights"] != nil
        }
        let holiday: SecondAccount.Holdings = ["Holiday": ["Flights": []]]
        XCTAssertEqual(held, holiday, "his other device should hold Holiday and nothing else")

        // Scenario SAMP-07
        // 7. He signs out. The list is empty, and the right side says No
        // budgets yet.
        run.signOut()
        XCTAssertTrue(run.listText(SyncWording.footer(signedIn: false)).waitForExistence(timeout: 30),
                      "Sign out did not sign him out. On screen: \(run.visibleTexts())")
        run.expectNoBudgets("signed out")

        // Scenario SAMP-07
        // 8. The samples do not come back, even after WellSpent is quit and
        // opened again.
        run.quitAndOpenAgain()
        run.expectNoBudgets("quit and opened again")

        // Scenario SAMP-07
        // 9. An account Leslie then makes on this computer starts empty too.
        // Her code is read at once, before anything else emails her address,
        // and she leaves it for later.
        run.click(AccessibilityID.sidebarSignIn)
        try run.createAccount(email: leslie, password: lesliesPassword, server: mailbox.server)
        let code = try await mailbox.code(for: leslie, timeout: 30)
        run.closeAccountSheet()
        run.expectNoBudgets("Leslie's new account")

        // 10. Robin's link: the second test account, with no window, makes a
        // group and a link to it at Add, as Robin.
        let (link, invited) = try await Self.robinsLink(accounts)

        // Scenario CLICK-06
        // 11. Leslie, signed in with her email not confirmed yet, clicks it.
        // The page asks her to confirm her email first, with Confirm your
        // email… in place of Join.
        try run.click(link: link.url)
        XCTAssertTrue(run.listText(invited).waitForExistence(timeout: 30),
                      "no invitation page. On screen: \(run.visibleTexts())")
        XCTAssertTrue(run.listText(JoinScreen.Words.confirmToJoin).waitForExistence(timeout: 30),
                      "the page does not ask her to confirm her email first. On screen: \(run.visibleTexts())")
        let confirm = run.element(AccessibilityID.invitationConfirmEmail)
        XCTAssertTrue(run.wait(for: confirm, says: JoinScreen.Words.confirmEmail, timeout: 30),
                      "no \(JoinScreen.Words.confirmEmail) on the page: \(confirm.exists ? confirm.title : "no button")")
        XCTAssertFalse(run.element(AccessibilityID.invitationJoin).exists, "Join, with her email not confirmed")

        // Scenario CLICK-06
        // 12. Confirm your email… opens the account sheet, where she can
        // confirm it. Once she has, with the code from her email, the page
        // shows Join.
        run.click(AccessibilityID.invitationConfirmEmail)
        XCTAssertTrue(run.element(AccessibilityID.accountConfirmEmail).waitForExistence(timeout: 30),
                      "no account sheet with a way to confirm her email. On screen: \(run.visibleTexts())")
        run.click(AccessibilityID.accountConfirmEmail)
        run.confirmEmail(with: code)
        XCTAssertTrue(run.element(AccessibilityID.invitationJoin).waitForExistence(timeout: 30),
                      "no Join once her email is confirmed. On screen: \(run.visibleTexts())")
        XCTAssertTrue(run.wait(for: run.listText(JoinScreen.Words.confirmToJoin), until: "exists == false",
                               timeout: 30), "the page still asks her to confirm her email")
        XCTAssertTrue(run.listText(invited).exists, "the invitation page did not stay")
    }

    // MARK: - Groups made or changed before signing up, and an invitation kept

    @MainActor
    func testGroupsMadeOrChangedBeforeSigningUpComeAlongAndTheInvitationStays() async throws {
        let mailbox = try StagingMailbox.fromEnvironment()
        let accounts = try TestAccounts.fromEnvironment()
        let run = try start()
        let leslie = StagingMailbox.freshAddress("mac", for: "leslie")
        let password = Self.newPassword()

        // 1. A fresh install, with the two sample groups.
        run.expectTheSamples()

        // 2. Before she has an account, Leslie makes a group, Road trip, with
        // a budget, Fuel, and an entry in it, Gas station.
        run.addGroup(named: "Road trip")
        run.addBudget(named: "Fuel", amount: "300", inGroup: "Road trip")
        run.addEntry(merchant: "Gas station", amount: "45.00")

        // 3. She adds Farmers market to the sample budget Groceries. A budget
        // lists this month's entries only, so which sample entries show
        // depends on the day. Those that show are noted.
        run.openBudget(named: "Groceries")
        run.addEntry(merchant: "Farmers market", amount: "18.00")
        let shown: Set<String> = Self.household["Groceries", default: []].filter { run.listText($0).exists }

        // 4. Robin's link: the second test account, with no window, makes a
        // group and a link to it at Add, as Robin.
        let (link, invited) = try await Self.robinsLink(accounts)

        // 5. Leslie clicks it, and types Leslie in Your name.
        try run.click(link: link.url)
        XCTAssertTrue(run.listText(invited).waitForExistence(timeout: 30),
                      "no invitation page. On screen: \(run.visibleTexts())")
        run.type("Leslie", into: AccessibilityID.invitationName)

        // 6. Sign in… opens the account sheet. She creates an account
        // there, and confirms her email with the code sent to it.
        run.click(AccessibilityID.invitationSignIn)
        try run.createAccount(email: leslie, password: password, server: mailbox.server)
        run.confirmEmail(with: try await mailbox.code(for: leslie, timeout: 30))

        // Scenario CLICK-07
        // 7. The invitation page is still up, with Leslie still in Your name,
        // and Join is lit.
        XCTAssertTrue(run.listText(invited).waitForExistence(timeout: 30),
                      "the invitation page did not stay. On screen: \(run.visibleTexts())")
        let name = run.element(AccessibilityID.invitationName)
        XCTAssertTrue(run.wait(for: name, holds: "Leslie", timeout: 30),
                      "Your name does not hold Leslie: \(run.text(of: name))")
        XCTAssertTrue(run.element(AccessibilityID.invitationJoin).waitForExistence(timeout: 30),
                      "no Join once her email is confirmed. On screen: \(run.visibleTexts())")
        run.expect(AccessibilityID.invitationJoin, enabled: true, "Join, once her email is confirmed")

        // Scenario SAMP-03, SAMP-04
        // 8. The list holds Road trip, with its budget, and Household, which
        // she changed, with its three budgets. Side Business, which she did
        // not change, stays out.
        let budgets: Set<String> = Set(Self.household.keys).union(["Fuel"])
        run.expectList(groups: ["Road trip", "Household"], budgets: budgets, "her new account")

        // Scenario CLICK-07
        // 9. Join takes her into Robin's group: it is in the list, and its
        // page opens in place of the invitation.
        run.click(AccessibilityID.invitationJoin)
        let summary = MembersScreen.Words.line([MembersScreen.Words.shared, MembersScreen.Words.peopleCount(2),
                                                MembersScreen.Words.madeBy("Robin")])
        XCTAssertTrue(run.wait(for: run.element(AccessibilityID.groupSummary), holds: summary, timeout: 60),
                      "the group's page did not open with \(summary). On screen: \(run.visibleTexts())")
        XCTAssertTrue(run.element(AccessibilityID.sidebarGroup(link.groupName)).exists, "the group is not in the list")
        XCTAssertFalse(run.listText(invited).exists, "the invitation page is still up")

        // Scenario SAMP-03
        // 10. Road trip's entry came along too: Fuel lists Gas station.
        run.openBudget(named: "Fuel")
        XCTAssertTrue(run.entryRow("Gas station").waitForExistence(timeout: 30),
                      "Gas station did not come along. On screen: \(run.visibleTexts())")

        // Scenario SAMP-04
        // 11. All of Household came along: Groceries lists Farmers market,
        // and the sample entries it listed before.
        run.openBudget(named: "Groceries")
        for merchant in shown.sorted() + ["Farmers market"] {
            XCTAssertTrue(run.entryRow(merchant).waitForExistence(timeout: 30),
                          "\(merchant) did not come along. On screen: \(run.visibleTexts())")
        }

        // Scenario SAMP-03, SAMP-04
        // 12. Both sync to her account: her other device gets Road trip and
        // Household, each with every budget and entry, and no Side Business.
        let otherDevice = try Self.otherDevice(server: mailbox.server)
        try await otherDevice.signIn(email: leslie, password: password)
        let held = try await otherDevice.waitForHoldings { (held: SecondAccount.Holdings) -> Bool in
            let roadTrip: Bool = held["Road trip"]?["Fuel"]?.contains("Gas station") == true
            let household: Bool = held["Household"]?["Groceries"]?.contains("Farmers market") == true
            return roadTrip && household
        }
        var household: [String: Set<String>] = Self.household
        household["Groceries", default: []].insert("Farmers market")
        let roadTrip: [String: Set<String>] = ["Fuel": ["Gas station"]]
        XCTAssertEqual(held["Road trip"], roadTrip, "Road trip did not reach her other device whole")
        XCTAssertEqual(held["Household"], household, "Household did not reach her other device whole")
        XCTAssertNil(held["Side Business"], "Side Business reached her other device")
    }

    // MARK: - A sample renamed

    @MainActor
    func testARenamedSampleComesAlongUnderItsNewName() throws {
        let mailbox = try StagingMailbox.fromEnvironment()
        let run = try start()

        // 1. A fresh install, with the two sample groups.
        run.expectTheSamples()

        // 2. Robin renames Side Business to Pottery.
        run.renameGroup("Side Business", to: "Pottery")

        // 3. He creates an account, and leaves the code for later.
        run.click(AccessibilityID.sidebarSignIn)
        try run.createAccount(email: StagingMailbox.freshAddress("mac", for: "robin"), password: Self.newPassword(),
                              server: mailbox.server)
        run.closeAccountSheet()

        // Scenario SAMP-05
        // 4. The list holds Pottery, with its budget Materials. Household,
        // which he did not change, stays out.
        run.expectList(groups: ["Pottery"], budgets: ["Materials"], "his new account")
    }

    // MARK: - Setting up and tidying

    /// Launches a fresh install, with a data folder of its own, and keeps it
    /// for tearDown.
    @MainActor
    private func start() throws -> TestApp {
        let run = try TestApp()
        Self.dataRootPath = run.dataRoot.path
        Self.window = run
        run.launch()
        return run
    }

    /// A password made in the run: a UUID's 36 characters, with a capital, a
    /// small letter, a figure and a sign after them. Never printed.
    private static func newPassword() -> String {
        UUID().uuidString + "Aa1!"
    }

    /// A new account's other device, with no window, not signed in yet.
    /// tearDown signs it out.
    @MainActor
    private static func otherDevice(server: String) throws -> SecondAccount {
        let device = try SecondAccount(server: server, settingsSuite: otherDeviceSuite)
        windowless.append(device)
        return device
    }

    /// The second test account, with no window, makes a group of this run's
    /// own with a budget and an entry, and a link to it at Add, signed as
    /// Robin. Returns the link, and what its invitation page says first, in
    /// the shared code's words. tearDown deletes the group.
    @MainActor
    private static func robinsLink(_ accounts: TestAccounts) async throws -> (link: InviteLink, invited: String) {
        let second = try SecondAccount(server: accounts.server)
        windowless.append(second)
        try await second.signIn(email: accounts.secondEmail, password: accounts.secondPassword)
        let name = "UI Join \(stamp())"
        sharedGroup = (second, name)
        let link = try await second.shareNewGroup(name, budget: "Bulk", entry: "Costco",
                                                  amount: Money(minorUnits: 2863), myName: "Robin", role: .add)
        let invited = try XCTUnwrap(JoinScreen(actions: second.sync, linkText: link.url).invitation,
                                    "the link does not read as an invite")
        return (link, invited)
    }

    /// Signs the window out through its Account button, then deletes the
    /// second test account's group and signs out every session with no
    /// window. Best effort, and bounded, so a slow server cannot hold the run.
    @MainActor
    private static func signOutOfEverything() {
        if let run = window, run.app.state == .runningForeground {
            // A sheet left up by a halted step is closed first.
            if run.app.sheets.count > 0 { run.app.typeKey(.escape, modifierFlags: []) }
            run.signOut()
        }
        window = nil
        let group = sharedGroup, devices = windowless
        sharedGroup = nil
        windowless = []
        guard group != nil || !devices.isEmpty else { return }
        let done = XCTestExpectation(description: "the sessions with no window end")
        Task { @MainActor in
            if let group { await group.owner.deleteGroup(named: group.name) }
            for device in devices { await device.cleanUp() }
            done.fulfill()
        }
        _ = XCTWaiter().wait(for: [done], timeout: 60)
    }

    /// Part of the group's name, so runs never share one.
    private static func stamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: Date())
    }
}

// MARK: - Steps these tests take

private extension TestApp {
    /// A fresh install shows the two sample groups. Each test starts here,
    /// so this checks only that they are there.
    func expectTheSamples(file: StaticString = #filePath, line: UInt = #line) {
        for group in ["Household", "Side Business"] {
            XCTAssertTrue(element(AccessibilityID.sidebarGroup(group)).waitForExistence(timeout: 30),
                          "no sample group \(group) on a fresh install. The list: \(sidebarIdentifiers())",
                          file: file, line: line)
        }
    }

    /// Looks at the samples and changes nothing: opens each of their
    /// budgets, and hides and shows each group's budgets with the arrow at
    /// the end of its line. A budget's line counts as more than one element,
    /// so the counts are compared with the count before the arrow.
    func lookAtTheSamples(file: StaticString = #filePath, line: UInt = #line) {
        for budget in ["Groceries", "Eating out", "Utilities", "Materials"] {
            openBudget(named: budget)
            XCTAssertTrue(element(AccessibilityID.budgetAdd).waitForExistence(timeout: 30),
                          "\(budget) did not open. On screen: \(visibleTexts())", file: file, line: line)
        }
        for (group, budget) in [("Household", "Groceries"), ("Side Business", "Materials")] {
            let shown: Int = sidebarBudgetCount(budget)
            XCTAssertGreaterThan(shown, 0, "\(budget) is not in the list. The list: \(sidebarIdentifiers())",
                                 file: file, line: line)
            clickGroupArrow(group)
            XCTAssertTrue(wait(forBudgetRows: budget, timeout: 30) { $0 < shown },
                          "the arrow did not hide \(group)'s budgets. The list: \(sidebarIdentifiers())",
                          file: file, line: line)
            clickGroupArrow(group)
            XCTAssertTrue(wait(forBudgetRows: budget, timeout: 30) { $0 == shown },
                          "the arrow did not show \(group)'s budgets again. The list: \(sidebarIdentifiers())",
                          file: file, line: line)
        }
    }

    /// Creates an account on the account sheet, from the step it opens on:
    /// Create an account, then the address, the password twice and the
    /// server, and Create account. Returns once the sheet asks for the code
    /// it emailed. A refusal fails with the sheet's words.
    func createAccount(email: String, password: String, server: String) throws {
        click(AccessibilityID.accountCreateAccount)
        let confirmation = element(AccessibilityID.accountConfirmation)
        guard confirmation.waitForExistence(timeout: 30) else {
            throw UITestError("the sheet did not move on to creating an account. On screen: \(visibleTexts())")
        }
        if (element(AccessibilityID.accountServer).value as? String) != server {
            type(server, into: AccessibilityID.accountServer)
        }
        pasteAndCheck(email, into: AccessibilityID.accountEmail)
        paste(password, into: AccessibilityID.accountPassword)
        paste(password, into: AccessibilityID.accountConfirmation)
        expect(AccessibilityID.accountSubmit, enabled: true, "Create account, with every field filled")
        click(AccessibilityID.accountSubmit)
        guard element(AccessibilityID.accountCode).waitForExistence(timeout: 60) else {
            let limited = AccountWording.words(for: ReadableTransportError.http(status: 429, reason: ""))
            if app.staticTexts[limited].exists {
                throw UITestError("staging turned the new account down: \(limited)")
            }
            throw UITestError("no account was made. On screen: \(visibleTexts())")
        }
    }

    /// The code, as the email shows it, on the step that asks for it, then
    /// Confirm. The sheet says the email is confirmed, and Done closes it.
    func confirmEmail(with code: String, file: StaticString = #filePath, line: UInt = #line) {
        pasteAndCheck(code, into: AccessibilityID.accountCode, file: file, line: line)
        click(AccessibilityID.accountSubmit)
        XCTAssertTrue(app.staticTexts[AccountFlow.Words.confirmed].waitForExistence(timeout: 30),
                      "the sheet does not say the email is confirmed. On screen: \(visibleTexts())",
                      file: file, line: line)
        click(AccessibilityID.accountClose)
        XCTAssertTrue(wait(for: element(AccessibilityID.accountClose), until: "exists == false", timeout: 30),
                      "Done did not close the sheet", file: file, line: line)
    }

    /// Not now, on the step that asks for the code. The sheet closes, and
    /// the person stays signed in, with the email not confirmed yet.
    func closeAccountSheet(file: StaticString = #filePath, line: UInt = #line) {
        click(AccessibilityID.accountClose)
        XCTAssertTrue(wait(for: element(AccessibilityID.accountCode), until: "exists == false", timeout: 30),
                      "Not now did not close the sheet. On screen: \(visibleTexts())", file: file, line: line)
    }

    /// The names in the sidebar's list now: its groups' and its budgets'.
    /// Read from one snapshot, by the identifiers the list gives them. Nil
    /// when the window cannot be read, so that is never taken for an empty
    /// list.
    func sidebarList() -> (groups: Set<String>, budgets: Set<String>)? {
        let groupPrefix = AccessibilityID.sidebarGroup(""), budgetPrefix = AccessibilityID.sidebarBudget("")
        var groups: Set<String> = [], budgets: Set<String> = []
        guard let root = try? app.snapshot() else { return nil }
        func walk(_ node: XCUIElementSnapshot) {
            if node.identifier.hasPrefix(groupPrefix) {
                groups.insert(String(node.identifier.dropFirst(groupPrefix.count)))
            } else if node.identifier.hasPrefix(budgetPrefix) {
                budgets.insert(String(node.identifier.dropFirst(budgetPrefix.count)))
            }
            node.children.forEach(walk)
        }
        walk(root)
        return (groups, budgets)
    }

    /// Waits until the sidebar's list holds exactly these groups and these
    /// budgets, and fails with what it holds when it does not.
    func expectList(groups: Set<String>, budgets: Set<String>, _ what: String,
                    file: StaticString = #filePath, line: UInt = #line) {
        let holds = NSPredicate { _, _ in
            guard let shown = self.sidebarList() else { return false }
            return shown.groups == groups && shown.budgets == budgets
        }
        let found = XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: holds, object: nil)], timeout: 30)
        guard found != .completed else { return }
        guard let shown = sidebarList() else {
            XCTFail("\(what): the window could not be read", file: file, line: line)
            return
        }
        XCTFail("\(what): the list holds the groups \(shown.groups.sorted()) and the budgets "
                + "\(shown.budgets.sorted()), not \(groups.sorted()) and \(budgets.sorted())", file: file, line: line)
    }

    /// The list is empty, and the right side says there are no budgets yet
    /// and what a budget is.
    func expectNoBudgets(_ what: String, file: StaticString = #filePath, line: UInt = #line) {
        expectList(groups: [], budgets: [], what, file: file, line: line)
        for words in [MainScreen.Words.noBudgetsTitle, MainScreen.Words.noBudgetsText] {
            XCTAssertTrue(listText(words).waitForExistence(timeout: 30),
                          "\(what): the right side does not say \(words) On screen: \(visibleTexts())",
                          file: file, line: line)
        }
    }

    /// Waits until an element shows these words. A Mac button gives its
    /// words as its title, a text as its value, so any of the three counts.
    func wait(for element: XCUIElement, says words: String, timeout: TimeInterval) -> Bool {
        let says = NSPredicate { candidate, _ in
            guard let element = candidate as? XCUIElement, element.exists else { return false }
            return element.title == words || element.label == words || (element.value as? String) == words
        }
        let expectation = XCTNSPredicateExpectation(predicate: says, object: element)
        return XCTWaiter().wait(for: [expectation], timeout: timeout) == .completed
    }

    /// Rename… from a group's menu, until the sheet that opens holds this
    /// group's name: a right-click that lands on the line beside it opens
    /// the other group's menu, which offers Rename… too. Such a sheet is
    /// cancelled and the menu tried again, twice. Then the new name, and Save.
    func renameGroup(_ name: String, to newName: String, file: StaticString = #filePath, line: UInt = #line) {
        let groupLine = AccessibilityID.sidebarGroup(name)
        let field = element(AccessibilityID.groupEditorName)
        var opened = false
        for _ in 0..<3 {
            openMenu(on: element(groupLine), groupLine, offering: MainScreen.Words.rename)
            clickMenuItem(MainScreen.Words.rename)
            XCTAssertTrue(field.waitForExistence(timeout: 30), "Rename\u{2026} opened no sheet", file: file, line: line)
            if wait(for: field, holds: name, timeout: 5) {
                opened = true
                break
            }
            click(AccessibilityID.groupEditorCancel)
            wait(for: field, until: "exists == false", timeout: 30)
        }
        XCTAssertTrue(opened, "Rename\u{2026} never opened \(name)'s sheet", file: file, line: line)
        type(newName, into: AccessibilityID.groupEditorName)
        click(AccessibilityID.groupEditorSave)
        XCTAssertTrue(element(AccessibilityID.sidebarGroup(newName)).waitForExistence(timeout: 30),
                      "\(newName) is not in the list. The list: \(sidebarIdentifiers())", file: file, line: line)
        XCTAssertTrue(wait(for: element(groupLine), until: "exists == false", timeout: 30),
                      "\(name) is still in the list", file: file, line: line)
    }

    /// Quits with Command-Q, as a person does, then opens the app again on
    /// the run's own folder.
    func quitAndOpenAgain(file: StaticString = #filePath, line: UInt = #line) {
        app.typeKey("q", modifierFlags: .command)
        XCTAssertTrue(app.wait(for: .notRunning, timeout: 30), "Command-Q did not quit the app", file: file, line: line)
        launch()
    }
}

private extension SecondAccount {
    /// What an account holds: each group by name, each of its budgets by
    /// name, and each budget's entries by merchant.
    typealias Holdings = [String: [String: Set<String>]]

    func holdings() throws -> Holdings {
        var held: Holdings = [:]
        for group in AppModel(store: sync.store).groups {
            var budgets: [String: Set<String>] = [:]
            for budget in try sync.store.budgets(in: group.id) {
                budgets[budget.name] = Set(try sync.store.transactions(in: budget.id).map(\.merchant))
            }
            held[group.name] = budgets
        }
        return held
    }

    /// Syncs until what the account holds passes `ready`, or the time runs
    /// out, and returns what it holds then. The window sends a change a
    /// moment after it is made, so the first sync can come too soon.
    func waitForHoldings(timeout: TimeInterval = 60, until ready: (Holdings) -> Bool) async throws -> Holdings {
        let deadline = Date().addingTimeInterval(timeout)
        var held = try holdings()
        while !ready(held), Date() < deadline {
            try await Task.sleep(for: .seconds(3))
            try await syncAll()
            held = try holdings()
        }
        return held
    }
}
