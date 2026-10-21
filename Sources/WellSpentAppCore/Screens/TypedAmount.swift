import Foundation
import WellSpentModel

/// An amount as a person types it, read the way their region writes numbers.
/// Where a comma marks decimals, "12,50" is twelve fifty. Where a comma
/// groups thousands, "12,50" is not an amount anyone writes, since a thousands
/// group has three digits, so it is refused with the way to type it. It is
/// never guessed: a guess puts the wrong amount of real money in someone's
/// budget. Statements from a bank are not read here: their files say how
/// they write numbers, and StatementParser reads them that way.
public enum TypedAmount: Equatable, Sendable {
    /// Nothing typed yet.
    case empty
    case amount(Money)
    /// Typed, but not clearly an amount the way this region writes one.
    case unclear

    public init(_ text: String, currency: Currency = .usd, locale: Locale = AppLocale.current) {
        self = Self.read(text, currency: currency, marks: Marks(locale))
    }

    /// The amount, when there is one.
    public var money: Money? {
        if case .amount(let money) = self { return money }
        return nil
    }

    /// What an amount field starts with: the region's decimal mark and no
    /// thousands marks, so it reads back as the same amount.
    public static func text(_ money: Money, locale: Locale = AppLocale.current) -> String {
        money.description.replacingOccurrences(of: ".", with: Marks(locale).decimal)
    }

    public enum Words {
        /// Said under the amount, with an example written the region's way.
        public static func unclear(locale: Locale = AppLocale.current) -> String {
            "That amount can't be read clearly. Type it like \(TypedAmount.text(Money(minorUnits: 1_250), locale: locale))."
        }
    }

    /// How a region writes numbers: its decimal mark, its thousands mark, and
    /// the sizes of its groups. Most regions group by three. India groups the
    /// last three, then by two: 1,23,456.
    struct Marks {
        let decimal: String
        let grouping: String
        let groupSize: Int
        let otherGroupSize: Int

        init(_ locale: Locale) {
            let formatter = NumberFormatter()
            formatter.locale = locale
            formatter.numberStyle = .decimal
            decimal = formatter.decimalSeparator.flatMap { $0.isEmpty ? nil : $0 } ?? "."
            grouping = formatter.groupingSeparator.flatMap { $0.isEmpty ? nil : $0 } ?? ","
            // The group sizes come from how the system writes a long number,
            // so they always match what it writes. Linux's formatter leaves
            // its second size at zero even where the region uses one.
            var written: [Int] = []
            if grouping.count == 1, let mark = grouping.first,
               let long = formatter.string(from: NSNumber(value: 1_234_567_890)) {
                written = long.split(separator: mark).map(\.count)
            }
            if written.count >= 3 {
                groupSize = written[written.count - 1]
                otherGroupSize = written[written.count - 2]
            } else {
                groupSize = formatter.groupingSize > 0 ? formatter.groupingSize : 3
                otherGroupSize = formatter.secondaryGroupingSize > 0 ? formatter.secondaryGroupingSize : groupSize
            }
        }
    }

    static func read(_ typed: String, currency: Currency, marks: Marks) -> TypedAmount {
        var text = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return .empty }
        guard let decimal = marks.decimal.first, let grouping = marks.grouping.first,
              marks.decimal.count == 1, marks.grouping.count == 1 else { return .unclear }

        var negative = false
        // An accountant writes money out in brackets: (25.00).
        if text.hasPrefix("("), text.hasSuffix(")"), text.count > 2 {
            negative = true
            text = String(text.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
        }
        if let sign = text.first, "+-\u{2212}".contains(sign) {
            negative = sign != "+"
            text = String(text.dropFirst()).trimmingCharacters(in: .whitespaces)
        }
        if text.hasPrefix(currency.symbol) {
            text = String(text.dropFirst(currency.symbol.count)).trimmingCharacters(in: .whitespaces)
        }
        // A region that groups with a space takes any of the spaces a
        // keyboard types, and one that groups with an apostrophe takes either.
        let spaces: Set<Character> = [" ", "\u{00A0}", "\u{202F}"]
        let apostrophes: Set<Character> = ["'", "\u{2019}"]
        text = String(text.map { mark in
            if spaces.contains(grouping), spaces.contains(mark) { return grouping }
            if apostrophes.contains(grouping), apostrophes.contains(mark) { return grouping }
            return mark
        })
        guard text.allSatisfy({ ("0"..."9").contains($0) || $0 == decimal || $0 == grouping }) else {
            return .unclear
        }

        let halves = text.split(separator: decimal, omittingEmptySubsequences: false).map(String.init)
        guard halves.count <= 2 else { return .unclear }
        let whole = halves[0]
        let part = halves.count == 2 ? halves[1] : ""
        // "12," is twelve, and ",50" is fifty cents. A mark alone is nothing.
        guard !(whole.isEmpty && part.isEmpty), part.count <= currency.minorUnitDigits,
              !part.contains(grouping) else { return .unclear }

        let groups = whole.split(separator: grouping, omittingEmptySubsequences: false).map(String.init)
        if groups.count > 1 {
            // The last group has the region's group size, the ones before it
            // the other size, and the first may be shorter, but never empty.
            // Nor does it start with a zero: nobody writes five hundred as
            // "0.500", so where a dot groups thousands that is refused.
            guard groups.last?.count == marks.groupSize,
                  groups.dropFirst().dropLast().allSatisfy({ $0.count == marks.otherGroupSize }),
                  let first = groups.first, (1...marks.otherGroupSize).contains(first.count),
                  !first.hasPrefix("0") else { return .unclear }
        }

        let digits = groups.joined() + part.padding(toLength: currency.minorUnitDigits, withPad: "0", startingAt: 0)
        guard digits.count <= 15, let units = Int(digits) else { return .unclear }
        return .amount(Money(minorUnits: negative ? -units : units, currency: currency))
    }
}
