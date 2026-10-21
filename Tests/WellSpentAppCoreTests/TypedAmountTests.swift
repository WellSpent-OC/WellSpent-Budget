import Testing
import Foundation
@testable import WellSpentAppCore
import WellSpentModel

/// An amount as a person types it, read the way their region writes numbers,
/// and refused when it can't be read clearly, never guessed.
@Suite("Typed amounts")
struct TypedAmountTests {
    static let us = Locale(identifier: "en_US")
    static let germany = Locale(identifier: "de_DE")
    static let france = Locale(identifier: "fr_FR")
    static let switzerland = Locale(identifier: "de_CH")
    static let india = Locale(identifier: "en_IN")

    private func cents(_ text: String, _ locale: Locale) -> Int? {
        TypedAmount(text, locale: locale).money?.minorUnits
    }

    // Scenario ENTRY-12
    @Test func whereACommaMarksDecimalsItReadsAsOne() {
        #expect(cents("12,50", Self.germany) == 1_250)
        #expect(cents("1.250,50", Self.germany) == 125_050)
        #expect(cents("1.250", Self.germany) == 125_000)
        #expect(cents("1 250,50", Self.france) == 125_050, "a space typed for the narrow one")
        #expect(cents("1\u{202F}250,50", Self.france) == 125_050)
    }

    @Test func whereADotMarksDecimalsTheCommaGroupsThousands() {
        #expect(cents("12.50", Self.us) == 1_250)
        #expect(cents("1,250", Self.us) == 125_000)
        #expect(cents("1,250.5", Self.us) == 125_050)
        #expect(cents("$12.50", Self.us) == 1_250)
        #expect(cents("-12.50", Self.us) == -1_250)
        #expect(cents("(25.00)", Self.us) == -2_500, "an accountant's brackets")
        #expect(cents("12", Self.us) == 1_200)
        #expect(cents("12.", Self.us) == 1_200)
        #expect(cents(".5", Self.us) == 50)
    }

    // Scenario ENTRY-13
    @Test func anAmountThatCannotBeReadClearlyIsRefusedNotGuessed() {
        #expect(TypedAmount("12,50", locale: Self.us) == .unclear, "a thousands group has three digits")
        #expect(TypedAmount("12.50", locale: Self.germany) == .unclear)
        #expect(TypedAmount("1.250", locale: Self.us) == .unclear, "a dollar has two decimals, not three")
        #expect(TypedAmount("1,250", locale: Self.germany) == .unclear)
        #expect(TypedAmount("12.505", locale: Self.us) == .unclear)
        #expect(TypedAmount("1,2,3", locale: Self.us) == .unclear)
        #expect(TypedAmount("1,,250", locale: Self.us) == .unclear)
        #expect(TypedAmount("lots", locale: Self.us) == .unclear)
        #expect(TypedAmount(".", locale: Self.us) == .unclear)
        #expect(TypedAmount("", locale: Self.us) == .empty)
        #expect(TypedAmount("   ", locale: Self.us) == .empty)
    }

    @Test func regionsThatGroupAnotherWayReadTheirOwnWay() {
        #expect(cents("1\u{2019}250.50", Self.switzerland) == 125_050)
        #expect(cents("1'250.50", Self.switzerland) == 125_050, "either apostrophe")
        // India groups the last three, then by two, where the system's own
        // region data says so. Either way, what the system writes for India
        // reads back as the same amount.
        let written = Self.written(123_456.78, Self.india)
        #expect(cents(written, Self.india) == 12_345_678, "\(written) reads back")
        if written == "1,23,456.78" {
            #expect(TypedAmount("123,456.78", locale: Self.india) == .unclear)
        }
    }

    @Test func whatTheSystemWritesForARegionReadsBack() {
        for locale in [Self.us, Self.germany, Self.france, Self.switzerland, Self.india] {
            let written = Self.written(1_234_567.89, locale)
            #expect(cents(written, locale) == 123_456_789, "\(locale.identifier) wrote \(written)")
        }
    }

    /// An amount as the system writes it for a region, with two decimals.
    static func written(_ amount: Double, _ locale: Locale) -> String {
        let formatter = NumberFormatter()
        formatter.locale = locale
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = 2
        formatter.maximumFractionDigits = 2
        return formatter.string(from: NSNumber(value: amount)) ?? ""
    }

    @Test func aFieldStartsWithTheAmountWrittenTheRegionsWay() {
        let amount = Money(minorUnits: 125_050)
        #expect(TypedAmount.text(amount, locale: Self.us) == "1250.50")
        #expect(TypedAmount.text(amount, locale: Self.germany) == "1250,50")
        for locale in [Self.us, Self.germany, Self.france, Self.switzerland, Self.india] {
            #expect(TypedAmount(TypedAmount.text(amount, locale: locale), locale: locale).money == amount,
                    "\(locale.identifier) reads back its own text")
        }
    }

    @Test func theRefusalSaysHowToTypeItTheRegionsWay() {
        #expect(TypedAmount.Words.unclear(locale: Self.us) == "That amount can't be read clearly. Type it like 12.50.")
        #expect(TypedAmount.Words.unclear(locale: Self.germany) == "That amount can't be read clearly. Type it like 12,50.")
    }
}
