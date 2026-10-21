import Foundation
import Testing
@testable import WellSpentAppCore
import WellSpentModel

/// The app's locale: the system's on the Mac and the iPhone, the region its
/// environment names on Linux, and the one shared code reads amounts and
/// dates with.
@Suite("The app's locale")
struct AppLocaleTests {
    static let germany = Locale(identifier: "de_DE")
    static let october16 = Date(timeIntervalSince1970: 1_792_150_000)

    // MARK: - Which region a Linux environment names

    @Test func lcAllComesFirstThenLcNumericThenLang() {
        #expect(AppLocale.posix(["LC_ALL": "de_DE.UTF-8", "LC_NUMERIC": "fr_FR.UTF-8", "LANG": "en_US.UTF-8"])?
            .identifier == "de_DE")
        #expect(AppLocale.posix(["LC_NUMERIC": "fr_FR.UTF-8", "LANG": "en_US.UTF-8"])?.identifier == "fr_FR")
        #expect(AppLocale.posix(["LANG": "en_US.UTF-8"])?.identifier == "en_US")
    }

    @Test func anEmptyValueIsPassedOver() {
        #expect(AppLocale.posix(["LC_ALL": "", "LANG": "de_DE.UTF-8"])?.identifier == "de_DE")
    }

    @Test func lcTimeIsNotRead() {
        // So numbers and dates never split two ways.
        #expect(AppLocale.posix(["LC_TIME": "de_DE.UTF-8", "LANG": "en_US.UTF-8"])?.identifier == "en_US")
        #expect(AppLocale.posix(["LC_TIME": "de_DE.UTF-8"]) == nil)
    }

    @Test func cAndPosixNameNoRegion() {
        #expect(AppLocale.posix(["LANG": "C.UTF-8"]) == nil)
        #expect(AppLocale.posix(["LANG": "C"]) == nil)
        #expect(AppLocale.posix(["LANG": "POSIX"]) == nil)
        // LC_ALL set to C wins over a region in LANG, as in the C library.
        #expect(AppLocale.posix(["LC_ALL": "C", "LANG": "de_DE.UTF-8"]) == nil)
        #expect(AppLocale.posix([:]) == nil)
    }

    @Test func theCodesetAndModifierAreDropped() {
        #expect(AppLocale.posix(["LANG": "de_DE@euro"])?.identifier == "de_DE")
        #expect(AppLocale.posix(["LANG": "de_DE.ISO-8859-15@euro"])?.identifier == "de_DE")
        #expect(AppLocale.posix(["LANG": "fr_CA.utf8"])?.identifier == "fr_CA")
    }

    @Test func aNameFoundationDoesNotKnowNamesNoRegion() {
        #expect(AppLocale.posix(["LANG": "xx_YY.UTF-8"]) == nil)
    }

    // MARK: - Shared code reads it

    @Test func inAGermanRegionAmountsReadTheGermanWay() {
        AppLocale.$override.withValue(Self.germany) {
            #expect(TypedAmount("12,50").money?.minorUnits == 1_250)
            #expect(TypedAmount("1.250,50").money?.minorUnits == 125_050)
            // A German "1,250" is one and a quarter: refused, since a dollar
            // has two places after the mark. Never twelve hundred and fifty.
            #expect(TypedAmount("1,250") == .unclear)
            #expect(TypedAmount.Words.unclear() == "That amount can't be read clearly. Type it like 12,50.")
        }
    }

    @Test func inAGermanRegionDatesReadTheGermanWay() {
        AppLocale.$override.withValue(Self.germany) {
            let short = BudgetScreen.shortDate(Self.october16)
            #expect(short.contains("Okt"), "\(short)")
            #expect(AppLocale.calendar.locale?.identifier == "de_DE")
        }
    }

    @Test func withNothingSetItIsTheSystems() {
        #expect(AppLocale.current.identifier == Locale.autoupdatingCurrent.identifier)
        #expect(AppLocale.calendar.identifier == Calendar.autoupdatingCurrent.identifier)
        #expect(BudgetScreen.shortDate(Self.october16)
            == Self.october16.formatted(.dateTime.day().month(.abbreviated)))
    }

    // MARK: - Nothing reads the system's locale around it

    /// Shared code formats and reads with `AppLocale`, never with the system's
    /// locale or calendar, or a formatter made without a locale: on Linux
    /// those are en_001 whatever the computer's region, which reads a German
    /// "1,250" as twelve hundred and fifty.
    @Test func sharedCodeReadsTheLocaleOnlyFromAppLocale() throws {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/WellSpentAppCore")
        let forbidden: [(pattern: String, why: String)] = [
            (#"\bLocale\.(current|autoupdatingCurrent)"#, "the system's locale"),
            (#"Locale\s*=\s*\.(current|autoupdatingCurrent)"#, "the system's locale as a default"),
            (#"locale\s*\?\?\s*\.(current|autoupdatingCurrent)"#, "the system's locale as a fallback"),
            (#"\bCalendar\.(current|autoupdatingCurrent)"#, "the system's calendar, with its locale"),
            (#"Calendar\s*=\s*\.(current|autoupdatingCurrent)"#, "the system's calendar as a default"),
            (#"\.formatted\(date:"#, "a date written in the system's locale"),
            (#"\.formatted\(\.dateTime(?!.*\.locale\()"#, "a date written in the system's locale"),
        ]
        var found: [String] = []
        let files = try #require(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))
        for case let file as URL in files where file.pathExtension == "swift" && file.lastPathComponent != "AppLocale.swift" {
            let lines = try String(contentsOf: file, encoding: .utf8).components(separatedBy: "\n")
            for (index, line) in lines.enumerated() {
                let code = line.components(separatedBy: "//").first ?? ""
                for rule in forbidden where code.range(of: rule.pattern, options: .regularExpression) != nil {
                    found.append("\(file.lastPathComponent):\(index + 1): \(rule.why)")
                }
                // A formatter takes its locale on the line after it's made.
                if code.range(of: #"\b(NumberFormatter|DateFormatter)\(\)"#, options: .regularExpression) != nil {
                    let next = lines.dropFirst(index + 1).prefix(3).joined()
                    if !next.contains(".locale =") {
                        found.append("\(file.lastPathComponent):\(index + 1): a formatter made without a locale")
                    }
                }
            }
        }
        #expect(found.isEmpty, "Read AppLocale.current or AppLocale.calendar instead:\n\(found.joined(separator: "\n"))")
    }
}
