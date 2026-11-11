// SwiftUI and ViewInspector exist only on Apple systems; these are the Mac's views.
#if canImport(SwiftUI) && os(macOS)
import AppKit
import Testing
import Foundation
import SwiftUI
import ViewInspector
@testable import WellSpentAppCore
import WellSpentPlans
import WellSpentKeyStore
import WellSpentStore

private func answer(_ tier: PlanTier = .free, state: PlanAnswer.State = .free,
                    source: PlanAnswer.Source = .apple) -> PlanAnswer {
    let free = tier == .free
    return PlanAnswer(tier: tier, period: free ? .none : .monthly, state: state, source: free ? .none : source,
                      paidUntil: free ? nil : Date().addingTimeInterval(30 * 86_400), renews: state == .active,
                      nextTier: nil, limits: .init(properties: free ? 1 : 5, groups: nil, invitedPerGroup: nil),
                      used: .init(properties: 1, groups: 1, invitedPerGroup: 0), extensionsOpen: [],
                      canSyncPriceLabs: !free, refreshMinutes: 60, appleAccountToken: UUID())
}

/// A coordinator showing `answer`, as a pinned staging build does.
@MainActor
private func plans(_ answer: PlanAnswer?) async -> PurchaseCoordinator {
    let service: any PlanService = answer.map { PinnedPlanService(answer: $0) } ?? PinnedPlanService(file: "/no/such")
    let plans = PurchaseCoordinator(store: nil, service: service, cache: DefaultsPlanCache(defaults: isolatedDefaults()))
    await plans.refresh()
    return plans
}

/// Draws a view in a window, as the Mac does, so its whole body runs.
@MainActor
private func draw(_ view: some View, width: CGFloat = 480) {
    let host = NSHostingView(rootView: view)
    host.frame.size = CGSize(width: width, height: 900)
    let window = NSWindow(contentRect: host.bounds, styleMask: [.borderless], backing: .buffered, defer: false)
    window.contentView = host
    host.layoutSubtreeIfNeeded()
}

@Suite("Mac plan views", .serialized)
@MainActor
struct PlanViewTests {
    @Test func theCardShowsTheSharedWordsAndItsAction() throws {
        let card = PlanCardScreen(answer: answer(), platform: .appleStore)
        var acted: [PlanCardScreen.Action] = []
        let view = PlanCardView(card: card, act: { acted.append($0) }, changeWhatStaysOpen: {})
        draw(view)
        let texts = try view.inspect().findAll(ViewType.Text.self).map { try $0.string() }
        #expect(texts.contains("Free plan") && texts.contains("Free"))
        #expect(texts.contains("Free forever. No card, no end date."))
        try view.inspect().find(button: "See Plans").tap()
        #expect(acted == [.seePlans])
    }

    @Test func aFailingPaymentCardIsInTheWarningColourWithItsAction() throws {
        let card = PlanCardScreen(answer: answer(.growth, state: .grace), platform: .appleStore)
        #expect(card.tone == .warning)
        var acted: [PlanCardScreen.Action] = []
        let view = PlanCardView(card: card, act: { acted.append($0) }, changeWhatStaysOpen: {})
        draw(view)
        try view.inspect().find(button: "Open Apple Settings").tap()
        #expect(acted == [.openAppleSettings])
    }

    @Test func anEndedPlanOffersChangeWhatStaysOpen() throws {
        let ended = PlanAnswer(tier: .free, period: .none, state: .free, source: .none, paidUntil: nil, renews: false,
                               nextTier: nil, limits: .init(properties: 1, groups: 1, invitedPerGroup: 1),
                               used: .init(properties: 2, groups: 1, invitedPerGroup: 0), extensionsOpen: [],
                               canSyncPriceLabs: false, refreshMinutes: 60, appleAccountToken: nil,
                               lastPlan: .init(tier: .growth, endedOn: Date(), reason: .ended))
        var changed = 0
        let view = PlanCardView(card: PlanCardScreen(answer: ended, platform: .appleStore, openNames: ["Home"]),
                                act: { _ in }, changeWhatStaysOpen: { changed += 1 })
        draw(view)
        try view.inspect().find(button: PlanWording.changeWhatStaysOpen).tap()
        #expect(changed == 1)
        #expect(try view.inspect().find(text: "Open now: Home.").string() == "Open now: Home.")
    }

    @Test func theSectionShowsOnlyOnceThereIsAnAnswer() async throws {
        let none = PlanSection(plans: await plans(nil), openNames: [])
        draw(none)
        #expect(try none.inspect().findAll(ViewType.Text.self).isEmpty)
        let some = PlanSection(plans: await plans(answer()), openNames: [])
        draw(some)
        let texts = try some.inspect().findAll(ViewType.Text.self).map { try $0.string() }
        #expect(texts.contains(PlanWording.yourPlan) && texts.contains(PlanWording.restoreHint))
        #expect(try some.inspect().find(button: PlanWording.restore).isDisabled() == false)
    }

    @Test func choosingAPlanListsTheThreeSizesWithApplesFinePrint() async throws {
        let sheet = ChoosePlanSheet(plans: await plans(answer()))
        draw(sheet)
        let texts = try sheet.inspect().findAll(ViewType.Text.self).map { try $0.string() }
        for wanted in ["Choose a plan", "Starter", "Growth", "Portfolio", "$19", "$49", "$99",
                       PlanWording.appleFinePrint, PlanWording.paidAdds, PlanWording.peopleFree] {
            #expect(texts.contains(wanted), "\(wanted) is missing: \(texts)")
        }
        #expect(throws: Never.self) { try sheet.inspect().find(button: "Subscribe for $19 a Month") }
        #expect(throws: Never.self) { try sheet.inspect().find(button: "Not Now") }
        #expect(throws: Never.self) { try sheet.inspect().find(button: PlanWording.restore) }
        try sheet.inspect().find(button: "Growth").tap()
    }

    @Test func eachRowSaysItsPriceAndWhetherItIsPicked() throws {
        let row = PlanChoicesScreen(answer: answer(), platform: .appleStore, period: .yearly,
                                    storefrontIsUS: true).rows[1]
        var chosen = 0
        let view = PlanRowView(row: row, isSelected: true) { chosen += 1 }
        draw(view)
        let texts = try view.inspect().findAll(ViewType.Text.self).map { try $0.string() }
        #expect(texts.contains("Growth") && texts.contains("$490") && texts.contains("a year"))
        try view.inspect().find(ViewType.Button.self).tap()
        #expect(chosen == 1)
        draw(PlanRowView(row: row, isSelected: false) {})
    }

    @Test func whatRestoreFoundIsSaidInItsSheet() throws {
        for result in [RestoreResultScreen(answer: answer(.growth, state: .active), device: "Mac"),
                       RestoreResultScreen(answer: nil, device: "Mac")] {
            let view = RestoreResultSheet(result: result)
            draw(view, width: 380)
            let texts = try view.inspect().findAll(ViewType.Text.self).map { try $0.string() }
            #expect(texts.contains(result.title))
            #expect(result.lines.allSatisfy(texts.contains))
            #expect(throws: Never.self) { try view.inspect().find(button: result.close) }
        }
        #expect(RestoreResultScreen(answer: nil, device: "Mac").id != RestoreResultScreen(answer: answer(.growth, state: .active), device: "Mac").id)
    }

    @Test func theAccountSheetCarriesThePlanWhenGivenOne() async throws {
        let sync = SyncCoordinator(store: Store(database: try WellSpentDatabase.inMemory()),
                                   keyStore: InMemoryKeyStore(), defaults: isolatedDefaults())
        draw(AccountSheet(sync: sync, plans: await plans(answer()), openNames: []), width: 440)
    }
}
#endif
