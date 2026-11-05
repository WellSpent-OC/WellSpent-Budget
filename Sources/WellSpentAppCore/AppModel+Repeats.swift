import Foundation
import WellSpentCrypto
import WellSpentModel
import WellSpentStore

/// Repeat expenses: a rule that makes a normal transaction each month. Only the
/// rule's owner's devices make them, because the server gives a transaction to
/// whoever stores it first. Everyone else sees the bill when it syncs.
public extension AppModel {
    /// Which months a change to a made bill reaches.
    enum RepeatReach: Equatable, Sendable {
        case thisMonthOnly
        case thisMonthAndLater
    }

    /// Makes every month that has come and isn't made yet, one each. A month
    /// someone deleted counts as made, so it doesn't come back. True when
    /// something new was made.
    @discardableResult
    func makeDueRepeats() -> Bool {
        var madeAny = false
        do {
            let me = me()
            for group in try store.groups() where mayAddEntries(group.id) {
                for rule in try store.repeatRules(in: group.id) where rule.createdBy == nil || rule.createdBy == me {
                    for month in rule.monthsDue(today: today(), calendar: AppLocale.calendar) {
                        guard let made = rule.made(in: month),
                              let budget = try store.budget(made.budgetID), !budget.isDeleted else { continue }
                        if try store.saveMade(made) { madeAny = true }
                    }
                }
            }
        } catch {
            errorMessage = String(describing: error)
        }
        return madeAny
    }

    /// The live repeats in a budget, by name, as they stand this month.
    func repeats(in budget: BudgetID, group: GroupID) -> [RepeatRule] {
        let month = RepeatRule.month(of: today(), calendar: AppLocale.calendar)
        let rules = (try? store.repeatRules(in: group)) ?? []
        return rules.filter { $0.terms(in: month).budgetID == budget && $0.runs(in: month) && $0.stopMonth == nil }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// The rule that made an entry.
    func rule(of entry: Transaction) -> RepeatRule? {
        entry.repeatRuleID.flatMap { try? store.repeatRule($0) }
    }

    /// Only the rule's owner or a manager changes the rule (REPEAT-11).
    func mayChangeRule(_ rule: RepeatRule) -> Bool {
        rule.createdBy == nil || rule.createdBy == me() || mayManageEntries(rule.groupID)
    }

    /// Adds a bill that repeats on its date's day from its own month on. The
    /// entry takes the ID the rule would give that month, so the rule sees it
    /// as made and there's no duplicate in the first month.
    func addRepeatingTransaction(merchant: String, amount: Money, date: Date, note: String, budget chosen: BudgetID,
                                 link: RecordID? = nil) {
        guard let budget = budget(for: chosen) else { return }
        guard mayAddEntries(budget.groupID) else {
            errorMessage = SyncWording.viewOnly
            return
        }
        do {
            let calendar = AppLocale.calendar
            let month = RepeatRule.month(of: date, calendar: calendar)
            let signed = Money(minorUnits: -abs(amount.minorUnits), currency: amount.currency)
            let rule = RepeatRule(groupID: budget.groupID, budgetID: budget.id, name: merchant, amount: signed,
                                  day: calendar.component(.day, from: date), extensionLink: link, firstMonth: month,
                                  createdBy: me())
            try store.save(rule)
            try store.save(Transaction(id: .repeatMade(group: budget.groupID, rule: rule.id, month: month),
                                       budgetID: budget.id, groupID: budget.groupID, date: date, merchant: merchant,
                                       note: note, amount: signed, kind: .spending, createdBy: me(), extensionLink: link,
                                       repeatRuleID: rule.id, repeatMonth: month))
            changed()
        } catch {
            errorMessage = String(describing: error)
        }
    }

    /// Turns the row on for an entry already there: it stays as it is, and the
    /// rule starts next month.
    func startRepeating(from id: RecordID) {
        do {
            guard let entry = try store.transaction(id), !entry.isDeleted, entry.repeatRuleID == nil,
                  mayAddEntries(entry.groupID) else { return }
            let calendar = AppLocale.calendar
            let month = RepeatRule.month(after: RepeatRule.month(of: entry.date, calendar: calendar))
            try store.save(RepeatRule(groupID: entry.groupID, budgetID: entry.budgetID, name: entry.merchant,
                                      amount: Money(minorUnits: -abs(entry.amount.minorUnits), currency: entry.amount.currency),
                                      day: calendar.component(.day, from: entry.date), extensionLink: entry.extensionLink,
                                      firstMonth: month, createdBy: me()))
            changed()
        } catch {
            errorMessage = String(describing: error)
        }
    }

    /// Saves a change to a made bill, and with "this month and later" adds it to
    /// the rule from that month on. Months already made stay as they are, other
    /// than this one.
    @discardableResult
    func updateMadeEntry(_ id: RecordID, _ change: EntryChange, reach: RepeatReach) -> EntrySaveResult {
        let result = updateEntry(id, change)
        guard result == .saved, reach == .thisMonthAndLater, let entry = try? store.transaction(id),
              let month = entry.repeatMonth, let rule = rule(of: entry), mayChangeRule(rule) else { return result }
        addChange(to: rule, fromMonth: month, entry: entry)
        return result
    }

    /// Changes the rule itself, from this month on, from its own sheet.
    func changeRule(_ id: RecordID, name: String?, amount: Money?, day: Int?, budget: BudgetID?, link: LinkChange? = nil) {
        do {
            guard var rule = try store.repeatRule(id), mayChangeRule(rule) else { return }
            let month = RepeatRule.month(of: today(), calendar: AppLocale.calendar)
            let terms = rule.terms(in: month)
            if let name { rule.name = name }
            switch link {
            case .to(let house): rule.extensionLink = house
            case .cleared: rule.extensionLink = nil
            case nil: break
            }
            rule.changes.removeAll { $0.fromMonth == month }
            rule.changes.append(.init(fromMonth: month, budgetID: budget ?? terms.budgetID,
                                      amount: amount.map { Money(minorUnits: -abs($0.minorUnits), currency: $0.currency) } ?? terms.amount,
                                      day: day ?? terms.day))
            rule.updatedAt = Date()
            try store.save(rule)
            changed()
        } catch {
            errorMessage = String(describing: error)
        }
    }

    /// No later month is made, and months already made stay. Undo clears it.
    func stopRepeating(_ id: RecordID) {
        do {
            guard var rule = try store.repeatRule(id), mayChangeRule(rule) else { return }
            let previous = rule.stopMonth
            rule.stopMonth = RepeatRule.month(after: RepeatRule.month(of: today(), calendar: AppLocale.calendar))
            rule.updatedAt = Date()
            try store.save(rule)
            changed()
            offerUndo(UndoOffer(stopping: rule, previousStop: previous))
        } catch {
            errorMessage = String(describing: error)
        }
    }

    /// Deletes this month's bill and makes no later month. Undo brings both back.
    @discardableResult
    func deleteAndStopRepeating(_ id: RecordID) -> EntrySaveResult {
        guard let entry = try? store.transaction(id), let month = entry.repeatMonth, var rule = rule(of: entry),
              mayChangeRule(rule) else { return deleteEntry(id) }
        let previous = rule.stopMonth
        let result = deleteEntry(id)
        guard result == .saved else { return result }
        do {
            rule.stopMonth = RepeatRule.month(after: month)
            rule.updatedAt = Date()
            try store.save(rule)
            changed()
            offerUndo(UndoOffer(deleting: entry, stopping: rule, previousStop: previous))
        } catch {
            errorMessage = String(describing: error)
        }
        return result
    }

    private func addChange(to rule: RepeatRule, fromMonth month: String, entry: Transaction) {
        do {
            var rule = rule
            rule.changes.removeAll { $0.fromMonth == month }
            rule.changes.append(.init(fromMonth: month, budgetID: entry.budgetID, amount: entry.amount,
                                      day: AppLocale.calendar.component(.day, from: entry.date)))
            rule.updatedAt = Date()
            try store.save(rule)
            changed()
        } catch {
            errorMessage = String(describing: error)
        }
    }
}
