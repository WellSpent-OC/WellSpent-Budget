import Foundation
import Crypto
import WellSpentCrypto
import WellSpentModel

/// One line as it appeared on a bank or card statement, before anything is
/// decided about it.
public struct StatementLine: Equatable, Sendable {
    public let date: Date
    /// What the bank actually printed, warts and all: `HILLTOP #17 SPRING HILL OH`.
    public let rawDescription: String
    public let amount: Money
    /// The bank's own id for the row, when the format carries one. OFX and QFX do.
    public let bankReference: String?

    public init(date: Date, rawDescription: String, amount: Money, bankReference: String? = nil) {
        self.date = date
        self.rawDescription = rawDescription
        self.amount = amount
        self.bankReference = bankReference
    }

    /// A merchant name a person would recognise.
    ///
    /// Banks pad descriptions with store numbers, cities, state codes and payment
    /// processor prefixes. This strips the obvious noise. It is deliberately
    /// conservative: a wrong guess that hides information is worse than leaving
    /// something slightly ugly on screen, and the raw text is always kept.
    public var cleanedDescription: String {
        var text = rawDescription.uppercased()

        // Payment processor prefixes, which say nothing about who was paid.
        for prefix in ["SQ *", "TST* ", "SP ", "PAYPAL *", "PP*", "AMZN MKTP "] {
            if text.hasPrefix(prefix) { text = String(text.dropFirst(prefix.count)) }
        }

        // Store numbers, card tails and long digit runs. A `#` marks a store
        // number whatever its length; a bare number needs three digits before it
        // is safe to drop, or "7 ELEVEN" loses its name.
        text = text.replacingOccurrences(of: #"\s+#\d+\b"#, with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: #"\s+\d{3,}\b"#, with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: #"\s+X{2,}\d+\b"#, with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: #"\s+\d{2}/\d{2}\b"#, with: "", options: .regularExpression)

        // A trailing two-letter state code, usually after a city.
        text = text.replacingOccurrences(of: #"\s+[A-Z]{2}$"#, with: "", options: .regularExpression)

        text = text.replacingOccurrences(of: #"\s{2,}"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        return text.isEmpty ? rawDescription : text.capitalizedWords
    }

    /// Recognises the same row on a later import of an overlapping file.
    ///
    /// Two properties matter. It has to be stable, because banks re-issue the same
    /// rows in the next statement. And it has to stay inside the encrypted record:
    /// a fingerprint column the server could see would let whoever steals the
    /// database correlate customers who shopped at the same place. Keyed with the
    /// budget key, so it is meaningless outside this group.
    public func fingerprint(budgetKey: SymmetricKey) -> String {
        var authenticator = HMAC<SHA256>(key: budgetKey)
        authenticator.update(data: Data("wellspent/v1/import-row".utf8))
        if let bankReference {
            // The bank's own id is the strongest signal when it exists.
            authenticator.update(data: Data(bankReference.utf8))
        } else {
            var day = CanonicalTime.seconds(date)
            day -= day % 86_400
            withUnsafeBytes(of: day.bigEndian) { authenticator.update(data: Data($0)) }
            authenticator.update(data: Data(rawDescription.uppercased().utf8))
            withUnsafeBytes(of: Int64(amount.minorUnits).bigEndian) { authenticator.update(data: Data($0)) }
        }
        return Data(authenticator.finalize()).base64EncodedString()
    }
}

extension String {
    /// `HILLTOP GROCERY` reads better as `Hilltop Grocery`.
    ///
    /// Every word is title-cased, with no exception for short all-caps tokens.
    /// There was one, to keep `USPS` intact, and it also kept `THE`. Telling an
    /// acronym from an ordinary word needs a dictionary, and getting `Usps` is a
    /// far smaller problem than getting `THE Home Depot`. The raw description is
    /// always kept alongside, so nothing is actually lost.
    var capitalizedWords: String {
        split(separator: " ")
            .map { $0.prefix(1).uppercased() + $0.dropFirst().lowercased() }
            .joined(separator: " ")
    }
}

public enum ImportError: Error, Equatable, Sendable {
    case unrecognisedFormat
    case noRowsFound
    case malformedRow(line: Int, reason: String)
}

public enum StatementFormat: String, Sendable, CaseIterable {
    case csv
    case ofx      // covers .qfx, which is the same grammar
}
