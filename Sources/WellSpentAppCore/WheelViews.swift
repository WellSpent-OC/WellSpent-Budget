// The money wheel and a budget row's fill, drawn in SwiftUI. The Mac's
// screens draw them, and they build for the iPhone too. SwiftUI exists only
// on Apple systems; the Linux app draws the same shared shapes with its own
// screens.
#if canImport(SwiftUI)
import SwiftUI

/// A money wheel. Every number comes from MoneyWheel and WheelGeometry.
/// Layout only.
///
/// The empty band, what is left drawn over it clockwise from the top, the
/// band's two edges, the tick where an even pace would be today, and the
/// words in the middle. To a screen reader the wheel is one element, saying
/// what its middle says.
struct MoneyWheelView: View {
    /// What the middle says: the key, the amount and "of" on a budget's or a
    /// group's page, or the amount and one word in Home's small wheel.
    enum Middle: Equatable {
        case full(amountSize: CGFloat)
        case compact
    }

    let wheel: MoneyWheel
    let geometry: WheelGeometry
    let middle: Middle

    var body: some View {
        let g = geometry
        ZStack {
            Circle().inset(by: g.center - g.radius)
                .stroke(Color(PaletteValues.wheelTrack), lineWidth: g.band)
            // A trimmed circle starts at 3 o'clock and runs clockwise, so a
            // quarter turn back starts it at the top.
            Circle().inset(by: g.center - g.radius)
                .trim(from: 0, to: wheel.arc)
                .stroke(Color(wheel.arcColor), style: StrokeStyle(lineWidth: g.band, lineCap: .butt))
                .rotationEffect(.degrees(-90))
            Circle().inset(by: g.center - g.outerEdge)
                .stroke(Color(PaletteValues.wheelEdge), lineWidth: WheelGeometry.edgeWidth)
            Circle().inset(by: g.center - g.innerEdge)
                .stroke(Color(PaletteValues.wheelEdge), lineWidth: WheelGeometry.edgeWidth)
            if let tick = wheel.tick {
                let line = g.tick(at: tick)
                Path { path in
                    path.move(to: CGPoint(x: line.from.x, y: line.from.y))
                    path.addLine(to: CGPoint(x: line.to.x, y: line.to.y))
                }
                .stroke(Color(PaletteValues.wheelEdge),
                        style: StrokeStyle(lineWidth: WheelGeometry.tickWidth, lineCap: .butt))
            }
            middleWords
                // Inside the tick's inner end, so the words never cross it.
                .frame(width: g.tickInner * 2)
        }
        .frame(width: g.size, height: g.size)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(wheel.spokenSummary)
    }

    /// Each on one line, shrinking to fit rather than wrapping.
    @ViewBuilder
    private var middleWords: some View {
        switch middle {
        case .full(let amountSize):
            VStack(spacing: 2) {
                Text(wheel.middleKey)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Palette.muted)
                    .fitting()
                Text(wheel.middleAmount)
                    .font(.system(size: amountSize, weight: .medium).monospacedDigit())
                    .foregroundStyle(Color(wheel.amountColor))
                    .fitting()
                Text(wheel.middleOf)
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.muted)
                    .fitting()
            }
        case .compact:
            VStack(spacing: 0) {
                Text(wheel.middleAmount)
                    .font(.system(size: 17, weight: .semibold).monospacedDigit())
                    .foregroundStyle(Color(wheel.amountColor))
                    .fitting()
                Text(wheel.compactWord)
                    .font(.system(size: 10))
                    .foregroundStyle(Palette.muted)
                    .fitting()
            }
        }
    }
}

/// A budget's row drawn as its own bar, behind the row's words: the empty
/// track, and the fill from the left as far as the budget is used this
/// period. Layout only.
/// A month bar. Every share and colour comes from MonthBar. Layout only.
///
/// The track, the first fill to the covered day (or to today in the over
/// colour when not covered), the second fill to today, the covered day's tick
/// standing past the bar's edges, a faint mark at today, and the outline. To a
/// screen reader the bar is one element, saying what MonthBar says.
struct MonthBarView: View {
    let bar: MonthBar
    var height: CGFloat = 26

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let today = width * bar.todayShare
            let covered = bar.coveredShare.map { width * $0 }
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 4).fill(Color(PaletteValues.wheelTrack))
                Rectangle().fill(Color(bar.firstFillColor))
                    .frame(width: covered ?? today)
                if let covered, today > covered {
                    Rectangle().fill(Color(MonthBar.secondFillColor))
                        .frame(width: today - covered)
                        .offset(x: covered)
                }
                if let covered {
                    Rectangle().fill(Color(PaletteValues.wheelEdge))
                        .frame(width: WheelGeometry.tickWidth, height: height + 16)
                        .offset(x: covered - WheelGeometry.tickWidth / 2, y: -8)
                }
                Rectangle().fill(Color(PaletteValues.wheelEdge).opacity(0.5))
                    .frame(width: 2)
                    .offset(x: today - 1)
                RoundedRectangle(cornerRadius: 4)
                    .strokeBorder(Color(PaletteValues.wheelEdge), lineWidth: WheelGeometry.edgeWidth)
            }
        }
        .frame(height: height)
        .padding(.vertical, 8)
        .accessibilityElement(children: .ignore)
        .accessibilityValue(bar.spokenValue)
    }
}

struct RowFillBackground: View {
    let fill: RowFill
    let cornerRadius: CGFloat

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: cornerRadius)
                    .fill(Color(PaletteValues.rowTrack))
                RoundedRectangle(cornerRadius: cornerRadius)
                    .fill(Color(fill.fillColor))
                    .frame(width: proxy.size.width * fill.share)
            }
        }
        // The row's own words and value say how far it is used.
        .accessibilityHidden(true)
    }
}

private extension View {
    /// One line, shrinking to half its size before it would wrap.
    func fitting() -> some View {
        lineLimit(1).minimumScaleFactor(0.5)
    }
}

#endif
