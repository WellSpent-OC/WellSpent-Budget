import Foundation
import XCTest
import WellSpentAppCore
import WellSpentModel
import WellSpentSync

/// Signed in, on a phone: sign in by pasting, see an entry someone else adds
/// to a shared group arrive when Home is pulled down, with her name beside
/// it, and sign out. Leslie, and Robin's other device, have no window: each
/// is a coordinator inside this process, against the same staging server.
///
/// Needs the four WELLSPENT_UI_TEST_ variables (see UITestAccounts.swift)
/// and skips without them. Both accounts must exist on staging with their
/// addresses confirmed, since joining needs a confirmed address. Every run
/// makes a group of its own, named with the time, and deletes it at the end
/// for everyone.
final class PhoneSignInSyncTests: XCTestCase {
    nonisolated(unsafe) private static var dataRootPath: String?

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    /// No await in it: an awaiting teardown never finished after a halted
    /// test on the Mac's first runs. The staging side is tidied at the end of
    /// the test itself, so a halted run can leave a group named
    /// "UI Test <time>" on staging.
    override func tearDown() {
        let app = XCUIApplication()
        if app.state != .notRunning { app.terminate() }
        if let path = Self.dataRootPath { try? FileManager.default.removeItem(atPath: path) }
        Self.dataRootPath = nil
        super.tearDown()
    }

    @MainActor
    func testSignInSharedEntryArrivesAndSignOut() async throws {
        let accounts = try TestAccounts.fromEnvironment()
        let run = PhoneTestApp()
        Self.dataRootPath = run.dataRoot.path
        let leslie = try SecondAccount(server: accounts.server)
        let robinsOtherDevice = try SecondAccount(server: accounts.server, settingsSuite: "app.wellspent.uitest.robin")
        let groupName = "UI Test \(PhoneTestApp.stamp())"
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

        // Scenario ENTRY-08, ENTRY-09
        // 3. Leslie shares a group with an entry in it, and Robin's account
        // takes the invite on his other device. Pulling Home down brings the
        // group in, and her entry says she added it.
        try await leslie.signIn(email: accounts.secondEmail, password: accounts.secondPassword)
        await leslie.deleteLeftoverRuns()
        let link = try await leslie.shareNewGroup(groupName, budget: "Costs", entry: "Costco",
                                                  amount: Money(minorUnits: 9900), myName: "Leslie", role: .add)
        try await robinsOtherDevice.signIn(email: accounts.email, password: accounts.password)
        _ = try await robinsOtherDevice.join(link, as: "Robin")
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
        run.scrollTo(AccessibilityID.sidebarBudget("Costs"))
        run.openBudget(named: "Costs")
        XCTAssertTrue(run.element(AccessibilityID.entryRow("Costco")).waitForExistence(timeout: 15),
                      "Leslie's entry is not in the list. On screen: \(run.visibleTexts())")
        XCTAssertTrue(run.text("Leslie").exists, "her entry does not say she added it")
        run.goBack()

        // Scenario ACCT-11
        // 4. Sign out: the foot says the budgets are kept on this iPhone,
        // and the account's group goes from Home.
        run.signOut()
        XCTAssertTrue(run.text(SyncWording.footer(signedIn: false, device: PhoneTestApp.device)).exists,
                      "still signed in. On screen: \(run.visibleTexts())")
        XCTAssertFalse(header.exists, "the account's group is still on Home")

        // 5. Tidy: the group goes for everyone, every session ends.
        await leslie.deleteGroup(named: groupName)
        await robinsOtherDevice.cleanUp()
        await leslie.cleanUp()
    }
}
