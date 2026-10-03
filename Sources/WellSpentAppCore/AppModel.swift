import Foundation
import Observation
import Crypto
import WellSpentCrypto
import WellSpentImport
import WellSpentModel
import WellSpentStore

/// The app's state, over the local database.
///
/// Everything here reads and writes the plaintext database on this machine. No
/// screen waits on a network call, because none of them needs one. Syncing is a
/// background errand, not something the interface is built around.
@MainActor
@Observable
public final class AppModel {
    public private(set) var groups: [BudgetGroup] = []
    public private(set) var summaries: [GroupID: [BudgetSummary]] = [:]
    public private(set) var transactions: [Transaction] = []
    public var errorMessage: String?

    public var selectedBudget: BudgetID? {
        didSet { reloadTransactions() }
    }

    /// Set while a statement is being reviewed, before anything is written.
    public var pendingImport: PendingImport?

    public let store: Store

    /// Called after anything here writes a change that will sync. Not called by
    /// `reload()`, which also runs after a sync brings changes in, so a sync never
    /// sets off another one.
    public var didChange: (@MainActor () -> Void)?

    public struct PendingImport: Identifiable {
        public let id = UUID()
        public let filename: String
        public var proposals: [ImportProposal]
        public var summary: ImportSummary
        public var chosenBudgets: [Int: BudgetID] = [:]
    }

    public init(store: Store) {
        self.store = store
        reload()
    }

    /// Opens the database where a Mac app is supposed to put it.
    public static func makeDefault() throws -> AppModel {
        let base = try FileManager.default.url(for: .applicationSupportDirectory,
                                               in: .userDomainMask,
                                               appropriateFor: nil, create: true)
        let url = base.appendingPathComponent("WellSpent/budget.sqlite")
        let database = try WellSpentDatabase.open(at: url)
        let model = AppModel(store: Store(database: database))
        if model.groups.isEmpty { try model.seedFirstRun() }
        return model
    }

    // MARK: - Loading

    public func reload() {
        do {
            groups = try store.groups()
            var loaded: [GroupID: [BudgetSummary]] = [:]
            for group in groups {
                loaded[group.id] = try store.summaries(in: group.id)
            }
            summaries = loaded
            if selectedBudget == nil {
                selectedBudget = loaded.values.flatMap(\.self).first?.budget.id
            }
            reloadTransactions()
        } catch {
            errorMessage = String(describing: error)
        }
    }

    func reloadTransactions() {
        guard let selectedBudget else {
            transactions = []
            return
        }
        do {
            let budget = try store.budget(selectedBudget)
            let period = budget?.reset.period(containing: Date())
            transactions = try store.transactions(in: selectedBudget, period: period)
        } catch {
            errorMessage = String(describing: error)
        }
    }

    public func summary(for id: BudgetID) -> BudgetSummary? {
        summaries.values.flatMap(\.self).first { $0.budget.id == id }
    }

    public func budget(for id: BudgetID) -> Budget? { summary(for: id)?.budget }

    public func group(named id: GroupID) -> BudgetGroup? { groups.first { $0.id == id } }

    // MARK: - Editing

    public func addTransaction(merchant: String, amount: Money, date: Date, note: String) {
        guard let selectedBudget, let budget = budget(for: selectedBudget) else { return }
        do {
            // Stored negative: a budget counts money going out.
            let signed = Money(minorUnits: -abs(amount.minorUnits), currency: amount.currency)
            try store.save(Transaction(budgetID: budget.id, groupID: budget.groupID, date: date,
                                       merchant: merchant, note: note, amount: signed))
            changed()
        } catch {
            errorMessage = String(describing: error)
        }
    }

    public func trash(_ transaction: Transaction) {
        do {
            try store.trash(transaction)
            changed()
        } catch {
            errorMessage = String(describing: error)
        }
    }

    /// Adds a budget at the end of its group, in the next color, and selects it.
    @discardableResult
    public func addBudget(named name: String, limit: Money, in group: GroupID) -> BudgetID? {
        do {
            let siblings = try store.budgets(in: group)
            let budget = Budget(groupID: group, name: Self.clean(name), limit: limit.magnitude,
                                colorIndex: siblings.count,
                                sortOrder: (siblings.map(\.sortOrder).max() ?? -1) + 1)
            try store.save(budget)
            selectedBudget = budget.id
            changed()
            return budget.id
        } catch {
            errorMessage = String(describing: error)
            return nil
        }
    }

    /// Name and amount only. Moving a budget to another group is not offered:
    /// a group is what gets shared, with its own key, so a move would mean
    /// re-sealing every transaction for a different set of people.
    public func updateBudget(_ id: BudgetID, name: String, limit: Money) {
        do {
            guard var budget = try store.budget(id) else { return }
            budget.name = Self.clean(name)
            budget.limit = limit.magnitude
            budget.updatedAt = Date()
            try store.save(budget)
            changed()
        } catch {
            errorMessage = String(describing: error)
        }
    }

    /// Deletes the budget and its transactions. Both are marked deleted rather than
    /// removed, so the deletion syncs to every other device.
    public func deleteBudget(_ id: BudgetID) {
        do {
            try trashBudget(id)
            if selectedBudget == id { selectedBudget = nil }
            changed()
        } catch {
            errorMessage = String(describing: error)
        }
    }

    @discardableResult
    public func addGroup(named name: String) -> GroupID? {
        do {
            let group = BudgetGroup(name: Self.clean(name))
            try store.save(group)
            changed()
            return group.id
        } catch {
            errorMessage = String(describing: error)
            return nil
        }
    }

    public func renameGroup(_ id: GroupID, to name: String) {
        do {
            guard var group = try store.group(id) else { return }
            group.name = Self.clean(name)
            group.updatedAt = Date()
            try store.save(group)
            changed()
        } catch {
            errorMessage = String(describing: error)
        }
    }

    /// Deletes the group with every budget and transaction in it.
    ///
    /// `reach` is what the person was told the delete does, and it is binding.
    /// It is decided here, when they confirm, because a sync round already
    /// running sends whatever is queued by the time it reaches the group.
    /// There is no default, so no caller can queue a delete for everyone
    /// without saying so.
    ///
    /// Only `.everyone` and `.justYou` queue anything. The other two stay on
    /// this Mac and queue nothing:
    /// - `.thisMacOnly` is for a shared group this person may not delete for
    ///   everyone. Their budget and transaction deletes would reach every
    ///   other member, even though the group's own delete is refused.
    /// - `.declinesInvite`, or any group still waiting to join, is only a
    ///   placeholder for someone else's group. Its delete would land on the
    ///   inviter's real group, so its queued rows are dropped as well.
    public func deleteGroup(_ id: GroupID, reach: GroupDeleteReach) {
        do {
            guard var group = try store.group(id) else { return }
            let declining = try reach == .declinesInvite || store.pendingJoin(id) != nil
            let queue = !declining && reach.reachesOthersOrNobody
            let budgets = try store.budgets(in: id)
            for budget in budgets { try trashBudget(budget.id, queue: queue) }
            group.isDeleted = true
            group.updatedAt = Date()
            try store.save(group, queue: queue)
            if declining {
                // Saved before this Mac saw the real group, so none of it may go.
                try store.clearOutbox(in: id)
                try store.deletePendingJoin(id)
            }
            if let selected = selectedBudget, budgets.contains(where: { $0.id == selected }) {
                selectedBudget = nil
            }
            changed()
        } catch {
            errorMessage = String(describing: error)
        }
    }

    /// How many transactions a delete would take with it, for the confirmation.
    public func transactionCount(inBudget id: BudgetID) -> Int {
        (try? store.transactions(in: id).count) ?? 0
    }

    private func trashBudget(_ id: BudgetID, queue: Bool = true) throws {
        guard var budget = try store.budget(id) else { return }
        for transaction in try store.transactions(in: id) { try store.trash(transaction, queue: queue) }
        budget.isDeleted = true
        budget.updatedAt = Date()
        try store.save(budget, queue: queue)
    }

    private static func clean(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public func dismissError() { errorMessage = nil }

    /// After an edit: show it, then say so.
    private func changed() {
        reload()
        didChange?()
    }

    // MARK: - Members

    /// Everyone with access to the group, from its verified membership log. One
    /// for a group nobody else has joined, or that has never synced.
    public func memberCount(in group: GroupID) -> Int {
        guard let log = try? store.membershipLog(for: group), !log.isEmpty,
              let state = try? MembershipLog.replay(log, scope: .group(group)) else { return 1 }
        return max(1, state.members.count)
    }

    public func isShared(_ group: GroupID) -> Bool { memberCount(in: group) > 1 }

    /// What to show in "Added by": "You" for this person's own, otherwise the
    /// name that member gave the group.
    public func addedBy(_ transaction: Transaction, me: UserID?) -> String {
        guard let owner = transaction.createdBy, owner != me else { return "You" }
        let profile = try? store.profile(MemberProfile.recordID(group: transaction.groupID, user: owner))
        return profile?.displayName ?? "A member"
    }

    /// The name this person shows a group. Each group gets its own copy, sealed
    /// with that group's key.
    public func setDisplayName(_ name: String, for user: UserID, in group: GroupID) {
        do {
            try store.save(MemberProfile(groupID: group, userID: user, displayName: Self.clean(name)))
            didChange?()
        } catch {
            errorMessage = String(describing: error)
        }
    }

    // MARK: - Statement import

    /// Reads a statement and works out what should happen, without writing anything.
    /// Nothing is saved until the review sheet is confirmed.
    public func prepareImport(from url: URL) {
        do {
            let needsScope = url.startAccessingSecurityScopedResource()
            defer { if needsScope { url.stopAccessingSecurityScopedResource() } }

            let contents = try String(contentsOf: url, encoding: .utf8)
            let lines = try StatementParser.parse(contents: contents, filename: url.lastPathComponent)

            guard let group = groups.first else {
                errorMessage = "Make a budget group first."
                return
            }
            let allTransactions = try store.budgets(in: group.id)
                .flatMap { try store.transactions(in: $0.id) }

            // The group's own key, kept in the database. A key made fresh at each
            // launch gave the same statement a different fingerprint every time,
            // so re-importing it duplicated every row instead of skipping them.
            guard let budgetKey = try fingerprintKey(for: group.id) else {
                errorMessage = "This group's keys have not arrived yet. Sync, then import again."
                return
            }

            let context = StatementMatcher.Context(
                budgetKey: budgetKey,
                existingFingerprints: try store.existingFingerprints(
                    lines.map { $0.fingerprint(budgetKey: budgetKey) }, in: group.id),
                receipts: try store.receipts(in: group.id),
                recentTransactions: allTransactions,
                merchantRules: StatementMatcher.merchantRules(from: allTransactions),
                defaultBudget: nil
            )

            let matcher = StatementMatcher()
            let proposals = matcher.propose(lines, context: context)
            pendingImport = PendingImport(filename: url.lastPathComponent,
                                          proposals: proposals,
                                          summary: matcher.summarise(proposals))
        } catch {
            errorMessage = String(describing: error)
        }
    }

    /// Writes what the review sheet agreed to.
    public func commitImport() {
        guard let pending = pendingImport, let group = groups.first else { return }
        do {
            var added = 0
            var skipped = 0

            for (index, proposal) in pending.proposals.enumerated() {
                switch proposal.decision {
                case .alreadyImported:
                    skipped += 1

                case .matchesReceipt, .matchesTransaction:
                    // Already represented. Linking the two is the next piece of
                    // work; for now the row is not duplicated, which is the part
                    // that matters.
                    skipped += 1

                case .add(let budgetID):
                    try write(proposal, into: budgetID, group: group.id)
                    added += 1

                case .needsBudget:
                    guard let chosen = pending.chosenBudgets[index] else { continue }
                    try write(proposal, into: chosen, group: group.id)
                    added += 1
                }
            }

            try store.save(ImportedStatement(
                groupID: group.id, filename: pending.filename, format: "auto",
                rowCount: pending.proposals.count, addedCount: added, skippedCount: skipped))

            pendingImport = nil
            changed()
        } catch {
            errorMessage = String(describing: error)
        }
    }

    /// The key statement fingerprints are made with: the oldest key this Mac
    /// holds for the group, or nil when it holds none it may use.
    ///
    /// Only a group of this person's own gets a key made here. In a group
    /// shared with them the keys come from whoever shared it, and this Mac
    /// never replaces a key it holds. One made here before the real one
    /// arrived would be kept, and nothing anyone else sealed would open.
    private func fingerprintKey(for group: GroupID) throws -> SymmetricKey? {
        if let oldest = try store.cachedKeys(scope: .group(group)).first { return oldest.material }
        guard try store.pendingJoin(group) == nil else { return nil }
        let log = try store.membershipLog(for: group)
        if !log.isEmpty {
            guard let state = try? MembershipLog.replay(log, scope: .group(group)),
                  state.members.count <= 1 else { return nil }
        }
        return try store.localKey(for: .group(group)).material
    }

    /// Files the row under its budget's own group. A row given a budget from
    /// another group, and filed under the group being imported into, was
    /// shown here and refused by every other member.
    private func write(_ proposal: ImportProposal, into budgetID: BudgetID, group: GroupID) throws {
        let home = try store.budget(budgetID)?.groupID ?? group
        try store.save(Transaction(
            budgetID: budgetID, groupID: home, date: proposal.line.date,
            merchant: proposal.line.cleanedDescription,
            note: proposal.line.rawDescription,
            amount: proposal.line.amount,
            source: .statement,
            importFingerprint: proposal.fingerprint
        ))
    }

    public func cancelImport() { pendingImport = nil }

    // MARK: - First run

    /// Something to look at on a fresh install. Replaced the moment real data
    /// arrives, and never written over an existing database.
    func seedFirstRun() throws {
        let household = BudgetGroup(name: "Household")
        try store.save(household)

        let groceries = Budget(groupID: household.id, name: "Groceries",
                               limit: Money(minorUnits: 100_000), colorIndex: 0, sortOrder: 0)
        let eatingOut = Budget(groupID: household.id, name: "Eating out",
                               limit: Money(minorUnits: 30_000), colorIndex: 1, sortOrder: 1)
        let utilities = Budget(groupID: household.id, name: "Utilities",
                               limit: Money(minorUnits: 45_000), colorIndex: 2, sortOrder: 2)
        for budget in [groceries, eatingOut, utilities] { try store.save(budget) }

        let business = BudgetGroup(name: "Side Business")
        try store.save(business)
        try store.save(Budget(groupID: business.id, name: "Materials",
                              limit: Money(minorUnits: 500_000), colorIndex: 3))

        let calendar = Calendar.current
        let samples: [(Budget, String, Int, Int)] = [
            (groceries, "Hilltop Grocery", -14208, 5),
            (groceries, "Costco", -28631, 6),
            (groceries, "Sunny's", -5477, 8),
            (eatingOut, "Sunrise Cafe", -4250, 3),
            (eatingOut, "Riverside Grill", -6810, 9),
            (utilities, "Regional Power", -9603, 12),
        ]
        for (budget, merchant, cents, daysAgo) in samples {
            let date = calendar.date(byAdding: .day, value: -daysAgo, to: Date()) ?? Date()
            try store.save(Transaction(budgetID: budget.id, groupID: budget.groupID, date: date,
                                       merchant: merchant, amount: Money(minorUnits: cents)))
        }
        reload()
    }
}

public extension Money {
    /// For display. The stored value stays an integer; only this adds a symbol.
    var display: String {
        let sign = minorUnits < 0 ? "-" : ""
        return sign + currency.symbol + magnitude.description
    }
}

/// What deleting a group does beyond this Mac, as the confirmation says it.
public enum GroupDeleteReach: Equatable, Sendable {
    /// Nobody else is in it.
    case justYou
    /// Shared, and this person may delete it for every member.
    case everyone
    /// Shared, and only its founder or an admin may delete it for everyone.
    case thisMacOnly
    /// Still waiting to join, so deleting it turns the invite down on this Mac.
    case declinesInvite

    /// Whether the delete may be queued: sent to everyone, or to nobody
    /// because nobody else is in the group. The other two stay on this Mac.
    var reachesOthersOrNobody: Bool { self == .everyone || self == .justYou }

    /// Of two readings, the one that sends less. The reach a dialog showed can
    /// be out of date by the time Delete is confirmed.
    func stricter(_ other: GroupDeleteReach) -> GroupDeleteReach {
        reachesOthersOrNobody ? other : self
    }
}
