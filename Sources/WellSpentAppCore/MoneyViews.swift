// The money wheel on a desktop: the open budget's outline in the sidebar, a
// budget's page and a group's MONEY section. SwiftUI exists only on Apple
// systems; the Linux app draws the same shared logic with its own screens.
#if canImport(SwiftUI)
import SwiftUI

// MARK: - A budget's row

/// The outline round the open budget's row in the sidebar, in place of the
/// list's highlight, drawn inside the row's edge. The row keeps its fill.
struct PickedRowOutline: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 4)
            .strokeBorder(Color(PaletteValues.rowOutline), lineWidth: 2)
    }
}

// MARK: - A budget's page

/// The top of a budget's page, in place of the bar: the day of its period,
/// its wheel, and beside the wheel its figures and the pace words when there
/// are any. Then the line counting its transactions. What it says is
/// BudgetScreen's. Layout only.
struct BudgetWheelPanel: View {
    /// The least width of the figures and the pace words beside the wheel.
    static let columnMinWidth: CGFloat = 260

    let screen: BudgetScreen
    /// Opens the Edit Budget sheet, from Edit Budget… beside the pace words.
    let editBudget: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let dayLine = screen.dayLine {
                Text(dayLine)
                    .font(.system(size: 13))
                    .foregroundStyle(Palette.muted)
                    .accessibilityIdentifier(AccessibilityID.budgetDayLine)
            }
            HStack(spacing: 20) {
                MoneyWheelView(wheel: screen.wheel, geometry: .budgetDesktop, middle: .full(amountSize: 28))
                    .accessibilityIdentifier(AccessibilityID.budgetWheel)
                VStack(alignment: .leading, spacing: 10) {
                    FiguresList(figures: screen.wheel.figures)
                    if let pace = screen.pace {
                        PaceLine(pace: pace, editBudget: editBudget)
                    }
                }
                // A floor as well as a ceiling. The pace words take their full
                // height, so squeezed to a sliver they would stand very tall,
                // and the window's least height with them. Then the window
                // grew taller than the screen, and its sheets went off it.
                .frame(minWidth: Self.columnMinWidth, maxWidth: 360, alignment: .leading)
            }
            Text(screen.countLine)
                .font(.system(size: 11))
                .foregroundStyle(Palette.muted)
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The figures beside a wheel: Spent, then Left or Over, then Expected left
/// by today when there is one, with a rule between each. Plain texts, so each
/// amount can be found by its words. Layout only.
struct FiguresList: View {
    let figures: [MoneyWheel.Figure]

    var body: some View {
        VStack(spacing: 0) {
            ForEach(figures) { figure in
                HStack(spacing: 12) {
                    Text(figure.label)
                        .font(.system(size: 13))
                    Spacer(minLength: 0)
                    Text(figure.amount)
                        .font(.money(13))
                        .foregroundStyle(Color(figure.amountColor))
                }
                .padding(.vertical, 5)
                if figure.id != figures.last?.id {
                    Rectangle()
                        .fill(Palette.line)
                        .frame(height: 1)
                }
            }
        }
        // The labels in ink, not the system's text colour, which turns light
        // in dark mode while the page under them stays light. Each amount
        // has its own colour.
        .foregroundStyle(Palette.ink)
    }
}

/// The pace words under a budget's figures, and beside them Edit Budget… for
/// someone who may change the budget. Layout only.
struct PaceLine: View {
    let pace: BudgetPace
    let editBudget: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(pace.text)
                .font(.system(size: 12))
                .foregroundStyle(Palette.ink)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier(AccessibilityID.budgetPace)
            if pace.offersEdit {
                Button(BudgetPace.Words.editBudget(onPhone: false), action: editBudget)
                    .buttonStyle(.bordered)
                    // The button keeps its whole width, and the words wrap in
                    // what is left. Given the room first, the words took it
                    // all, and the button read "E…".
                    .fixedSize()
                    .accessibilityIdentifier(AccessibilityID.budgetPaceEdit)
            }
        }
    }
}

// MARK: - A group's page

/// MONEY on a group's page, above PEOPLE: the group's wheel, every budget in
/// it added up for the month, and beside the wheel its figures and a note
/// saying what it counts. What it says is GroupMoney's. Layout only.
struct GroupMoneySection: View {
    let money: GroupMoney

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(GroupMoney.Words.section.uppercased())
                .font(.system(size: 11, weight: .semibold))
                .tracking(0.8)
                .foregroundStyle(Palette.muted)
            HStack(spacing: 20) {
                MoneyWheelView(wheel: money.wheel, geometry: .groupDesktop, middle: .full(amountSize: 28))
                    .accessibilityIdentifier(AccessibilityID.groupWheel)
                VStack(alignment: .leading, spacing: 8) {
                    Text(GroupMoney.Words.card)
                        .font(.system(size: 13, weight: .semibold))
                    FiguresList(figures: money.wheel.figures)
                    if let covered = money.wheel.overBudgetsCoveredLine {
                        Text(covered)
                            .font(.system(size: 12))
                            .foregroundStyle(Color(PaletteValues.warning))
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier(AccessibilityID.groupOverBudgetsCovered)
                    }
                    ForEach(money.otherMoneyLines, id: \.self) { line in
                        Text(line)
                            .font(.system(size: 12))
                            .accessibilityIdentifier(AccessibilityID.groupOtherMoney)
                    }
                    Text(money.note)
                        .font(.system(size: 12))
                        .foregroundStyle(Palette.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                // In ink, as the figures are: the well stays light in dark mode.
                .foregroundStyle(Palette.ink)
                // A floor too, for the same reason as a budget's figures.
                .frame(minWidth: BudgetWheelPanel.columnMinWidth, maxWidth: 360, alignment: .leading)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Palette.sidebar, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Palette.line, lineWidth: 1))
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(AccessibilityID.groupMoney)
    }
}

#endif
