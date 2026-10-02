import Foundation

/// Money, as whole minor units. Never a float.
///
/// The old API stored amounts as `t.float`, which is the classic way to lose a
/// cent per thousand transactions and never be able to explain the drift. `0.1 +
/// 0.2` is not `0.3` in binary floating point, and a budget that is off by a penny
/// is a budget nobody trusts.
///
/// `Decimal` would also be correct, but it encodes inconsistently across platforms
/// and compares in ways that surprise people. An integer count of cents is exact,
/// sorts properly, sums without error, and serialises identically everywhere.
public struct Money: Hashable, Codable, Sendable, Comparable, CustomStringConvertible {
    /// Cents for dollars, pence for pounds. Whatever the currency's minor unit is.
    public var minorUnits: Int
    public var currency: Currency

    public init(minorUnits: Int, currency: Currency = .usd) {
        self.minorUnits = minorUnits
        self.currency = currency
    }

    public static func dollars(_ value: Double, currency: Currency = .usd) -> Money {
        Money(minorUnits: Int((value * 100).rounded()), currency: currency)
    }

    public static func zero(_ currency: Currency = .usd) -> Money {
        Money(minorUnits: 0, currency: currency)
    }

    public var isNegative: Bool { minorUnits < 0 }
    public var magnitude: Money { Money(minorUnits: abs(minorUnits), currency: currency) }

    public static func < (a: Money, b: Money) -> Bool {
        precondition(a.currency == b.currency, "cannot compare \(a.currency) with \(b.currency)")
        return a.minorUnits < b.minorUnits
    }

    public static func + (a: Money, b: Money) -> Money {
        precondition(a.currency == b.currency, "cannot add \(a.currency) to \(b.currency)")
        return Money(minorUnits: a.minorUnits + b.minorUnits, currency: a.currency)
    }

    public static func - (a: Money, b: Money) -> Money {
        precondition(a.currency == b.currency, "cannot subtract \(b.currency) from \(a.currency)")
        return Money(minorUnits: a.minorUnits - b.minorUnits, currency: a.currency)
    }

    public static func += (a: inout Money, b: Money) { a = a + b }
    public static func -= (a: inout Money, b: Money) { a = a - b }

    /// Plain digits with a decimal point. Locale formatting is a view concern and
    /// does not belong on the stored value.
    public var description: String {
        let unit = currency.minorUnitDigits
        guard unit > 0 else { return "\(minorUnits)" }
        let divisor = Int(pow(10.0, Double(unit)))
        let sign = minorUnits < 0 ? "-" : ""
        let whole = abs(minorUnits) / divisor
        let part = abs(minorUnits) % divisor
        return "\(sign)\(whole).\(String(format: "%0\(unit)d", part))"
    }

    /// Sums a sequence without needing a seed, which would force a currency guess.
    public static func total(_ values: some Sequence<Money>, currency: Currency = .usd) -> Money {
        values.reduce(Money.zero(currency), +)
    }
}

public enum Currency: String, Codable, Sendable, CaseIterable {
    case usd = "USD"
    case eur = "EUR"
    case gbp = "GBP"
    case cad = "CAD"
    case mxn = "MXN"

    public var minorUnitDigits: Int { 2 }

    public var symbol: String {
        switch self {
        case .usd, .cad, .mxn: return "$"
        case .eur: return "\u{20AC}"
        case .gbp: return "\u{A3}"
        }
    }
}
