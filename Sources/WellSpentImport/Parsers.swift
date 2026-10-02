import Foundation
import WellSpentModel

/// Reads the files banks actually hand out.
///
/// Every bank's CSV is different, so the columns are detected from the header
/// rather than assumed. OFX and QFX share one grammar and are far more reliable,
/// which is why the app should ask for those first.
public enum StatementParser {

    public static func detectFormat(filename: String, contents: String) -> StatementFormat? {
        let lowered = filename.lowercased()
        if lowered.hasSuffix(".ofx") || lowered.hasSuffix(".qfx") { return .ofx }
        if lowered.hasSuffix(".csv") || lowered.hasSuffix(".tsv") { return .csv }
        // Some banks serve an OFX body with no useful filename.
        if contents.contains("<STMTTRN>") || contents.contains("OFXHEADER") { return .ofx }
        if contents.contains(",") { return .csv }
        return nil
    }

    public static func parse(contents: String, filename: String,
                             currency: Currency = .usd) throws -> [StatementLine] {
        guard let format = detectFormat(filename: filename, contents: contents) else {
            throw ImportError.unrecognisedFormat
        }
        let lines: [StatementLine]
        switch format {
        case .csv: lines = try parseCSV(contents, currency: currency)
        case .ofx: lines = try parseOFX(contents, currency: currency)
        }
        guard !lines.isEmpty else { throw ImportError.noRowsFound }
        return lines
    }

    // MARK: - OFX and QFX

    /// OFX is SGML, not XML, and banks close tags inconsistently, so a real XML
    /// parser rejects perfectly ordinary files. Scanning for the fields directly is
    /// both simpler and more tolerant.
    public static func parseOFX(_ contents: String, currency: Currency = .usd) throws -> [StatementLine] {
        var results: [StatementLine] = []

        for block in contents.components(separatedBy: "<STMTTRN>").dropFirst() {
            let body = block.components(separatedBy: "</STMTTRN>").first ?? block

            guard let rawDate = value(of: "DTPOSTED", in: body),
                  let date = parseOFXDate(rawDate),
                  let rawAmount = value(of: "TRNAMT", in: body),
                  let amount = parseAmount(rawAmount, currency: currency) else { continue }

            // NAME is the merchant; MEMO carries more detail when NAME is generic.
            let name = value(of: "NAME", in: body) ?? ""
            let memo = value(of: "MEMO", in: body) ?? ""
            let description = name.isEmpty ? memo : (memo.isEmpty || memo == name ? name : "\(name) \(memo)")

            results.append(StatementLine(
                date: date,
                rawDescription: description.trimmingCharacters(in: .whitespaces),
                amount: amount,
                bankReference: value(of: "FITID", in: body)
            ))
        }
        return results
    }

    private static func value(of tag: String, in body: String) -> String? {
        guard let start = body.range(of: "<\(tag)>") else { return nil }
        let rest = body[start.upperBound...]
        // A value ends at the next tag or the end of the line, whichever comes
        // first, because the closing tag is optional in practice.
        let end = rest.firstIndex { $0 == "<" || $0 == "\n" || $0 == "\r" } ?? rest.endIndex
        let text = rest[..<end].trimmingCharacters(in: .whitespaces)
        return text.isEmpty ? nil : text
    }

    /// `20260922120000.000[-7:MST]` and `20260922` are both real.
    static func parseOFXDate(_ raw: String) -> Date? {
        let digits = raw.prefix { $0.isNumber }
        guard digits.count >= 8 else { return nil }

        var components = DateComponents()
        components.year = Int(digits.prefix(4))
        components.month = Int(digits.dropFirst(4).prefix(2))
        components.day = Int(digits.dropFirst(6).prefix(2))
        if digits.count >= 14 {
            components.hour = Int(digits.dropFirst(8).prefix(2))
            components.minute = Int(digits.dropFirst(10).prefix(2))
        } else {
            components.hour = 12       // midday, so a timezone shift cannot move the day
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
        return calendar.date(from: components)
    }

    // MARK: - CSV

    public static func parseCSV(_ contents: String, currency: Currency = .usd) throws -> [StatementLine] {
        let rows = splitCSV(contents)
        guard let header = rows.first else { throw ImportError.noRowsFound }

        let columns = header.map { $0.lowercased().trimmingCharacters(in: .whitespaces) }
        func find(_ candidates: [String]) -> Int? {
            for candidate in candidates {
                if let index = columns.firstIndex(where: { $0 == candidate }) { return index }
            }
            for candidate in candidates {
                if let index = columns.firstIndex(where: { $0.contains(candidate) }) { return index }
            }
            return nil
        }

        guard let dateIndex = find(["date", "transaction date", "posted date", "posting date"]) else {
            throw ImportError.malformedRow(line: 1, reason: "no date column")
        }
        guard let descriptionIndex = find(["description", "payee", "name", "merchant", "memo"]) else {
            throw ImportError.malformedRow(line: 1, reason: "no description column")
        }

        // Some banks give one signed Amount. Others give Debit and Credit columns.
        let amountIndex = find(["amount"])
        let debitIndex = find(["debit", "withdrawal"])
        let creditIndex = find(["credit", "deposit"])
        guard amountIndex != nil || debitIndex != nil || creditIndex != nil else {
            throw ImportError.malformedRow(line: 1, reason: "no amount column")
        }

        var results: [StatementLine] = []
        for (offset, row) in rows.dropFirst().enumerated() {
            guard row.count > max(dateIndex, descriptionIndex) else { continue }
            guard let date = parseCSVDate(row[dateIndex]) else { continue }

            var amount: Money?
            if let amountIndex, row.count > amountIndex {
                amount = parseAmount(row[amountIndex], currency: currency)
            }
            if amount == nil, let debitIndex, row.count > debitIndex,
               let debit = parseAmount(row[debitIndex], currency: currency), debit.minorUnits != 0 {
                // A debit column holds a positive number for money going out.
                amount = Money(minorUnits: -abs(debit.minorUnits), currency: currency)
            }
            if amount == nil, let creditIndex, row.count > creditIndex,
               let credit = parseAmount(row[creditIndex], currency: currency), credit.minorUnits != 0 {
                amount = Money(minorUnits: abs(credit.minorUnits), currency: currency)
            }
            guard let amount, amount.minorUnits != 0 else { continue }

            let reference = find(["reference", "transaction id", "id"]).flatMap { index -> String? in
                row.count > index && !row[index].isEmpty ? row[index] : nil
            }

            results.append(StatementLine(
                date: date,
                rawDescription: row[descriptionIndex].trimmingCharacters(in: .whitespaces),
                amount: amount,
                bankReference: reference
            ))
            _ = offset
        }
        return results
    }

    /// Handles quoted fields containing commas, which is most descriptions.
    static func splitCSV(_ contents: String) -> [[String]] {
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var inQuotes = false
        var iterator = contents.makeIterator()
        var pending: Character?

        func endField() { row.append(field); field = "" }
        func endRow() {
            endField()
            if row.contains(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) { rows.append(row) }
            row = []
        }

        while let character = pending ?? iterator.next() {
            pending = nil
            if inQuotes {
                if character == "\"" {
                    if let next = iterator.next() {
                        if next == "\"" { field.append("\"") } else { inQuotes = false; pending = next }
                    } else {
                        inQuotes = false
                    }
                } else {
                    field.append(character)
                }
            } else {
                switch character {
                case "\"": inQuotes = true
                case ",", "\t": endField()
                case "\n": endRow()
                case "\r": break
                default: field.append(character)
                }
            }
        }
        if !field.isEmpty || !row.isEmpty { endRow() }
        return rows
    }

    static func parseCSVDate(_ raw: String) -> Date? {
        let text = raw.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return nil }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt

        // ISO first, because it is unambiguous.
        let parts = text.split(whereSeparator: { $0 == "/" || $0 == "-" || $0 == "." })
        guard parts.count == 3, let a = Int(parts[0]), let b = Int(parts[1]), let c = Int(parts[2]) else {
            return nil
        }

        var components = DateComponents()
        components.hour = 12
        if String(parts[0]).count == 4 {
            components.year = a; components.month = b; components.day = c
        } else {
            // US order. A day above 12 proves which field is which; otherwise
            // month-first is the safe assumption for a US bank export.
            let year = c < 100 ? 2000 + c : c
            if a > 12 {
                components.day = a; components.month = b
            } else {
                components.month = a; components.day = b
            }
            components.year = year
        }
        return calendar.date(from: components)
    }

    /// Public because the app's own amount field should accept exactly the
    /// shapes a statement does: `$1,234.56`, `(25.00)`, `-12.34`.
    public static func parseAmount(_ raw: String, currency: Currency) -> Money? {
        var text = raw.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return nil }

        // Accounting style: (12.34) means negative.
        var negative = false
        if text.hasPrefix("(") && text.hasSuffix(")") {
            negative = true
            text = String(text.dropFirst().dropLast())
        }
        if text.hasPrefix("-") { negative = true; text = String(text.dropFirst()) }
        if text.hasPrefix("+") { text = String(text.dropFirst()) }

        text = text.replacingOccurrences(of: currency.symbol, with: "")
            .replacingOccurrences(of: ",", with: "")
            .replacingOccurrences(of: " ", with: "")
        guard let value = Double(text) else { return nil }

        // Rounded through cents rather than kept as a Double, so nothing drifts.
        let minorUnits = Int((value * 100).rounded())
        return Money(minorUnits: negative ? -minorUnits : minorUnits, currency: currency)
    }
}
