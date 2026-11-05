import Foundation
import WellSpentCrypto

/// When a repeat makes what, and exactly what it makes. Every field of a made
/// transaction comes from the rule and the month, never the clock, so two
/// devices write identical bytes and their copies tie harmlessly.
public extension RepeatRule {
    /// The month a date falls in, "yyyy-MM".
    static func month(of date: Date, calendar: Calendar) -> String {
        let parts = calendar.dateComponents([.year, .month], from: date)
        return String(format: "%04d-%02d", parts.year ?? 0, parts.month ?? 0)
    }

    /// The month after, "yyyy-MM".
    static func month(after month: String) -> String {
        let parts = month.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 2 else { return month }
        return parts[1] >= 12 ? String(format: "%04d-01", parts[0] + 1) : String(format: "%04d-%02d", parts[0], parts[1] + 1)
    }

    /// What holds in a month: the rule's own terms, or its latest change by then.
    func terms(in month: String) -> (budgetID: BudgetID, amount: Money, day: Int) {
        let change = changes.filter { $0.fromMonth <= month }.max { $0.fromMonth < $1.fromMonth }
        return (change?.budgetID ?? budgetID, change?.amount ?? amount, change?.day ?? day)
    }

    /// Whether the rule makes anything in this month.
    func runs(in month: String) -> Bool {
        !isDeleted && month >= firstMonth && (stopMonth.map { month < $0 } ?? true)
    }

    /// The day it shows up in a month, the month's last day if that's sooner.
    func dayOfMonth(_ month: String) -> Int {
        let parts = month.split(separator: "-").compactMap { Int($0) }
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        guard parts.count == 2, let first = utc.date(from: DateComponents(year: parts[0], month: parts[1], day: 1)),
              let days = utc.range(of: .day, in: .month, for: first)?.count else { return terms(in: month).day }
        return min(max(terms(in: month).day, 1), days)
    }

    /// The transaction it makes in a month. Noon UTC keeps the date on its day
    /// nearly everywhere, and the same for every device.
    func made(in month: String) -> Transaction? {
        guard runs(in: month) else { return nil }
        let parts = month.split(separator: "-").compactMap { Int($0) }
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        guard parts.count == 2, let date = utc.date(from: DateComponents(year: parts[0], month: parts[1],
                                                                         day: dayOfMonth(month), hour: 12))
        else { return nil }
        let terms = terms(in: month)
        return Transaction(id: .repeatMade(group: groupID, rule: id, month: month), budgetID: terms.budgetID,
                           groupID: groupID, date: date, merchant: name, amount: terms.amount, kind: .spending,
                           createdBy: createdBy, extensionLink: extensionLink, repeatRuleID: id, repeatMonth: month,
                           createdAt: createdAt, updatedAt: createdAt)
    }

    /// The months that have come by today, in order, from the first.
    func monthsDue(today: Date, calendar: Calendar) -> [String] {
        let now = Self.month(of: today, calendar: calendar)
        let dayNow = calendar.component(.day, from: today)
        var months: [String] = []
        var month = firstMonth
        while month <= now {
            if runs(in: month), month < now || dayOfMonth(month) <= dayNow { months.append(month) }
            month = Self.month(after: month)
        }
        return months
    }
}
