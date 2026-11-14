// The iPhone's screens, built the iPhone's way. Layout only.
#if os(iOS)
import SwiftUI
import WellSpentPlans

/// "Your plan" on Account: the one plan card, drawn from `PlanCardScreen`.
/// No answer from the server yet means no card at all, as on the Mac.
struct PhonePlanCardSection: View {
    let plans: PurchaseCoordinator
    let openNames: [String]
    let seePlans: () -> Void
    let changeWhatStaysOpen: () -> Void
    @Environment(\.openURL) private var openURL

    var body: some View {
        if let answer = plans.answer {
            let card = PlanCardScreen(answer: answer, platform: .appleStore, openNames: openNames)
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(card.title)
                            .font(.headline)
                            .foregroundStyle(card.tone == .warning ? Palette.warning : Palette.ink)
                            .accessibilityIdentifier(AccessibilityID.planCardTitle)
                        if let badge = card.badge {
                            Text(badge)
                                .font(.caption.weight(.bold))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Capsule().fill(Palette.ink))
                                .foregroundStyle(Palette.accent)
                        }
                    }
                    ForEach(card.lines, id: \.self) { line in
                        Text(line).font(.subheadline)
                    }
                    if card.showsChangeWhatStaysOpen {
                        Button(PlanWording.changeWhatStaysOpen, action: changeWhatStaysOpen)
                            .font(.subheadline)
                            .buttonStyle(.borderless)
                            .accessibilityIdentifier(AccessibilityID.planChangeWhatStaysOpen)
                    }
                    if let action = card.action {
                        actionButton(action, primary: card.actionIsPrimary)
                            .padding(.top, 4)
                    }
                }
                .padding(.vertical, 4)
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier(AccessibilityID.planCard)
            } header: {
                Text(PlanWording.yourPlan)
            }
            .listRowBackground(Palette.surface)
            .overlay {
                if card.tone == .warning {
                    RoundedRectangle(cornerRadius: 10).stroke(Palette.warning, lineWidth: 2)
                        .allowsHitTesting(false)
                }
            }
        }
    }

    @ViewBuilder
    private func actionButton(_ action: PlanCardScreen.Action, primary: Bool) -> some View {
        let button = Button(action.title) { run(action) }
            .accessibilityIdentifier(AccessibilityID.planCardAction)
        if primary {
            button.buttonStyle(.borderedProminent)
        } else {
            button.buttonStyle(.bordered)
        }
    }

    private func run(_ action: PlanCardScreen.Action) {
        switch action {
        case .seePlans, .changePlan: seePlans()
        case .keepPlan, .openAppleSettings: openURL(PlanLinks.appleSubscriptions)
        case .manageOnWebsite: openURL(PlanLinks.manage)
        }
    }
}

/// Restore Purchases, as a row on Account, and what it found.
/// Restore Purchases. Its result is held by the screen around it, which
/// presents it: inside a Form this row can be rebuilt while Restore runs (its
/// status line comes and goes), and a result kept in the row's own state was
/// lost with it, so nothing showed (#202).
struct PhoneRestoreRow: View {
    let plans: PurchaseCoordinator
    @Binding var result: RestoreResultScreen?

    var body: some View {
        Group {
            Button(PlanWording.restore) {
                Task {
                    await plans.restore()
                    if plans.status == .idle { result = RestoreResultScreen(answer: plans.answer, device: "iPhone") }
                }
            }
            .disabled(plans.status == .working)
            .accessibilityIdentifier(AccessibilityID.planRestore)
            if let line = PlanStatusWording.line(plans.status) {
                Text(line)
                    .font(.footnote)
                    .foregroundStyle(PlanStatusWording.isWarning(plans.status) ? Palette.warning : Palette.muted)
                    .accessibilityIdentifier(AccessibilityID.planStatus)
            }
        }
    }
}

/// What Restore Purchases found, from `RestoreResultScreen`.
struct PhoneRestoreResultSheet: View {
    let result: RestoreResultScreen
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    ForEach(result.lines, id: \.self) { Text($0) }
                }
                .listRowBackground(Palette.surface)
            }
            .phoneSheet(title: result.title)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(result.close) { dismiss() }
                }
            }
        }
        .presentationDetents([.medium])
    }
}

/// Choose a plan: monthly or yearly, the three sizes, and Subscribe. Drawn
/// from `PlanChoicesScreen`; Apple's own prices replace the US ones once the
/// store answers. `afterBuying` runs once a purchase is accepted, such as
/// taking over paying for a locked group, as on the Mac.
struct PhoneChoosePlanSheet: View {
    let plans: PurchaseCoordinator
    var afterBuying: (() async -> Void)? = nil
    @State private var period: BillingPeriod = .monthly
    @State private var selected: PaidTier?
    @State private var prices: PlanPrices = .us
    @State private var storefrontIsUS = true
    /// What Restore Purchases found, presented from here (#202).
    @State private var restored: RestoreResultScreen?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    private var screen: PlanChoicesScreen {
        PlanChoicesScreen(answer: plans.answer, platform: .appleStore, period: period, selected: selected,
                          prices: prices, storefrontIsUS: storefrontIsUS)
    }

    var body: some View {
        let screen = screen
        NavigationStack {
            Form {
                Section {
                    Text(screen.intro).font(.subheadline)
                } footer: {
                    // In the footer, not a row: a row takes taps for itself.
                    HStack(spacing: 0) {
                        periodButton(.monthly, screen.monthlyLabel, note: nil, id: AccessibilityID.planMonthly)
                        periodButton(.yearly, screen.yearlyLabel, note: screen.yearlyNote, id: AccessibilityID.planYearly)
                    }
                    .overlay(Capsule().stroke(Palette.ink, lineWidth: 1.5))
                    .clipShape(Capsule())
                    .padding(.top, 8)
                    .textCase(nil)
                }
                .listRowBackground(Palette.surface)

                Section {
                    ForEach(screen.rows, id: \.tier) { row in
                        Button { selected = row.tier } label: { rowLabel(row, picked: row.tier == screen.selected) }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier(AccessibilityID.planRow(row.tier))
                            .accessibilityAddTraits(row.tier == screen.selected ? .isSelected : [])
                    }
                }
                .listRowBackground(Palette.surface)

                Section {
                    Text(screen.paidAdds)
                    Text(screen.peopleFree)
                    if let more = screen.moreThan15 {
                        Button(more) { openURL(PlanLinks.emailUs) }
                            .buttonStyle(.borderless)
                            .accessibilityIdentifier(AccessibilityID.planEmailUs)
                    }
                }
                .font(.footnote)
                .foregroundStyle(Palette.muted)
                .listRowBackground(Color.clear)

                Section {
                    Button { Task { await buy(screen) } } label: {
                        Text(screen.buy).frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    // "Coming soon" until the App Store sells plans (PLAN-17).
                    .disabled(!screen.canBuy || plans.status == .working)
                    .accessibilityIdentifier(AccessibilityID.planBuy)
                    if let status = PlanStatusWording.line(plans.status) {
                        Text(status)
                            .font(.footnote)
                            .foregroundStyle(PlanStatusWording.isWarning(plans.status) ? Palette.warning : Palette.muted)
                            .accessibilityIdentifier(AccessibilityID.planStatus)
                    }
                } footer: {
                    VStack(spacing: 6) {
                        Text(screen.finePrint)
                        HStack(spacing: 12) {
                            if screen.showsRestore { PhoneRestoreRow(plans: plans, result: $restored) }
                            if screen.showsTermsAndPrivacy {
                                Link("Terms", destination: PlanLinks.terms)
                                Link("Privacy", destination: PlanLinks.privacy)
                            }
                        }
                        .buttonStyle(.borderless)
                    }
                    .font(.footnote)
                    .frame(maxWidth: .infinity)
                    .multilineTextAlignment(.center)
                }
                .listRowBackground(Color.clear)
            }
            .phoneSheet(title: PlanWording.choosePlan)
            .sheet(item: $restored) { PhoneRestoreResultSheet(result: $0).tint(Palette.accent) }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(screen.notNow) { dismiss() }
                        .accessibilityIdentifier(AccessibilityID.planNotNow)
                }
            }
        }
        .task {
            let offers = await plans.offers()
            if !offers.isEmpty { prices = PlanPrices(offers: offers) }
            storefrontIsUS = await plans.storefrontIsUS()
        }
    }

    private func periodButton(_ value: BillingPeriod, _ label: String, note: String?, id: String) -> some View {
        let on = period == value
        return Button { period = value } label: {
            (Text(label).font(.subheadline.weight(.semibold))
                + Text(note.map { " \($0)" } ?? "").font(.caption))
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity)
                .foregroundStyle(on ? Palette.accent : Palette.ink)
                .background(on ? Palette.ink : Color.clear)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(id)
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    private func rowLabel(_ row: PlanChoicesScreen.Row, picked: Bool) -> some View {
        HStack(spacing: 12) {
            Image(systemName: picked ? "largecircle.fill.circle" : "circle")
                .foregroundStyle(Palette.ink)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(row.name).font(.headline)
                Text(row.detail).font(.caption).foregroundStyle(Palette.muted)
            }
            Spacer()
            (Text(row.price).font(.title3.weight(.bold)) + Text(row.unit).font(.caption))
                .foregroundStyle(Palette.ink)
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
    }

    private func buy(_ screen: PlanChoicesScreen) async {
        await plans.buy(screen.product(period))
        // Bought and accepted by the server: the card shows the new plan.
        if plans.status == .idle, plans.answer?.state != .free {
            await afterBuying?()
            dismiss()
        }
    }
}

#endif
