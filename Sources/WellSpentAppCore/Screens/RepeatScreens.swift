import Foundation
import Observation
import WellSpentCrypto
import WellSpentModel

/// A budget's repeats, for the short list its count line opens (REPEAT-12).
public struct RepeatsList: Equatable, Sendable {
    public struct Row: Equatable, Sendable, Identifiable {
        public let id: RecordID
        public let name: String
        /// "The 14th of each month".
        public let line: String
        public let amount: String
    }

    public let title: String
    public let rows: [Row]

    @MainActor public init(budget: Budget, model: AppModel) {
        title = Words.title(budget.name)
        let month = RepeatRule.month(of: model.today(), calendar: AppLocale.calendar)
        rows = model.repeats(in: budget.id, group: budget.groupID).map { rule in
            let terms = rule.terms(in: month)
            return Row(id: rule.id, name: rule.name, line: Words.line(day: terms.day), amount: terms.amount.magnitude.display)
        }
    }

    /// "2 repeats", or nil for a budget with none.
    public var countWords: String? { Words.count(rows.count) }

    public enum Words {
        public static func title(_ budget: String) -> String { "Repeats in \(budget)" }
        public static func line(day: Int) -> String { "The \(ordinal(day)) of each month" }
        public static func count(_ count: Int) -> String? {
            count == 0 ? nil : "\(count) repeat\(count == 1 ? "" : "s")"
        }
        public static let done = "Done"

        /// "14th", "1st", "22nd", "3rd".
        public static func ordinal(_ day: Int) -> String {
            let tens = day % 100
            if (11...13).contains(tens) { return "\(day)th" }
            switch day % 10 {
            case 1: return "\(day)st"
            case 2: return "\(day)nd"
            case 3: return "\(day)rd"
            default: return "\(day)th"
            }
        }
    }
}

/// A repeat's own sheet: what changes from this month on, or how to stop it. Read
/// only below its owner or a manager (REPEAT-11, 12). Each app draws it.
@MainActor
@Observable
public final class RepeatEditor {
    public let ruleID: RecordID
    public let mayChange: Bool
    public var name: String
    public var amountText: String
    public var dayText: String
    public var linkID: RecordID?
    public let linkChoices: EntryLinkChoices?
    /// "Only Robin or a manager can change this repeat."
    public let readOnlyLine: String?
    public let locale: Locale
    private let original: (name: String, amount: Money, day: Int, link: RecordID?)
    private let model: AppModel

    public init?(model: AppModel, rule id: RecordID, locale: Locale = AppLocale.current) {
        guard let rule = try? model.store.repeatRule(id) else { return nil }
        self.model = model
        self.locale = locale
        ruleID = id
        let terms = rule.terms(in: RepeatRule.month(of: model.today(), calendar: AppLocale.calendar))
        original = (rule.name, terms.amount, terms.day, rule.extensionLink)
        name = rule.name
        amountText = TypedAmount.text(terms.amount.magnitude, locale: locale)
        dayText = String(terms.day)
        linkID = rule.extensionLink
        linkChoices = model.linkChoices(rule.groupID).flatMap { $0.choices.isEmpty ? nil : $0 }
        mayChange = model.mayChangeRule(rule)
        readOnlyLine = mayChange ? nil : Words.onlyOwner(rule.createdBy.flatMap { model.memberName($0, in: rule.groupID) })
    }

    private var amount: Money? { TypedAmount(amountText, currency: original.amount.currency, locale: locale).money }
    private var day: Int? { Int(dayText.trimmingCharacters(in: .whitespaces)).flatMap { (1...31).contains($0) ? $0 : nil } }

    public var canSave: Bool {
        guard mayChange, !name.trimmingCharacters(in: .whitespaces).isEmpty, let amount, let day else { return false }
        return name != original.name || amount.magnitude != original.amount.magnitude || day != original.day
            || linkID != original.link
    }

    /// True when the sheet may close.
    @discardableResult
    public func save() -> Bool {
        guard canSave else { return false }
        model.changeRule(ruleID, name: name, amount: amount, day: day, budget: nil,
                         link: linkID == original.link ? nil : (linkID.map(LinkChange.to) ?? .cleared))
        return model.errorMessage == nil
    }

    public func stop() { model.stopRepeating(ruleID) }

    public enum Words {
        public static let subtitle = "Repeats every month"
        public static let merchant = EntryEditor.Words.merchant
        public static let amount = EntryEditor.Words.amount
        public static let day = "Day of the month"
        public static let note = "Changes this month and every month after. Earlier months stay as they are. "
            + "To change one month, open that month's bill."
        public static let stop = "Stop repeating\u{2026}"
        public static let stopTitle = "Stop repeating?"
        public static let stopMessage = "No more bills come. Earlier bills stay."
        public static let stopConfirm = "Stop Repeating"
        public static let cancel = "Cancel"
        public static let save = "Save"
        public static let close = "Close"
        public static func onlyOwner(_ owner: String?) -> String {
            "Only \(owner ?? "its owner") or a manager can change this repeat."
        }
    }
}
