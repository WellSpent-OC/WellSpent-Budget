// The Mac's plan screens: the plan card in the account sheet, Choose a plan,
// and what Restore Purchases found. The words and choices are the shared
// screens' (PlanScreens, PlanResultScreens); this is layout only.
#if canImport(SwiftUI) && os(macOS)
import SwiftUI
import WellSpentPlans

/// "Your plan" in the account sheet: the card, Restore Purchases, and the
/// sheets they open. Nothing shows until the server has answered once.
struct PlanSection: View {
    let plans: PurchaseCoordinator
    let openNames: [String]
    /// "Change what stays open", once a paid plan has ended.
    var onChangeWhatStaysOpen: () -> Void = {}
    /// False in build A: no Restore Purchases until the App Store sells plans.
    var buyingIsOpen = PlanBuying.isOpen()

    @State private var choosing = false
    @State private var restored: RestoreResultScreen?
    @Environment(\.openURL) private var openURL

    var body: some View {
        if let answer = plans.answer {
            let card = PlanCardScreen(answer: answer, platform: .appleStore, openNames: openNames)
            VStack(alignment: .leading, spacing: 10) {
                Text(PlanWording.yourPlan)
                    .font(.system(size: 13, weight: .semibold))
                PlanCardView(card: card, act: act, changeWhatStaysOpen: onChangeWhatStaysOpen)
                if buyingIsOpen {
                    HStack {
                        Button(PlanWording.restore) { restore() }
                            .linkButtonStyle()
                            .accessibilityIdentifier(AccessibilityID.planRestore)
                            .disabled(plans.status == .working)
                        Spacer()
                        Text(PlanWording.restoreHint)
                            .font(.system(size: 11))
                            .foregroundStyle(Palette.muted)
                    }
                }
            }
            .sheet(isPresented: $choosing) { ChoosePlanSheet(plans: plans, buyingIsOpen: buyingIsOpen) }
            .sheet(item: $restored) { result in RestoreResultSheet(result: result) }
        }
    }

    private func act(_ action: PlanCardScreen.Action) {
        switch action {
        case .seePlans, .changePlan: choosing = true
        case .keepPlan, .openAppleSettings: openURL(PlanLinks.appleSubscriptions)
        case .manageOnWebsite: openURL(PlanLinks.manage)
        }
    }

    private func restore() {
        Task {
            await plans.restore()
            if plans.status == .idle { restored = RestoreResultScreen(answer: plans.answer, device: "Mac") }
        }
    }
}

/// One plan card, in any state the server can answer.
struct PlanCardView: View {
    let card: PlanCardScreen
    let act: (PlanCardScreen.Action) -> Void
    let changeWhatStaysOpen: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(card.title)
                    .font(.system(size: 15, weight: .bold))
                    .accessibilityIdentifier(AccessibilityID.planCardTitle)
                if let badge = card.badge {
                    Text(badge)
                        .font(.system(size: 11, weight: .bold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Palette.accent.opacity(0.25)))
                }
            }
            ForEach(card.lines, id: \.self) { line in
                Text(line)
                    .font(.system(size: 12))
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let action = card.action {
                actionButton(action)
                    .accessibilityIdentifier(AccessibilityID.planCardAction)
            }
            if card.showsChangeWhatStaysOpen {
                Button(PlanWording.changeWhatStaysOpen, action: changeWhatStaysOpen)
                    .linkButtonStyle()
                    .accessibilityIdentifier(AccessibilityID.planChangeWhatStaysOpen)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10)
            .strokeBorder(card.tone == .warning ? Palette.warning : Palette.muted.opacity(0.5), lineWidth: 1.5))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(AccessibilityID.planCard)
    }

    @ViewBuilder
    private func actionButton(_ action: PlanCardScreen.Action) -> some View {
        if card.actionIsPrimary {
            Button(action.title) { act(action) }.buttonStyle(.borderedProminent)
        } else {
            Button(action.title) { act(action) }.buttonStyle(.bordered)
        }
    }
}

/// Choose a plan: monthly or yearly, the three sizes, and Apple's fine print.
struct ChoosePlanSheet: View {
    let plans: PurchaseCoordinator
    var buyingIsOpen = PlanBuying.isOpen()
    /// Run once a purchase is through, before the sheet closes: taking over
    /// a locked group, when the sheet was opened for one.
    var afterBuying: (() async -> Void)? = nil

    @State private var period: BillingPeriod = .monthly
    @State private var selected: PaidTier?
    @State private var prices: PlanPrices = .us
    @State private var storefrontIsUS = false
    @State private var restored: RestoreResultScreen?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    private var screen: PlanChoicesScreen {
        PlanChoicesScreen(answer: plans.answer, platform: .appleStore, period: period, selected: selected,
                          prices: prices, storefrontIsUS: storefrontIsUS, buyingIsOpen: buyingIsOpen)
    }

    var body: some View {
        let screen = self.screen
        VStack(alignment: .leading, spacing: 12) {
            Text(PlanWording.choosePlan)
                .font(.system(size: 17, weight: .semibold))
            Text(screen.intro)
                .font(.system(size: 13))
                .fixedSize(horizontal: false, vertical: true)
            Picker("", selection: $period) {
                Text(screen.monthlyLabel).tag(BillingPeriod.monthly)
                    .accessibilityIdentifier(AccessibilityID.planMonthly)
                Text("\(screen.yearlyLabel) · \(screen.yearlyNote)").tag(BillingPeriod.yearly)
                    .accessibilityIdentifier(AccessibilityID.planYearly)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            ForEach(screen.rows, id: \.tier) { row in
                PlanRowView(row: row, isSelected: row.tier == screen.selected) { selected = row.tier }
            }
            note(screen.paidAdds)
            HStack(spacing: 4) {
                note(screen.peopleFree)
            }
            if let more = screen.moreThan15 {
                Button(more) { openURL(PlanLinks.emailUs) }
                    .linkButtonStyle()
                    .font(.system(size: 11))
                    .accessibilityIdentifier(AccessibilityID.planEmailUs)
            }
            note(screen.finePrint)
            if screen.showsTermsAndPrivacy {
                HStack(spacing: 6) {
                    Button(PlanWording.terms) { openURL(PlanLinks.terms) }.linkButtonStyle()
                    Text("·").foregroundStyle(Palette.muted)
                    Button(PlanWording.privacy) { openURL(PlanLinks.privacy) }.linkButtonStyle()
                }
                .font(.system(size: 11))
            }
            if let line = PlanStatusWording.line(plans.status) {
                Text(line)
                    .font(.system(size: 11))
                    .foregroundStyle(PlanStatusWording.isWarning(plans.status) ? Palette.warning : Palette.muted)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier(AccessibilityID.planStatus)
            }
            HStack {
                if screen.showsRestore {
                    Button(PlanWording.restore) { restore() }
                        .linkButtonStyle()
                        .accessibilityIdentifier(AccessibilityID.planRestore)
                }
                Spacer()
                Button(screen.notNow) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier(AccessibilityID.planNotNow)
                Button(screen.buy) { buy(screen.product(period)) }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(!screen.canBuy)
                    .accessibilityIdentifier(AccessibilityID.planBuy)
            }
            .disabled(plans.status == .working)
        }
        .padding(20)
        .frame(width: 480)
        // Contain, so each row keeps its own identifier under the sheet's.
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(AccessibilityID.planChoices)
        .task {
            let offers = await plans.offers()
            if !offers.isEmpty { prices = PlanPrices(offers: offers) }
            storefrontIsUS = await plans.storefrontIsUS()
        }
        .sheet(item: $restored) { result in RestoreResultSheet(result: result) }
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(Palette.muted)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func buy(_ product: PlanProduct) {
        Task {
            await plans.buy(product)
            // Bought and accepted by the server: the card shows the new plan.
            if plans.status == .idle, plans.answer?.state != .free {
                await afterBuying?()
                dismiss()
            }
        }
    }

    private func restore() {
        Task {
            await plans.restore()
            if plans.status == .idle { restored = RestoreResultScreen(answer: plans.answer, device: "Mac") }
        }
    }
}

/// One plan size: its name, how many properties, and its price.
struct PlanRowView: View {
    let row: PlanChoicesScreen.Row
    let isSelected: Bool
    let choose: () -> Void

    var body: some View {
        Button(action: choose) {
            HStack(spacing: 10) {
                Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                    .font(.system(size: 16))
                VStack(alignment: .leading, spacing: 2) {
                    Text(row.name).font(.system(size: 14, weight: .semibold))
                    Text(row.detail).font(.system(size: 11)).foregroundStyle(Palette.muted)
                }
                Spacer()
                Text(row.price).font(.system(size: 18, weight: .bold))
                Text(row.unit.trimmingCharacters(in: .whitespaces)).font(.system(size: 11))
            }
            .padding(10)
            .contentShape(Rectangle())
            .background(RoundedRectangle(cornerRadius: 8)
                .fill(isSelected ? Palette.accent.opacity(0.15) : Color.clear))
            .overlay(RoundedRectangle(cornerRadius: 8)
                .strokeBorder(isSelected ? Palette.accent : Palette.muted.opacity(0.5), lineWidth: 1.5))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(AccessibilityID.planRow(row.tier))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// What Restore Purchases found.
struct RestoreResultSheet: View {
    let result: RestoreResultScreen
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(result.title).font(.system(size: 17, weight: .semibold))
            ForEach(result.lines, id: \.self) { line in
                Text(line).font(.system(size: 13)).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button(result.close) { dismiss() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .frame(width: 380)
    }
}
#endif
