import AppKit
import Foundation
import XCTest
import WellSpentAppCore
import WellSpentCrypto
import WellSpentModel
import WellSpentSync

/// Email invitations in the real window, alongside legacy received links,
/// signed-out and unconfirmed-email refusals, leaving and local samples.
/// Each test starts with a fresh data folder. Account scenarios require the
/// WELLSPENT_UI_TEST_ fixtures and skip without them; the unconfirmed-account
/// scenario also needs the test mailbox token. Groups use timestamped names
/// and are deleted after a successful run.
final class SharingGapTests: XCTestCase {
    /// The run's data folder, for tearDown.
    nonisolated(unsafe) private static var dataRootPath: String?
    /// The sample groups a fresh install opens with, and their budgets.
    private static let sampleGroups = ["Household", "Side Business"]
    private static let sampleBudgets = ["Groceries", "Eating out", "Utilities", "Materials"]
    /// What the names of each person's groups start with, so a later run can
    /// find the ones a halted run left.
    fileprivate static let robinsPrefix = "UI Share "
    fileprivate static let lesliesPrefix = "UI Leave "
    fileprivate static let unconfirmedPrefix = "UI Unconfirmed "

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    /// Runs after each test, passed or halted, with no await in it, as in
    /// SignInBudgetShareSyncTests. The app is closed, and nothing of the run
    /// stays on this Mac, the clipboard included: the tests paste links.
    override func tearDown() {
        let app = XCUIApplication()
        if app.state != .notRunning { app.terminate() }
        TestApp.wipeSettings()
        if let path = Self.dataRootPath { try? FileManager.default.removeItem(atPath: path) }
        Self.dataRootPath = nil
        NSPasteboard.general.clearContents()
        super.tearDown()
    }

    // MARK: - Signed out

    @MainActor
    func testSignedOutShareMakesNoLinkAndJoinAddsNothing() throws {
        let run = try TestApp()
        Self.dataRootPath = run.dataRoot.path

        // 1. A fresh install, signed out, with Household kept on this
        // computer only.
        try run.launchAsFreshInstall()
        XCTAssertTrue(run.element(AccessibilityID.sidebarGroup("Household")).waitForExistence(timeout: 30),
                      "no sample Household. Sidebar: \(run.sidebarIdentifiers())")
        XCTAssertTrue(run.app.staticTexts[SyncWording.footer(signedIn: false)].exists,
                      "the foot does not say the budgets are kept on this computer. On screen: \(run.visibleTexts())")

        // Scenario SHARE-04
        // 2. Share… in Household's menu says to sign in first. Send Invite
        // stays dimmed, even with a name typed, and Cancel closes the sheet.
        run.openShare(of: "Household")
        XCTAssertTrue(run.app.staticTexts[ShareScreen.Words.signInToShare].exists,
                      "no notice to sign in first. On screen: \(run.visibleTexts())")
        run.expect(AccessibilityID.shareCreate, enabled: false, "Send Invite, signed out")
        run.type("Robin", into: AccessibilityID.shareName)
        XCTAssertTrue(run.wait(for: run.element(AccessibilityID.shareName), holds: "Robin", timeout: 30),
                      "the name did not go in")
        run.type("Leslie", into: AccessibilityID.shareInviteeName)
        run.type("person@example.com", into: AccessibilityID.shareEmail)
        run.expect(AccessibilityID.shareCreate, enabled: false, "Send Invite, signed out with all fields filled")
        run.click(AccessibilityID.shareCancel)
        XCTAssertTrue(run.wait(for: run.element(AccessibilityID.shareName), until: "exists == false", timeout: 10),
                      "the Share sheet did not close")

        // Scenario SHARE-09
        // 3. Robin's link, pasted into Join a Group…, says who sent it to
        // which group, and that joining needs a sign-in or an account. Join
        // stays dimmed, even with a name typed. The link is made here, of
        // this build's type: signed out, the sheet asks the server nothing.
        let secret = Data((0..<32).map { _ in UInt8.random(in: 0...255) })
        let link = InviteLink(secret: secret, groupName: "Household", inviterName: "Robin",
                              scheme: AppEnvironment.staging.inviteScheme)
        let invitation = try XCTUnwrap(Self.invitation(in: link), "the shared Join screen does not read the link")
        run.openJoin()
        run.paste(link.url, into: AccessibilityID.joinLink)
        XCTAssertTrue(run.app.staticTexts[invitation].waitForExistence(timeout: 30),
                      "the sheet does not read the link. On screen: \(run.visibleTexts())")
        XCTAssertTrue(run.app.staticTexts[JoinScreen.Words.signInToJoin].exists,
                      "no notice to sign in or make an account first. On screen: \(run.visibleTexts())")
        run.type("Leslie", into: AccessibilityID.joinName)
        run.expect(AccessibilityID.joinJoin, enabled: false, "Join, signed out with a name typed")
        run.cancelJoin()
    }

    // MARK: - Signed in, the email not confirmed

    @MainActor
    func testJoiningBeforeTheEmailIsConfirmedAddsNothing() async throws {
        let mailbox = try StagingMailbox.fromEnvironment()
        let accounts = try TestAccounts.fromEnvironment()
        let run = try TestApp()
        Self.dataRootPath = run.dataRoot.path
        let robin = try SecondAccount(server: mailbox.server)
        let robinsGroup = Self.unconfirmedPrefix + Self.stamp()
        let address = StagingMailbox.freshAddress("mac", for: "leslie")
        let password = UUID().uuidString + "Aa1!"
        let refused = AccountWording.words(for: SyncCoordinator.Failure.emailNotConfirmed)

        // 1. Robin, with no window, makes a group with a budget and Costco in
        // it, and a link that invites at Add. The link is real, so the server
        // would add her if her Join ever reached it.
        try await robin.signIn(email: accounts.secondEmail, password: accounts.secondPassword)
        await robin.deleteLeftovers(startingWith: Self.unconfirmedPrefix)
        let link = try await robin.shareNewGroup(robinsGroup, budget: "Groceries", entry: "Costco",
                                                 amount: Money(minorUnits: 2863), myName: "Robin", role: .add)
        let maker = try XCTUnwrap(robin.sync.userID, "Robin is not signed in")

        // 2. A fresh install. Leslie makes an account here and does not
        // confirm its email: Not now closes the sheet, and she stays signed
        // in.
        try run.launchAsFreshInstall()
        run.signUpWithoutConfirming(email: address, password: password, server: mailbox.server)

        // Scenario SHARE-09
        // 3. Robin's link, pasted into Join a Group…: the sheet says to
        // confirm her email first, with Confirm your email…, which closes the
        // sheet and opens the account sheet.
        run.openAccountThroughJoin(link)
        run.click(AccessibilityID.accountClose)
        XCTAssertTrue(run.wait(for: run.element(AccessibilityID.accountClose), until: "exists == false", timeout: 10),
                      "the account sheet did not close")

        // Scenario SHARE-09
        // 4. The link again, with her name, and Join pressed anyway: the
        // sheet also says to confirm her address and try again, and stays.
        // She is not added: no group comes to her list, and the server lists
        // only Robin in his group.
        let groups = run.groupLines()
        run.openJoin()
        run.paste(link.url, into: AccessibilityID.joinLink)
        run.type("Leslie", into: AccessibilityID.joinName)
        run.expect(AccessibilityID.joinJoin, enabled: true, "Join, with the link and her name")
        run.click(AccessibilityID.joinJoin)
        XCTAssertTrue(run.app.staticTexts[refused].waitForExistence(timeout: 30),
                      "the sheet does not say \(refused) On screen: \(run.visibleTexts())")
        XCTAssertTrue(run.app.staticTexts[JoinScreen.Words.confirmToJoin].exists,
                      "the notice to confirm the email first went. On screen: \(run.visibleTexts())")
        run.cancelJoin()
        XCTAssertEqual(run.groupLines(), groups, "a group was added to her list")
        let members = try await robin.members(of: robinsGroup)
        XCTAssertEqual(Array(members.keys), [maker], "the server lists \(members.count) people in Robin's group")

        // 5. Tidy: Confirm your email… opens the account sheet again, and
        // she signs out there, so her session ends on the server. With no
        // budget open, the window has no other way to it. Robin's group goes,
        // for everyone, and his session ends.
        run.openAccountThroughJoin(link)
        run.click(AccessibilityID.accountSignOut)
        XCTAssertTrue(run.app.staticTexts[SyncWording.footer(signedIn: false)].waitForExistence(timeout: 30),
                      "still signed in. On screen: \(run.visibleTexts())")
        await robin.deleteGroup(named: robinsGroup)
        await robin.cleanUp()
    }

    // MARK: - Signed in

    @MainActor
    func testEmailInvitationFormALegacyUsedLinkLeavingAndTheSamples() async throws {
        let accounts = try TestAccounts.fromEnvironment()
        let run = try TestApp()
        Self.dataRootPath = run.dataRoot.path
        let leslie = try SecondAccount(server: accounts.server)
        let stamp = Self.stamp()
        let robinsGroup = Self.robinsPrefix + stamp, lesliesGroup = Self.lesliesPrefix + stamp
        let budget = "Bulk \(stamp)"

        // 1. A fresh install, signed out, with the two sample groups. What
        // their budgets' rows say is kept, to compare after signing out.
        try run.launchAsFreshInstall()
        for group in Self.sampleGroups {
            XCTAssertTrue(run.element(AccessibilityID.sidebarGroup(group)).waitForExistence(timeout: 30),
                          "no sample \(group). Sidebar: \(run.sidebarIdentifiers())")
        }
        let samples = run.rows(of: Self.sampleBudgets)
        // Two empty lists would compare equal, so each sample budget must
        // have a row before it counts as "as they were" later.
        for budget in Self.sampleBudgets {
            XCTAssertFalse(samples[budget, default: []].isEmpty,
                           "no row for the sample budget \(budget). Sidebar: \(run.sidebarIdentifiers())")
        }

        // Scenario SAMP-06
        // 2. Signed in to the account made on another computer: the list
        // shows that account's groups, and no sample group.
        try run.signIn(email: accounts.email, password: accounts.password, server: accounts.server)
        for group in Self.sampleGroups {
            XCTAssertTrue(run.wait(for: run.element(AccessibilityID.sidebarGroup(group)), until: "exists == false",
                                   timeout: 30), "the sample \(group) shows in the account")
        }
        run.deleteLeftovers(startingWith: Self.robinsPrefix)

        // Scenario SHARE-01
        // 3. A group of his own. Share… in its menu opens a sheet titled with
        // it. It asks for his name, with the prompt in the empty field, what
        // they can do, with Add chosen, and what they see, with Everything so
        // far chosen. The form explains email delivery, and Send Invite
        // stays dimmed until all required fields are valid.
        run.addGroup(named: robinsGroup)
        run.revealLine(AccessibilityID.sidebarGroup(robinsGroup))
        run.openShare(of: robinsGroup)
        run.expectTheShareForm()

        // Scenario SHARE-01
        // 4. The line says what the chosen level lets someone do, and only
        // that level. Add is chosen again after.
        for role in [InviteRole.view, .manage, .add] {
            run.choose(role)
            XCTAssertTrue(run.app.staticTexts[role.explanation].waitForExistence(timeout: 30),
                          "no line saying what \(role.title) lets them do. On screen: \(run.visibleTexts())")
            for other in InviteRole.allCases where other != role {
                XCTAssertTrue(run.wait(for: run.app.staticTexts[other.explanation], until: "exists == false",
                                       timeout: 30),
                              "with \(role.title) chosen, a line still says what \(other.title) lets them do")
            }
        }

        // Scenario EMAIL-01
        // 5. All three fields are required. Sending emails the invitation;
        // the success page offers Done, without a link to copy.
        run.type("Robin", into: AccessibilityID.shareName)
        run.expect(AccessibilityID.shareCreate, enabled: false, "Send Invite without a recipient")
        run.type("Leslie", into: AccessibilityID.shareInviteeName)
        run.type("not-an-address", into: AccessibilityID.shareEmail)
        run.expect(AccessibilityID.shareCreate, enabled: false, "Send Invite with an invalid email")
        run.paste(accounts.secondEmail, into: AccessibilityID.shareEmail)
        run.expect(AccessibilityID.shareCreate, enabled: true, "Send Invite with all fields filled")
        run.click(AccessibilityID.shareCreate)
        XCTAssertTrue(run.element(AccessibilityID.shareDone).waitForExistence(timeout: 30),
                      "the email invitation did not finish")
        XCTAssertFalse(run.element(AccessibilityID.shareCopyLink).exists, "Copy Link is still offered")
        XCTAssertFalse(run.element(AccessibilityID.shareLink).exists, "a sender sees a bearer link")

        // Scenario SHARE-01
        // 7. Done closes the sheet. Share… again: Your name holds the name he
        // used for this group.
        run.click(AccessibilityID.shareDone)
        XCTAssertTrue(run.wait(for: run.element(AccessibilityID.shareDone), until: "exists == false", timeout: 10),
                      "Done did not close the sheet")
        run.openGroupPage(named: robinsGroup)
        XCTAssertTrue(run.app.staticTexts[EmailInvitationWords.pending].waitForExistence(timeout: 15),
                      "the sender has no Pending invitation")
        let pendingSummary = MembersScreen.Words.line([MembersScreen.Words.notShared, MembersScreen.Words.madeByYou])
        XCTAssertTrue(run.wait(for: run.element(AccessibilityID.groupSummary), holds: pendingSummary, timeout: 15),
                      "a pending invitation was counted as membership")
        // Scenario EMAIL-05
        run.app.buttons[EmailInvitationWords.cancelInvite].firstMatch.click()
        try XCTUnwrap(run.dialogButton(MainScreen.Words.cancel)).click()
        XCTAssertTrue(run.app.staticTexts[EmailInvitationWords.pending].exists)
        run.app.buttons[EmailInvitationWords.cancelInvite].firstMatch.click()
        try XCTUnwrap(run.dialogButton(EmailInvitationWords.cancelInvite)).click()
        XCTAssertTrue(run.wait(for: run.app.staticTexts[EmailInvitationWords.pending],
                               until: "exists == false", timeout: 15))
        run.revealLine(AccessibilityID.sidebarGroup(robinsGroup))
        run.openShare(of: robinsGroup)
        XCTAssertTrue(run.wait(for: run.element(AccessibilityID.shareName), holds: "Robin", timeout: 30),
                      "Your name does not hold Robin: \(run.text(of: run.element(AccessibilityID.shareName)))")
        run.click(AccessibilityID.shareCancel)
        XCTAssertTrue(run.wait(for: run.element(AccessibilityID.shareName), until: "exists == false", timeout: 10),
                      "the Share sheet did not close")

        // 8. Leslie, with no window, makes a group with a budget and Costco
        // in it, and a link that invites at Add.
        try await leslie.signIn(email: accounts.secondEmail, password: accounts.secondPassword)
        await leslie.deleteLeftovers(startingWith: Self.lesliesPrefix)
        let first = try await leslie.shareNewGroup(lesliesGroup, budget: budget, entry: "Costco",
                                                   amount: Money(minorUnits: 2863), myName: "Leslie", role: .add)
        let group = try XCTUnwrap(leslie.groupID(named: lesliesGroup), "Leslie has no group of that name")

        // Scenario SHARE-08
        // 9. Join a Group…, with his name typed: a web address is not an
        // invite link, and her link cut short, as a message app can cut one,
        // has part missing. Join stays dimmed either way.
        run.openJoin()
        run.type("Robin", into: AccessibilityID.joinName)
        run.paste("https://wellspent.space/join", into: AccessibilityID.joinLink)
        XCTAssertTrue(run.app.staticTexts[JoinScreen.Words.notALink].waitForExistence(timeout: 30),
                      "no line saying it is not an invite link. On screen: \(run.visibleTexts())")
        run.expect(AccessibilityID.joinJoin, enabled: false, "Join, for a web address")
        run.paste(String(first.url.prefix("\(first.scheme)://join#s=".count + 20)), into: AccessibilityID.joinLink)
        XCTAssertTrue(run.app.staticTexts[JoinScreen.Words.notWhole].waitForExistence(timeout: 30),
                      "no line saying part of the link is missing. On screen: \(run.visibleTexts())")
        run.expect(AccessibilityID.joinJoin, enabled: false, "Join, for a link cut short")

        // 10. Her whole link, in the same sheet, joins her group. He adds an
        // entry of his own, so this Mac holds its 1 budget and 2
        // transactions.
        run.paste(first.url, into: AccessibilityID.joinLink)
        run.expect(AccessibilityID.joinJoin, enabled: true, "Join, for her whole link")
        run.click(AccessibilityID.joinJoin)
        XCTAssertTrue(run.wait(for: run.element(AccessibilityID.joinJoin), until: "exists == false", timeout: 60),
                      "joining did not finish. On screen: \(run.visibleTexts())")
        run.open(budget: budget)
        if !run.entryRow("Costco").waitForExistence(timeout: 10) { run.syncNow() }
        XCTAssertTrue(run.entryRow("Costco").waitForExistence(timeout: 30),
                      "her entry is not in her budget. On screen: \(run.visibleTexts())")
        run.addEntry(merchant: "Bakery", amount: "5.00")

        // Scenario SHARE-15
        // 11. Her group's menu ends with Leave…, and has no Delete…. Leave…
        // asks first, saying what goes from his devices with it, with Leave
        // and Cancel. Leave takes the group from his sidebar.
        let leaving = PendingDelete.group(BudgetGroup(name: lesliesGroup), budgets: 1, transactions: 2,
                                          reach: .thisMacOnly)
        run.askToLeave(lesliesGroup, question: leaving.title)
        XCTAssertTrue(run.staticText(leaving.message(sendsChanges: true)).waitForExistence(timeout: 30),
                      "the question does not say \(leaving.message(sendsChanges: true)) On screen: \(run.visibleTexts())")
        XCTAssertNotNil(run.dialogButton(MainScreen.Words.cancel), "no Cancel on the question")
        try XCTUnwrap(run.dialogButton(leaving.confirmLabel), "no Leave on the question").click()
        XCTAssertTrue(run.wait(for: run.element(AccessibilityID.sidebarGroup(lesliesGroup)), until: "exists == false",
                               timeout: 30), "her group is still in his sidebar")

        // Scenario SHARE-15
        // 12. Leslie keeps the group, with its budget, Costco and his Bakery.
        // Once his leave reaches the server, it lists only her.
        let listed = try await leslie.members(of: group, until: 1)
        XCTAssertEqual(listed, 1, "the server still lists him in her group")
        let kept = try await leslie.wait(for: lesliesGroup, toHold: budget, with: ["Costco", "Bakery"])
        XCTAssertTrue(kept, "Leslie lost her group, its budget, Costco or his Bakery")

        // Scenario SHARE-10
        // 13. The link he joined with, pasted again with his name: Join says
        // it was already accepted, and he is not added.
        run.openJoin()
        run.paste(first.url, into: AccessibilityID.joinLink)
        run.type("Robin", into: AccessibilityID.joinName)
        run.click(AccessibilityID.joinJoin)
        XCTAssertTrue(run.app.staticTexts[Self.alreadyAccepted].waitForExistence(timeout: 30),
                      "the sheet does not say \(Self.alreadyAccepted) On screen: \(run.visibleTexts())")
        run.cancelJoin()
        XCTAssertFalse(run.element(AccessibilityID.sidebarGroup(lesliesGroup)).exists,
                       "the used link brought her group back")
        await leslie.sync.refresh(group)
        XCTAssertEqual(leslie.sync.members(of: group).count, 1, "the used link added him to her group")

        // Scenario SHARE-15
        // 14. A new link from Leslie, at View, brings the group back whole:
        // its budget, Costco and his Bakery.
        let again = try await leslie.newLink(to: lesliesGroup, role: .view, myName: "Leslie")
        run.join(again.url, as: "Robin")
        run.open(budget: budget)
        for merchant in ["Costco", "Bakery"] {
            XCTAssertTrue(run.entryRow(merchant).waitForExistence(timeout: 30),
                          "\(merchant) did not come back with the group. On screen: \(run.visibleTexts())")
        }

        // Scenario SHARE-15
        // 15. At View, Leave… asks without the two sentences about changes
        // not synced yet. Cancel keeps the group.
        run.askToLeave(lesliesGroup, question: leaving.title)
        XCTAssertTrue(run.staticText(leaving.message(sendsChanges: false)).waitForExistence(timeout: 30),
                      "the question does not say \(leaving.message(sendsChanges: false)) On screen: \(run.visibleTexts())")
        try XCTUnwrap(run.dialogButton(MainScreen.Words.cancel), "no Cancel on the question").click()
        XCTAssertTrue(run.wait(for: run.app.staticTexts[leaving.title], until: "exists == false", timeout: 30),
                      "Cancel did not close the question")
        XCTAssertTrue(run.element(AccessibilityID.sidebarGroup(lesliesGroup)).exists, "Cancel did not keep the group")

        // 16. His own group goes, for everyone, and a sync takes the delete
        // to the server.
        run.revealLine(AccessibilityID.sidebarGroup(robinsGroup))
        run.deleteGroup(named: robinsGroup)
        XCTAssertFalse(run.element(AccessibilityID.sidebarGroup(robinsGroup)).exists, "his group was not deleted")
        run.open(budget: budget)
        run.syncAndWait()

        // Scenario SAMP-06
        // 17. Signed out, the samples show again, as they were.
        run.signOut()
        XCTAssertTrue(run.app.staticTexts[SyncWording.footer(signedIn: false)].waitForExistence(timeout: 30),
                      "still signed in. On screen: \(run.textsWithoutAddresses())")
        for group in Self.sampleGroups {
            XCTAssertTrue(run.element(AccessibilityID.sidebarGroup(group)).waitForExistence(timeout: 30),
                          "the sample \(group) did not come back. Sidebar: \(run.sidebarIdentifiers())")
        }
        // The rows come back with the next draw, so they get up to 30
        // seconds to read as they did.
        var rowsNow = run.rows(of: Self.sampleBudgets)
        let deadline = Date().addingTimeInterval(30)
        while rowsNow != samples, Date() < deadline {
            try await Task.sleep(for: .seconds(1))
            rowsNow = run.rows(of: Self.sampleBudgets)
        }
        XCTAssertEqual(rowsNow, samples, "the samples are not as they were")

        // 18. Tidy: Leslie's group goes, for everyone, and her session ends.
        await leslie.deleteGroup(named: lesliesGroup)
        await leslie.cleanUp()
    }

    /// The server's words for an invite someone already used, as the app
    /// shows a refusal. No shared Words enum holds them: they come from the
    /// server, so the test has the server's reason and the app's wording.
    private static let alreadyAccepted = AccountWording.words(
        for: ReadableTransportError.http(status: 409, reason: "that invite has already been accepted"))

    /// What the Join sheet says a link invites to, worded by the shared Join
    /// screen. Its words need a coordinator to read the link with: one with
    /// no account, which asks the server nothing. Its settings go at once.
    @MainActor
    private static func invitation(in link: InviteLink) throws -> String? {
        let reader = try SecondAccount(server: AppEnvironment.staging.defaultServerAddress)
        defer { UserDefaults(suiteName: reader.suite)?.removePersistentDomain(forName: reader.suite) }
        return JoinScreen(actions: reader.sync, linkText: link.url).invitation
    }

    @MainActor
    func testEmailInboxRejectAndAcceptAFreshInvitation() async throws {
        let accounts = try TestAccounts.fromEnvironment()
        let run = try TestApp()
        Self.dataRootPath = run.dataRoot.path
        let sender = try SecondAccount(server: accounts.server)
        try await sender.signIn(email: accounts.secondEmail, password: accounts.secondPassword)
        let stamp = Self.stamp()
        let groupName = Self.lesliesPrefix + stamp + " Inbox"
        let ownGroup = Self.robinsPrefix + stamp + " Inbox"
        let budgets = ["Food " + stamp, "Travel " + stamp]
        let group = try await EmailInvitationFixture.makeGroup(sender: sender, named: groupName, budgets: budgets)
        let first = try await EmailInvitationFixture.send(sender: sender, group: group,
                                                           groupName: groupName, to: accounts.email)
        run.launch()
        try run.signIn(email: accounts.email, password: accounts.password, server: accounts.server)
        run.addGroup(named: ownGroup)
        run.addBudget(named: "Local " + stamp, amount: "100", inGroup: ownGroup)

        // Scenario EMAIL-02
        XCTAssertTrue(run.element(AccessibilityID.incomingInvitation(first.id)).waitForExistence(timeout: 20))
        XCTAssertTrue(run.app.staticTexts[EmailInvitationWords.invited].exists)
        XCTAssertTrue(run.app.staticTexts[EmailInvitationWords.from("Leslie")].exists)
        XCTAssertTrue(run.app.staticTexts[InviteRole.add.title + " · " + JoinScreen.Words.sees(.all)].exists)
        XCTAssertFalse(run.element(AccessibilityID.sidebarGroup(groupName)).exists,
                       "an invitation already grants membership")
        for budget in budgets { XCTAssertFalse(run.element(AccessibilityID.sidebarBudget(budget)).exists) }

        // Scenario EMAIL-04
        run.click(AccessibilityID.rejectInvitation(first.id))
        try XCTUnwrap(run.dialogButton(MainScreen.Words.cancel)).click()
        XCTAssertTrue(run.element(AccessibilityID.acceptInvitation(first.id)).exists)
        run.click(AccessibilityID.rejectInvitation(first.id))
        try XCTUnwrap(run.dialogButton(EmailInvitationWords.reject)).click()
        XCTAssertTrue(run.wait(for: run.element(AccessibilityID.incomingInvitation(first.id)),
                               until: "exists == false", timeout: 20))
        let rejected = try await sender.sync.invites(in: group)
        XCTAssertEqual(rejected.first { $0.id == first.id }?.status, "rejected")
        run.syncAndWait()
        XCTAssertFalse(run.element(AccessibilityID.incomingInvitation(first.id)).exists,
                       "rejected invitation returned at sync")

        let fresh = try await EmailInvitationFixture.send(sender: sender, group: group,
                                                           groupName: groupName, to: accounts.email)
        XCTAssertNotEqual(fresh.id, first.id)
        run.syncAndWait()
        XCTAssertTrue(run.element(AccessibilityID.acceptInvitation(fresh.id)).waitForExistence(timeout: 20))

        // Scenario EMAIL-03
        run.click(AccessibilityID.acceptInvitation(fresh.id))
        XCTAssertTrue(run.element(AccessibilityID.groupSummary).waitForExistence(timeout: 20),
                      "Accept did not open the group page")
        XCTAssertFalse(run.element(AccessibilityID.invitationName).exists, "Accept asked for a name")
        XCTAssertTrue(run.app.staticTexts[MembersScreen.Words.you("Robin")].waitForExistence(timeout: 15),
                      "the accepted member did not receive their invited name")
        XCTAssertFalse(run.element(AccessibilityID.incomingInvitation(fresh.id)).exists)
        for budget in budgets {
            XCTAssertTrue(run.element(AccessibilityID.sidebarBudget(budget)).waitForExistence(timeout: 20),
                          "Accept did not bring every budget")
        }
        run.click(AccessibilityID.sidebarBudget(budgets[0]))
        XCTAssertTrue(run.app.staticTexts["Existing purchase"].waitForExistence(timeout: 15))

        run.deleteGroup(named: ownGroup)
        run.signOut()
        await sender.deleteGroup(named: groupName)
        await sender.cleanUp()
    }

    /// Part of each name, so runs never share one.
    private static func stamp() -> String {
        stampFormatter().string(from: Date())
    }

    fileprivate static func stampFormatter() -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter
    }
}

// MARK: - Helpers

@MainActor
private extension TestApp {
    /// Launches as a fresh install, with the samples and no settings left by
    /// an earlier run. The app starts its settings afresh only for a data
    /// folder that does not exist yet (AccountDirectory.testing). TestApp
    /// makes the folder first, and wipes the settings from the test runner,
    /// which is sandboxed, so that wipe reaches the runner's own copy, not
    /// the app's. On a Mac that ran the UI tests before, the app then opens
    /// with no samples. So the folder goes first, and the app makes it again.
    func launchAsFreshInstall() throws {
        try FileManager.default.removeItem(at: dataRoot)
        launch()
    }

    /// Scrolls the sidebar until a line sits clear of the bar at its foot,
    /// with TestApp.revealInSidebar. A line just added, or far down a long
    /// list, has no place on screen for a moment, and revealInSidebar takes
    /// that for a line in view. So this waits for its place first, then
    /// checks it can be clicked.
    func revealLine(_ identifier: String, file: StaticString = #filePath, line: UInt = #line) {
        let target = element(identifier)
        // Up to 30 seconds: a budget of a group just joined comes with the
        // sync that follows, which a slow machine takes a while over.
        XCTAssertTrue(target.waitForExistence(timeout: 30), "no line called \(identifier). Sidebar: \(sidebarIdentifiers())",
                      file: file, line: line)
        let placed = NSPredicate { _, _ in !target.frame.isEmpty }
        XCTAssertEqual(XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: placed, object: nil)], timeout: 30),
                       .completed, "\(identifier) has no place on screen", file: file, line: line)
        revealInSidebar(target)
        waitUntilHittable(target, identifier)
    }

    /// A budget, opened from the sidebar once its row is in view.
    func open(budget name: String, file: StaticString = #filePath, line: UInt = #line) {
        revealLine(AccessibilityID.sidebarBudget(name), file: file, line: line)
        openBudget(named: name)
    }

    /// Deletes groups of this test's own that a run stopped before its end
    /// left in the account signed in here: named with the prefix and a time
    /// more than an hour ago. Another run may be going on, so newer ones
    /// stay. Best effort: nothing here fails the test.
    func deleteLeftovers(startingWith prefix: String) {
        let formatter = SharingGapTests.stampFormatter()
        let anHourAgo = Date().addingTimeInterval(-3600)
        let start = AccessibilityID.sidebarGroup(prefix)
        let lines = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@", start))
        let names = Set(lines.allElementsBoundByIndex.map { String($0.identifier.dropFirst(start.count - prefix.count)) })
        for name in names {
            guard let made = formatter.date(from: String(name.dropFirst(prefix.count).prefix(15))), made < anHourAgo
            else { continue }
            let target = element(AccessibilityID.sidebarGroup(name))
            let placed = NSPredicate { _, _ in !target.frame.isEmpty }
            _ = XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: placed, object: nil)], timeout: 10)
            revealInSidebar(target)
            deleteGroup(named: name)
        }
    }

    /// Share… from a group's menu, until the sheet that opens is titled with
    /// that group. A right-click beside the line can open a neighbor's menu.
    func openShare(of group: String) {
        let line = AccessibilityID.sidebarGroup(group)
        let form = element(AccessibilityID.shareName)
        let title = app.staticTexts["Invite someone to “\(group)”"].firstMatch
        for _ in 0..<3 {
            openMenu(on: element(line), line, offering: MainScreen.Words.share)
            clickMenuItem(MainScreen.Words.share)
            XCTAssertTrue(form.waitForExistence(timeout: 30), "Share\u{2026} opened no sheet. On screen: \(visibleTexts())")
            if title.waitForExistence(timeout: 3) { return }
            click(AccessibilityID.shareCancel)
            wait(for: form, until: "exists == false", timeout: 10)
        }
        XCTFail("Share\u{2026} never opened the sheet for \(group). On screen: \(visibleTexts())")
    }

    /// The Share sheet before anything is typed or picked, as SHARE-01 says.
    func expectTheShareForm(file: StaticString = #filePath, line: UInt = #line) {
        typealias Words = EmailInviteScreen.Words
        for (id, prompt) in [(AccessibilityID.shareEmail, Words.emailPrompt),
                             (AccessibilityID.shareInviteeName, Words.inviteeNamePrompt)] {
            let field = element(id)
            XCTAssertTrue(field.exists, "a required recipient field is missing", file: file, line: line)
            XCTAssertEqual(field.value as? String ?? "", "", file: file, line: line)
            XCTAssertEqual(field.placeholderValue, prompt, file: file, line: line)
        }
        let name = element(AccessibilityID.shareName)
        XCTAssertEqual(name.value as? String ?? "", "", "Your name is not empty", file: file, line: line)
        XCTAssertEqual(name.placeholderValue, Words.namePrompt, "the empty field's prompt", file: file, line: line)
        XCTAssertTrue(shows(Words.name, on: name), "no Your name. On screen: \(visibleTexts())", file: file, line: line)
        let roles = element(AccessibilityID.shareRole)
        XCTAssertTrue(shows(Words.role, on: roles), "no They can. On screen: \(visibleTexts())", file: file, line: line)
        for role in InviteRole.allCases {
            XCTAssertTrue(segment(role).exists, "They can offers no \(role.title)", file: file, line: line)
        }
        XCTAssertTrue(isChosen(segment(.add)), "Add is not chosen", file: file, line: line)
        XCTAssertTrue(app.staticTexts[InviteRole.add.explanation].exists,
                      "no line saying what Add lets them do. On screen: \(visibleTexts())", file: file, line: line)
        let history = historyPicker()
        XCTAssertTrue(shows(Words.history, on: history), "no They see. On screen: \(visibleTexts())",
                      file: file, line: line)
        XCTAssertTrue(wait(for: history, holds: Words.historyAll, timeout: 30),
                      "They see does not hold \(Words.historyAll): \(text(of: history))", file: file, line: line)
        waitUntilHittable(history, AccessibilityID.shareHistory)
        history.click()
        for choice in [Words.historyAll, Words.historyFromNow] {
            XCTAssertTrue(menuItem(choice).waitForExistence(timeout: 30), "They see offers no \(choice)",
                          file: file, line: line)
        }
        menuItem(Words.historyAll).click()
        XCTAssertTrue(wait(for: history, holds: Words.historyAll, timeout: 30),
                      "They see does not hold \(Words.historyAll) again: \(text(of: history))", file: file, line: line)
        let note = app.staticTexts[Words.note].firstMatch
        let cancel = element(AccessibilityID.shareCancel), create = element(AccessibilityID.shareCreate)
        XCTAssertTrue(note.exists, "no line explaining email delivery. On screen: \(visibleTexts())", file: file, line: line)
        XCTAssertEqual(cancel.label, Words.cancel, file: file, line: line)
        XCTAssertEqual(create.label, Words.send, file: file, line: line)
        XCTAssertTrue(onOneLine(cancel, create), "Cancel and Send Invite do not share a button row",
                      file: file, line: line)
        XCTAssertLessThanOrEqual(note.frame.maxY, create.frame.minY,
                                 "the email explanation overlaps the buttons", file: file, line: line)
        XCTAssertFalse(create.isEnabled, "Send Invite is not dimmed with no name", file: file, line: line)
    }

    /// Whether these words show as a control's own label or title, or as a
    /// text on screen beside it.
    func shows(_ words: String, on control: XCUIElement) -> Bool {
        control.label == words || control.title == words || app.staticTexts[words].exists
    }

    /// Whether two elements sit on one line: the second to the right of the
    /// first, their middles at about the same height.
    func onOneLine(_ left: XCUIElement, _ right: XCUIElement) -> Bool {
        left.frame.maxX <= right.frame.minX && abs(left.frame.midY - right.frame.midY) <= right.frame.height
    }

    /// A segment of They can, in the Share sheet, by its role's name.
    func segment(_ role: InviteRole) -> XCUIElement {
        let picker = element(AccessibilityID.shareRole)
        return [picker.radioButtons[role.title].firstMatch, picker.buttons[role.title].firstMatch,
                app.radioButtons[role.title].firstMatch].first { $0.exists } ?? picker.radioButtons[role.title].firstMatch
    }

    /// Whether a segment shows as the chosen one.
    func isChosen(_ segment: XCUIElement) -> Bool {
        if segment.isSelected { return true }
        if let number = segment.value as? NSNumber { return number.intValue == 1 }
        return (segment.value as? String) == "1"
    }

    /// A click on a segment of They can, which then shows as chosen.
    func choose(_ role: InviteRole, file: StaticString = #filePath, line: UInt = #line) {
        let chosen = segment(role)
        waitUntilHittable(chosen, role.title)
        chosen.click()
        let shown = NSPredicate { [weak self] _, _ in self?.isChosen(chosen) == true }
        XCTAssertEqual(XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: shown, object: nil)], timeout: 30),
                       .completed, "\(role.title) is not chosen after a click", file: file, line: line)
    }

    /// They see, in the Share sheet: its pop-up button.
    func historyPicker() -> XCUIElement {
        let found = element(AccessibilityID.shareHistory)
        return [app.popUpButtons[AccessibilityID.shareHistory].firstMatch, found.popUpButtons.firstMatch]
            .first { $0.exists } ?? found
    }

    /// Leave… from a group's menu. The menu ends with it, and offers no
    /// Delete…. It asks first, with this question.
    func askToLeave(_ group: String, question: String, file: StaticString = #filePath, line: UInt = #line) {
        let groupLine = AccessibilityID.sidebarGroup(group)
        revealLine(groupLine, file: file, line: line)
        openMenu(on: element(groupLine), groupLine, offering: MainScreen.Words.leave)
        let items = itemsOfMenu(holding: MainScreen.Words.leave)
        XCTAssertEqual(items.last, MainScreen.Words.leave, "the menu's last item: \(items)", file: file, line: line)
        XCTAssertFalse(items.contains(MainScreen.Words.delete), "the menu offers Delete\u{2026}: \(items)",
                       file: file, line: line)
        clickMenuItem(MainScreen.Words.leave)
        XCTAssertTrue(app.staticTexts[question].waitForExistence(timeout: 30),
                      "no question \(question) On screen: \(visibleTexts())", file: file, line: line)
    }

    /// The items of the menu open now that holds `item`, in order, with the
    /// dividers left out.
    func itemsOfMenu(holding item: String) -> [String] {
        let menu = app.menus.containing(NSPredicate(format: "title == %@", item)).firstMatch
        return menu.menuItems.allElementsBoundByIndex.map(\.title).filter { !$0.isEmpty }
    }

    /// What each budget's row in the sidebar says, by budget: every element
    /// with its identifier, its words and its value, which says how full it
    /// is, as a screen reader reads it.
    func rows(of budgets: [String]) -> [String: [String]] {
        var rows: [String: [String]] = [:]
        for budget in budgets {
            rows[budget] = app.descendants(matching: .any).matching(identifier: AccessibilityID.sidebarBudget(budget))
                .allElementsBoundByIndex.map { "\($0.label) | \(($0.value as? String) ?? "")" }
        }
        return rows
    }

    /// Join a Group…, from the Add menu, with its sheet open.
    func openJoin() {
        openAddMenu()
        clickMenuItem(MainScreen.Words.join)
        XCTAssertTrue(element(AccessibilityID.joinLink).waitForExistence(timeout: 30),
                      "Join a Group\u{2026} opened no sheet. On screen: \(visibleTexts())")
    }

    /// A text on screen with exactly these words. A query by its words alone
    /// refuses words longer than 128 characters, so this names what to match.
    func staticText(_ words: String) -> XCUIElement {
        app.staticTexts.matching(NSPredicate(format: "label == %@ OR value == %@", words, words)).firstMatch
    }

    /// Sign in…, then Create an account, with an address nobody confirms.
    /// The sheet moves on to confirming the email, signed in, and Not now
    /// closes it.
    func signUpWithoutConfirming(email: String, password: String, server: String) {
        click(AccessibilityID.sidebarSignIn)
        click(AccessibilityID.accountCreateAccount)
        let serverField = element(AccessibilityID.accountServer)
        XCTAssertTrue(serverField.waitForExistence(timeout: 30), "Create an account did not open")
        if (serverField.value as? String) != server { type(server, into: AccessibilityID.accountServer) }
        type(email, into: AccessibilityID.accountEmail)
        paste(password, into: AccessibilityID.accountPassword)
        paste(password, into: AccessibilityID.accountConfirmation)
        click(AccessibilityID.accountSubmit)
        XCTAssertTrue(element(AccessibilityID.accountCode).waitForExistence(timeout: 30),
                      "Create account did not move on to confirming the email. On screen: \(visibleTexts())")
        XCTAssertTrue(app.staticTexts[SyncWording.footer(signedIn: true)].waitForExistence(timeout: 30),
                      "not signed in after Create account. On screen: \(visibleTexts())")
        click(AccessibilityID.accountClose)
        XCTAssertTrue(wait(for: element(AccessibilityID.accountCode), until: "exists == false", timeout: 10),
                      "Not now did not close the account sheet")
    }

    /// Join a Group…, with a link pasted, signed in with an address not
    /// confirmed yet: the sheet says to confirm it first, and Confirm your
    /// email… closes the sheet and opens the account sheet.
    func openAccountThroughJoin(_ link: InviteLink, file: StaticString = #filePath, line: UInt = #line) {
        openJoin()
        paste(link.url, into: AccessibilityID.joinLink)
        XCTAssertTrue(app.staticTexts[JoinScreen.Words.confirmToJoin].waitForExistence(timeout: 30),
                      "no notice to confirm the email first. On screen: \(visibleTexts())", file: file, line: line)
        let confirm = app.buttons[JoinScreen.Words.confirmEmail].firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 30), "no Confirm your email\u{2026}. On screen: \(visibleTexts())",
                      file: file, line: line)
        waitUntilHittable(confirm, JoinScreen.Words.confirmEmail)
        confirm.click()
        XCTAssertTrue(wait(for: element(AccessibilityID.joinLink), until: "exists == false", timeout: 10),
                      "Confirm your email\u{2026} did not close Join a Group", file: file, line: line)
        XCTAssertTrue(element(AccessibilityID.accountSignOut).waitForExistence(timeout: 30),
                      "Confirm your email\u{2026} did not open the account sheet. On screen: \(visibleTexts())",
                      file: file, line: line)
    }

    /// The group lines in the sidebar, by identifier.
    func groupLines() -> Set<String> {
        Set(app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'sidebar.group.'"))
            .allElementsBoundByIndex.map(\.identifier))
    }

    /// Cancel, in Join a Group, and the sheet goes.
    func cancelJoin() {
        click(AccessibilityID.joinCancel)
        XCTAssertTrue(wait(for: element(AccessibilityID.joinLink), until: "exists == false", timeout: 10),
                      "Join a Group stayed open")
    }

    /// Sync, in the toolbar, then waits until it is done: the button is off
    /// while a sync runs, and on again after, saying Sync.
    func syncAndWait() {
        syncNow()
        let button = element(AccessibilityID.toolbarSync)
        wait(for: button, until: "isEnabled == false", timeout: 3)
        XCTAssertTrue(wait(for: button, until: "isEnabled == true", timeout: 60), "the sync did not finish")
        let synced = SyncWording.syncTitle(for: .signedIn(email: ""))
        XCTAssertTrue(wait(for: button, holds: synced, timeout: 30), "the sync did not go through: \(button.label)")
    }

    /// What visibleTexts reads, less any line that gives a test account's
    /// address away, as the account sheet's line saying who is signed in
    /// does. A failure's message goes to CI's log, which is public.
    func textsWithoutAddresses() -> [String] {
        let giveaways: [String] = ScreenPrivacy.giveaways
        return visibleTexts().filter { (text: String) -> Bool in
            let lowered: String = text.lowercased()
            return !giveaways.contains { lowered.contains($0) }
        }
    }
}

@MainActor
private extension SecondAccount {
    /// A group of this person's, by its name.
    func groupID(named name: String) -> GroupID? {
        AppModel(store: sync.store).groups.first { $0.name == name }?.id
    }

    /// Asks the server who is in the group until it lists `count` people, or
    /// the time runs out. Returns how many it listed last.
    func members(of group: GroupID, until count: Int, timeout: TimeInterval = 60) async throws -> Int {
        let deadline = Date().addingTimeInterval(timeout)
        await sync.refresh(group)
        var listed = sync.members(of: group).count
        while listed != count, Date() < deadline {
            try await Task.sleep(for: .seconds(2))
            await sync.refresh(group)
            listed = sync.members(of: group).count
        }
        return listed
    }

    /// Syncs until the group holds the budget, with an entry for each
    /// merchant, or the time runs out.
    func wait(for group: String, toHold budget: String, with merchants: Set<String>,
              timeout: TimeInterval = 60) async throws -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            try await syncAll()
            let model = AppModel(store: sync.store)
            if let found = model.groups.first(where: { $0.name == group }),
               let summary = model.summaries[found.id]?.first(where: { $0.budget.name == budget }),
               merchants.isSubset(of: Set(try model.store.transactions(in: summary.budget.id).map(\.merchant))) {
                return true
            }
            try await Task.sleep(for: .seconds(3))
        } while Date() < deadline
        return false
    }

    /// A new link to a group of this person's own, showing everything so
    /// far, with the name they give the group.
    func newLink(to group: String, role: InviteRole, myName: String) async throws -> InviteLink {
        guard let id = groupID(named: group) else { throw UITestError("Leslie has no group called \(group)") }
        let link = try await sync.share(group: id, groupName: group, level: role.level, historyAccess: .all,
                                        myName: myName)
        try await syncAll()
        return link
    }

    /// Deletes groups this person made in runs of these tests that stopped
    /// before their end: named with the prefix and a time more than an hour
    /// ago. Another run may be going on now, so newer ones stay. Best effort.
    func deleteLeftovers(startingWith prefix: String) async {
        let formatter = SharingGapTests.stampFormatter()
        let anHourAgo = Date().addingTimeInterval(-3600)
        let model = AppModel(store: sync.store)
        for group in model.groups where group.name.hasPrefix(prefix) {
            let made = formatter.date(from: String(group.name.dropFirst(prefix.count).prefix(15)))
            guard let made, made < anHourAgo else { continue }
            model.deleteGroup(group.id, reach: sync.deleteReach(of: group.id))
        }
        await sync.syncAll()
    }
}
