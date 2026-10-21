import Foundation
import SwiftCrossUI
import WellSpentAppCore
import WellSpentModel

// The money wheel and a budget row's fill on Linux: the open budget's row in
// the sidebar, a budget's page and a group's MONEY section. Every number,
// word and colour comes from the shared code (MoneyWheel, WheelGeometry,
// RowFill, BudgetPace, GroupMoney and PaletteValues). This is layout only.
//
// GTK draws each shape in its own drawing area, clipped to its frame, and
// joins two shapes in one path with a straight line. So the ring's track, its
// two edges, the arc and the tick are each a shape of their own, stacked.
// Colours come from Color(_ pair:) in Palette.swift.

// MARK: - The wheel's shapes

/// A circle round the middle of its frame.
struct RingShape: Shape {
    let radius: Double

    func path(in bounds: Path.Rect) -> Path {
        Path().addCircle(center: bounds.center, radius: radius)
    }
}

/// The drawn part of the ring, clockwise from the top. WheelGeometry splits
/// it at 3 o'clock, so no angle passes a full turn, and the two spans meet
/// there, so they share one path without a stray line.
struct ArcShape: Shape {
    let spans: [WheelGeometry.Span]
    let radius: Double

    func path(in bounds: Path.Rect) -> Path {
        var path = Path()
        for span in spans {
            path = path.addArc(center: bounds.center, radius: radius,
                               startAngle: span.start, endAngle: span.end, clockwise: true)
        }
        return path
    }
}

/// The tick across the band, where an even pace would be today.
struct TickShape: Shape {
    let line: WheelGeometry.Line

    func path(in bounds: Path.Rect) -> Path {
        Path().move(to: SIMD2(line.from.x, line.from.y)).addLine(to: SIMD2(line.to.x, line.to.y))
    }
}

// MARK: - The wheel

/// A money wheel: the empty band, what is left drawn over it clockwise from
/// the top, the band's two edges, the tick where an even pace would be
/// today, and the words in the middle. Layout only.
struct MoneyWheelView: View {
    let wheel: MoneyWheel
    let geometry: WheelGeometry

    var body: some View {
        let g = geometry
        return ZStack {
            RingShape(radius: g.radius)
                .stroke(Color(PaletteValues.wheelTrack), style: StrokeStyle(width: g.band))
            ArcShape(spans: g.spans(for: wheel.arc), radius: g.radius)
                .stroke(Color(wheel.arcColor), style: StrokeStyle(width: g.band, cap: .butt))
            RingShape(radius: g.outerEdge)
                .stroke(Color(PaletteValues.wheelEdge), style: StrokeStyle(width: WheelGeometry.edgeWidth))
            RingShape(radius: g.innerEdge)
                .stroke(Color(PaletteValues.wheelEdge), style: StrokeStyle(width: WheelGeometry.edgeWidth))
            if let tick = wheel.tick {
                TickShape(line: g.tick(at: tick))
                    .stroke(Color(PaletteValues.wheelEdge),
                            style: StrokeStyle(width: WheelGeometry.tickWidth, cap: .butt))
            }
            // Each on one line, inside the tick's inner end, so the words
            // never cross it.
            VStack(spacing: 2) {
                Text(wheel.middleKey)
                    .font(.system(size: Self.fitting(wheel.middleKey, size: 12, in: g), weight: .semibold))
                    .foregroundColor(Color(PaletteValues.muted))
                    .fixedSize()
                Text(wheel.middleAmount)
                    .font(.system(size: Self.fitting(wheel.middleAmount, size: 28, in: g), weight: .medium))
                    .foregroundColor(Color(wheel.amountColor))
                    .fixedSize()
                Text(wheel.middleOf)
                    .font(.system(size: Self.fitting(wheel.middleOf, size: 11, in: g)))
                    .foregroundColor(Color(PaletteValues.muted))
                    .fixedSize()
            }
            .frame(width: g.tickInner * 2)
        }
        .frame(width: g.size, height: g.size)
    }

    /// The size for one line in the wheel's middle: `size`, made smaller when
    /// the line would pass the tick's inner end, as the Mac shrinks its words
    /// to fit. SwiftCrossUI cannot shrink words to fit, so this counts the
    /// characters: each takes at most 0.7 of the size across, and a comma, a
    /// full stop or a space 0.38.
    private static func fitting(_ words: String, size: Double, in geometry: WheelGeometry) -> Double {
        let narrow = words.filter { ",. ".contains($0) }.count
        let across = 0.7 * Double(words.count - narrow) + 0.38 * Double(narrow)
        guard across > 0 else { return size }
        return min(size, geometry.tickInner * 2 / across)
    }
}

// MARK: - A budget's row

/// A budget's row in the sidebar, drawn as its own bar: filled from the left
/// as far as the budget is used this period, with its name and what is left,
/// or how far over, on top. The open budget's row keeps its fill and gets an
/// outline, in place of a list's highlight. What it says is RowFill's.
/// Layout only.
struct BudgetRow: View {
    let summary: BudgetSummary
    /// Whether this is the open budget.
    let isPicked: Bool

    var body: some View {
        let fill = RowFill(summary)
        return HStack {
            Text(summary.budget.name)
                .font(.system(size: 13))
                .foregroundColor(Color(PaletteValues.rowWords))
            Spacer()
            Text(fill.amount)
                .font(.system(size: 13, weight: fill.isOver ? Font.Weight.semibold : nil))
                .foregroundColor(Color(PaletteValues.rowAmount))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(RowFillBackground(fill: fill))
        .overlay {
            if isPicked {
                // Inside the row's edge, so the fill stays the row's size.
                RoundedRectangle(cornerRadius: 4)
                    .inset(by: 1)
                    .stroke(Color(PaletteValues.rowOutline), style: StrokeStyle(width: 2))
            }
        }
    }
}

/// Behind a budget's row: the empty track, and the fill from the left as far
/// as the budget is used this period. Layout only.
struct RowFillBackground: View {
    let fill: RowFill

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color(PaletteValues.rowTrack))
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color(fill.fillColor))
                    .frame(width: proxy.size.width * fill.share)
            }
        }
    }
}

// MARK: - A budget's page

/// The top of a budget's page, in place of the bar: the day of its period,
/// its wheel, and beside the wheel its figures and the pace words when there
/// are any. Then the line counting its transactions. What it says is
/// BudgetScreen's. Layout only.
struct BudgetWheelPanel: View {
    let screen: BudgetScreen
    /// Opens the Edit Budget sheet, from Edit Budget… beside the pace words.
    var editBudget: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let dayLine = screen.dayLine {
                Text(dayLine)
                    .font(.system(size: 13))
                    .foregroundColor(Color(PaletteValues.muted))
            }
            HStack(spacing: 20) {
                MoneyWheelView(wheel: screen.wheel, geometry: .budgetDesktop)
                VStack(alignment: .leading, spacing: 10) {
                    FiguresList(figures: screen.wheel.figures)
                    if let pace = screen.pace {
                        PaceLine(pace: pace, editBudget: editBudget)
                    }
                }
                .frame(maxWidth: 360)
            }
            Text(screen.countLine)
                .font(.system(size: 11))
                .foregroundColor(Color(PaletteValues.muted))
        }
    }
}

/// The figures beside a wheel: Spent, then Left or Over, then Expected left
/// by today when there is one, with a rule between each. Layout only.
struct FiguresList: View {
    let figures: [MoneyWheel.Figure]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(figures) { figure in
                HStack(spacing: 12) {
                    Text(figure.label)
                        .font(.system(size: 13))
                    Spacer()
                    // The Over figure's amount is in the warning colour, and
                    // its label says Over, so the colour is not the only sign.
                    Text(figure.amount)
                        .font(.system(size: 13))
                        .foregroundColor(Color(figure.isWarning ? PaletteValues.warning : PaletteValues.ink))
                }
                .padding(.vertical, 5)
                if figure.id != figures.last?.id {
                    Color(PaletteValues.line)
                        .frame(height: 1)
                }
            }
        }
    }
}

/// The pace words under a budget's figures, and beside them Edit Budget… for
/// someone who may change the budget. Layout only.
struct PaceLine: View {
    let pace: BudgetPace
    var editBudget: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            // As many lines as the words take, never cut short.
            Text(pace.text)
                .font(.system(size: 12))
                .foregroundColor(Color(PaletteValues.ink))
                .fixedSize(horizontal: false, vertical: true)
            if pace.offersEdit {
                Button(BudgetPace.Words.editBudget(onPhone: false)) { editBudget() }
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
        VStack(alignment: .leading, spacing: 6) {
            Text(GroupMoney.Words.section.uppercased())
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(Color(PaletteValues.muted))
            HStack(spacing: 16) {
                MoneyWheelView(wheel: money.wheel, geometry: .groupDesktop)
                VStack(alignment: .leading, spacing: 8) {
                    Text(GroupMoney.Words.card)
                        .font(.system(size: 13, weight: .semibold))
                    FiguresList(figures: money.wheel.figures)
                    Text(money.note)
                        .font(.system(size: 12))
                        .foregroundColor(Color(PaletteValues.muted))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: 360)
            }
            // In a well, as on the Mac.
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color(PaletteValues.sidebar)))
        }
    }
}
