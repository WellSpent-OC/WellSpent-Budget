import Foundation
import XCTest
import WellSpentAppCore
import WellSpentPlans

/// The plan card on Account in every state the server can answer, and Choose
/// a plan. The answer comes from a file the staging build reads in place of
/// the server's (`Workspace.pinnedPlanVariable`), so no state needs a real
/// purchase, and the store is an empty stand-in (`Workspace.emptyStoreVariable`).
/// Signs in with the first test account, so it runs in light only.
///
/// What the card should say comes from `PlanCardScreen` itself, so no word is
/// written twice: this checks that the phone draws it.
final class PhonePlanTests: XCTestCase {
    nonisolated(unsafe) private static var dataRootPath: String?
    nonisolated(unsafe) private static var planFile: URL?

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

    // MARK: - Answers

    private static let now = Date()
    private static func days(_ count: Int) -> Date { now.addingTimeInterval(Double(count) * 86_400) }
    private static let token = UUID()

    private static func answer(_ tier: PlanTier, _ state: PlanAnswer.State, period: PlanAnswer.Period = .monthly,
                               source: PlanAnswer.Source = .apple, paidUntil: Date? = days(30),
                               lastPlan: PlanAnswer.LastPlan? = nil, locked: PlanAnswer.Locked? = nil)
        -> PlanAnswer {
        let limit = switch tier {
        case .free: 1
        case .starter: 2
        case .growth: 5
        case .portfolio: 15
        }
        return PlanAnswer(tier: tier, period: tier == .free ? .none : period, state: state,
                          source: tier == .free ? .none : source, paidUntil: tier == .free ? nil : paidUntil,
                          renews: state == .active, nextTier: nil,
                          limits: .init(properties: limit, groups: nil, invitedPerGroup: nil),
                          used: .init(properties: 3, groups: 2, invitedPerGroup: nil), extensionsOpen: [],
                          canSyncPriceLabs: false, refreshMinutes: 60, appleAccountToken: token,
                          lastPlan: lastPlan, locked: locked)
    }

    private static let someLocked = PlanAnswer.Locked(
        groupIDs: [UUID()], people: [.init(groupID: UUID(), userID: UUID()), .init(groupID: UUID(), userID: UUID())],
        houseIDs: [UUID(), UUID()])

    /// Every state the card has, by name, for the failure messages.
    private static let states: [(String, PlanAnswer)] = [
        ("free", answer(.free, .free)),
        ("active monthly", answer(.growth, .active)),
        ("active yearly", answer(.growth, .active, period: .yearly)),
        ("grace", answer(.growth, .grace, paidUntil: days(-1))),
        ("billing problem", answer(.growth, .billingProblem, locked: someLocked)),
        ("canceled", answer(.growth, .canceled)),
        ("ended", answer(.free, .free, lastPlan: .init(tier: .growth, endedOn: days(-2), reason: .ended),
                         locked: someLocked)),
        ("refunded", answer(.free, .free, lastPlan: .init(tier: .growth, endedOn: days(-2), reason: .refunded),
                            locked: someLocked)),
        ("website", answer(.growth, .active, source: .paddle)),
    ]

    // MARK: - Tests

    // Scenario PLAN-01, PLAN-06, PLAN-07, PLAN-08, PLAN-09, PLAN-10, PLAN-11, PLAN-12, PLAN-13, PLAN-14
    // Each state comes in as a changed answer and a return to the front, with
    // no sign-in, as PLAN-14 says.
    @MainActor
    func testTheCardInEveryPlanState() throws {
        let accounts = try TestAccounts.fromEnvironment()
        let run = try launch(with: Self.states[0].1)
        try run.signIn(email: accounts.email, password: accounts.password, server: accounts.server)

        for (name, answer) in Self.states {
            try show(answer, in: run)
            openAccount(run)
            let card = PlanCardScreen(answer: answer, platform: .appleStore)
            XCTAssertTrue(run.has(AccessibilityID.planCard, timeout: 15), "\(name): no plan card. On screen: \(run.visibleTexts())")
            XCTAssertTrue(run.shows(card.title), "\(name): no title \"\(card.title)\"")
            for line in card.lines {
                XCTAssertTrue(run.shows(line), "\(name): missing \"\(line)\"")
            }
            if let action = card.action {
                XCTAssertEqual(run.element(AccessibilityID.planCardAction).label, action.title, "\(name): wrong button")
            } else {
                XCTAssertTrue(run.lacks(AccessibilityID.planCardAction), "\(name): a button where none belongs")
            }
            XCTAssertEqual(run.element(AccessibilityID.planChangeWhatStaysOpen).exists, card.showsChangeWhatStaysOpen,
                           "\(name): Change what stays open")
            XCTAssertTrue(run.has(AccessibilityID.planRestore), "\(name): no Restore Purchases")
            run.tap(AccessibilityID.accountClose)
        }
    }

    // Scenario PLAN-02, PLAN-03
    @MainActor
    func testSeePlansOpensChooseAPlanAndYearlyShowsYearlyPrices() throws {
        let accounts = try TestAccounts.fromEnvironment()
        let free = Self.states[0].1
        let run = try launch(with: free)
        try run.signIn(email: accounts.email, password: accounts.password, server: accounts.server)
        openAccount(run)
        run.tap(AccessibilityID.planCardAction)

        // 1. Monthly, with the plan that fits 3 properties picked.
        let monthly = PlanChoicesScreen(answer: free, platform: .appleStore, period: .monthly, storefrontIsUS: true)
        XCTAssertTrue(run.app.navigationBars[PlanWording.choosePlan].waitForExistence(timeout: 10), "no Choose a plan")
        for row in monthly.rows {
            let label = run.element(AccessibilityID.planRow(row.tier)).label
            XCTAssertTrue(label.contains(row.name) && label.contains(row.price) && label.contains(row.unit),
                          "monthly: \(row.name) reads \"\(label)\"")
        }
        XCTAssertTrue(run.element(AccessibilityID.planRow(monthly.selected)).isSelected, "the fitting plan isn't picked")
        XCTAssertTrue(run.scrollTo(AccessibilityID.planBuy).label.hasPrefix("Subscribe for "), "monthly: no Subscribe")

        // 2. Yearly shows each plan's yearly price.
        // Reading Subscribe scrolled the list down, past the period buttons.
        run.scrollTo(AccessibilityID.planYearly)
        run.tap(AccessibilityID.planYearly)
        XCTAssertTrue(run.element(AccessibilityID.planYearly).isSelected, "Yearly isn't picked after its tap")
        let yearly = PlanChoicesScreen(answer: free, platform: .appleStore, period: .yearly, storefrontIsUS: true)
        for row in yearly.rows {
            let label = run.element(AccessibilityID.planRow(row.tier)).label
            XCTAssertTrue(label.contains(row.name) && label.contains(row.price) && label.contains(row.unit),
                          "yearly: \(row.name) reads \"\(label)\"")
        }
        let yearlyBuy = run.scrollTo(AccessibilityID.planBuy).label
        XCTAssertTrue(yearlyBuy.hasSuffix(" a Year"), "yearly: Subscribe reads \"\(yearlyBuy)\"")

        // 3. Not Now closes it, and nothing changed.
        run.tap(AccessibilityID.planNotNow)
        XCTAssertTrue(run.has(AccessibilityID.planCard), "Not Now didn't go back to Account")
    }

    // Scenario PLAN-15
    @MainActor
    func testRestoreWithNothingToRestoreSaysSo() throws {
        let accounts = try TestAccounts.fromEnvironment()
        let free = Self.states[0].1
        let run = try launch(with: free)
        try run.signIn(email: accounts.email, password: accounts.password, server: accounts.server)
        openAccount(run)
        run.tap(AccessibilityID.planRestore)

        // The local test store holds no purchase, so nothing comes back.
        let nothing = RestoreResultScreen(answer: free, device: "iPhone")
        XCTAssertFalse(nothing.found)
        XCTAssertTrue(run.app.navigationBars[nothing.title].waitForExistence(timeout: 20),
                      "no \"\(nothing.title)\". On screen: \(run.visibleTexts())")
        for line in nothing.lines {
            XCTAssertTrue(run.shows(line), "missing \"\(line)\"")
        }
        run.app.navigationBars[nothing.title].buttons[nothing.close].tap()
        XCTAssertTrue(run.has(AccessibilityID.planCard), "the plan card went away after Restore")
    }

    /// Opens Account and waits for it. Account is disabled while a sync
    /// runs, and coming back to the front starts one, so it waits for the
    /// button to be enabled before tapping.
    @MainActor
    private func openAccount(_ run: PhoneTestApp) {
        let button = run.element(AccessibilityID.toolbarAccount)
        XCTAssertTrue(run.wait(for: button, until: "isEnabled == true", timeout: 60),
                      "Account stayed disabled. On screen: \(run.visibleTexts())")
        run.tap(AccessibilityID.toolbarAccount)
        XCTAssertTrue(run.app.navigationBars[AccountFlow.Step.account.title].waitForExistence(timeout: 10),
                      "Account didn't open. On screen: \(run.visibleTexts())")
    }

    // Scenario PLAN-16
    @MainActor
    func testAPurchaseTheStoreRefusesSaysSoAndChangesNothing() throws {
        let accounts = try TestAccounts.fromEnvironment()
        let free = Self.states[0].1
        let run = try launch(with: free)
        try run.signIn(email: accounts.email, password: accounts.password, server: accounts.server)
        openAccount(run)
        run.tap(AccessibilityID.planCardAction)
        XCTAssertTrue(run.app.navigationBars[PlanWording.choosePlan].waitForExistence(timeout: 10), "no Choose a plan")

        run.scrollTo(AccessibilityID.planBuy)
        run.tap(AccessibilityID.planBuy)
        let refused = try XCTUnwrap(PlanStatusWording.line(.failed(.storeFailed)))
        XCTAssertTrue(run.shows(refused, timeout: 15), "no \"\(refused)\". On screen: \(run.visibleTexts())")

        // Still on the free plan: Not Now goes back to the same card.
        run.tap(AccessibilityID.planNotNow)
        let card = PlanCardScreen(answer: free, platform: .appleStore)
        XCTAssertTrue(run.shows(card.title), "the card changed after a refused purchase")
    }

    // MARK: - Launching with an answer

    @MainActor
    private func launch(with answer: PlanAnswer) throws -> PhoneTestApp {
        let run = PhoneTestApp()
        Self.dataRootPath = run.dataRoot.path
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("plan-\(UUID().uuidString).json")
        Self.planFile = file
        try answer.encoded().write(to: file, options: .atomic)
        run.app.launchEnvironment[Workspace.pinnedPlanVariable] = file.path
        // A store with nothing in it, which refuses every purchase: the same
        // every run, with no Apple account. The real store is checked in
        // Apple's sandbox on a device.
        run.app.launchEnvironment[Workspace.emptyStoreVariable] = "empty"
        run.launch()
        return run
    }

    /// The pinned file is read on every plan refresh, and coming to the front
    /// refreshes, so a new answer needs no relaunch and no second sign-in.
    /// Written whole (atomic), so the app never reads half a file.
    @MainActor
    private func show(_ answer: PlanAnswer, in run: PhoneTestApp) throws {
        try answer.encoded().write(to: XCTUnwrap(Self.planFile), options: .atomic)
        XCUIDevice.shared.press(.home)
        run.app.activate()
        XCTAssertTrue(run.has(AccessibilityID.toolbarAccount, timeout: 15), "not back on Home after coming to the front")
    }
}
