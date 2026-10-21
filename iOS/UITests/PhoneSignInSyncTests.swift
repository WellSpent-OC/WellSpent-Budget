import Foundation
import UIKit
import XCTest
import WellSpentAppCore
import WellSpentModel
import WellSpentSync

/// Signed in, on a phone: sign in by pasting, see an entry someone else adds
/// to a shared group arrive when Home is pulled down, with her name beside
/// it, find it opens read-only at Add while his own stays his to change, and
/// sign out. Leslie, and Robin's other device, have no window: each
/// is a coordinator inside this process, against the same staging server.
///
/// Needs the four WELLSPENT_UI_TEST_ variables (see UITestAccounts.swift)
/// and skips without them. Both accounts must exist on staging with their
/// addresses confirmed, since joining needs a confirmed address. Every run
/// makes a group of its own, named with the time, and deletes it at the end
/// for everyone. Other runs may share the accounts at the same time, so it
/// never assumes the groups it sees are its own.
final class PhoneSignInSyncTests: XCTestCase {
    nonisolated(unsafe) private static var dataRootPath: String?

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    /// No await in it: an awaiting teardown never finished after a halted
    /// test on the Mac's first runs. The staging side is tidied at the end of
    /// the test itself, so a halted run can leave a group named
    /// "UI Phone <time>" on staging, which a later run clears.
    override func tearDown() {
        let app = XCUIApplication()
        if app.state != .notRunning { app.terminate() }
        if let path = Self.dataRootPath { try? FileManager.default.removeItem(atPath: path) }
        Self.dataRootPath = nil
        // A halted run must not leave the staging password on the pasteboard.
        UIPasteboard.general.items = []
        super.tearDown()
    }

    @MainActor
    func testSignInSharedEntryArrivesAndSignOut() async throws {
        let accounts = try TestAccounts.fromEnvironment()
        let run = PhoneTestApp()
        Self.dataRootPath = run.dataRoot.path
        let leslie = try SecondAccount(server: accounts.server)
        let robinsOtherDevice = try SecondAccount(server: accounts.server, settingsSuite: "app.wellspent.uitest.robin")
        let stamp = PhoneTestApp.stamp()
        let groupName = SecondAccount.phoneRunPrefix + stamp
        // Named for the run too: an earlier run's group can still be on Home
        // while its delete syncs, and a test taps rows by name.
        let budgetName = "Costs \(stamp)"
        // The phone's own group, named like the run's so a later run clears it.
        let phoneGroup = groupName + " mine"
        let phoneBudget = "Trip \(stamp)"
        run.launch()

        // Scenario PASTE-02, ACCT-08
        // 1. Signed in by pasting the email and the password. The foot says
        // the budgets sync through the server, and Account shows in place of
        // Sign in.
        try run.signIn(email: accounts.email, password: accounts.password, server: accounts.server)
        XCTAssertTrue(run.element(AccessibilityID.toolbarAccount).waitForExistence(timeout: 10), "no Account")
        XCTAssertFalse(run.element(AccessibilityID.sidebarSignIn).exists, "Sign in still shows")

        // Scenario SAMP-06
        // 2. The samples stay on the phone: none show in the account.
        XCTAssertTrue(run.wait(for: run.element(AccessibilityID.sidebarGroup("Side Business")),
                               until: "exists == false", timeout: 10), "a sample group came into the account")

        // Scenario BUDGET-01, BUDGET-03, ENTRY-01
        // 3. What the phone makes reaches the server: a group, a budget in it
        // and an entry, made on the phone while signed in, all arrive on
        // Robin's other device, signed in to the same account.
        try await robinsOtherDevice.signIn(email: accounts.email, password: accounts.password)
        await robinsOtherDevice.deleteLeftoverRuns()
        run.addGroup(named: phoneGroup)
        run.addBudget(named: phoneBudget, amount: "300", inGroup: phoneGroup)
        run.addEntry(merchant: "Ferry", amount: "25.00")
        run.goBack()
        // No pull: the app sends each change a moment after it is made.
        let arrived = try await robinsOtherDevice.waitFor(group: phoneGroup, budget: phoneBudget, merchant: "Ferry")
        XCTAssertTrue(arrived, "the phone's group, budget and entry did not reach the other device")

        // Scenario ENTRY-08, ENTRY-09
        // 4. Leslie shares a group with an entry in it, and Robin's account
        // takes the invite on his other device. Pulling Home down brings the
        // group in, and her entry says she added it.
        try await leslie.signIn(email: accounts.secondEmail, password: accounts.secondPassword)
        await leslie.deleteLeftoverRuns()
        let link = try await leslie.shareNewGroup(groupName, budget: budgetName, entry: "Costco",
                                                  amount: Money(minorUnits: 9900), myName: "Leslie", role: .add)
        _ = try await robinsOtherDevice.join(link, as: "Robin")
        run.app.swipeDown()
        run.pullDown()
        // The account may hold other groups, so the new one can be below the
        // bottom of the screen.
        let headerID = AccessibilityID.sidebarGroup(groupName)
        var header = run.scrollTo(headerID)
        if !header.exists {
            run.app.swipeDown()
            run.pullDown()
            header = run.scrollTo(headerID)
        }
        XCTAssertTrue(header.exists, "the shared group did not arrive. On screen: \(run.visibleTexts())")
        run.scrollTo(AccessibilityID.sidebarBudget(budgetName))
        run.openBudget(named: budgetName)
        XCTAssertTrue(run.element(AccessibilityID.entryRow("Costco")).waitForExistence(timeout: 15),
                      "Leslie's entry is not in the list. On screen: \(run.visibleTexts())")
        XCTAssertTrue(run.row("Costco", says: "Leslie"), "her entry does not say she added it. The row says: \(run.rowLabel("Costco"))")

        // Scenario EDIT-01, EDIT-11
        // 5. Robin is at Add, so a tap opens her Costco read-only: who added
        // it and where it came from above, its details as plain text, the
        // line saying why, and Done alone.
        run.openEntry("Costco")
        XCTAssertEqual(run.element(AccessibilityID.entryTopLine).label,
                       "\(EntryEditor.Words.addedBy("Leslie")) \u{00B7} Manual")
        XCTAssertEqual(run.element(AccessibilityID.entryDetail(EntryEditor.Words.merchant)).value as? String, "Costco")
        XCTAssertFalse(run.element(AccessibilityID.entryMerchant).exists, "a field, not plain text")
        let line = EntryAccess.someoneElses(name: "Leslie").line ?? ""
        XCTAssertTrue(run.shows(line), "no line saying why. On screen: \(run.visibleTexts())")
        XCTAssertTrue(run.button(AccessibilityID.entryDone).exists, "no Done")
        for other in [AccessibilityID.entrySave, AccessibilityID.entryDelete, AccessibilityID.entryCancel] {
            XCTAssertFalse(run.element(other).exists, "\(other) on a sheet that can't be changed")
        }
        run.tap(AccessibilityID.entryDone)
        run.expectNoSheet()

        // Scenario EDIT-17
        // 6. A swipe to the left on her row offers nothing.
        run.swipeLeft(onEntry: "Costco")
        XCTAssertFalse(run.app.buttons[PhoneWording.button(MainScreen.Words.edit)].waitForExistence(timeout: 3),
                       "the swipe offers Edit on her row")
        XCTAssertFalse(run.app.buttons[PhoneWording.button(MainScreen.Words.delete)].exists,
                       "the swipe offers Delete on her row")

        // Scenario EDIT-11
        // 7. What Robin adds himself, he may change and delete.
        run.addEntry(merchant: "Bakery", amount: "5.00")
        run.openEntry("Bakery")
        XCTAssertTrue(run.button(AccessibilityID.entrySave).exists, "no Save on his own")
        XCTAssertTrue(run.button(AccessibilityID.entryDelete).exists, "no Delete on his own")
        run.tap(AccessibilityID.entryCancel)
        run.expectNoSheet()
        run.goBack()

        // Scenario ACCT-11
        // 8. Sign out: the foot says the budgets are kept on this iPhone,
        // and the account's group goes from Home.
        run.signOut()
        XCTAssertTrue(run.shows(SyncWording.footer(signedIn: false, device: PhoneTestApp.device)),
                      "still signed in. On screen: \(run.visibleTexts())")
        XCTAssertFalse(header.exists, "the account's group is still on Home")

        // 9. Tidy: both groups go for everyone, every session ends.
        await leslie.deleteGroup(named: groupName)
        await robinsOtherDevice.deleteGroup(named: phoneGroup)
        await robinsOtherDevice.cleanUp()
        await leslie.cleanUp()
    }
}
