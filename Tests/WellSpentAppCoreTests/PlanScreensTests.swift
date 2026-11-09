import Foundation
import Testing
import WellSpentAppCore
import WellSpentPlans
import WellSpentKeyStore
import WellSpentStore
import WellSpentSync

private var utc: Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    return calendar
}

private func date(_ text: String) -> Date { ISO8601DateFormatter().date(from: text + "T12:00:00Z")! }
private let now = date("2026-11-09")

private func answer(_ tier: PlanTier = .growth, state: PlanAnswer.State = .active, period: PlanAnswer.Period = .monthly,
                    source: PlanAnswer.Source = .apple, paidUntil: String? = "2026-12-09", properties: Int = 3)
    -> PlanAnswer {
    let free = tier == .free
    return PlanAnswer(tier: tier, period: free ? .none : period, state: free ? .free : state,
                      source: free ? .none : source, paidUntil: free ? nil : paidUntil.map(date), renews: state == .active,
                      nextTier: nil,
                      limits: .init(properties: free ? 1 : [PlanTier.starter: 2, .growth: 5, .portfolio: 15][tier],
                                    groups: free ? 1 : nil, invitedPerGroup: free ? 1 : nil),
                      used: .init(properties: properties, groups: 1, invitedPerGroup: 1), extensionsOpen: [],
                      canSyncPriceLabs: !free, refreshMinutes: 60, appleAccountToken: UUID())
}

private func card(_ answer: PlanAnswer, _ platform: PlanPlatform = .appleStore, open: [String] = []) -> PlanCardScreen {
    PlanCardScreen(answer: answer, platform: platform, openNames: open, now: now, calendar: utc)
}

private func ids(_ count: Int) -> [UUID] { (0 ..< count).map { _ in UUID() } }

private let twoTwoOne = PlanAnswer.Locked(groupIDs: ids(1),
                                           people: ids(2).map { PlanAnswer.Person(groupID: UUID(), userID: $0) },
                                           houseIDs: ids(2))

/// A free answer after a paid plan, as the server sends it.
private func after(_ reason: PlanAnswer.LastPlan.Reason, locked: PlanAnswer.Locked? = twoTwoOne) -> PlanAnswer {
    let free = answer(.free, properties: 1)
    return PlanAnswer(tier: .free, period: .none, state: .free, source: .none, paidUntil: nil, renews: false,
                      nextTier: nil, limits: free.limits, used: free.used, extensionsOpen: [], canSyncPriceLabs: false,
                      refreshMinutes: 60, appleAccountToken: UUID(),
                      lastPlan: .init(tier: .growth, endedOn: date("2026-11-09"), reason: reason), locked: locked)
}

struct PlanCardScreenTests {
    @Test func theFreePlan() {
        let free = card(answer(.free, properties: 1))
        #expect(free.title == "Free plan")
        #expect(free.badge == "Free")
        #expect(free.lines == ["1 property, sync on every device, and 1 group shared with 1 person.",
                               "Free forever. No card, no end date."])
        #expect(free.action == .seePlans && free.actionIsPrimary)
        #expect(card(answer(.free), .website).action == .seePlans)
    }

    @Test func aMonthlyPlanFromApple() {
        let paid = card(answer())
        #expect(paid.title == "Growth · $49 a month")
        #expect(paid.badge == nil)
        #expect(paid.lines == ["Up to 5 properties. You have 3.", "Renews Dec 9. Bought through Apple."])
        #expect(paid.action == .changePlan && !paid.actionIsPrimary)
        #expect(paid.tone == .plain)
    }

    @Test func aYearlyPlanRenewingNextYear() {
        let paid = card(answer(period: .yearly, paidUntil: "2027-11-09"))
        #expect(paid.title == "Growth · $490 a year")
        #expect(paid.lines.last == "Renews Nov 9, 2027. Bought through Apple.")
    }

    @Test func theStoresOwnPriceWins() {
        let prices = PlanPrices(offers: [StoreOffer(product: PlanProduct(.growth, .monthly), displayPrice: "€49,99")])
        let paid = PlanCardScreen(answer: answer(), platform: .appleStore, prices: prices, now: now, calendar: utc)
        #expect(paid.title == "Growth · €49,99 a month")
        #expect(prices.price(.starter, .monthly) == "$19")
    }

    @Test func aPlanBoughtOnTheWebsite() {
        let web = card(answer(source: .paddle))
        #expect(web.lines.last == "Renews Dec 9. Bought on wellspent.space.")
        #expect(web.action == .manageOnWebsite)
        #expect(card(answer(source: .paddle), .website).action == .manageOnWebsite)
    }

    @Test func anApplePlanSeenOnLinuxCantBeChangedThere() {
        let linux = card(answer(), .website)
        #expect(linux.lines == ["Up to 5 properties. You have 3.", "Renews Dec 9.",
                                "Bought through Apple, so it's managed on your Mac or iPhone."])
        #expect(linux.action == nil && !linux.actionIsPrimary)
    }

    @Test func theGracePeriod() {
        let grace = card(answer(state: .grace, paidUntil: "2026-11-09"))
        #expect(grace.title == "Apple couldn't renew your plan")
        #expect(grace.badge == "Growth")
        #expect(grace.lines == ["Everything keeps working for 16 days, until Nov 25, while Apple tries again.",
                                "Update your payment in your Apple account settings."])
        #expect(grace.action == .openAppleSettings && grace.actionIsPrimary)
        #expect(grace.tone == .warning)

        let onLinux = card(answer(state: .grace, paidUntil: "2026-11-09"), .website)
        #expect(onLinux.lines.last == "Update your payment in your Apple account settings, on your Mac or iPhone.")
        #expect(onLinux.action == nil)

        let web = card(answer(state: .grace, source: .paddle, paidUntil: "2026-11-09"))
        #expect(web.title == "Your payment didn't go through")
        #expect(web.lines == ["Everything keeps working for 16 days, until Nov 25, while we try again.",
                              "Update your payment on wellspent.space."])
        #expect(web.action == .manageOnWebsite)
    }

    @Test func aBillingProblemAfterTheGracePeriod() {
        let paused = card(answer(state: .billingProblem))
        #expect(paused.title == "Growth is paused")
        #expect(paused.badge == "Free")
        #expect(paused.lines == ["Apple still couldn't take payment, so you're on the free plan for now.",
                                 "Anything past the free plan is locked until the payment goes through. Nothing was deleted."])
        #expect(paused.action == .openAppleSettings)
        #expect(paused.tone == .warning)
        #expect(card(answer(state: .billingProblem), .website).lines.last
                == "Bought through Apple, so it's managed on your Mac or iPhone.")
        #expect(card(answer(state: .billingProblem, source: .paddle)).lines.first
                == "We still couldn't take payment, so you're on the free plan for now.")
    }

    @Test func aCanceledPlanStillPaidFor() {
        let canceled = card(answer(state: .canceled))
        #expect(canceled.title == "Growth · ends Dec 9")
        #expect(canceled.lines == ["You canceled. Everything works until Dec 9, then you move to the free plan.",
                                   "Nothing is deleted."])
        #expect(canceled.action == .keepPlan && canceled.actionIsPrimary)
        #expect(card(answer(state: .canceled), .website).action == nil)
        #expect(card(answer(state: .canceled, source: .paddle)).action == .manageOnWebsite)
    }

    @Test func theServersGraceEndWins() {
        let base = answer(state: .grace, paidUntil: "2026-11-09")
        let apple = PlanAnswer(tier: base.tier, period: base.period, state: .grace, source: .apple,
                               paidUntil: base.paidUntil, renews: true, nextTier: nil, limits: base.limits,
                               used: base.used, extensionsOpen: [], canSyncPriceLabs: true, refreshMinutes: 60,
                               appleAccountToken: UUID(), graceUntil: date("2026-11-28"))
        #expect(card(apple).lines.first == "Everything keeps working for 16 days, until Nov 28, while Apple tries again.")
    }

    @Test func aBillingProblemCountsWhatsLocked() {
        let base = answer(state: .billingProblem)
        let counted = PlanAnswer(tier: base.tier, period: base.period, state: .billingProblem, source: .apple,
                                 paidUntil: base.paidUntil, renews: false, nextTier: nil, limits: base.limits,
                                 used: base.used, extensionsOpen: [], canSyncPriceLabs: false, refreshMinutes: 60,
                                 appleAccountToken: UUID(), locked: twoTwoOne)
        #expect(card(counted).lines.last
                == "2 properties, 1 group and 2 people are locked until the payment goes through. Nothing was deleted.")
    }

    @Test func anEndedPlanSaysWhatsLockedAndWhatsOpen() {
        let ended = card(after(.ended), open: ["Household", "Cabin on Elm", "Sam"])
        #expect(ended.title == "Free plan")
        #expect(ended.badge == "Free")
        #expect(ended.lines == ["Your Growth plan ended Nov 9.",
                                "2 properties, 1 group and 2 people are locked until you pick a plan. Nothing was deleted.",
                                "Open now: Household, Cabin on Elm and Sam."])
        #expect(ended.action == .seePlans && !ended.actionIsPrimary)
        #expect(ended.showsChangeWhatStaysOpen)
        #expect(card(after(.ended), .website).action == .seePlans)
        #expect(!card(answer(.free)).showsChangeWhatStaysOpen)
    }

    @Test func aRefundedPlan() {
        let refunded = card(after(.refunded))
        #expect(refunded.title == "Refunded")
        #expect(refunded.lines == ["Your Nov 9 payment was refunded, so you're on the free plan.",
                                   "2 properties, 1 group and 2 people are locked until you pick a plan. Nothing was deleted."])
        #expect(!refunded.showsChangeWhatStaysOpen)
    }

    @Test func lockedWordsReadRightForOneThingOrNone() {
        let oneGroup = PlanAnswer.Locked(groupIDs: ids(1), people: [], houseIDs: [])
        #expect(card(after(.ended, locked: oneGroup)).lines[1]
                == "1 group is locked until you pick a plan. Nothing was deleted.")
        let empty = PlanAnswer.Locked(groupIDs: [], people: [], houseIDs: [])
        #expect(card(after(.ended, locked: empty)).lines[1]
                == "Anything past the free plan is locked until you pick a plan. Nothing was deleted.")
        #expect(card(after(.ended, locked: nil)).lines.count == 2)
    }

    @Test func eachActionHasItsButtonWords() {
        #expect([PlanCardScreen.Action.seePlans, .changePlan, .keepPlan, .openAppleSettings, .manageOnWebsite].map(\.title)
                == ["See Plans", "Change Plan", "Keep My Plan", "Open Apple Settings", "Manage on wellspent.space"])
    }
}

struct PlanChoicesScreenTests {
    @Test func monthlyOnTheMacFromTheFreePlan() {
        let choices = PlanChoicesScreen(answer: answer(.free, properties: 1), platform: .appleStore, period: .monthly,
                                        storefrontIsUS: true)
        #expect(choices.intro == "You're on the free plan: 1 property, sync on every device, and 1 group shared with 1 person.")
        #expect(choices.rows.map(\.name) == ["Starter", "Growth", "Portfolio"])
        #expect(choices.rows.map(\.price) == ["$19", "$49", "$99"])
        #expect(choices.rows[0].unit == " a month")
        #expect(choices.rows[0].detail == "Up to 2 properties · or $190 a year")
        #expect(choices.rows.allSatisfy { !$0.isCurrent })
        #expect(choices.selected == .starter)
        #expect(choices.buy == "Subscribe for $19 a Month")
        #expect(choices.product(.monthly).id == "app.wellspent.pro.starter.monthly")
        #expect(choices.moreThan15 == "More than 15 properties? Email us.")
        #expect(choices.finePrint.hasPrefix("Billed to your Apple account."))
        #expect(choices.showsRestore && choices.showsTermsAndPrivacy)
        #expect(choices.yearlyNote == "2 months free")
    }

    @Test func yearlyPicksTheSmallestPlanThatFits() {
        let choices = PlanChoicesScreen(answer: answer(.free, properties: 4), platform: .appleStore, period: .yearly,
                                        storefrontIsUS: true)
        #expect(choices.selected == .growth)
        #expect(choices.rows[1].detail == "Up to 5 properties")
        #expect(choices.rows[1].unit == " a year")
        #expect(choices.buy == "Subscribe for $490 a Year")
    }

    @Test func aPaidPlanStartsOnItself() {
        let choices = PlanChoicesScreen(answer: answer(.portfolio, properties: 1), platform: .appleStore,
                                        period: .monthly, storefrontIsUS: true)
        #expect(choices.intro == "You're on Portfolio: up to 15 properties.")
        #expect(choices.selected == .portfolio)
        #expect(choices.rows.map(\.isCurrent) == [false, false, true])
    }

    @Test func outsideTheUSTheAppDoesntOfferEmailUs() {
        let choices = PlanChoicesScreen(answer: nil, platform: .appleStore, period: .monthly, storefrontIsUS: false)
        #expect(choices.moreThan15 == nil)
        #expect(PlanChoicesScreen(answer: nil, platform: .website, period: .monthly, storefrontIsUS: false).moreThan15 != nil)
    }

    @Test func onLinuxTheButtonGoesToTheWebsite() {
        let choices = PlanChoicesScreen(answer: answer(.free), platform: .website, period: .monthly, selected: .growth,
                                        storefrontIsUS: true)
        #expect(choices.buy == "Continue on wellspent.space")
        #expect(choices.finePrint == "On Linux you pay on our website. The plan works on every device you sign in on.")
        #expect(!choices.showsRestore && !choices.showsTermsAndPrivacy)
        #expect(choices.selected == .growth)
    }

    @Test func pastFifteenTheBiggestPlanIsOffered() {
        let choices = PlanChoicesScreen(answer: answer(.free, properties: 20), platform: .appleStore, period: .monthly,
                                        storefrontIsUS: true)
        #expect(choices.selected == .portfolio)
    }
}

struct PlanLinksTests {
    @Test func everyAppLinksToTheSameWebsitePages() {
        #expect(PlanLinks.checkout(.growth, .yearly).absoluteString == "https://wellspent.space/checkout?plan=growth&period=yearly")
        #expect(PlanLinks.manage.absoluteString == "https://wellspent.space/account")
        #expect(PlanLinks.prices.absoluteString == "https://wellspent.space/prices")
        #expect(PlanLinks.emailUs.scheme == "mailto")
        #expect([PlanWording.yourPlan, PlanWording.choosePlan, PlanWording.changeWhatStaysOpen]
                == ["Your plan", "Choose a plan", "Change what stays open"])
    }
}

@MainActor
struct WorkspacePlansTests {
    @Test func signedOutThereIsNoPlanToAskAbout() async throws {
        let sync = SyncCoordinator(store: Store(database: try WellSpentDatabase.inMemory()), keyStore: InMemoryKeyStore(),
                                   defaults: isolatedDefaults())
        await #expect(throws: ReadableTransportError.self) { try await sync.plan() }
        await #expect(throws: ReadableTransportError.self) { try await sync.submitApple(signedTransaction: "jws") }
    }

    @Test func theWorkspaceKeepsOnePurchaseCoordinator() async throws {
        let model = AppModel(store: Store(database: try WellSpentDatabase.inMemory()))
        let sync = SyncCoordinator(store: model.store, keyStore: InMemoryKeyStore(), defaults: isolatedDefaults())
        let workspace = Workspace(model: model, sync: sync)
        // Linux hands in no store, so buying happens on the website.
        #expect(!workspace.plans.canBuyInApp)
        await workspace.plans.refresh()
        #expect(workspace.plans.answer == nil)
    }

    @Test func signedOutComingToTheFrontDoesntAskForAPlan() async throws {
        let model = AppModel(store: Store(database: try WellSpentDatabase.inMemory()))
        let defaults = isolatedDefaults()
        let sync = SyncCoordinator(store: model.store, keyStore: InMemoryKeyStore(), defaults: defaults)
        let cache = DefaultsPlanCache(defaults: defaults)
        cache.save(answer(.starter))
        let workspace = Workspace(model: model, sync: sync)
        #expect(workspace.plans.answer?.tier == .starter)

        await workspace.cameToFront()
        #expect(workspace.plans.answer?.tier == .starter)

        // A switch to no account, as signing out does, forgets the plan.
        sync.didSwitchStore?(model.store)
        #expect(workspace.plans.answer == nil)
        #expect(cache.load() == nil)
    }
}
