import Foundation
import WellSpentCrypto
import WellSpentModel

/// The dates the money wheel's tests read: Gregorian, in Denver, written the
/// American way, so they pass the same on every machine, Linux included.
/// Each date is at noon, which keeps it on the same day in any time zone.
enum WheelCalendar {
    static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Denver")!
        calendar.locale = Locale(identifier: "en_US")
        return calendar
    }()

    static func date(_ year: Int, _ month: Int, _ day: Int) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: 12))!
    }

    /// The calendar month holding the date, as a budget that resets on the
    /// 1st has it.
    static func month(of date: Date) -> BudgetPeriod {
        ResetSchedule.firstOfMonth.period(containing: date, calendar: calendar)
    }

    /// A budget's summary in the month holding `now`: `limit` a month, with
    /// `spent` spent from it. Amounts in cents.
    static func summary(_ name: String = "Groceries", limit: Int, spent: Int, on now: Date,
                        currency: Currency = .usd, in group: GroupID = GroupID()) -> BudgetSummary {
        BudgetSummary(budget: Budget(groupID: group, name: name, limit: Money(minorUnits: limit, currency: currency)),
                      period: month(of: now), spent: Money(minorUnits: spent, currency: currency),
                      transactionCount: spent == 0 ? 0 : 1)
    }
}
