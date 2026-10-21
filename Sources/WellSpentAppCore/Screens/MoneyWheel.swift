import Foundation
import WellSpentModel

// The money wheel: what is left of one budget, or of a group's budgets added
// up, this period. It is full before anything is spent, its green runs
// clockwise from the top and shrinks back as money goes out, and a tick marks
// where an even pace would be today. Its shape, colours and words live here,
// and each app only draws them.

/// How far through its period a budget is today: "day 18 of 31".
public struct PeriodDay: Equatable, Sendable {
    /// Today, counted from 1.
    public let day: Int
    /// The days in the period.
    public let days: Int
    /// The start of the period's first day.
    public let start: Date
    /// Today's month, "October".
    public let month: String

    /// Nil when the period has no end, as for a budget that never resets.
    ///
    /// Today counts as spent through, so day 18 of 31 leaves 13 days to come.
    /// A day read before midnight on the period's last day stays on that day
    /// until the app reads its budgets again.
    public init?(period: BudgetPeriod, now: Date, calendar: Calendar) {
        guard period.start != .distantPast, period.end != .distantFuture else { return nil }
        let start = calendar.startOfDay(for: period.start)
        guard let days = calendar.dateComponents([.day], from: start, to: calendar.startOfDay(for: period.end)).day,
              days > 0 else { return nil }
        let today = calendar.dateComponents([.day], from: start, to: calendar.startOfDay(for: now)).day ?? 0
        self.day = min(max(today + 1, 1), days)
        self.days = days
        self.start = start
        month = now.formatted(Date.FormatStyle(locale: calendar.locale ?? .current, calendar: calendar,
                                               timeZone: calendar.timeZone).month(.wide))
    }

    /// The days still to come after today.
    public var daysToCome: Int { days - day }
    /// The share of the period still to come after today, 0 to 1.
    public var shareToCome: Double { Double(daysToCome) / Double(days) }
    /// Whether today is in the period's last 7 days.
    public var isLastWeek: Bool { daysToCome < 7 }
    /// Under a budget's name: "October · day 18 of 31".
    public var line: String { "\(month) \u{00B7} day \(day) of \(days)" }
    /// "Day 18 of 31".
    public var shortLine: String { "Day \(day) of \(days)" }
}

/// What is left of one budget, or of a group's budgets added up, this
/// period: the wheel's shape, its colours and its words.
public struct MoneyWheel: Equatable, Sendable {
    /// A budget's own wheel, or a group's, which adds up its budgets for the
    /// month.
    public enum Scope: Equatable, Sendable { case budget, group }

    /// One line beside the wheel: "Spent" and "$555.36".
    public struct Figure: Equatable, Sendable, Identifiable {
        public let label: String
        public let amount: String
        /// True for the Over figure, whose amount shows in the warning colour.
        public let isWarning: Bool

        public init(label: String, amount: String, isWarning: Bool = false) {
            self.label = label
            self.amount = amount
            self.isWarning = isWarning
        }

        public var id: String { label }
    }

    public let scope: Scope
    public let budgeted: Money
    public let spent: Money
    /// Nil for a budget that never resets: its wheel has no tick and no
    /// expected figure.
    public let day: PeriodDay?

    public init(scope: Scope, budgeted: Money, spent: Money, day: PeriodDay?) {
        self.scope = scope
        self.budgeted = budgeted
        self.spent = spent
        self.day = day
    }

    /// A budget's wheel, from its summary and its own period.
    public init(budget summary: BudgetSummary, now: Date = Date(), calendar: Calendar = .autoupdatingCurrent) {
        self.init(scope: .budget, budgeted: summary.budget.limit, spent: summary.spent,
                  day: PeriodDay(period: summary.period, now: now, calendar: calendar))
    }

    /// What is left. Below zero when over.
    public var left: Money { budgeted - spent }
    public var isOver: Bool { spent > budgeted }

    /// How much of the ring is drawn, 0 to 1: all of it when over, in the
    /// warning colour. A refund larger than the spending keeps it full.
    public var arc: Double {
        if isOver { return 1 }
        guard budgeted.minorUnits > 0 else { return 0 }
        return min(max(Double(left.minorUnits) / Double(budgeted.minorUnits), 0), 1)
    }

    /// Where the tick goes, 0 to 1 clockwise from the top: where the green
    /// would end today at an even pace. None when over, or with no period.
    public var tick: Double? {
        guard !isOver, let day else { return nil }
        return day.shareToCome
    }

    /// What would be left today at an even pace: the budget's share for the
    /// days still to come, rounded half up to the cent.
    public var expectedLeft: Money? {
        guard !isOver, let day, budgeted.minorUnits > 0 else { return nil }
        let units = (budgeted.minorUnits * day.daysToCome * 2 + day.days) / (2 * day.days)
        return Money(minorUnits: units, currency: budgeted.currency)
    }

    /// Less is left than an even pace would leave today.
    public var isOverPace: Bool {
        guard let expectedLeft else { return false }
        return left < expectedLeft
    }

    /// Whether the wheel shows in the warning colour: over, or for a budget,
    /// over pace. A group's wheel says nothing about its pace in words, so
    /// its colour does not either.
    public var isWarning: Bool { isOver || (scope == .budget && isOverPace) }

    /// The drawn part of the ring.
    public var arcColor: ColorPair { isWarning ? PaletteValues.warning : PaletteValues.wheelLeft }
    /// The amount in the wheel's middle. Over pace keeps it in ink.
    public var amountColor: ColorPair { isOver ? PaletteValues.warning : PaletteValues.ink }

    /// Above the amount in the wheel's middle: "Left", "Over", "Left this
    /// month" or "Over this month".
    public var middleKey: String {
        switch scope {
        case .budget: return isOver ? Words.over : Words.left
        case .group: return isOver ? Words.overThisMonth : Words.leftThisMonth
        }
    }

    /// In the wheel's middle, in whole units: what is left, or how far over.
    /// Over by less than half a unit still shows one whole unit, so an
    /// orange wheel never says "Over $0".
    public var middleAmount: String {
        guard isOver else { return left.wholeDisplay }
        let over = spent - budgeted
        return Money(minorUnits: max(over.minorUnits, over.minorUnitsPerUnit), currency: over.currency).wholeDisplay
    }
    /// Under the amount in the wheel's middle: "of $1,000".
    public var middleOf: String { Words.of(budgeted.wholeDisplay) }
    /// Under the amount in Home's small wheel: "left" or "over".
    public var compactWord: String { isOver ? Words.compactOver : Words.compactLeft }

    /// Beside the wheel: Spent, then Over or Left, then Expected left by
    /// today when there is an even pace to measure.
    public var figures: [Figure] {
        var figures = [Figure(label: Words.spent, amount: spent.display)]
        if isOver {
            figures.append(Figure(label: Words.over, amount: (spent - budgeted).display, isWarning: true))
        } else {
            figures.append(Figure(label: Words.left, amount: left.display))
        }
        if let expectedLeft {
            figures.append(Figure(label: Words.expectedLeft, amount: expectedLeft.display))
        }
        return figures
    }

    /// The whole wheel for a screen reader: "Left $445 of $1,000".
    public var spokenSummary: String { [middleKey, middleAmount, middleOf].joined(separator: " ") }

    public enum Words {
        public static let left = "Left"
        public static let over = "Over"
        public static let leftThisMonth = "Left this month"
        public static let overThisMonth = "Over this month"
        public static let spent = "Spent"
        public static let expectedLeft = "Expected left by today"
        /// Under the amount in Home's small wheel.
        public static let compactLeft = "left"
        public static let compactOver = "over"
        /// "of $1,000".
        public static func of(_ amount: String) -> String { "of \(amount)" }
    }
}

/// Where every part of a wheel goes, for each app to draw: SwiftUI on the
/// Mac and the iPhone, SwiftCrossUI on Linux. Points, y down, origin at the
/// top left of a square `size` across.
///
/// The band's middle sits 3 inside the frame's edge, then two edges ring the
/// band, and the tick runs from 6 inside the inner edge to the frame's edge,
/// so nothing draws outside the square.
public struct WheelGeometry: Equatable, Sendable {
    public struct Point: Equatable, Sendable {
        public let x: Double
        public let y: Double

        public init(x: Double, y: Double) {
            self.x = x
            self.y = y
        }
    }

    public struct Line: Equatable, Sendable {
        public let from: Point
        public let to: Point

        public init(from: Point, to: Point) {
            self.from = from
            self.to = to
        }
    }

    /// An arc, in radians measured clockwise from the trailing side
    /// (3 o'clock), each end within 0 and 2π.
    public struct Span: Equatable, Sendable {
        public let start: Double
        public let end: Double

        public init(start: Double, end: Double) {
            self.start = start
            self.end = end
        }
    }

    /// How far across the wheel's square is.
    public let size: Double
    /// How wide the ring's band is.
    public let band: Double

    public init(size: Double, band: Double) {
        self.size = size
        self.band = band
    }

    /// A budget's wheel on a desktop.
    public static let budgetDesktop = WheelGeometry(size: 210, band: 26)
    /// A group's wheel on a desktop.
    public static let groupDesktop = WheelGeometry(size: 170, band: 22)
    /// A budget's wheel on a phone.
    public static let budgetPhone = WheelGeometry(size: 190, band: 24)
    /// The small wheel on Home's card on a phone.
    public static let homeCard = WheelGeometry(size: 96, band: 12)
    /// How wide each of the band's two edges is drawn.
    public static let edgeWidth = 3.0
    /// How wide the tick is drawn, with square ends.
    public static let tickWidth = 5.0

    /// The middle of the square, across and down.
    public var center: Double { size / 2 }
    /// The radius of the band's middle, where the ring and its arc are drawn.
    public var radius: Double { (size - band) / 2 - 3 }
    public var outerEdge: Double { radius + band / 2 }
    public var innerEdge: Double { radius - band / 2 }
    /// Where the tick starts, inside the band.
    public var tickInner: Double { innerEdge - 6 }
    /// Where the tick ends: the frame's edge.
    public var tickOuter: Double { size / 2 }

    /// The top of the wheel, where every arc starts.
    private static let top = Double.pi * 3 / 2

    /// The drawn part of the ring: clockwise from the top, split at
    /// 3 o'clock so no angle passes 2π.
    public func spans(for share: Double) -> [Span] {
        guard share > 0 else { return [] }
        let turn = 2 * Double.pi
        guard share < 1 else { return [Span(start: 0, end: turn)] }
        let end = Self.top + turn * share
        if end <= turn { return [Span(start: Self.top, end: end)] }
        return [Span(start: Self.top, end: turn), Span(start: 0, end: end - turn)]
    }

    /// The tick at a share of the way round, clockwise from the top: a line
    /// across the band from `tickInner` to `tickOuter`.
    public func tick(at share: Double) -> Line {
        let angle = Self.top + 2 * Double.pi * share
        func point(_ radius: Double) -> Point {
            Point(x: center + radius * cos(angle), y: center + radius * sin(angle))
        }
        return Line(from: point(tickInner), to: point(tickOuter))
    }
}

public extension Money {
    /// Whole units, rounded half up, with a comma every three digits: "$1,302".
    /// For the middle of a wheel, where the drawing has room for no cents.
    var wholeDisplay: String {
        let units = wholeUnits
        var digits = String(units)
        var grouped: [String] = []
        while digits.count > 3 {
            grouped.insert(String(digits.suffix(3)), at: 0)
            digits.removeLast(3)
        }
        grouped.insert(digits, at: 0)
        let sign = minorUnits < 0 && units > 0 ? "-" : ""
        return sign + currency.symbol + grouped.joined(separator: ",")
    }
}

extension Money {
    /// How many minor units make one whole unit: 100 cents to the dollar.
    var minorUnitsPerUnit: Int { Int(pow(10.0, Double(currency.minorUnitDigits))) }

    /// The size of the amount in whole units, rounded half up.
    var wholeUnits: Int {
        let divisor = minorUnitsPerUnit
        return (abs(minorUnits) + divisor / 2) / divisor
    }
}
