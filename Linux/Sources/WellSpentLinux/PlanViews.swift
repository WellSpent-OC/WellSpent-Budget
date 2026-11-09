import Foundation
import SwiftCrossUI
import WellSpentAppCore
import WellSpentPlans

/// The one plan card on Account. What it says, and which button it offers,
/// is PlanCardScreen's; on Linux the button goes to the website, and a plan
/// bought through Apple has none. Layout only.
struct PlanCardView: View {
    let card: PlanCardScreen
    var act: (PlanCardScreen.Action) -> Void
    var changeWhatStaysOpen: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(card.title)
                    .font(.system(size: 15, weight: .bold))
                if let badge = card.badge {
                    Text(badge)
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(Palette.surface)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(RoundedRectangle(cornerRadius: 4).fill(Palette.ink))
                }
            }
            ForEach(card.lines, id: \.self) { line in
                Text(line)
                    .font(.system(size: 13))
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let action = card.action {
                Button(action.title) { act(action) }
            }
            if card.showsChangeWhatStaysOpen {
                Button(PlanWording.changeWhatStaysOpen) { changeWhatStaysOpen() }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8)
            .fill(card.tone == .warning ? Palette.track : Palette.sidebar))
    }
}

/// Choose a plan: monthly or yearly, the three sizes, and on Linux a button
/// that continues on the website. What it says is PlanChoicesScreen's.
/// Layout only.
struct PlanChoicesView: View {
    let answer: PlanAnswer?
    /// The chosen plan, to pay for on the website.
    var checkout: (PlanProduct) -> Void
    var emailUs: () -> Void
    var close: () -> Void

    @State private var period: BillingPeriod = .monthly
    @State private var picked: PaidTier?

    var body: some View {
        let screen = PlanChoicesScreen(answer: answer, platform: .website, period: period, selected: picked,
                                       storefrontIsUS: true)
        VStack(alignment: .leading, spacing: 12) {
            Text(PlanWording.choosePlan)
                .font(.system(size: 17, weight: .semibold))
            Text(screen.intro)
                .font(.system(size: 13))
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 6) {
                periodButton(screen.monthlyLabel, .monthly)
                periodButton("\(screen.yearlyLabel) \(screen.yearlyNote)", .yearly)
            }
            ForEach(screen.rows, id: \.tier) { row in
                Button(action: { picked = row.tier }) {
                    HStack(spacing: 10) {
                        Text(row.tier == screen.selected ? "●" : "○")
                        VStack(alignment: .leading, spacing: 2) {
                            Text(row.name).font(.system(size: 14, weight: .semibold))
                            Text(row.detail)
                                .font(.system(size: 12))
                                .foregroundColor(Palette.muted)
                        }
                        Spacer()
                        Text(row.price).font(.system(size: 16, weight: .bold))
                        Text(row.unit)
                            .font(.system(size: 12))
                            .foregroundColor(Palette.muted)
                    }
                    .padding(10)
                    .frame(maxWidth: 10_000)
                    .background(RoundedRectangle(cornerRadius: 8)
                        .fill(row.tier == screen.selected ? Palette.track : Palette.surface))
                }
                .buttonStyle(.plain)
                .accessibility(label: "\(row.name) \(row.price)\(row.unit)", selected: row.tier == screen.selected)
            }
            note(screen.everyFeature)
            note(screen.peopleFree)
            // "More than 15 properties? Email us.", with Email us as its link.
            if screen.moreThan15 != nil {
                HStack(spacing: 4) {
                    note(PlanWording.moreThan15)
                    Button(PlanWording.emailUs) { emailUs() }
                }
            }
            note(screen.finePrint)
            HStack {
                Spacer()
                Button(screen.notNow) { close() }
                Button(screen.buy) { checkout(screen.product(period)) }
                    .defaultAction()
            }
        }
        .padding(20)
        .frame(width: 560)
        .foregroundColor(Palette.ink)
        .background(Palette.surface)
    }

    private func periodButton(_ title: String, _ choice: BillingPeriod) -> some View {
        Button(title) { period = choice }
            .accessibility(selected: period == choice)
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12))
            .foregroundColor(Palette.muted)
            .fixedSize(horizontal: false, vertical: true)
    }
}
