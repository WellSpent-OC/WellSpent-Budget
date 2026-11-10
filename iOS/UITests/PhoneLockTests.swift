import Foundation
import XCTest
import WellSpentAppCore
import WellSpentModel
import WellSpentPlans

/// Locks and the pick, on a phone. The groups are made first by a headless
/// client signed in as each test account, so their ids are known. Then the
/// app starts with a pinned plan answer that locks some of them
/// (`Workspace.pinnedPlanVariable`) and an empty stand-in store.
///
/// What each screen should say comes from `LockedScreen` and `PickOpenScreen`
/// themselves, so no word is written twice. Signs in, so it runs in light only.
final class PhoneLockTests: XCTestCase {
    nonisolated(unsafe) private static var dataRootPath: String?
    nonisolated(unsafe) private static var planFile: URL?
    nonisolated(unsafe) private static var cleanups: [() async -> Void] = []

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    override func tearDown() {
        let app = XCUIApplication()
        if app.state != .notRunning { app.terminate() }
        if let path = Self.dataRootPath { try? FileManager.default.removeItem(atPath: path) }
        if let file = Self.planFile { try? FileManager.default.removeItem(at: file) }
        Self.dataRootPath = nil
        Self.planFile = nil
        super.tearDown()
    }

    override func tearDown() async throws {
        for cleanup in Self.cleanups { await cleanup() }
        Self.cleanups = []
        try await super.tearDown()
    }

    // MARK: - LOCK-01, LOCK-03

    // Scenario LOCK-01, LOCK-03
    @MainActor
    func testALockedGroupSaysLockedAndShowsWhyInPlaceOfItsPage() async throws {
        let accounts = try TestAccounts.fromEnvironment()
        let stamp = PhoneTestApp.stamp()
        let robin = try await Self.headless(accounts.email, accounts.password, accounts.server, suite: "robin")
        let home = try await Self.makeGroup("Home \(stamp)", for: robin)
        let beach = try await Self.makeGroup("Beach \(stamp)", for: robin)

        let answer = Self.ended(locked: .init(groupIDs: [beach.id], people: [], houseIDs: []),
                                open: .init(groupID: home.id, person: nil, houseIDs: []))
        let run = try launch(with: answer)
        try run.signIn(email: accounts.email, password: accounts.password, server: accounts.server)
        run.syncAndWait()

        // 1. Beach says Locked beside its name on Home, and Home doesn't.
        XCTAssertTrue(run.has(AccessibilityID.lockedMark(beach.id), timeout: 20), "no Locked beside \(beach.name)")
        XCTAssertTrue(run.lacks(AccessibilityID.lockedMark(home.id)), "Locked beside the open group")

        // 2. Opening Beach shows why, in place of its page. Not
        // openGroupPage, which waits for the page this replaces.
        run.scrollTo(AccessibilityID.sidebarGroup(beach.name))
        run.tap(AccessibilityID.sidebarGroup(beach.name))
        let locked = LockedScreen(.ownGroup(open: home.name), groupChangedAt: nil)
        XCTAssertTrue(run.has(AccessibilityID.lockedCard, timeout: 30), "no locked card. On screen: \(run.visibleTexts())")
        XCTAssertTrue(run.shows(locked.title), "no \"\(locked.title)\"")
        for line in locked.lines {
            XCTAssertTrue(run.shows(line), "missing \"\(line)\"")
        }
        for action in locked.actions {
            XCTAssertTrue(run.has(AccessibilityID.lockedAction(action)), "no \(action.title)")
        }
    }

    // MARK: - LOCK-02

    // Scenario LOCK-02
    @MainActor
    func testAGroupWhosePayerIsPastTheirPlanAsksAMemberToPay() async throws {
        let accounts = try TestAccounts.fromEnvironment()
        let stamp = PhoneTestApp.stamp()
        let leslie = try await Self.headless(accounts.secondEmail, accounts.secondPassword, accounts.server,
                                             suite: "leslie")
        let name = SecondAccount.phoneRunPrefix + stamp
        let link = try await leslie.shareNewGroup(name, budget: "Costs \(stamp)", entry: "Costco",
                                                  amount: Money(minorUnits: 9900), myName: "Leslie", role: .add)
        let cabin = try XCTUnwrap(AppModel(store: leslie.sync.store).groups.first { $0.name == name })

        let answer = Self.ended(locked: .init(groupIDs: [cabin.id.uuid], people: [], houseIDs: []), open: nil)
        let run = try launch(with: answer)
        try run.signIn(email: accounts.email, password: accounts.password, server: accounts.server)
        // Joining opens the group, and a locked group opens on the card that
        // takes its page's place. Not the shared join helper, which waits for
        // the page itself.
        run.open(link: link.url)
        run.type("Robin", into: AccessibilityID.invitationName)
        run.tap(AccessibilityID.invitationJoin)
        XCTAssertTrue(run.has(AccessibilityID.lockedCard, timeout: 30), "no locked card after Join. On screen: \(run.visibleTexts())")
        let locked = LockedScreen(.memberGroup(payer: "Leslie"))
        XCTAssertTrue(run.shows(locked.title), "no \"\(locked.title)\". On screen: \(run.visibleTexts())")
        for line in locked.lines {
            XCTAssertTrue(run.shows(line), "missing \"\(line)\"")
        }
        XCTAssertTrue(run.has(AccessibilityID.lockedAction(.payForThisGroup)), "no Pay for This Group")
    }

    // MARK: - LOCK-04, LOCK-05, LOCK-07

    // Scenario LOCK-04
    @MainActor
    func testChangeWhatStaysOpenSavesThePick() async throws {
        let (run, home, beach, _) = try await pickSetUp(changedAt: nil)
        let screen = PickOpenScreen(answer: Self.lastAnswer!, groups: [home, beach], people: [:], properties: [])

        // 1. The payer's groups, with the open one picked.
        XCTAssertTrue(run.element(AccessibilityID.pickGroup(home.id)).isSelected, "the open group isn't picked")
        XCTAssertFalse(run.element(AccessibilityID.pickGroup(beach.id)).isSelected)
        XCTAssertTrue(screen.canChangeGroup)

        // 2. Another group, then Keep These Open: saved, and the sheet closes.
        run.tap(AccessibilityID.pickGroup(beach.id))
        XCTAssertTrue(run.element(AccessibilityID.pickGroup(beach.id)).isSelected, "the tap didn't pick it")
        run.tap(AccessibilityID.pickKeep)
        XCTAssertTrue(run.lacks(AccessibilityID.pickKeep, timeout: 15), "the sheet stayed open after Keep")
    }

    // Scenario LOCK-05
    @MainActor
    func testSkipKeepsTheFirstOnesAndSaysSoBefore() async throws {
        let (run, home, beach, _) = try await pickSetUp(changedAt: nil)
        let screen = PickOpenScreen(answer: Self.lastAnswer!, groups: [home, beach], people: [:], properties: [])
        XCTAssertTrue(run.shows(screen.skipNote), "no \"\(screen.skipNote)\". On screen: \(run.visibleTexts())")
        run.tap(AccessibilityID.pickSkip)
        XCTAssertTrue(run.lacks(AccessibilityID.pickSkip, timeout: 15), "the sheet stayed open after Skip")
    }

    // Scenario LOCK-07
    @MainActor
    func testTheOpenGroupChangesAtMostOnceIn30Days() async throws {
        let tenDaysAgo = Date().addingTimeInterval(-10 * 86_400)
        let (run, home, beach, _) = try await pickSetUp(changedAt: tenDaysAgo)
        let screen = PickOpenScreen(answer: Self.lastAnswer!, groups: [home, beach], people: [:], properties: [])
        XCTAssertFalse(screen.canChangeGroup)
        XCTAssertTrue(run.shows(screen.groupNote), "no \"\(screen.groupNote)\". On screen: \(run.visibleTexts())")

        // The other group can't be picked.
        run.element(AccessibilityID.pickGroup(beach.id)).tap()
        XCTAssertTrue(run.element(AccessibilityID.pickGroup(home.id)).isSelected, "the open group changed")
        XCTAssertFalse(run.element(AccessibilityID.pickGroup(beach.id)).isSelected)
    }

    // MARK: - Setting up

    nonisolated(unsafe) private static var lastAnswer: PlanAnswer?

    /// Two groups of Robin's, Home open and Beach locked, then Account and
    /// Change what stays open.
    @MainActor
    private func pickSetUp(changedAt: Date?) async throws -> (PhoneTestApp, PlanItem, PlanItem, TestAccounts) {
        let accounts = try TestAccounts.fromEnvironment()
        let stamp = PhoneTestApp.stamp()
        let robin = try await Self.headless(accounts.email, accounts.password, accounts.server, suite: "robin")
        let home = try await Self.makeGroup("Home \(stamp)", for: robin)
        let beach = try await Self.makeGroup("Beach \(stamp)", for: robin)
        let answer = Self.ended(locked: .init(groupIDs: [beach.id], people: [], houseIDs: []),
                                open: .init(groupID: home.id, person: nil, houseIDs: [], groupChangedAt: changedAt))
        Self.lastAnswer = answer

        let run = try launch(with: answer)
        try run.signIn(email: accounts.email, password: accounts.password, server: accounts.server)
        run.syncAndWait()
        let button = run.element(AccessibilityID.toolbarAccount)
        XCTAssertTrue(run.wait(for: button, until: "isEnabled == true", timeout: 60), "Account stayed disabled")
        run.tap(AccessibilityID.toolbarAccount)
        run.tap(AccessibilityID.planChangeWhatStaysOpen)
        XCTAssertTrue(run.has(AccessibilityID.pickGroup(home.id), timeout: 15),
                      "Pick what stays open didn't list Home. On screen: \(run.visibleTexts())")
        return (run, home, beach, accounts)
    }

    /// An answer for a Growth plan that ended two days ago, with these
    /// locked and open.
    private static func ended(locked: PlanAnswer.Locked, open: PlanAnswer.Open?) -> PlanAnswer {
        PlanAnswer(tier: .free, period: .none, state: .free, source: .none, paidUntil: nil, renews: false,
                   nextTier: nil, limits: .init(properties: 1, groups: 1, invitedPerGroup: 1),
                   used: .init(properties: 0, groups: 2, invitedPerGroup: 0), extensionsOpen: [],
                   canSyncPriceLabs: false, refreshMinutes: 60, appleAccountToken: UUID(),
                   lastPlan: .init(tier: .growth, endedOn: Date().addingTimeInterval(-2 * 86_400), reason: .ended),
                   locked: locked, open: open)
    }

    /// A headless client signed in as one test account. Signed out at the end.
    @MainActor
    private static func headless(_ email: String, _ password: String, _ server: String,
                                 suite: String) async throws -> SecondAccount {
        let account = try SecondAccount(server: server, settingsSuite: "\(SecondAccount.settingsSuite).\(suite)")
        try await account.signIn(email: email, password: password)
        cleanups.append { await account.cleanUp() }
        return account
    }

    /// A group with one budget, made and sent by the headless client, and
    /// deleted again at the end.
    @MainActor
    private static func makeGroup(_ name: String, for account: SecondAccount) async throws -> PlanItem {
        let model = AppModel(store: account.sync.store)
        guard let group = model.addGroup(named: name),
              model.addBudget(named: "Costs", limit: Money(minorUnits: 50_000), in: group) != nil else {
            throw UITestError("could not make \(name): \(model.errorMessage ?? "")")
        }
        try await account.syncAll()
        cleanups.insert({ await account.deleteGroup(named: name) }, at: 0)
        return PlanItem(id: group.uuid, name: name)
    }

    @MainActor
    private func launch(with answer: PlanAnswer) throws -> PhoneTestApp {
        let run = PhoneTestApp()
        Self.dataRootPath = run.dataRoot.path
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("plan-\(UUID().uuidString).json")
        Self.planFile = file
        try answer.encoded().write(to: file, options: .atomic)
        run.app.launchEnvironment[Workspace.pinnedPlanVariable] = file.path
        run.app.launchEnvironment[Workspace.emptyStoreVariable] = "empty"
        run.launch()
        return run
    }
}
