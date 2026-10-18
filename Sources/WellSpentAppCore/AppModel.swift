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
    /// Whether this person may add entries to a group. The workspace answers
    /// it from the server's levels; a model on its own allows everything.
    public var mayAddEntries: (GroupID) -> Bool = { _ in true }
    /// Whether this person may change anyone's entries in a group, which
    /// takes Manage. The workspace answers it the same way.
    public var mayManageEntries: (GroupID) -> Bool = { _ in true }
    /// Who is signed in, so the entries they added count as their own. Nil
    /// on a model on its own.
    public var me: () -> UserID? = { nil }
    /// This device, so a change of its own that lost or was refused can be
    /// told apart from another device's. Nil on a model on its own.
    public var thisDevice: () -> DeviceID? = { nil }

    /// The bar after a delete. It goes after `undoWindow`, or at the next
    /// change made here. A sync that brings changes in leaves it.
    public private(set) var undoOffer: UndoOffer?
    /// How long the bar stays.
    public let undoWindow: Duration
    public static let defaultUndoWindow: Duration = .seconds(10)
    @ObservationIgnored private var undoTimer: Task<Void, Never>?
    /// The entries in the list whose last change from this device didn't go
    /// through, until each one is opened.
    private(set) var notices: Set<RecordID> = []

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
        /// The group it goes into, chosen when it was read.
        public let groupID: GroupID
        public let groupName: String
        public var proposals: [ImportProposal]
        public var summary: ImportSummary
        public var chosenBudgets: [Int: BudgetID] = [:]
    }

    /// Whether a budget opens by itself while none is open: one at launch,
    /// and another after the open one is deleted. Right beside a list, as on
    /// the Mac, where the right side would otherwise be empty. A phone shows
    /// a budget in place of the list, so there only a tap opens one, and
    /// deleting the open one goes back to the list.
    public let opensFirstBudget: Bool

    /// `undoWindow` is how long the bar after a delete stays. Tests pass a
    /// short one, as `AutoSync` takes its wait time.
    public init(store: Store, undoWindow: Duration = AppModel.defaultUndoWindow,
                opensFirstBudget: Bool = true) {
        self.store = store
        self.undoWindow = undoWindow
        self.opensFirstBudget = opensFirstBudget
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
            if selectedBudget == nil, opensFirstBudget {
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
            notices = []
            return
        }
        do {
            let budget = try store.budget(selectedBudget)
            let period = budget?.reset.period(containing: Date())
            transactions = try store.transactions(in: selectedBudget, period: period)
            if let device = thisDevice() {
                notices = try store.unnoticedCopies(among: transactions.map(\.id), from: device)
            } else {
                notices = []
            }
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
        // A button left showing cannot add what the server would refuse.
        guard mayAddEntries(budget.groupID) else {
            errorMessage = SyncWording.viewOnly
            return
        }
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

    // MARK: - One entry

    /// Saves the fields a person changed onto the entry as it is stored now,
    /// so a field someone else changed meanwhile keeps their change. The
    /// entry keeps its ID, group, owner, created date, source, receipt and
    /// import mark: the server refuses a changed owner.
    ///
    /// Nothing is saved when it was deleted meanwhile, since a save would
    /// bring it back for everyone, or when this person may not change it
    /// now. A move must be to a live budget in the entry's own group.
    @discardableResult
    public func updateEntry(_ id: RecordID, _ change: EntryChange) -> EntrySaveResult {
        do {
            var entry: Transaction
            switch try changeable(id) {
            case .refused(let result): return result
            case .ready(let stored): entry = stored
            }
            if let budget = change.budget, budget != entry.budgetID {
                let found = try store.budget(budget)
                guard let target = found, !target.isDeleted, target.groupID == entry.groupID else {
                    let name = found?.name ?? ""
                    errorMessage = found?.isDeleted == false ? EntryEditor.Words.budgetElsewhere(name)
                                                             : EntryEditor.Words.budgetGone(name)
                    return .failed
                }
                entry.budgetID = target.id
            }
            if let merchant = change.merchant { entry.merchant = merchant }
            if let amount = change.amount {
                let size = abs(amount.minorUnits)
                entry.amount = Money(minorUnits: entry.amount.minorUnits > 0 ? size : -size,
                                     currency: entry.amount.currency)
            }
            if let date = change.date { entry.date = date }
            if let note = change.note { entry.note = note }
            entry.updatedAt = Date()
            try store.save(entry)
            changed()
            return .saved
        } catch {
            errorMessage = String(describing: error)
            return .failed
        }
    }

    /// Marks the entry deleted, which keeps all of it, so Undo can bring it
    /// back. Refused the same way as a change. Then the bar offers Undo.
    @discardableResult
    public func deleteEntry(_ id: RecordID) -> EntrySaveResult {
        do {
            let entry: Transaction
            switch try changeable(id) {
            case .refused(let result): return result
            case .ready(let stored): entry = stored
            }
            try store.trash(entry)
            changed()
            offerUndo(UndoOffer(deleting: entry))
            return .saved
        } catch {
            errorMessage = String(describing: error)
            return .failed
        }
    }

    /// Brings back the entry the bar names, as a newer version than the
    /// delete, so it wins on the server and on every device. The bar goes
    /// either way. If the entry is back already, from someone's newer edit,
    /// that is all. When it can't come back, the app's error says why.
    public func undoDelete() {
        guard let offer = undoOffer else { return }
        withdrawUndo()
        do {
            guard var entry = try store.transaction(offer.entry), entry.isDeleted else { return }
            let access = access(to: entry)
            guard access.mayChange else {
                errorMessage = UndoOffer.Words.refused(access)
                return
            }
            if let budget = try store.budget(entry.budgetID), budget.isDeleted {
                errorMessage = UndoOffer.Words.budgetGone(budget.name)
                return
            }
            entry.isDeleted = false
            entry.updatedAt = Date()
            try store.save(entry)
            changed()
        } catch {
            errorMessage = String(describing: error)
        }
    }

    private enum Changeable {
        case ready(Transaction)
        case refused(EntrySaveResult)
    }

    /// The entry as stored now, read again because a sync may have deleted
    /// it, or moved this person down, since it was opened.
    private func changeable(_ id: RecordID) throws -> Changeable {
        guard let entry = try store.transaction(id), !entry.isDeleted else {
            return .refused(.deletedMeanwhile(by: try deleter(of: id)))
        }
        let access = access(to: entry)
        return access.mayChange ? .ready(entry) : .refused(.notAllowed(access))
    }

    /// Why a change or a delete would be refused now. Nil when nothing
    /// stands in the way.
    func refusal(toChange id: RecordID) -> EntrySaveResult? {
        do {
            if case .refused(let result) = try changeable(id) { return result }
            return nil
        } catch {
            errorMessage = String(describing: error)
            return .failed
        }
    }

    /// Who deleted an entry: whoever wrote the version on file.
    private func deleter(of id: RecordID) throws -> EntrySaveResult.Deleter {
        guard let author = try store.recordVersion(id)?.author else { return .someone(name: nil) }
        if author == me() { return .you }
        let group = try store.transaction(id)?.groupID
        return .someone(name: group.flatMap { memberName(author, in: $0) })
    }

    /// The question a delete asks first, about the entry as stored now. Nil
    /// when there is no live entry to ask about.
    func deleteQuestion(for id: RecordID) -> PendingDelete? {
        guard let entry = try? store.transaction(id), !entry.isDeleted else { return nil }
        let budget = (try? store.budget(entry.budgetID))?.name ?? ""
        return .entry(entry, budget: budget, group: group(named: entry.groupID)?.name ?? "",
                      shared: isShared(entry.groupID))
    }

    private func offerUndo(_ offer: UndoOffer) {
        undoOffer = offer
        undoTimer = Task { [weak self, undoWindow] in
            try? await Task.sleep(for: undoWindow)
            guard !Task.isCancelled else { return }
            self?.withdrawUndo()
        }
    }

    private func withdrawUndo() {
        undoTimer?.cancel()
        undoTimer = nil
        undoOffer = nil
    }

    /// Whether this device's last change to the entry didn't go through,
    /// and nobody had opened it since. Asking marks it read, so the row's
    /// line goes. That stays on this computer: it doesn't sync, and it is
    /// not a change, so the Undo bar stays.
    func takeNotice(of id: RecordID) -> Bool {
        guard let device = thisDevice() else { return false }
        do {
            guard try store.unnoticedCopies(among: [id], from: device).contains(id) else { return false }
            try store.markCopiesNoticed(of: id)
            notices.remove(id)
            return true
        } catch {
            errorMessage = String(describing: error)
            return false
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
    ///   other member, even though the group's own delete is refused. It asks
    ///   to leave the group instead, which the next readable sync round does
    ///   (`GroupAction.leave`).
    /// - `.declinesInvite`, or any group still waiting to join, is only a
    ///   placeholder for someone else's group. Its delete would land on the
    ///   inviter's real group, so its queued rows are dropped as well.
    public func deleteGroup(_ id: GroupID, reach: GroupDeleteReach) {
        do {
            guard var group = try store.group(id) else { return }
            let declining = try reach == .declinesInvite || store.pendingJoin(id) != nil
            let queue = !declining && reach.reachesOthersOrNobody
            if !declining, reach == .thisMacOnly { try store.requestLeave(id) }
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

    /// How many transactions a group's delete would take with it, in all its
    /// budgets and every period, for the confirmation.
    public func transactionCount(inGroup id: GroupID) -> Int {
        let budgets = (try? store.budgets(in: id)) ?? []
        return budgets.reduce(0) { $0 + transactionCount(inBudget: $1.id) }
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

    /// After an edit: the Undo bar goes, the edit shows, then it says so.
    private func changed() {
        withdrawUndo()
        reload()
        didChange?()
    }

    // MARK: - Members

    /// Everyone with access to the group, as the server last listed them.
    /// One for a group nobody else has joined, or that has never synced.
    public func memberCount(in group: GroupID) -> Int {
        let members = (try? store.members(in: group)) ?? [:]
        guard members.isEmpty else { return members.count }
        return SealedHistory.memberCount(in: group, store: store)
    }

    public func isShared(_ group: GroupID) -> Bool { memberCount(in: group) > 1 }

    /// What to show in "Added by": "You" for this person's own, otherwise the
    /// name that member gave the group.
    public func addedBy(_ transaction: Transaction, me: UserID?) -> String {
        guard let owner = transaction.createdBy, owner != me else { return "You" }
        return memberName(owner, in: transaction.groupID) ?? "A member"
    }

    /// The name a member gave a group, or nil when they gave none.
    func memberName(_ user: UserID, in group: GroupID) -> String? {
        (try? store.profile(MemberProfile.recordID(group: group, user: user)))?.displayName
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

            guard let group = importGroup else {
                errorMessage = "Make a budget group first."
                return
            }
            guard mayAddEntries(group.id) else {
                errorMessage = SyncWording.viewOnly
                return
            }
            let allTransactions = try store.budgets(in: group.id)
                .flatMap { try store.transactions(in: $0.id) }

            // The group's own key, kept in the database. A key made fresh at each
            // launch gave the same statement a different fingerprint every time,
            // so re-importing it duplicated every row instead of skipping them.
            guard let budgetKey = try fingerprintKey(for: group.id) else {
                errorMessage = "This group is not ready for imports yet. Sync, then import again."
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
                                          groupID: group.id, groupName: group.name,
                                          proposals: proposals,
                                          summary: matcher.summarise(proposals))
        } catch {
            errorMessage = ImportWording.words(for: error, file: url.lastPathComponent)
        }
    }

    /// The group a statement goes into: the one whose budget is open, so a
    /// business statement read from a business budget goes into the business
    /// group. The first group only when no budget is open.
    var importGroup: BudgetGroup? {
        if let selectedBudget, let id = budget(for: selectedBudget)?.groupID, let open = group(named: id) {
            return open
        }
        return groups.first
    }

    /// Writes what the review sheet agreed to, into the group it was read for.
    public func commitImport() {
        guard let pending = pendingImport else { return }
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
                    try write(proposal, into: budgetID, group: pending.groupID)
                    added += 1

                case .needsBudget:
                    guard let chosen = pending.chosenBudgets[index] else { continue }
                    try write(proposal, into: chosen, group: pending.groupID)
                    added += 1
                }
            }

            try store.save(ImportedStatement(
                groupID: pending.groupID, filename: pending.filename, format: "auto",
                rowCount: pending.proposals.count, addedCount: added, skippedCount: skipped))

            pendingImport = nil
            changed()
        } catch {
            errorMessage = String(describing: error)
        }
    }

    /// The key statement fingerprints are made with: the server's for the
    /// group once it has one, and the group's first key from before the
    /// switch until then (`Store.importKey`). Nil when this Mac holds none
    /// it may use.
    ///
    /// Only a group of this person's own gets a key made here, and it goes to
    /// the server when the group is first sent. A group the server lists
    /// with no key yet waits for its founder's: a key made here would never
    /// match the one every other member uses, so the same line imported by
    /// two people would count twice.
    private func fingerprintKey(for group: GroupID) throws -> SymmetricKey? {
        if let key = try store.importKey(for: group) { return SymmetricKey(data: key) }
        guard try store.serverGroup(group) == nil, try store.pendingJoin(group) == nil else { return nil }
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
        try store.saveImported(Transaction(
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
    /// arrives, and never written over an existing database. Returns the
    /// groups it made, so that untouched ones can stay out of an account.
    @discardableResult
    func seedFirstRun() throws -> [GroupID] {
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
        return [household.id, business.id]
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
    /// Nothing of the group is deleted for the others. On readable sync this
    /// person leaves it, on every device of theirs.
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
