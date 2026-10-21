import Foundation
import UIKit
import XCTest
import WellSpentAppCore
import WellSpentCrypto
import WellSpentModel
import WellSpentSync

/// What a new account brings with it, on a phone: the sample groups stay out
/// unless they were changed, a group made before signing up comes along, the
/// samples come only once. And joining with an account made from the
/// invitation itself, a manager's view of the group's page, and a link
/// someone else already used.
///
/// Each new account has a fresh address at example.com, its codes from
/// staging's test mailbox (StagingMailbox.swift). The fixed accounts stand in
/// for Robin and Sam, with no window (SecondAccountSteps.swift). Needs the
/// mailbox token and the four WELLSPENT_UI_TEST_ variables, and skips without
/// them. Runs in light only, under the shared sign-in lock.
final class PhoneNewAccountTests: XCTestCase {
    nonisolated(unsafe) private static var dataRootPath: String?

    static let password = "a-long-password-1"

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    /// No await in it, as in PhoneSignInSyncTests.
    override func tearDown() {
        let app = XCUIApplication()
        if app.state != .notRunning { app.terminate() }
        if let path = Self.dataRootPath { try? FileManager.default.removeItem(atPath: path) }
        Self.dataRootPath = nil
        UIPasteboard.general.items = []
        super.tearDown()
    }

    @MainActor
    private func freshInstall() -> PhoneTestApp {
        let run = PhoneTestApp()
        Self.dataRootPath = run.dataRoot.path
        run.launch()
        XCTAssertTrue(run.element(AccessibilityID.sidebarGroup("Household")).waitForExistence(timeout: 10), "no samples")
        return run
    }

    // MARK: - The samples and a new account

    @MainActor
    func testSamplesNobodyChangedStayOutOfANewAccount() async throws {
        let mailbox = try StagingMailbox.fromEnvironment()
        let address = StagingMailbox.freshAddress("iphone", for: "robin")
        let run = freshInstall()

        // Scenario SAMP-02
        // 1. Robin only looks at the samples: opens a budget, hides and shows
        // a group's budgets. His new account starts with no groups, and the
        // samples never reach the server.
        run.openBudget(named: "Groceries")
        run.goBack()
        run.tap(AccessibilityID.sidebarGroupToggle("Household"))
        run.tap(AccessibilityID.sidebarGroupToggle("Household"))
        run.makeAccount(address, password: Self.password, server: mailbox.server)
        XCTAssertTrue(run.text(MainScreen.Words.noBudgetsTitle).waitForExistence(timeout: 20),
                      "the new account does not start empty. On screen: \(run.visibleTexts())")
        XCTAssertTrue(run.text(MainScreen.Words.noBudgetsText).exists)
        XCTAssertFalse(run.element(AccessibilityID.sidebarGroup("Household")).exists, "a sample came into the account")
        run.syncAndWait()
        let otherDevice = try SecondAccount(server: mailbox.server, settingsSuite: "app.wellspent.uitest.robin")
        try await otherDevice.signIn(email: address, password: Self.password)
        XCTAssertTrue(AppModel(store: otherDevice.sync.store).groups.isEmpty, "a sample reached the server")
        await otherDevice.cleanUp()
        run.signOut()
    }

    @MainActor
    func testAGroupMadeBeforeSigningUpComesAlongAndTheSamplesDoNot() async throws {
        let mailbox = try StagingMailbox.fromEnvironment()
        let address = StagingMailbox.freshAddress("iphone", for: "robin")
        let run = freshInstall()

        // Scenario SAMP-03
        // 1. Road trip, with Fuel and Gas station, made before signing up,
        // is the only group in the new account, and reaches his other
        // devices.
        run.addGroup(named: "Road trip")
        run.addBudget(named: "Fuel", amount: "300", inGroup: "Road trip")
        run.addEntry(merchant: "Gas station", amount: "40.00")
        run.goBack()
        run.makeAccount(address, password: Self.password, server: mailbox.server)
        XCTAssertTrue(run.element(AccessibilityID.sidebarGroup("Road trip")).waitForExistence(timeout: 20), "Road trip did not come along")
        for sample in ["Household", "Side Business"] {
            XCTAssertFalse(run.element(AccessibilityID.sidebarGroup(sample)).exists, "\(sample) came along")
        }
        run.openBudget(named: "Fuel")
        XCTAssertTrue(run.element(AccessibilityID.entryRow("Gas station")).waitForExistence(timeout: 10), "Gas station did not come along")
        run.goBack()
        run.syncAndWait()
        let otherDevice = try SecondAccount(server: mailbox.server, settingsSuite: "app.wellspent.uitest.robin")
        try await otherDevice.signIn(email: address, password: Self.password)
        let arrived = try await otherDevice.waitFor(group: "Road trip", budget: "Fuel", merchant: "Gas station")
        XCTAssertTrue(arrived, "Road trip did not reach his other device")
        XCTAssertEqual(AppModel(store: otherDevice.sync.store).groups.map(\.name), ["Road trip"])
        await otherDevice.cleanUp()
        run.signOut()
    }

    @MainActor
    func testASampleGivenAnEntryComesAlongAndAnUnchangedOneStaysOut() async throws {
        let mailbox = try StagingMailbox.fromEnvironment()
        let address = StagingMailbox.freshAddress("iphone", for: "robin")
        let run = freshInstall()

        // Scenario SAMP-04
        // 1. Farmers market added to the sample Groceries: Household comes
        // along with its three budgets, its samples and Farmers market, and
        // syncs. Side Business, untouched, stays out.
        run.openBudget(named: "Groceries")
        run.addEntry(merchant: "Farmers market", amount: "18.00")
        run.goBack()
        run.makeAccount(address, password: Self.password, server: mailbox.server)
        XCTAssertTrue(run.element(AccessibilityID.sidebarGroup("Household")).waitForExistence(timeout: 20), "Household did not come along")
        for budget in ["Groceries", "Eating out", "Utilities"] {
            XCTAssertTrue(run.scrollTo(AccessibilityID.sidebarBudget(budget)).exists, "\(budget) did not come along")
        }
        XCTAssertFalse(run.element(AccessibilityID.sidebarGroup("Side Business")).exists, "Side Business came along")
        run.openBudget(named: "Groceries")
        XCTAssertTrue(run.element(AccessibilityID.entryRow("Farmers market")).waitForExistence(timeout: 10), "Farmers market is missing")
        run.goBack()
        run.syncAndWait()
        let otherDevice = try SecondAccount(server: mailbox.server, settingsSuite: "app.wellspent.uitest.robin")
        try await otherDevice.signIn(email: address, password: Self.password)
        let arrived = try await otherDevice.waitFor(group: "Household", budget: "Groceries", merchant: "Farmers market")
        XCTAssertTrue(arrived, "Household did not reach his other device")
        XCTAssertEqual(AppModel(store: otherDevice.sync.store).groups.map(\.name), ["Household"])
        await otherDevice.cleanUp()
        run.signOut()
    }

    @MainActor
    func testASampleRenamedComesAlongUnderItsNewName() async throws {
        let mailbox = try StagingMailbox.fromEnvironment()
        let address = StagingMailbox.freshAddress("iphone", for: "robin")
        let run = freshInstall()

        // Scenario SAMP-05
        // 1. Side Business renamed Pottery comes along with Materials, and
        // Household, untouched, stays out.
        run.longPress(AccessibilityID.sidebarGroup("Side Business"))
        run.tapMenuItem(MainScreen.Words.rename)
        run.type("Pottery", into: AccessibilityID.groupEditorName)
        run.tap(AccessibilityID.groupEditorSave)
        XCTAssertTrue(run.element(AccessibilityID.sidebarGroup("Pottery")).waitForExistence(timeout: 10), "no Pottery")
        run.makeAccount(address, password: Self.password, server: mailbox.server)
        XCTAssertTrue(run.element(AccessibilityID.sidebarGroup("Pottery")).waitForExistence(timeout: 20), "Pottery did not come along")
        XCTAssertTrue(run.element(AccessibilityID.sidebarBudget("Materials")).exists, "Materials did not come along")
        XCTAssertFalse(run.element(AccessibilityID.sidebarGroup("Household")).exists, "Household came along")
        run.syncAndWait()
        run.signOut()
    }

    @MainActor
    func testTheSamplesComeOnlyOnce() async throws {
        let mailbox = try StagingMailbox.fromEnvironment()
        let run = freshInstall()

        // Scenario SAMP-07
        // 1. After an account was made on this phone and signed out, the list
        // is empty and says so, and stays so after WellSpent is quit and
        // opened again. An account Leslie then makes here starts empty too.
        run.makeAccount(StagingMailbox.freshAddress("iphone", for: "robin"), password: Self.password, server: mailbox.server)
        run.signOut()
        XCTAssertTrue(run.text(MainScreen.Words.noBudgetsTitle).waitForExistence(timeout: 10),
                      "the samples came back after signing out. On screen: \(run.visibleTexts())")
        XCTAssertFalse(run.element(AccessibilityID.sidebarGroup("Household")).exists, "Household came back")
        run.app.terminate()
        run.launch()
        XCTAssertTrue(run.text(MainScreen.Words.noBudgetsTitle).waitForExistence(timeout: 10),
                      "the samples came back after quitting. On screen: \(run.visibleTexts())")
        run.makeAccount(StagingMailbox.freshAddress("iphone", for: "leslie"), password: Self.password, server: mailbox.server)
        XCTAssertTrue(run.text(MainScreen.Words.noBudgetsTitle).waitForExistence(timeout: 20),
                      "Leslie's new account does not start empty. On screen: \(run.visibleTexts())")
        run.signOut()
    }

    // MARK: - Joining with a new account

    @MainActor
    func testJoiningWithAnAccountMadeOnTheInvitationAndUsedLinks() async throws {
        let accounts = try TestAccounts.fromEnvironment()
        let mailbox = try StagingMailbox.fromEnvironment()
        let robin = try SecondAccount(server: accounts.server)
        let sam = try SecondAccount(server: accounts.server, settingsSuite: "app.wellspent.uitest.sam")
        let address = StagingMailbox.freshAddress("iphone", for: "leslie")
        let stamp = PhoneTestApp.stamp()
        let groupName = SecondAccount.phoneRunPrefix + stamp
        let usedGroup = groupName + " Used"
        try await robin.signIn(email: accounts.email, password: accounts.password)
        await robin.deleteLeftoverRuns()
        let link = try await robin.shareNewGroup(groupName, budget: "Costs \(stamp)", entry: "Costco",
                                                 amount: Money(minorUnits: 9900), myName: "Robin", role: .manage)
        let run = PhoneTestApp()
        Self.dataRootPath = run.dataRoot.path
        run.launch()

        // Scenario CLICK-06, CLICK-07
        // 1. Leslie, with no account, taps Robin's link and types her name.
        // Sign in, then Create an account, makes one, left unconfirmed. The
        // page is still up, and asks her to confirm her email first, with
        // Confirm your email in place of Join.
        run.open(link: link.url)
        XCTAssertTrue(run.text("Robin invited you to \u{201C}\(groupName)\u{201D}.").waitForExistence(timeout: 15), "no invitation")
        run.type("Leslie", into: AccessibilityID.invitationName)
        run.tap(AccessibilityID.invitationSignIn)
        run.makeAccount(address, password: Self.password, server: mailbox.server, fromHome: false)
        XCTAssertTrue(run.text(JoinScreen.Words.confirmToJoin).waitForExistence(timeout: 20),
                      "the page does not ask to confirm first. On screen: \(run.visibleTexts())")
        XCTAssertFalse(run.element(AccessibilityID.invitationJoin).exists, "Join before the email is confirmed")

        // Scenario CLICK-06, CLICK-07
        // 2. Confirm your email opens the account sheet, where the emailed
        // code confirms it. Back on the page, Join shows and is lit, her name
        // is still there, and Join takes her into the group.
        run.tap(AccessibilityID.invitationConfirmEmail)
        if run.element(AccessibilityID.accountConfirmEmail).waitForExistence(timeout: 5) {
            run.tap(AccessibilityID.accountConfirmEmail)
        }
        let code = try await mailbox.code(for: address)
        run.type(code, into: AccessibilityID.accountCode)
        run.tap(AccessibilityID.accountSubmit)
        XCTAssertTrue(run.text(AccountFlow.Words.confirmed).waitForExistence(timeout: 30), "the code did not confirm the email")
        run.tap(AccessibilityID.accountClose)
        let join = run.button(AccessibilityID.invitationJoin)
        XCTAssertTrue(join.waitForExistence(timeout: 15), "no Join once confirmed. On screen: \(run.visibleTexts())")
        XCTAssertEqual(run.fieldText(AccessibilityID.invitationName), "Leslie", "her name was lost")
        XCTAssertTrue(join.isEnabled, "Join is not lit")
        join.tap()
        let summary = run.element(AccessibilityID.groupSummary)
        XCTAssertTrue(summary.waitForExistence(timeout: 20), "Join did not take her in. On screen: \(run.visibleTexts())")

        // Scenario PAGE-11
        // 3. Sam joins at Add. On Leslie's page, as a manager, Sam's row
        // offers View and Add and Remove. Robin's and her own show levels
        // only. Invite Someone shows, and Leave Group is at the end.
        let groupID = try robin.group(named: groupName).id
        let samLink = try await robin.sync.share(group: groupID, groupName: groupName, level: .write, historyAccess: .all,
                                                 myName: "Robin")
        try await sam.signIn(email: accounts.secondEmail, password: accounts.secondPassword)
        _ = try await sam.join(samLink, as: "Sam")
        run.pullDown()
        let three = MembersScreen.Words.line([MembersScreen.Words.shared, MembersScreen.Words.peopleCount(3),
                                              MembersScreen.Words.madeBy("Robin")])
        XCTAssertTrue(run.wait(for: summary, until: "label == '\(three)'", timeout: 30), "Sam did not show: \(summary.label)")
        for row in ["Robin", "Leslie"] {
            XCTAssertNotEqual(run.element(AccessibilityID.groupPerson(row)).elementType, .button, "\(row)'s row opens a page")
        }
        XCTAssertTrue(run.element(AccessibilityID.groupInvite).exists, "no Invite Someone")
        XCTAssertTrue(run.element(AccessibilityID.groupLeave).exists, "no Leave Group")
        run.tap(AccessibilityID.groupPerson("Sam"))
        let levels = run.app.buttons
        for offered in [AccessLevel.read, .write] {
            let title = MembersScreen.Words.levelTitle(offered)
            XCTAssertTrue(levels.matching(NSPredicate(format: "label BEGINSWITH %@", title)).firstMatch.waitForExistence(timeout: 10),
                          "Sam's page does not offer \(title)")
        }
        for refused in [AccessLevel.manage, .admin] {
            let title = MembersScreen.Words.levelTitle(refused)
            XCTAssertFalse(levels.matching(NSPredicate(format: "label BEGINSWITH %@", title)).firstMatch.exists,
                           "a manager is offered \(title) for Sam")
        }
        XCTAssertTrue(run.element(AccessibilityID.groupRemove("Sam")).exists, "no Remove for Sam")
        run.goBack()
        run.goBack()

        // Scenario CLICK-09
        // 4. A link Sam already used still names who invited her, with no
        // level or history, and says the invite was not found. Join says it
        // was already accepted, and adds nothing.
        let used = try await robin.shareNewGroup(usedGroup, budget: "Used \(stamp)", entry: "Costco",
                                                 amount: Money(minorUnits: 9900), myName: "Robin", role: .add)
        _ = try await sam.join(used, as: "Sam")
        run.open(link: used.url)
        XCTAssertTrue(run.text("Robin invited you to \u{201C}\(usedGroup)\u{201D}.").waitForExistence(timeout: 15), "no invitation")
        XCTAssertTrue(run.text("That invite was not found. It may have been cancelled.").waitForExistence(timeout: 15),
                      "the page does not say the invite was not found. On screen: \(run.visibleTexts())")
        XCTAssertFalse(run.app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "You'd")).firstMatch.exists,
                       "a used link shows a level or history")
        run.type("Leslie", into: AccessibilityID.invitationName)
        run.tap(AccessibilityID.invitationJoin)
        XCTAssertTrue(run.text("That invite has already been accepted.").waitForExistence(timeout: 15),
                      "Join does not say the invite was accepted. On screen: \(run.visibleTexts())")
        run.goBack()
        XCTAssertFalse(run.element(AccessibilityID.sidebarGroup(usedGroup)).exists, "the used link added the group")

        // Scenario SHARE-10
        // 5. Pasted into Join a Group, the used link says the same, and adds
        // nothing.
        run.openAddMenu()
        run.tapMenuItem(MainScreen.Words.join)
        run.paste(used.url, into: AccessibilityID.joinLink)
        run.type("Leslie", into: AccessibilityID.joinName)
        run.tap(AccessibilityID.joinJoin)
        XCTAssertTrue(run.text("That invite has already been accepted.").waitForExistence(timeout: 15),
                      "Join a Group does not say the invite was accepted. On screen: \(run.visibleTexts())")
        run.tap(AccessibilityID.joinCancel)
        XCTAssertFalse(run.element(AccessibilityID.sidebarGroup(usedGroup)).exists, "the pasted used link added the group")

        // 6. Tidy.
        run.signOut()
        await robin.deleteGroup(named: groupName)
        await robin.deleteGroup(named: usedGroup)
        await sam.cleanUp()
        await robin.cleanUp()
    }
}
