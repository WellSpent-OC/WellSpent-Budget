// The iPhone's screens, built the iPhone's way. Layout only.
#if os(iOS)
import SwiftUI
import WellSpentModel

/// The top of a budget's screen, as sections of its list: the day of the
/// period and the budget's wheel, then its figures with the count under them,
/// then the pace words when there are any. Draws `BudgetScreen`. Layout only.
struct PhoneBudgetWheelSections: View {
    let screen: BudgetScreen
    /// Opens the Edit Budget sheet, offered beside the pace words.
    let editBudget: () -> Void

    var body: some View {
        Section {
            VStack(spacing: 12) {
                if let dayLine = screen.dayLine {
                    Text(dayLine)
                        .font(.subheadline)
                        .foregroundStyle(Palette.muted)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityIdentifier(AccessibilityID.budgetDayLine)
                }
                MoneyWheelView(wheel: screen.wheel, geometry: .budgetPhone, middle: .full(amountSize: 26))
                    .accessibilityIdentifier(AccessibilityID.budgetWheel)
            }
            // The row's full width, so the wheel sits in the middle with or
            // without a day line: a budget that never resets has none.
            .frame(maxWidth: .infinity)
            .listRowBackground(Color.clear)
            // Ten down from the top: the section's rounded corner clips
            // whatever sits in it, even on a clear row.
            .listRowInsets(EdgeInsets(top: 10, leading: 4, bottom: 4, trailing: 4))
        }
        Section {
            ForEach(screen.wheel.figures) { figure in
                PhoneFigureRow(figure: figure)
            }
        } footer: {
            // The count, then the period's money in after a dot once there
            // is any: "5 transactions since Oct 1 · $3275.00 in" (INC-B).
            HStack(spacing: 0) {
                Text(screen.countLine)
                if let moneyIn = screen.moneyInLine {
                    Text(" \u{00B7} \(moneyIn)")
                        .accessibilityIdentifier(AccessibilityID.budgetMoneyInLine)
                }
            }
            .font(.footnote)
            .foregroundStyle(Palette.muted)
        }
        .listRowBackground(Palette.surface)
        if let pace = screen.pace {
            PhonePaceSection(pace: pace, editBudget: editBudget)
        }
    }
}

/// One figure under the wheel: "Spent" and "$555.36". Two plain texts, so a
/// screen reader and a test each find the amount on its own.
struct PhoneFigureRow: View {
    let figure: MoneyWheel.Figure

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(figure.label)
            Spacer(minLength: 8)
            Text(figure.amount)
                .font(.body.monospacedDigit())
                .foregroundStyle(figure.isWarning ? Palette.warning : Palette.ink)
        }
    }
}

/// The pace words under the figures: when the money runs out at this pace,
/// or, in the period's last week, that more is left than expected. Edit Budget
/// beside them for someone who may change the budget. No tinted card: the
/// wheel's colour and the words carry it, in light and dark alike.
struct PhonePaceSection: View {
    let pace: BudgetPace
    let editBudget: () -> Void

    var body: some View {
        Section {
            VStack(alignment: .leading, spacing: 10) {
                Text(pace.text)
                    .font(.subheadline)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier(AccessibilityID.budgetPace)
                if pace.offersEdit {
                    Button(BudgetPace.Words.editBudget(onPhone: true), action: editBudget)
                        .buttonStyle(.bordered)
                        .accessibilityIdentifier(AccessibilityID.budgetPaceEdit)
                }
            }
            .padding(.vertical, 4)
        }
        .listRowBackground(Palette.surface)
    }
}

#endif
