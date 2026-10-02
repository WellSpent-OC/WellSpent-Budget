import Foundation

/// The window a budget's spending is measured over.
public struct BudgetPeriod: Equatable, Sendable {
    public let start: Date
    public let end: Date          // exclusive

    public init(start: Date, end: Date) {
        self.start = start
        self.end = end
    }

    public func contains(_ date: Date) -> Bool { date >= start && date < end }
}

public extension ResetSchedule {
    /// The period containing `date`.
    ///
    /// A monthly budget that resets on the 1st and the 15th has two periods a
    /// month, and the one you are in runs from the most recent reset day to the
    /// next. The old schema stored these as a comma-separated string and left the
    /// client to work it out; doing it here means one implementation rather than
    /// one per platform.
    func period(containing date: Date, calendar: Calendar = .autoupdatingCurrent) -> BudgetPeriod {
        switch self {
        case .never:
            return BudgetPeriod(start: .distantPast, end: .distantFuture)

        case .weekly(let weekday):
            var components = DateComponents()
            components.weekday = weekday
            let start = calendar.nextDate(after: date, matching: components,
                                          matchingPolicy: .nextTime, direction: .backward)
                ?? calendar.startOfDay(for: date)
            let dayStart = calendar.startOfDay(for: start)
            let end = calendar.date(byAdding: .day, value: 7, to: dayStart) ?? date
            return BudgetPeriod(start: dayStart, end: end)

        case .monthly(let days):
            let sorted = Set(days).sorted()
            guard !sorted.isEmpty else {
                return ResetSchedule.never.period(containing: date, calendar: calendar)
            }

            // Every reset boundary in the previous, current and next month, so the
            // search works near either edge without special cases.
            var boundaries: [Date] = []
            for monthOffset in -1 ... 1 {
                guard let monthAnchor = calendar.date(byAdding: .month, value: monthOffset, to: date) else { continue }
                let parts = calendar.dateComponents([.year, .month], from: monthAnchor)
                let daysInMonth = calendar.range(of: .day, in: .month, for: monthAnchor)?.count ?? 31
                for day in sorted {
                    // A budget resetting on the 31st still resets in February.
                    var components = parts
                    components.day = Swift.min(day, daysInMonth)
                    if let boundary = calendar.date(from: components) {
                        boundaries.append(calendar.startOfDay(for: boundary))
                    }
                }
            }
            boundaries.sort()

            let start = boundaries.last { $0 <= date } ?? calendar.startOfDay(for: date)
            let end = boundaries.first { $0 > start } ?? date
            return BudgetPeriod(start: start, end: end)
        }
    }
}

/// What the app shows for one budget in one period.
public struct BudgetSummary: Equatable, Sendable {
    public let budget: Budget
    public let period: BudgetPeriod
    public let spent: Money
    public let transactionCount: Int

    public init(budget: Budget, period: BudgetPeriod, spent: Money, transactionCount: Int) {
        self.budget = budget
        self.period = period
        self.spent = spent
        self.transactionCount = transactionCount
    }

    public var remaining: Money { budget.limit - spent }
    public var isOverspent: Bool { spent > budget.limit }

    /// 0 to 1 for display. Clamped, so an overspent budget fills the bar rather
    /// than drawing past the end of it.
    public var fraction: Double {
        guard budget.limit.minorUnits > 0 else { return 0 }
        let raw = Double(spent.minorUnits) / Double(budget.limit.minorUnits)
        return Swift.min(Swift.max(raw, 0), 1)
    }
}
