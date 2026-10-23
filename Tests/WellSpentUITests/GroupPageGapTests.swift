import AppKit
import Foundation
import XCTest
import WellSpentAppCore
import WellSpentCrypto
import WellSpentModel
import WellSpentSync

/// A group's page in the real window, for the scenarios in GroupPage.md that
/// the other Mac tests leave out. Two tests:
/// - Signed out, with two groups of the run's own: the sidebar marks the
///   group whose page is open, the page says only that the group is not
///   shared, and the page stays open until its own group is deleted.
/// - Signed in to staging. The window is Robin. Leslie has no window: she is
///   a coordinator inside this process, as in SignInBudgetShareSyncTests.
///   She joins two groups of Robin's, and Robin changes her level and
///   removes her. Then Robin joins a group of hers, and sees a member's page
///   at each level before he leaves. Where a scenario has Leslie join a group
///   of Robin's to see a member's page, here the two names swap, and the
///   window stays Robin's.
///
/// PAGE-11 has a third person in the group. The test makes an account for
/// them at an example.com address, confirms it with the code staging's test
/// mailbox holds (StagingMailbox), and joins it to Leslie's group with no
/// name, so the page calls them Someone. The third person has no window
/// either.
///
/// What Leslie sees is read from the shared screens every app draws
/// (BudgetScreen, MembersScreen), through her coordinator, since she has no
/// window.
///
/// The signed-in test needs the four WELLSPENT_UI_TEST_ variables and the
/// mailbox token (see the Makefile's ui-test target), and skips without
/// them. It signs in twice, once for each test account, and makes one new
/// account. Its groups are named with the time, and all of them go at the
/// end, for everyone.
final class GroupPageGapTests: XCTestCase {
    /// The run's data folder, for tearDown.
    nonisolated(unsafe) private static var dataRootPath: String?
    /// Where the third person keeps their settings, apart from Leslie's.
    private static let thirdSuite = "app.wellspent.uitest.third"

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    /// Runs after each test, passed or halted, with no await in it, as in
    /// SignInBudgetShareSyncTests. The app is closed, and nothing of the run
    /// stays on this Mac: not its folder, not the other people's settings,
    /// and not the clipboard, which joining pastes a link through.
    override func tearDown() {
        let app = XCUIApplication()
        if app.state != .notRunning { app.terminate() }
        TestApp.wipeSettings()
        if let path = Self.dataRootPath { try? FileManager.default.removeItem(atPath: path) }
        Self.dataRootPath = nil
        // XCTest calls tearDown on the main thread.
        for suite in [MainActor.assumeIsolated { SecondAccount.settingsSuite }, Self.thirdSuite] {
            UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
        }
        NSPasteboard.general.clearContents()
        super.tearDown()
    }

    // MARK: - Signed out

    @MainActor
    func testTheOpenPageIsMarkedAndStaysUntilItsGroupGoes() throws {
        let run = try TestApp()
        Self.dataRootPath = run.dataRoot.path
        let stamp = Self.stamp()
        let household = "Household \(stamp)", sideBusiness = "Side Business \(stamp)"
        let groceries = "Groceries \(stamp)", materials = "Materials \(stamp)"
        let householdLine = AccessibilityID.sidebarGroup(household)
        let groceriesLine = AccessibilityID.sidebarBudget(groceries)
        let summary = run.element(AccessibilityID.groupSummary)

        // 1. Signed out, two groups of this run's own, each with a budget.
        // Saving a budget opens it, so Groceries is opened again after.
        run.launch()
        run.addGroup(named: household)
        run.addBudget(named: groceries, amount: "500", inGroup: household)
        run.addGroup(named: sideBusiness)
        run.addBudget(named: materials, amount: "100", inGroup: sideBusiness)
        run.openBudget(named: groceries)
        XCTAssertTrue(run.waitUntilMarked(groceriesLine),
                      "Groceries is not picked. Marked in the sidebar: \(run.markedSidebarLines())")

        // Scenario PAGE-04
        // 2. A click on Household's name opens its page, and marks the name
        // while the page shows. No budget is picked.
        run.openGroupPage(named: household)
        XCTAssertTrue(run.waitUntilMarked(householdLine),
                      "Household's name is not marked. Marked in the sidebar: \(run.markedSidebarLines())")
        XCTAssertEqual(run.markedSidebarLines(), [householdLine], "a budget is picked while the page shows")

        // Scenario PAGE-04
        // 3. A click on Groceries picks it in place of the page, and
        // Household's name is no longer marked.
        run.openBudget(named: groceries)
        XCTAssertTrue(run.wait(for: summary, until: "exists == false", timeout: 10), "the page stayed over Groceries")
        XCTAssertTrue(run.waitUntilMarked(groceriesLine),
                      "Groceries is not picked. Marked in the sidebar: \(run.markedSidebarLines())")
        XCTAssertTrue(run.waitUntilMarked(householdLine, false),
                      "Household's name is still marked. Marked in the sidebar: \(run.markedSidebarLines())")

        // Scenario PAGE-07
        // 4. Signed out, with Household kept on this computer only, its page
        // shows its name and "Not shared", and lists nobody.
        XCTAssertTrue(run.listText(SyncWording.footer(signedIn: false)).exists,
                      "the sidebar does not say budgets are kept on this computer. On screen: \(run.visibleTexts())")
        run.openGroupPage(named: household)
        XCTAssertTrue(run.wait(for: summary, holds: MembersScreen.Words.notShared, timeout: 10),
                      "the line under the name is not \(MembersScreen.Words.notShared): \(run.text(of: summary))")
        XCTAssertEqual(run.pageHeading(), household, "the page is not headed with the group's name")
        XCTAssertFalse(run.listText(MembersScreen.Words.people.uppercased()).exists,
                       "the page lists people. On the page: \(run.pageDescription())")
        XCTAssertEqual(run.levelLists(in: run.pageParts()).count, 0,
                       "the page has a level list. On the page: \(run.pageDescription())")

        // Scenario PAGE-07
        // 5. Invite Someone… opens the Share sheet, which says to sign in
        // first. Cancel closes it, and the page stays.
        run.click(AccessibilityID.groupInvite)
        XCTAssertTrue(run.app.staticTexts["Invite someone to “\(household)”"].waitForExistence(timeout: 10),
                      "Invite Someone\u{2026} opened no Share sheet. On screen: \(run.visibleTexts())")
        XCTAssertTrue(run.app.staticTexts[ShareScreen.Words.signInToShare].exists,
                      "the Share sheet does not say to sign in first. On screen: \(run.visibleTexts())")
        run.click(AccessibilityID.shareCancel)
        XCTAssertTrue(run.wait(for: run.element(AccessibilityID.shareName), until: "exists == false", timeout: 10),
                      "the Share sheet did not close")
        XCTAssertTrue(summary.exists, "the page closed with the sheet")

        // Scenario PAGE-16
        // 6. Materials, opened, then Household's page over it. Side Business,
        // deleted from its menu, takes Materials with it, and Household's
        // page stays open, its name still marked.
        run.openBudget(named: materials)
        run.openGroupPage(named: household)
        run.deleteFromMenu(sideBusiness)
        XCTAssertTrue(summary.waitForExistence(timeout: 5), "Household's page closed when Side Business went")
        XCTAssertEqual(run.pageHeading(), household, "the page open is not Household's")
        XCTAssertTrue(run.waitUntilMarked(householdLine),
                      "Household's name is not marked. Marked in the sidebar: \(run.markedSidebarLines())")

        // Scenario PAGE-16
        // 7. Household, deleted from its menu, takes its page with it.
        run.deleteFromMenu(household)
        XCTAssertTrue(run.wait(for: summary, until: "exists == false", timeout: 10),
                      "Household's page stayed after Household went. On screen: \(run.visibleTexts())")
    }

    // MARK: - Signed in

    @MainActor
    func testWhoIsInAGroupAndWhatEachOfThemMayDo() async throws {
        let accounts = try TestAccounts.fromEnvironment()
        let mailbox = try StagingMailbox.fromEnvironment()
        let run = try TestApp()
        Self.dataRootPath = run.dataRoot.path
        let leslie = try SecondAccount(server: accounts.server)
        let stamp = Self.stamp()
        // Two groups of Robin's, and one of Leslie's, each with a budget.
        let household = "UI Page \(stamp)", later = "UI Page \(stamp) later", hers = "UI Page \(stamp) Leslie"
        let bills = "Bills \(stamp)", groceries = "Groceries \(stamp)", costs = "Costs \(stamp)"
        let summary = run.element(AccessibilityID.groupSummary)
        let you = MembersScreen.Words.you("Robin"), someone = MembersScreen.Words.someone
        let alone = MembersScreen.Words.line([MembersScreen.Words.notShared, MembersScreen.Words.madeByYou])
        let twoOfUs = MembersScreen.Words.line([MembersScreen.Words.shared, MembersScreen.Words.peopleCount(2),
                                                MembersScreen.Words.madeByYou])
        let madeByLeslie = MembersScreen.Words.line([MembersScreen.Words.shared, MembersScreen.Words.peopleCount(2),
                                                     MembersScreen.Words.madeBy("Leslie")])

        // 1. Leslie signs in, with no window, and an account is made for a
        // third person at an example.com address, confirmed with the code
        // staging's test mailbox holds. Both come first, so that a refusal
        // stops the test before anything is made on staging. Then Robin
        // signs in, and makes two groups of his own, each with a budget, and
        // a link to each that invites at Add.
        try await leslie.signIn(email: accounts.secondEmail, password: accounts.secondPassword)
        let third = try SecondAccount(server: accounts.server, settingsSuite: Self.thirdSuite)
        let address = StagingMailbox.freshAddress("mac", for: "page")
        try await third.sync.signUp(email: address, password: UUID().uuidString)
        let code = try await mailbox.code(for: address)
        try await third.sync.verifyEmail(code: code)
        run.launch()
        try run.signIn(email: accounts.email, password: accounts.password, server: accounts.server)
        run.addGroup(named: later)
        run.addBudget(named: groceries, amount: "500", inGroup: later)
        run.addGroup(named: household)
        run.addBudget(named: bills, amount: "200", inGroup: household)
        let laterLink = try await run.legacyInvite(group: later, myName: "Robin", role: .add)
        let link = try await run.legacyInvite(group: household, myName: "Robin", role: .add)

        // 2. Household's page, open before anyone joins: nobody else is in it.
        run.openGroupPage(named: household)
        XCTAssertTrue(run.wait(for: summary, holds: alone, timeout: 15),
                      "the page's line is not \(alone): \(run.text(of: summary))")

        // Scenario PAGE-15
        // 3. Leslie joins with the link while the page is open. At Robin's
        // next sync her row shows on it, and the line says two people share
        // the group.
        _ = try await leslie.join(link, as: "Leslie")
        run.syncNow()
        XCTAssertTrue(run.wait(for: summary, holds: twoOfUs, timeout: 30),
                      "the page's line is not \(twoOfUs): \(run.text(of: summary))")
        XCTAssertTrue(run.listText("Leslie").waitForExistence(timeout: 15),
                      "her row does not show. On the page: \(run.pageDescription())")

        // Scenario PAGE-09
        // 4. Robin made the group. Leslie's row has a level list set to Add,
        // offering View, Add, Manage and Admin, and Remove…. His own row
        // shows Owner as a plain label, with no Remove…. Invite Someone… is
        // at the top, and there is no Leave Group….
        let herList = try XCTUnwrap(run.levelList(onRowOf: "Leslie"),
                                    "no level list on her row. On the page: \(run.pageDescription())")
        XCTAssertEqual(run.text(of: herList), MembersScreen.Words.levelTitle(.write), "her level list is not at Add")
        let ownersChoices: [AccessLevel] = [.read, .write, .manage, .admin]
        XCTAssertEqual(run.levels(offeredOnRowOf: "Leslie"), ownersChoices.map(MembersScreen.Words.levelTitle),
                       "her level list does not offer every level")
        XCTAssertEqual(run.text(of: herList), MembersScreen.Words.levelTitle(.write),
                       "closing her level list changed it")
        XCTAssertEqual(run.removeButtons(), [AccessibilityID.groupRemove("Leslie")],
                       "Remove\u{2026} is not on her row alone")
        run.expect(plainLevels: [(you, .superadmin)], "for the person who made it")
        run.expectInviteAtTheTop(above: you)
        XCTAssertFalse(run.element(AccessibilityID.groupLeave).exists,
                       "Leave Group\u{2026} for the person who made the group")

        // Scenario PAGE-10
        // 5. View, picked in Leslie's level list: her row says what View lets
        // her do. Once her app syncs, Bills offers her neither Add nor Import
        // statement: her budget's screen, which every app draws, says so.
        run.pick(.read, onRowOf: "Leslie")
        run.expect(rowOf: "Leslie", says: MembersScreen.Words.levelExplanation(.read))
        let addsAtView = try await leslie.budgetOffersAdd(bills, in: household, expecting: false)
        XCTAssertEqual(addsAtView, false, "once her app synced at View, Bills still offers her Add and Import statement")

        // Scenario PAGE-10
        // 6. Admin, picked instead: her row says what an admin may do. She
        // stays an admin, so she can delete Household at the end.
        run.pick(.admin, onRowOf: "Leslie")
        run.expect(rowOf: "Leslie", says: MembersScreen.Words.levelExplanation(.admin))

        // Scenario PAGE-15
        // 7. With Groceries open, not a page, Leslie joins Later with its
        // link and adds Costco to Groceries, at Add. Later's page, opened
        // after she joined, shows her at once, with no sync pressed.
        run.openBudget(named: groceries)
        XCTAssertTrue(run.wait(for: summary, until: "exists == false", timeout: 10), "the page stayed over Groceries")
        _ = try await leslie.join(laterLink, as: "Leslie")
        try await leslie.addEntry("Costco", amount: Money(minorUnits: 2863), inBudget: groceries, group: later)
        run.openGroupPage(named: later)
        XCTAssertTrue(run.wait(for: summary, holds: twoOfUs, timeout: 30),
                      "Later's page, opened after she joined, says \(run.text(of: summary)), not \(twoOfUs)")
        XCTAssertTrue(run.listText("Leslie").waitForExistence(timeout: 5),
                      "Later's page does not show her. On the page: \(run.pageDescription())")

        // 8. Leslie makes a group of her own, with Market in its budget, and
        // a link that invites at Add. Robin joins with it through Join a
        // Group…, and opens its page.
        let hersLink = try await leslie.shareNewGroup(hers, budget: costs, entry: "Market",
                                                      amount: Money(minorUnits: 1250), myName: "Leslie", role: .add)
        run.join(hersLink.url, as: "Robin")
        run.openGroupPage(named: hers)
        XCTAssertTrue(run.wait(for: summary, holds: madeByLeslie, timeout: 30),
                      "her group's page says \(run.text(of: summary)), not \(madeByLeslie)")
        let herGroup = try leslie.group(named: hers).id

        // Scenario PAGE-12
        // 9. At Add, Robin's page shows labels only: Leslie's row says Owner,
        // and his own says Add. There is no level list, no Remove… and no
        // Invite Someone…, and Leave Group… is at the bottom.
        run.expectLabelsOnly([("Leslie", .superadmin), (you, .write)], "at Add")
        XCTAssertFalse(run.element(AccessibilityID.groupInvite).exists, "Invite Someone\u{2026} at Add")
        run.expectLeaveGroupAtTheBottom(below: ["Leslie", you], "at Add")

        // Scenario PAGE-12
        // 10. At View the page is the same, with View as his label. Leslie
        // makes it View, and Robin's next sync shows it.
        try await leslie.setLevelOfTheOther(.read, in: hers)
        run.syncAndWait("after Leslie made him View")
        run.expectLabelsOnly([("Leslie", .superadmin), (you, .read)], "at View")
        XCTAssertFalse(run.element(AccessibilityID.groupInvite).exists, "Invite Someone\u{2026} at View")
        run.expectLeaveGroupAtTheBottom(below: ["Leslie", you], "at View")

        // 11. Leslie makes Robin a manager, and the third person joins her
        // group at Add, with a link she made. They give no name, so the page
        // calls them Someone.
        try await leslie.setLevelOfTheOther(.manage, in: hers)
        let thirdLink = try await leslie.sync.share(group: herGroup, groupName: hers, level: InviteRole.add.level,
                                                    historyAccess: .all, myName: "Leslie")
        _ = try await third.join(thirdLink, as: "")
        run.syncAndWait("after the third person joined")
        XCTAssertTrue(run.listText(someone).waitForExistence(timeout: 30),
                      "the third person's row does not show. On the page: \(run.pageDescription())")

        // Scenario PAGE-11
        // 12. At Manage, Robin may change and remove only people below
        // Manage. The third person's row offers View and Add, and Remove….
        // Leslie made the group, and a manager changes no one at Manage, so
        // her row and his own show plain labels, with no Remove…. Invite
        // Someone… shows, and Leave Group… is at the bottom.
        run.expect(plainLevels: [("Leslie", .superadmin), (you, .manage)], "at Manage")
        XCTAssertEqual(run.levels(offeredOnRowOf: someone),
                       [MembersScreen.Words.levelTitle(.read), MembersScreen.Words.levelTitle(.write)],
                       "the third person's level list does not offer View and Add alone")
        XCTAssertEqual(run.removeButtons(), [AccessibilityID.groupRemove(someone)],
                       "Remove\u{2026} is not on the third person's row alone")
        XCTAssertTrue(run.element(AccessibilityID.groupInvite).waitForExistence(timeout: 10),
                      "no Invite Someone\u{2026} at Manage. On the page: \(run.pageDescription())")
        run.expectLeaveGroupAtTheBottom(below: ["Leslie", you, someone], "at Manage")

        // Scenario PAGE-11
        // 13. Remove… on the third person's row takes them out, and the line
        // says two people are left.
        run.removeFromGroup(someone)
        XCTAssertTrue(run.listText(MembersScreen.Words.removed(someone)).waitForExistence(timeout: 30),
                      "no line saying the third person was removed. On screen: \(run.visibleTexts())")
        XCTAssertTrue(run.wait(for: summary, holds: madeByLeslie, timeout: 15),
                      "after the removal the page says \(run.text(of: summary)), not \(madeByLeslie)")
        await third.cleanUp()

        // Scenario PAGE-14
        // 14. Leslie makes Robin an admin. After his next sync his own row
        // says Admin, and the group's menu should offer him Delete…, which
        // deletes it for everyone, in place of Leave…. What the menu offers
        // is read here, for up to 30 seconds, and checked in step 21, after
        // the tidy, so that a failure there leaves nothing on staging. When
        // it never offers Delete…, it is read once more after the group's
        // budgets are hidden and shown again, which draws its line anew, to
        // say in the failure whether that changes it. A right-click can land
        // on the line beside hers, so a menu counts as hers only when it
        // offers People…, as a group's menu does, and no New Budget in
        // Household… or in Later…, which Robin's own groups always offer.
        try await leslie.setLevelOfTheOther(.admin, in: hers)
        run.syncAndWait("after Leslie made him an admin")
        run.expect(level: .admin, onRowOf: you, "as an admin")
        let hersLine = AccessibilityID.sidebarGroup(hers)
        let adminMenu = run.menuOffers(onGroup: hers, notOf: [household, later],
                                       until: MainScreen.Words.delete, not: MainScreen.Words.leave)
        var redrawnMenu: [String]?
        if !adminMenu.contains(MainScreen.Words.delete) {
            run.clickGroupArrow(hers)
            run.clickGroupArrow(hers)
            redrawnMenu = run.menuOffers(onGroup: hers, notOf: [household, later])
        }

        // Scenario PAGE-14
        // 15. Leave Group… on the page asks first, "Leave “…”?", with Leave
        // and Cancel, in words that start with what leaving does. Cancel
        // changes nothing.
        // How every leave's words start: what the shared words for a leave
        // with a count of what goes, and one without, have in common.
        let start = Self.commonStart(SyncWording.leaveGroupMessage(sendsChanges: true, taking: "1 budget"),
                                     SyncWording.leaveGroupMessage(sendsChanges: false))
        let leaveTitle = run.app.staticTexts[MembersScreen.Words.leaveTitle(hers)]
        run.click(AccessibilityID.groupLeave)
        XCTAssertTrue(leaveTitle.waitForExistence(timeout: 5), "no question before leaving. On screen: \(run.visibleTexts())")
        let opening = run.app.staticTexts.matching(NSPredicate(format: "value BEGINSWITH %@ OR label BEGINSWITH %@",
                                                               start, start)).firstMatch
        XCTAssertTrue(opening.exists, "the question's words do not start \(start). On screen: \(run.visibleTexts())")
        XCTAssertNotNil(run.dialogButton(MembersScreen.Words.leaveButton), "no Leave on the question")
        try XCTUnwrap(run.dialogButton(MainScreen.Words.cancel), "no Cancel on the question").click()
        XCTAssertTrue(run.wait(for: leaveTitle, until: "exists == false", timeout: 5), "the question stayed after Cancel")
        XCTAssertTrue(summary.exists && run.listText(you).exists, "Cancel changed the page")
        XCTAssertTrue(run.element(hersLine).exists, "Cancel took the group out of the sidebar")

        // Scenario PAGE-14
        // 16. Leave Group… again, then Leave: the group and its page go from
        // this Mac. Leslie keeps it, with Market in Costs, and once Robin's
        // leave reaches the server, her page lists only her.
        run.click(AccessibilityID.groupLeave)
        try XCTUnwrap(run.dialogButton(MembersScreen.Words.leaveButton), "no Leave on the question").click()
        XCTAssertTrue(run.wait(for: run.element(hersLine), until: "exists == false", timeout: 10),
                      "her group is still in the sidebar")
        XCTAssertTrue(run.wait(for: summary, until: "exists == false", timeout: 10), "its page is still open")
        let left = try await leslie.waitForMembers(1, in: hers, timeout: 60)
        XCTAssertTrue(left, "the server still lists Robin in her group")
        try await leslie.syncAll()
        let herPage = MembersScreen(actions: leslie.sync, group: herGroup, groupName: hers)
        XCTAssertEqual(herPage.rows.map(\.label), [MembersScreen.Words.you("Leslie")], "her page does not list only her")
        XCTAssertEqual(herPage.summary, alone, "her page does not say nobody else is in it")
        XCTAssertEqual(try leslie.entry("Market", inGroup: hers).budgetID, try leslie.budget(named: costs, inGroup: hers).id,
                       "Market is no longer in Costs")

        // 17. Tidy: Leslie's group goes, for everyone.
        await leslie.deleteGroup(named: hers)

        // 18. Groceries, synced: Costco is in it, added by Leslie.
        run.openBudget(named: groceries)
        run.syncAndWait("before the removal")
        XCTAssertTrue(run.entryRow("Costco").waitForExistence(timeout: 15),
                      "Costco is not in Groceries. On screen: \(run.visibleTexts())")
        XCTAssertTrue(run.listText("Leslie").waitForExistence(timeout: 15), "the Added by column does not name her")

        // Scenario PAGE-17
        // 19. Robin removes Leslie on Later's page. At his next sync Costco is
        // still in Groceries, and as the owner he may still change it or
        // delete it: a click opens it with Save and Delete…. Whether its
        // Added by column still says Leslie is read here, and checked in step
        // 21, after the tidy, so that a failure there leaves nothing on
        // staging.
        run.openGroupPage(named: later)
        run.removeFromGroup("Leslie")
        XCTAssertTrue(run.listText(MembersScreen.Words.removed("Leslie")).waitForExistence(timeout: 30),
                      "no line saying she was removed. On screen: \(run.visibleTexts())")
        run.openBudget(named: groceries)
        run.syncAndWait("after the removal")
        XCTAssertTrue(run.entryRow("Costco").waitForExistence(timeout: 15),
                      "Costco went with Leslie. On screen: \(run.visibleTexts())")
        let addedByAfterRemoval = run.listText("Leslie").waitForExistence(timeout: 15)
        let seenAfterRemoval = addedByAfterRemoval ? [] : run.visibleTexts()
        run.clickRow("Costco")
        run.expectSheet(for: "Costco")
        XCTAssertTrue(run.element(AccessibilityID.entrySave).exists, "no Save on Costco for its owner")
        XCTAssertTrue(run.element(AccessibilityID.entryDelete).exists, "no Delete\u{2026} on Costco for its owner")
        run.click(AccessibilityID.entryCancel)
        run.expectNoSheet()

        // 20. Tidy: Later goes, for everyone, and Robin's sync sends it. He
        // signs out from Bills. Then Leslie, an admin of Household since step
        // 6, deletes it for everyone, and signs out.
        run.deleteGroup(named: later)
        run.openBudget(named: bills)
        run.syncAndWait("after Later was deleted")
        run.signOut()
        await leslie.deleteForEveryone(household)
        await leslie.cleanUp()

        // Scenario PAGE-14, PAGE-17
        // 21. What steps 14 and 19 read, checked now that nothing is left on
        // staging: an admin's menu for Leslie's group offered Delete… and
        // not Leave…, and after the removal Costco's Added by column still
        // said Leslie. One check reports both.
        var wrong: [String] = []
        if !adminMenu.contains(MainScreen.Words.delete) || adminMenu.contains(MainScreen.Words.leave) {
            let redrawn: String = redrawnMenu
                .map { ". Once its budgets were hidden and shown again, it offered \($0)" } ?? ""
            wrong.append("once Robin was an admin of Leslie's group, its menu offered \(adminMenu) for 30 seconds, "
                         + "not Delete\u{2026}" + redrawn)
        }
        if !addedByAfterRemoval {
            wrong.append("after the removal and a sync, the Added by column did not say Leslie for Costco. "
                         + "On screen then: \(seenAfterRemoval)")
        }
        XCTAssertTrue(wrong.isEmpty, wrong.joined(separator: ". And "))
    }

    /// The longest start two texts share.
    private static func commonStart(_ first: String, _ second: String) -> String {
        String(zip(first, second).prefix { $0 == $1 }.map(\.0))
    }

    /// Part of each name, so runs never share one.
    private static func stamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: Date())
    }
}

// MARK: - Reading a group's page and the sidebar

private extension TestApp {
    /// Waits up to 30 seconds for a line in the sidebar to be marked as
    /// picked, or not, the way a screen reader hears it: selected.
    func waitUntilMarked(_ identifier: String, _ marked: Bool = true) -> Bool {
        let line = element(identifier)
        let holds = NSPredicate { _, _ in line.exists && line.isSelected == marked }
        let done = XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: holds, object: nil)], timeout: 30)
        return done == .completed
    }

    /// The lines the sidebar marks as picked, by identifier: the open
    /// budget's, or the name of the group whose page is open.
    func markedSidebarLines() -> [String] {
        let prefixes = [AccessibilityID.sidebarGroup(""), AccessibilityID.sidebarBudget("")]
        let marked = windowParts().filter { part in
            part.isSelected && prefixes.contains { part.identifier.hasPrefix($0) }
        }
        return Set(marked.map(\.identifier)).sorted()
    }

    /// Every element of the window, from one snapshot. Reading each one
    /// live is slow, and the page can change between reads.
    func windowParts() -> [XCUIElementSnapshot] {
        guard let root = try? app.windows.firstMatch.snapshot() else { return [] }
        var parts: [XCUIElementSnapshot] = []
        var waiting = [root]
        while let node = waiting.popLast() {
            parts.append(node)
            waiting.append(contentsOf: node.children)
        }
        return parts
    }

    /// What an element shows: a text's words, which the Mac gives as its
    /// value, or else its label, as a button's title is.
    func shown(_ part: XCUIElementSnapshot) -> String {
        if let value = part.value as? String, !value.isEmpty { return value }
        return part.label
    }

    /// What a group's page shows: every element from the left edge of the
    /// line under its name rightward, which leaves the sidebar out. Empty
    /// when no page is open.
    func pageParts() -> [XCUIElementSnapshot] {
        let parts = windowParts()
        guard let summary = parts.first(where: { $0.identifier == AccessibilityID.groupSummary }) else { return [] }
        return parts.filter { !$0.frame.isEmpty && $0.frame.minX >= summary.frame.minX - 2 }
    }

    /// The page's heading: the text right above the line under it, at the
    /// same left edge. Nil when no page is open.
    func pageHeading() -> String? {
        let parts = pageParts()
        guard let summary = parts.first(where: { $0.identifier == AccessibilityID.groupSummary }) else { return nil }
        return parts.filter { part in
            part.elementType == .staticText && part.frame.maxY <= summary.frame.minY + 1
                && abs(part.frame.minX - summary.frame.minX) < 2
        }
        .max { $0.frame.maxY < $1.frame.maxY }.map(shown)
    }

    /// The level lists among these: pop-up buttons, or menu buttons,
    /// whichever way the system draws a list.
    func levelLists(in parts: [XCUIElementSnapshot]) -> [XCUIElementSnapshot] {
        parts.filter { $0.elementType == .popUpButton || $0.elementType == .menuButton }
    }

    /// The Remove… buttons on a group's page, by identifier.
    func removeButtons() -> [String] {
        let removes = pageParts().filter { $0.identifier.hasPrefix(AccessibilityID.groupRemove("")) }
        return Set(removes.map(\.identifier)).sorted()
    }

    /// A person's row on a group's page, by the name it starts with: "Robin
    /// (you)", or a name alone. It runs from the name down to the line under
    /// it, which says what their level lets them do, and that line is
    /// `words`. Nil when no row shows that name.
    func personRow(_ label: String, in parts: [XCUIElementSnapshot])
        -> (name: CGRect, span: ClosedRange<CGFloat>, words: String)? {
        let texts = parts.filter { $0.elementType == .staticText }
        guard let name = texts.first(where: { shown($0) == label }) else { return nil }
        let under = texts.filter { text in
            text.frame.minY >= name.frame.maxY - 1 && abs(text.frame.minX - name.frame.minX) < 2
        }
        .min { $0.frame.minY < $1.frame.minY }
        let bottom = under?.frame.maxY ?? name.frame.maxY
        return (name.frame, (name.frame.minY - 2)...(bottom + 2), under.map(shown) ?? "")
    }

    /// The level a person's row shows as a plain label, right of the name.
    /// Nil when the row has a level list, shows no level, or is not there.
    func plainLevel(onRowOf label: String) -> String? {
        let parts = pageParts()
        guard let row = personRow(label, in: parts),
              !levelLists(in: parts).contains(where: { row.span.contains($0.frame.midY) }) else { return nil }
        let titles = Set(AccessLevel.allCases.map(MembersScreen.Words.levelTitle))
        return parts.first { part in
            part.elementType == .staticText && titles.contains(shown(part)) && row.span.contains(part.frame.midY)
                && part.frame.minX > row.name.maxX
        }.map(shown)
    }

    /// The level a person's row shows, in its level list or as a plain
    /// label. Nil when no row shows that name.
    func levelShown(onRowOf label: String) -> String? {
        let parts = pageParts()
        guard let row = personRow(label, in: parts) else { return nil }
        if let list = levelLists(in: parts).first(where: { row.span.contains($0.frame.midY) }) { return shown(list) }
        return plainLevel(onRowOf: label)
    }

    /// Waits for a person's row to show `level`, in its level list or as a
    /// plain label, as a sync may still be bringing it.
    func expect(level: AccessLevel, onRowOf label: String, _ what: String,
                file: StaticString = #filePath, line: UInt = #line) {
        let title = MembersScreen.Words.levelTitle(level)
        let shows = NSPredicate { _, _ in self.levelShown(onRowOf: label) == title }
        let done = XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: shows, object: nil)], timeout: 30)
        XCTAssertEqual(done, .completed, "\(what): \(label)'s row does not show \(title). On the page: "
                       + pageDescription(), file: file, line: line)
    }

    /// The level list on a person's row, live, so it can be clicked.
    func levelList(onRowOf label: String) -> XCUIElement? {
        guard let row = personRow(label, in: pageParts()) else { return nil }
        let left = element(AccessibilityID.groupSummary).frame.minX - 2
        let window = app.windows.firstMatch
        let lists = window.popUpButtons.allElementsBoundByIndex + window.menuButtons.allElementsBoundByIndex
        return lists.first { $0.frame.minX >= left && row.span.contains($0.frame.midY) }
    }

    /// The levels a person's level list offers, read from its menu, which
    /// is then closed with nothing picked. The menu is looked for under the
    /// list first, then anywhere in the app, where only the levels count.
    func levels(offeredOnRowOf label: String) -> [String] {
        guard let list = levelList(onRowOf: label) else { return [] }
        waitUntilHittable(list, "\(label)'s level list")
        list.click()
        let levels = Set(AccessLevel.allCases.map(MembersScreen.Words.levelTitle))
        let items = list.menuItems.firstMatch.waitForExistence(timeout: 5) ? list.menuItems : app.menuItems
        let titles = items.allElementsBoundByIndex.map(\.title).filter { levels.contains($0) }
        app.typeKey(.escape, modifierFlags: [])
        return titles
    }

    /// Picks a level in the level list on a person's row, and waits for the
    /// list to show it, once the server has taken the change.
    func pick(_ level: AccessLevel, onRowOf label: String, file: StaticString = #filePath, line: UInt = #line) {
        let title = MembersScreen.Words.levelTitle(level)
        guard let list = levelList(onRowOf: label) else {
            XCTFail("no level list on \(label)'s row. On the page: \(pageDescription())", file: file, line: line)
            return
        }
        waitUntilHittable(list, "\(label)'s level list")
        list.click()
        let inList = list.menuItems[title].firstMatch
        let item = inList.waitForExistence(timeout: 5) ? inList : menuItem(title)
        XCTAssertTrue(item.waitForExistence(timeout: 5),
                      "no \(title) in \(label)'s level list. Menu items on screen: \(visibleMenuItems())",
                      file: file, line: line)
        item.click()
        let shows = NSPredicate { _, _ in self.levelList(onRowOf: label).map { self.text(of: $0) } == title }
        let done = XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: shows, object: nil)], timeout: 30)
        XCTAssertEqual(done, .completed, "\(label)'s level list did not move to \(title). On the page: "
                       + pageDescription(), file: file, line: line)
    }

    /// Waits for the line under a person's name to say `words`.
    func expect(rowOf label: String, says words: String, file: StaticString = #filePath, line: UInt = #line) {
        let says = NSPredicate { _, _ in self.personRow(label, in: self.pageParts())?.words == words }
        let done = XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: says, object: nil)], timeout: 15)
        XCTAssertEqual(done, .completed, "\(label)'s row does not say \(words) It says: "
                       + (personRow(label, in: pageParts())?.words ?? "nothing, as no row shows that name"),
                       file: file, line: line)
    }

    /// Waits for each of these rows to show its person's level as a plain
    /// label, with no level list, as a sync may still be bringing it.
    func expect(plainLevels rows: [(label: String, level: AccessLevel)], _ what: String,
                file: StaticString = #filePath, line: UInt = #line) {
        for row in rows {
            let title = MembersScreen.Words.levelTitle(row.level)
            let labelled = NSPredicate { _, _ in self.plainLevel(onRowOf: row.label) == title }
            let done = XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: labelled, object: nil)], timeout: 30)
            XCTAssertEqual(done, .completed, "\(what): \(row.label)'s row does not show \(title) as a plain label. "
                           + "On the page: \(pageDescription())", file: file, line: line)
        }
    }

    /// A member's page with labels only: each row shows its person's level
    /// as a plain label, and the page has no level list and no Remove….
    func expectLabelsOnly(_ rows: [(label: String, level: AccessLevel)], _ what: String,
                          file: StaticString = #filePath, line: UInt = #line) {
        expect(plainLevels: rows, what, file: file, line: line)
        XCTAssertEqual(levelLists(in: pageParts()).count, 0, "\(what): a level list on the page. On the page: "
                       + pageDescription(), file: file, line: line)
        XCTAssertEqual(removeButtons(), [], "\(what): Remove\u{2026} on the page", file: file, line: line)
    }

    /// Invite Someone… shows, above the first person's row.
    func expectInviteAtTheTop(above first: String, file: StaticString = #filePath, line: UInt = #line) {
        let invite = element(AccessibilityID.groupInvite)
        XCTAssertTrue(invite.waitForExistence(timeout: 10), "no Invite Someone\u{2026}. On the page: "
                      + pageDescription(), file: file, line: line)
        guard let row = personRow(first, in: pageParts()) else {
            XCTFail("no row for \(first). On the page: \(pageDescription())", file: file, line: line)
            return
        }
        XCTAssertLessThanOrEqual(invite.frame.maxY, row.span.lowerBound,
                                 "Invite Someone\u{2026} is not at the top, above \(first)", file: file, line: line)
    }

    /// Leave Group… shows below every person's row.
    func expectLeaveGroupAtTheBottom(below people: [String], _ what: String,
                                     file: StaticString = #filePath, line: UInt = #line) {
        let leave = element(AccessibilityID.groupLeave)
        XCTAssertTrue(leave.waitForExistence(timeout: 10), "\(what): no Leave Group\u{2026}. On the page: "
                      + pageDescription(), file: file, line: line)
        let parts = pageParts()
        let bottoms = people.compactMap { personRow($0, in: parts)?.span.upperBound }
        XCTAssertEqual(bottoms.count, people.count, "\(what): not every row shows. On the page: \(pageDescription())",
                       file: file, line: line)
        XCTAssertGreaterThanOrEqual(leave.frame.minY, bottoms.max() ?? .infinity,
                                    "\(what): Leave Group\u{2026} is not at the bottom", file: file, line: line)
    }

    /// What the page shows, for a failure message: each text, list and
    /// button, with what it says. Never a test account's address.
    func pageDescription() -> String {
        let kinds: [XCUIElement.ElementType] = [.staticText, .button, .popUpButton, .menuButton]
        let giveaways = ScreenPrivacy.giveaways
        return pageParts().filter { kinds.contains($0.elementType) }
            .map { part in (levelLists(in: [part]).isEmpty ? "" : "list ") + shown(part) }
            .filter { text in !text.isEmpty && !giveaways.contains { text.lowercased().contains($0) } }
            .joined(separator: " | ")
    }

    // MARK: Doing things

    /// What a group's menu in the sidebar offers, read from one snapshot of
    /// the app while it is open, then closed with Escape. A right-click can
    /// land before the line holds still, and so on the line beside it, which
    /// opens that line's menu. So a read counts only when it offers People…,
    /// which no budget's menu does, and New Budget in… for none of `others`:
    /// the other groups in the sidebar, each one this person may add budgets
    /// to, so that their menus always offer it. It tries three times, as
    /// `openMenu` does. Empty when no read counted.
    func menuOffers(onGroup name: String, notOf others: [String]) -> [String] {
        let identifier = AccessibilityID.sidebarGroup(name)
        let line = element(identifier)
        // Every group's menu ends with one of these.
        let last = [MainScreen.Words.delete, MainScreen.Words.leave]
        let othersItems: Set<String> = Set(others.map(MainScreen.Words.newBudget(in:)))
        for _ in 0..<3 {
            revealInSidebar(line)
            rightClick(line, identifier)
            let opened = NSPredicate { _, _ in last.contains { self.menuItem($0).exists } }
            let done = XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: opened, object: nil)], timeout: 3)
            let titles = done == .completed ? openMenuTitles() : []
            app.typeKey(.escape, modifierFlags: [])
            if titles.contains(MembersScreen.Words.menuItem) && othersItems.isDisjoint(with: titles) { return titles }
        }
        return []
    }

    /// What a group's menu offers once it offers `wanted` and not
    /// `unwanted`, read again every two seconds for up to 30, as a sync or a
    /// redraw may still be bringing it. Only reads that count, as
    /// `menuOffers(onGroup:notOf:)` says, are kept. What the last of them
    /// offered when it never does, and empty when none counted.
    func menuOffers(onGroup name: String, notOf others: [String], until wanted: String,
                    not unwanted: String) -> [String] {
        let deadline = Date().addingTimeInterval(30)
        var offers: [String] = menuOffers(onGroup: name, notOf: others)
        while !offers.contains(wanted) || offers.contains(unwanted), Date() < deadline {
            // A waiter on an expectation nobody fulfils is XCTest's way to pause.
            _ = XCTWaiter().wait(for: [XCTestExpectation(description: "the menu to change")], timeout: 2)
            let read: [String] = menuOffers(onGroup: name, notOf: others)
            if !read.isEmpty { offers = read }
        }
        return offers
    }

    /// The items of the menus open on screen, from one snapshot of the app.
    /// A menu that is not open, such as the menu bar's, has items of no size.
    func openMenuTitles() -> [String] {
        guard let root = try? app.snapshot() else { return [] }
        var titles: [String] = []
        func walk(_ node: XCUIElementSnapshot) {
            if node.elementType == .menuItem, !node.frame.isEmpty, !node.title.isEmpty { titles.append(node.title) }
            node.children.forEach(walk)
        }
        walk(root)
        return titles
    }

    /// Delete… from a group's menu in the sidebar, for a group nobody else
    /// is in: it asks first, and Delete takes the group's line away.
    func deleteFromMenu(_ group: String, file: StaticString = #filePath, line: UInt = #line) {
        let identifier = AccessibilityID.sidebarGroup(group)
        let header = element(identifier)
        openMenu(on: header, identifier, offering: MainScreen.Words.delete)
        clickMenuItem(MainScreen.Words.delete)
        let question = PendingDelete.group(BudgetGroup(name: group), budgets: 0, reach: .justYou)
        XCTAssertTrue(app.staticTexts[question.title].waitForExistence(timeout: 5),
                      "no question before deleting \(group). On screen: \(visibleTexts())", file: file, line: line)
        guard let confirm = dialogButton(question.confirmLabel) else {
            XCTFail("no \(question.confirmLabel) on the question. On screen: \(visibleTexts())", file: file, line: line)
            return
        }
        confirm.click()
        XCTAssertTrue(wait(for: header, until: "exists == false", timeout: 10), "\(group) is still in the sidebar",
                      file: file, line: line)
    }

    /// Sync, in the toolbar, then waits for it to finish: the button is off
    /// while it runs, and on again after. A sync that failed says so in its
    /// place.
    func syncAndWait(_ what: String, file: StaticString = #filePath, line: UInt = #line) {
        syncNow()
        let button = element(AccessibilityID.toolbarSync)
        var looks = 0
        while button.isEnabled, looks < 15 {
            Thread.sleep(forTimeInterval: 0.2)
            looks += 1
        }
        XCTAssertTrue(wait(for: button, until: "isEnabled == true", timeout: 60), "\(what): the sync never finished",
                      file: file, line: line)
        XCTAssertNotEqual(button.label, SyncWording.syncTitle(for: .failed("")), "\(what): the sync failed",
                          file: file, line: line)
    }
}

// MARK: - What Leslie's app shows

private extension SecondAccount {
    /// Whether her screen for a budget offers Add and Import statement:
    /// BudgetScreen, which every app draws, over her budgets read the way her
    /// window would read them. A change made elsewhere reaches her only
    /// through the server, so it syncs until the screen says `expected`, or
    /// the time runs out. Nil when the budget never showed.
    func budgetOffersAdd(_ budget: String, in group: String, expecting expected: Bool,
                         timeout: TimeInterval = 30) async throws -> Bool? {
        let deadline = Date().addingTimeInterval(timeout)
        var offers: Bool?
        repeat {
            try await syncAll()
            let window = Workspace(model: AppModel(store: sync.store), sync: sync)
            if let found = window.model.groups.first(where: { $0.name == group }),
               let summary = window.model.summaries[found.id]?.first(where: { $0.budget.name == budget }) {
                offers = BudgetScreen(summary: summary, model: window.model, me: sync.userID).mayAdd
                if offers == expected { return offers }
            }
            try await Task.sleep(for: .seconds(2))
        } while Date() < deadline
        return offers
    }

    /// Deletes a group she may delete for everyone, as its maker or an
    /// admin, after a sync, so that her level in it is the server's. Best
    /// effort, like `deleteGroup(named:)`.
    func deleteForEveryone(_ name: String) async {
        try? await syncAll()
        await deleteGroup(named: name)
    }
}
