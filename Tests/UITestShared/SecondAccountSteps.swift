import Foundation
import WellSpentAppCore
import WellSpentCrypto
import WellSpentModel
import WellSpentStore
import WellSpentSync

/// What the second person does in a two-person UI test, with no window: the
/// same public steps the app's own screens take, a model and an editor over
/// their own store. Each sends what it changed to the server before it
/// returns, so the app under test can then sync it in. Groups, budgets and
/// entries are found by name, since the test named them.
@MainActor
extension SecondAccount {
    // MARK: - Finding things

    /// The second person's group with this name.
    func group(named name: String) throws -> BudgetGroup {
        guard let group = AppModel(store: sync.store).groups.first(where: { $0.name == name }) else {
            throw UITestError("the second account has no group called \(name)")
        }
        return group
    }

    /// A budget in one of the second person's groups.
    func budget(named name: String, inGroup group: String) throws -> Budget {
        let id = try self.group(named: group).id
        guard let budget = try sync.store.budgets(in: id).first(where: { $0.name == name }) else {
            throw UITestError("the second account has no budget called \(name) in \(group)")
        }
        return budget
    }

    /// An entry in any budget of the group, by its merchant.
    func entry(_ merchant: String, inGroup group: String) throws -> Transaction {
        let id = try self.group(named: group).id
        let entries = try sync.store.budgets(in: id).flatMap { try sync.store.transactions(in: $0.id) }
        guard let entry = entries.first(where: { $0.merchant == merchant }) else {
            throw UITestError("the second account has no \(merchant) in \(group)")
        }
        return entry
    }

    // MARK: - Entries

    /// Adds an entry to a budget, as Add does.
    func addEntry(_ merchant: String, amount: Money, inBudget budget: String, group: String,
                  date: Date = Date(), note: String = "") async throws {
        let model = AppModel(store: sync.store)
        model.selectedBudget = try self.budget(named: budget, inGroup: group).id
        model.addTransaction(merchant: merchant, amount: amount, date: date, note: note)
        if let problem = model.errorMessage {
            throw UITestError("the second account could not add \(merchant): \(problem)")
        }
        try await syncAll()
    }

    /// Changes an entry's note or amount, as its opened sheet's Save does.
    /// The amount is written the way a person types it, such as "60.00".
    func changeEntry(_ merchant: String, inGroup group: String, note: String? = nil, amount: String? = nil) async throws {
        let model = AppModel(store: sync.store)
        guard let editor = EntryEditor(model: model, entry: try entry(merchant, inGroup: group).id) else {
            throw UITestError("the second account could not open \(merchant)")
        }
        if let note { editor.note = note }
        if let amount { editor.amountText = amount }
        guard editor.save() else {
            throw UITestError("the second account could not change \(merchant): \(model.errorMessage ?? "refused")")
        }
        try await syncAll()
    }

    /// Deletes an entry, as Delete in its sheet does.
    func deleteEntry(_ merchant: String, inGroup group: String) async throws {
        let model = AppModel(store: sync.store)
        let result = model.deleteEntry(try entry(merchant, inGroup: group).id)
        guard result == .saved else {
            throw UITestError("the second account could not delete \(merchant): \(result)")
        }
        try await syncAll()
    }

    // MARK: - Importing

    /// Imports a statement into a budget, as Import statement and the review
    /// do, with that budget chosen for every line that needs one.
    func importStatement(_ file: URL, into budget: String, group: String) async throws {
        let model = AppModel(store: sync.store)
        let budgetID = try self.budget(named: budget, inGroup: group).id
        model.selectedBudget = budgetID
        model.prepareImport(from: file)
        if let problem = model.errorMessage {
            throw UITestError("the second account could not read \(file.lastPathComponent): \(problem)")
        }
        let review = ImportReviewScreen(model: model)
        for row in review.rows where row.needsBudget { review.choose(budgetID, for: row.id) }
        review.commit()
        if let problem = model.errorMessage {
            throw UITestError("the second account could not import \(file.lastPathComponent): \(problem)")
        }
        try await syncAll()
    }

    // MARK: - People

    /// Who is in the group, as the server says now.
    func members(of group: String) async throws -> [UserID: AccessLevel] {
        let id = try self.group(named: group).id
        await sync.refresh(id)
        return sync.members(of: id)
    }

    /// Moves the one other person in the group to `level`. The second person
    /// must be allowed to, as the owner is.
    func setLevelOfTheOther(_ level: AccessLevel, in group: String) async throws {
        let id = try self.group(named: group).id
        let others = try await members(of: group).keys.filter { $0 != sync.userID }
        guard others.count == 1, let other = others.first else {
            throw UITestError("the second account expected one other person in \(group), and found \(others.count)")
        }
        try await sync.setLevel(level, of: other, in: id)
    }

    /// Waits until the server lists this many people in the group, such as
    /// after the other person leaves. True when it does in time.
    func waitForMembers(_ count: Int, in group: String, timeout: TimeInterval = 30) async throws -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if try await members(of: group).count == count { return true }
            try await Task.sleep(for: .seconds(1))
        } while Date() < deadline
        return false
    }
}
