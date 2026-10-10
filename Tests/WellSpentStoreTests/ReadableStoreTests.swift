import Testing
import Foundation
import GRDB
@testable import WellSpentStore
import WellSpentCrypto
import WellSpentModel

private func makeStore() throws -> Store {
    Store(database: try WellSpentDatabase.inMemory())
}

/// Whole seconds, so a date read back from the database compares equal.
private let noon = Date(timeIntervalSince1970: 1_790_000_000)

/// An entry of a group's sealed history. Nothing here checks signatures.
private func logEntry(_ action: MembershipAction, subject: UserID, in group: GroupID,
                      sequence: UInt64) -> MembershipLogEntry {
    MembershipLogEntry(scope: .group(group), sequence: sequence, previousHash: MembershipLogEntry.rootHash,
                       action: action, subjectUserID: subject, subjectKeys: nil, level: .superadmin,
                       epochAfter: .initial, at: noon, authorUserID: subject, deviceID: nil,
                       devicePublicKey: nil, authorSignature: Data())
}

private func outbox(_ store: Store, in group: GroupID) throws -> [String: OutboxRow] {
    try store.database.read { db in
        Dictionary(uniqueKeysWithValues: try OutboxRow
            .filter(Column("budgetGroupId") == group.dbValue).fetchAll(db).map { ($0.recordId, $0) })
    }
}

@Suite("Readable sync: local tables")
struct ReadableStoreTests {
    /// A database from before the switch opens with everything it held, and
    /// the new tables empty. Opening it again runs nothing.
    @Test func aV8DatabaseOpensWithEverythingKept() throws {
        var configuration = Configuration()
        configuration.foreignKeysEnabled = true
        let queue = try DatabaseQueue(configuration: configuration)
        try WellSpentDatabase.migrator.migrate(queue, upTo: "v8-set-aside-sender")

        let group = BudgetGroup(name: "Household")
        let budget = Budget(groupID: group.id, name: "Groceries", limit: Money(minorUnits: 50_000))
        let spent = Transaction(budgetID: budget.id, groupID: group.id, date: noon, merchant: "Market",
                                amount: Money(minorUnits: -1_250), source: .manual)
        try queue.write { db in
            try GroupRow(group).insert(db)
            try BudgetRow(budget).insert(db)
            try TransactionRow(spent).insert(db)
            try OutboxRow(recordId: spent.id.dbValue, recordType: "transaction", budgetGroupId: group.id.dbValue,
                          budgetId: budget.id.dbValue, lamport: 3, isDeleted: false, queuedAt: noon,
                          isReseal: false, editLamport: nil).insert(db)
        }

        let store = Store(database: try WellSpentDatabase(writer: queue))
        #expect(try store.groups().map(\.id) == [group.id])
        #expect(try store.transactions(in: budget.id).map(\.id) == [spent.id])
        #expect(try store.outboxCount(in: group.id) == 1)
        #expect(try store.serverGroups().isEmpty)
        #expect(try store.setAsideCount(in: group.id) == 0)
        #expect(try store.moveCheck(group.id) == nil)
        let tables = ["serverGroup", "groupMember", "setAsideRecord", "readablePull", "moveCheck"]
        let made = try queue.read { db in try tables.filter { try db.tableExists($0) } }
        #expect(made == tables)

        _ = try WellSpentDatabase(writer: queue)
        #expect(try queue.read { db in try WellSpentDatabase.migrator.hasCompletedMigrations(db) })
        #expect(try store.outboxCount(in: group.id) == 1)
    }

    /// What the server says replaces what it said before, except when this
    /// Mac moved the group, which only this Mac knows.
    @Test func savingWhatTheServerSaysKeepsWhenThisMacMovedTheGroup() throws {
        let store = try makeStore()
        let group = GroupID(), founder = UserID()
        try store.saveServerGroup(ServerGroupInfo(groupID: group, founderID: founder, level: .superadmin,
                                                  importKey: Data(), refreshedAt: noon))
        try store.markMoved(group, at: noon)

        let key = Data(repeating: 7, count: 32)
        try store.saveServerGroup(ServerGroupInfo(groupID: group, founderID: founder, level: .write,
                                                  importKey: key, historyFloor: 12, deletedOnServer: true,
                                                  movedAt: nil, refreshedAt: noon.addingTimeInterval(60)))
        let saved = try #require(try store.serverGroup(group))
        #expect(saved == ServerGroupInfo(groupID: group, founderID: founder, level: .write, importKey: key,
                                         historyFloor: 12, deletedOnServer: true, movedAt: noon,
                                         refreshedAt: noon.addingTimeInterval(60)))
        #expect(try store.serverGroups() == [saved])

        #expect(throws: StoreError.self) { try store.markMoved(GroupID(), at: noon) }
    }

    /// Removed from a group, this Mac keeps what it knew, so a group listed
    /// again is never taken for one not yet sent up. The clock moves only up.
    @Test func aRemovedGroupKeepsItsNotes() throws {
        let store = try makeStore()
        let group = GroupID(), founder = UserID()
        try store.saveServerGroup(ServerGroupInfo(groupID: group, founderID: founder, level: .write,
                                                  importKey: Data(), refreshedAt: noon))
        try store.markMoved(group, at: noon)
        try store.replaceMembers([founder: .superadmin], in: group)
        try store.markRemoved(group, at: noon)
        try store.saveServerGroup(ServerGroupInfo(groupID: group, founderID: founder, level: .read,
                                                  importKey: Data(), refreshedAt: noon))
        let removed = try #require(try store.serverGroup(group))
        #expect(removed.movedAt == noon && removed.removedAt == noon)
        #expect(try store.members(in: group).isEmpty)
        try store.markListedAgain(group)
        #expect(try store.serverGroup(group)?.removedAt == nil)
        #expect(try store.serverGroup(group)?.movedAt == noon)

        try store.observeLamport(9, in: group)
        try store.observeLamport(4, in: group)
        #expect(try store.syncState(for: group).lamport == 9)
    }

    @Test func membersAreReplacedWholeAndOnlyInTheirGroup() throws {
        let store = try makeStore()
        let group = GroupID(), other = GroupID()
        let founder = UserID(), partner = UserID()
        try store.replaceMembers([founder: .superadmin, partner: .write], in: group)
        try store.replaceMembers([founder: .superadmin], in: other)

        try store.replaceMembers([founder: .superadmin, partner: .read], in: group)
        #expect(try store.members(in: group) == [founder: .superadmin, partner: .read])
        try store.replaceMembers([founder: .superadmin], in: group)
        #expect(try store.members(in: group) == [founder: .superadmin])
        #expect(try store.members(in: other) == [founder: .superadmin])
    }

    /// The founder is read from the first entry of the sealed history, and
    /// only when that entry founds the group.
    @Test func theFounderComesFromTheFirstSealedEntry() throws {
        let store = try makeStore()
        let group = GroupID(), founder = UserID(), partner = UserID()
        #expect(try !store.hasSealedHistory(group))
        #expect(try store.foundingSubject(of: group) == nil)

        try store.append(logEntry(.add, subject: partner, in: group, sequence: 1), in: group)
        try store.append(logEntry(.found, subject: founder, in: group, sequence: 0), in: group)
        #expect(try store.hasSealedHistory(group))
        #expect(try store.foundingSubject(of: group) == founder)

        let odd = GroupID()
        try store.append(logEntry(.add, subject: partner, in: odd, sequence: 0), in: odd)
        #expect(try store.foundingSubject(of: odd) == nil)
    }

    /// Lines imported before the switch were fingerprinted with the group's
    /// first key. That key is used until the server has one, and the
    /// server's is used from then on.
    @Test func theImportKeyIsTheServersOnceItHasOne() throws {
        let store = try makeStore()
        let group = GroupID()
        #expect(try store.importKey(for: group) == nil)

        let later = ScopedKey.generate(scope: .group(group), epoch: Epoch(2))
        let first = ScopedKey.generate(scope: .group(group), epoch: .initial)
        try store.cache(later)
        try store.cache(first)
        #expect(try store.oldestGroupKey(group) == first.rawBytes)
        #expect(try store.importKey(for: group) == first.rawBytes)

        try store.saveServerGroup(ServerGroupInfo(groupID: group, founderID: UserID(), level: .write,
                                                  importKey: Data(), refreshedAt: noon))
        #expect(try store.importKey(for: group) == first.rawBytes, "an empty key means not moved yet")

        let servers = Data(repeating: 9, count: 32)
        try store.saveServerGroup(ServerGroupInfo(groupID: group, founderID: UserID(), level: .write,
                                                  importKey: servers, refreshedAt: noon))
        #expect(try store.importKey(for: group) == servers)
    }

    /// The founder's re-send. Everything in the group is queued as it
    /// stands, at the Lamport value of the version on file, except what
    /// another member owns. Edits already queued keep the value they were
    /// made at. Re-seal rows and sealed set-aside records go.
    @Test func theFoundersResendQueuesEverythingTheyMayStore() throws {
        let store = try makeStore()
        let me = UserID(), partner = UserID()
        let group = BudgetGroup(name: "Household")
        let elsewhere = BudgetGroup(name: "Elsewhere")
        try store.save(group, queue: false)
        try store.save(elsewhere, queue: false)
        let groceries = Budget(groupID: group.id, name: "Groceries", limit: Money(minorUnits: 50_000))
        let fuel = Budget(groupID: group.id, name: "Fuel", limit: Money(minorUnits: 20_000))
        try store.save(groceries, queue: false)
        try store.save(fuel, queue: false)
        func spend(_ amount: Int, by user: UserID?, deleted: Bool = false) throws -> Transaction {
            let t = Transaction(budgetID: groceries.id, groupID: group.id, date: noon, merchant: "Market",
                                amount: Money(minorUnits: amount), source: .manual, createdBy: user,
                                isDeleted: deleted)
            try store.save(t, queue: false)
            return t
        }
        let mine = try spend(-100, by: me)
        _ = try spend(-200, by: partner)
        let older = try spend(-300, by: nil)
        let gone = try spend(-400, by: me, deleted: true)
        let receipt = Receipt(groupID: group.id, budgetID: groceries.id, filename: "r.pdf",
                              mediaType: "application/pdf", byteCount: 1, plaintextSHA256: Data([1]),
                              capturedAt: noon)
        try store.save(receipt, queue: false)
        let statement = ImportedStatement(groupID: group.id, filename: "s.csv", format: "csv", importedAt: noon)
        try store.save(statement, queue: false)
        let myName = MemberProfile(groupID: group.id, userID: me, displayName: "Me")
        let theirName = MemberProfile(groupID: group.id, userID: partner, displayName: "Partner")
        try store.save(myName, queue: false)
        try store.save(theirName, queue: false)

        // Versions on file for some records; the rest were never stamped.
        let device = DeviceID()
        try store.setRecordVersion(mine.id, lamport: 4, device: device, author: me, serverSeq: 2)
        try store.setRecordVersion(RecordID(groceries.id.uuid), lamport: 2, device: device, author: me, serverSeq: 1)
        try store.setRecordVersion(RecordID(group.id.uuid), lamport: 1, device: device, author: me, serverSeq: 1)

        // The queue: an edit, an edit owing a re-seal, and a plain re-seal.
        try store.save(older)                        // a plain edit
        let olderEdit = try #require(try store.queuedPush(older.id))
        try store.save(fuel)                         // an edit...
        let fuelEdit = try #require(try store.queuedPush(RecordID(fuel.id.uuid))).lamport
        try store.queueReseal(of: group.id, budgets: [fuel.id])   // ...owing a re-seal, and the group re-sealed
        #expect(try store.queuedPush(RecordID(fuel.id.uuid))?.editLamport == fuelEdit)
        #expect(try store.queuedPush(RecordID(group.id.uuid))?.isReseal == true)

        // Sealed records set aside here and in another group.
        let key = ScopedKey.generate(scope: .group(group.id))
        for home in [group.id, elsewhere.id] {
            let envelope = try RecordCodec.sealData(
                Data("{}".utf8), recordID: RecordID(), recordType: RecordType(rawValue: "future"),
                groupID: home, budgetID: nil, scopeKey: key, lamport: 3, author: partner,
                device: DeviceKeyPair(), membershipSequence: 0)
            try store.deferEnvelope(envelope, serverSeq: 5, unreadable: true)
        }
        try store.recordPull(group: group.id, serverSeq: 10, observedLamport: 0)
        let clockBefore = try store.syncState(for: group.id).lamport

        let summary = try store.prepareResend(of: group.id, scope: .everything, me: me)

        #expect(summary.droppedSetAside == 1)
        #expect(summary.droppedReseals == 1, "the group's own re-seal")
        #expect(summary.keptEdits == 2)
        #expect(summary.skipped == 2, "the partner's transaction and profile")
        #expect(try store.deferredCount(in: group.id) == 0)
        #expect(try store.deferredCount(in: elsewhere.id) == 1)

        let rows = try outbox(store, in: group.id)
        let expected = Set([group.id.dbValue, groceries.id.dbValue, fuel.id.dbValue]
            + [mine.id, older.id, gone.id, receipt.id, statement.id, myName.id].map(\.dbValue))
        #expect(Set(rows.keys) == expected)

        // Kept edits: each weighed at the value it was made at, and an edit again.
        #expect(rows[older.id.dbValue]?.lamport == Int64(olderEdit.lamport))
        #expect(rows[older.id.dbValue]?.isReseal == false)
        #expect(rows[fuel.id.dbValue]?.lamport == Int64(fuelEdit))
        #expect(rows[fuel.id.dbValue]?.editLamport == nil)
        #expect(rows[fuel.id.dbValue]?.isReseal == false)

        // Re-sends: at the version on file, or fresh above the old clock.
        #expect(rows[group.id.dbValue]?.lamport == 1)
        #expect(rows[groceries.id.dbValue]?.lamport == 2)
        #expect(rows[mine.id.dbValue]?.lamport == 4)
        for unstamped in [gone.id, receipt.id, statement.id, myName.id] {
            #expect((rows[unstamped.dbValue]?.lamport ?? 0) > Int64(clockBefore))
        }
        for resent in [group.id.dbValue, groceries.id.dbValue]
            + [mine.id, gone.id, receipt.id, statement.id, myName.id].map(\.dbValue) {
            #expect(rows[resent]?.isReseal == true)
            #expect(rows[resent]?.editLamport == nil)
        }
        #expect(rows[gone.id.dbValue]?.isDeleted == true, "a delete is sent as a delete")
        #expect(rows[groceries.id.dbValue]?.budgetId == groceries.id.dbValue)
        #expect(rows[mine.id.dbValue]?.budgetId == groceries.id.dbValue)
        #expect(rows[receipt.id.dbValue]?.budgetId == groceries.id.dbValue)
        #expect(rows[statement.id.dbValue]?.budgetId == nil)

        // The next readable pull starts over; the clock, the versions on
        // file, and the sealed app's own place all stay.
        #expect(try store.readableCursor(in: group.id) == 0)
        #expect(try store.syncState(for: group.id).serverSeq == 10, "the old app's place is its own")
        #expect(try store.syncState(for: group.id).lamport >= clockBefore)
        #expect(try store.recordVersion(mine.id)?.lamport == 4)
    }

    /// A member whose founder has already sent the group sends only their
    /// own transactions and their own profile.
    @Test func aMembersResendQueuesOnlyTheirOwnEntries() throws {
        let store = try makeStore()
        let me = UserID(), founder = UserID()
        let group = BudgetGroup(name: "Shared")
        try store.save(group, queue: false)
        let budget = Budget(groupID: group.id, name: "Food", limit: Money(minorUnits: 10_000))
        try store.save(budget, queue: false)
        func spend(by user: UserID?) throws -> Transaction {
            let t = Transaction(budgetID: budget.id, groupID: group.id, date: noon, merchant: "Cafe",
                                amount: Money(minorUnits: -500), source: .manual, createdBy: user)
            try store.save(t, queue: false)
            return t
        }
        let mine = try spend(by: me)
        _ = try spend(by: founder)
        _ = try spend(by: nil)
        let myName = MemberProfile(groupID: group.id, userID: me, displayName: "Me")
        try store.save(myName, queue: false)
        try store.save(MemberProfile(groupID: group.id, userID: founder, displayName: "Founder"), queue: false)

        let summary = try store.prepareResend(of: group.id, scope: .ownRecords, me: me)
        #expect(Set(try outbox(store, in: group.id).keys) == [mine.id.dbValue, myName.id.dbValue])
        #expect(summary.queued == 2)
        #expect(summary.skipped == 3)
    }

    /// A group deleted here sends only its own delete. Its contents, and
    /// edits queued in it, stay home.
    @Test func aGroupDeletedHereSendsOnlyItsDelete() throws {
        let store = try makeStore()
        let me = UserID()
        var group = BudgetGroup(name: "Old")
        try store.save(group, queue: false)
        let budget = Budget(groupID: group.id, name: "Food", limit: Money(minorUnits: 10_000))
        try store.save(budget, queue: false)
        try store.save(Transaction(budgetID: budget.id, groupID: group.id, date: noon, merchant: "Cafe",
                                   amount: Money(minorUnits: -500), source: .manual, createdBy: me))
        group.isDeleted = true
        try store.save(group, queue: false)

        try store.prepareResend(of: group.id, scope: .everything, me: me)
        let rows = try outbox(store, in: group.id)
        #expect(Array(rows.keys) == [group.id.dbValue])
        #expect(rows[group.id.dbValue]?.isDeleted == true)
    }

    /// Re-running after an interruption queues the same records at the same
    /// values wherever a version is on file.
    @Test func aResendRunTwiceQueuesTheSameRecords() throws {
        let store = try makeStore()
        let me = UserID()
        let group = BudgetGroup(name: "Household")
        try store.save(group, queue: false)
        let budget = Budget(groupID: group.id, name: "Food", limit: Money(minorUnits: 10_000))
        try store.save(budget, queue: false)
        try store.setRecordVersion(RecordID(budget.id.uuid), lamport: 6, device: DeviceID(), author: me, serverSeq: 3)

        try store.prepareResend(of: group.id, scope: .everything, me: me)
        let first = try outbox(store, in: group.id)
        try store.prepareResend(of: group.id, scope: .everything, me: me)
        let second = try outbox(store, in: group.id)
        #expect(Set(first.keys) == Set(second.keys))
        #expect(second[budget.id.dbValue]?.lamport == 6)
    }

    /// Re-sent records can share a Lamport value. Paging on (value, record)
    /// reads each row once, however the page boundaries fall on a tie.
    @Test func pagingTheOutboxReadsEveryTiedRowOnce() throws {
        let store = try makeStore()
        let group = GroupID()
        let lamports: [Int64] = [3, 7, 7, 7, 7, 7, 9, 2]
        let ids = lamports.map { _ in RecordID() }
        try store.database.write { db in
            for (id, lamport) in zip(ids, lamports) {
                try OutboxRow(recordId: id.dbValue, recordType: "budget", budgetGroupId: group.dbValue,
                              budgetId: id.dbValue, lamport: lamport, isDeleted: false, queuedAt: noon,
                              isReseal: true, editLamport: nil).insert(db)
            }
        }
        for pageSize in 1 ... 4 {
            var seen: [PendingPush] = []
            var cursor: Store.OutboxCursor?
            while true {
                let page = try store.pendingPushes(in: group, following: cursor, limit: pageSize)
                guard let last = page.last else { break }
                seen += page
                cursor = Store.OutboxCursor(after: last)
            }
            #expect(seen.count == ids.count, "page size \(pageSize)")
            #expect(Set(seen.map(\.recordID)) == Set(ids), "page size \(pageSize)")
            let order = seen.map { ($0.lamport, $0.recordID.dbValue) }
            #expect(zip(order, order.dropFirst()).allSatisfy { $0 < $1 }, "page size \(pageSize)")
        }
    }

    /// What the move compares. Live records only, except budgets, which are
    /// listed deleted or not, so a budget deleted on one side shows.
    @Test func totalsAddUpLiveRecordsPerBudget() throws {
        let store = try makeStore()
        let group = BudgetGroup(name: "Household")
        let other = BudgetGroup(name: "Other")
        try store.save(group, queue: false)
        try store.save(other, queue: false)
        let food = Budget(groupID: group.id, name: "Food", limit: Money(minorUnits: 10_000))
        var old = Budget(groupID: group.id, name: "Old", limit: Money(minorUnits: 5_000))
        old.isDeleted = true
        let away = Budget(groupID: other.id, name: "Away", limit: Money(minorUnits: 1_000))
        for budget in [food, old, away] { try store.save(budget, queue: false) }
        func spend(_ amount: Int, in budget: Budget, deleted: Bool = false) throws {
            try store.save(Transaction(budgetID: budget.id, groupID: group.id, date: noon, merchant: "M",
                                       amount: Money(minorUnits: amount), source: .manual, isDeleted: deleted),
                           queue: false)
        }
        try spend(-1_000, in: food)
        try spend(-250, in: food)
        try spend(-9_999, in: food, deleted: true)
        try spend(-70, in: away)
        try store.save(Receipt(groupID: group.id, filename: "r", mediaType: "image/png", byteCount: 1,
                               plaintextSHA256: Data([2]), capturedAt: noon), queue: false)
        try store.save(MemberProfile(groupID: group.id, userID: UserID(), displayName: "A"), queue: false)

        let totals = try store.groupTotals(in: group.id)
        #expect(totals.groupName == "Household")
        #expect(totals.groupDeleted == false)
        #expect(totals.receipts == 1)
        #expect(totals.statements == 0)
        #expect(totals.profiles == 1)
        let byID = Dictionary(uniqueKeysWithValues: totals.budgets.map { ($0.budgetID, $0) })
        #expect(totals.budgets.map(\.budgetID) == totals.budgets.map(\.budgetID).sorted())
        #expect(byID[food.id.dbValue] == BudgetTotals(budgetID: food.id.dbValue, name: "Food",
                                                       limitMinorUnits: 10_000, currency: "USD",
                                                       isDeleted: false, transactionCount: 2,
                                                       transactionSum: -1_250))
        #expect(byID[old.id.dbValue]?.isDeleted == true)
        #expect(byID[old.id.dbValue]?.transactionCount == 0)
        #expect(byID[away.id.dbValue]?.name == nil, "a budget the group does not hold")
        #expect(byID[away.id.dbValue]?.transactionSum == -70)

        #expect(try store.groupTotals(in: group.id) == totals)
        #expect(try store.groupTotals(in: GroupID()).groupName == nil)
    }

    @Test func aRecordSetAsideTwiceKeepsTheLaterCopy() throws {
        let store = try makeStore()
        let group = GroupID(), author = UserID()
        let first = RecordID(), second = RecordID()
        try store.setAside(SetAsideRecord(recordID: first, groupID: group, recordType: RecordType(rawValue: "future"),
                                          recordJSON: "{\"v\":1}", serverSeq: 8, authorUserID: author,
                                          unreadable: true))
        try store.setAside(SetAsideRecord(recordID: second, groupID: group, recordType: .transaction,
                                          recordJSON: "{}", serverSeq: 3, authorUserID: author, unreadable: false))
        try store.setAside(SetAsideRecord(recordID: first, groupID: group, recordType: RecordType(rawValue: "future"),
                                          recordJSON: "{\"v\":2}", serverSeq: 9, authorUserID: author,
                                          unreadable: true))

        let kept = try store.setAsideRecords(in: group)
        #expect(kept.map(\.recordID) == [second, first], "in the order the server stored them")
        #expect(kept.last?.recordJSON == "{\"v\":2}")
        #expect(try store.setAsideCount(in: group) == 2)
        #expect(try store.unreadableSetAsideCount(in: group, from: author, except: RecordID()) == 1)
        #expect(try store.unreadableSetAsideCount(in: group, from: author, except: first) == 0)
        #expect(try store.unreadableSetAsideCount(in: group, from: UserID(), except: RecordID()) == 0)

        try store.deleteSetAside(first)
        #expect(try store.setAsideRecords(in: group).map(\.recordID) == [second])
    }

    @Test func aMoveCheckIsSavedAndReplaced() throws {
        let store = try makeStore()
        let group = GroupID()
        try store.saveMoveCheck(StoredMoveCheck(groupID: group, attempts: 1, matches: false,
                                                reportJSON: "{}", checkedAt: noon))
        try store.saveMoveCheck(StoredMoveCheck(groupID: group, attempts: 2, matches: true,
                                                reportJSON: "{\"ok\":true}", checkedAt: noon))
        #expect(try store.moveCheck(group) == StoredMoveCheck(groupID: group, attempts: 2, matches: true,
                                                              reportJSON: "{\"ok\":true}", checkedAt: noon))
    }

    /// A stand-in group is made only where none is held, and never queued.
    @Test func aPlaceholderNeverReplacesAGroupHeldHere() throws {
        let store = try makeStore()
        let held = BudgetGroup(name: "Held")
        try store.save(held, queue: false)
        try store.placeholderGroup(held.id, name: "Stand-in")
        #expect(try store.group(held.id)?.name == "Held")

        let fresh = GroupID()
        try store.placeholderGroup(fresh, name: "Stand-in")
        #expect(try store.group(fresh)?.name == "Stand-in")
        #expect(try store.outboxCount(in: fresh) == 0)
    }

    @Test func hidingAGroupQueuesNothingAndDropsItsQueue() throws {
        let store = try makeStore()
        let group = BudgetGroup(name: "Left"), kept = BudgetGroup(name: "Kept")
        try store.save(group)
        try store.save(kept)
        try store.hideGroup(group.id)
        #expect(try store.group(group.id)?.isDeleted == true)
        #expect(try store.outboxCount(in: group.id) == 0)
        #expect(try store.outboxCount(in: kept.id) == 1)
    }

    @Test func sealedInvitesAreCleared() throws {
        let store = try makeStore()
        let group = GroupID()
        try store.save(SentInvite(id: Data([1]), groupID: group, secret: Data([2]), level: .write,
                                  historyAccess: .all, expiresAt: noon))
        try store.save(PendingJoin(groupID: GroupID(), groupName: "G", inviterName: "I",
                                   displayName: "D", level: .read))
        try store.clearSealedInvites()
        #expect(try store.sentInvites(in: group).isEmpty)
        #expect(try store.pendingJoins().isEmpty)
    }

    /// Unlike forgetting the pulls, the versions on file stay.
    @Test func resettingThePullCursorKeepsTheVersionsOnFile() throws {
        let store = try makeStore()
        let group = GroupID(), record = RecordID()
        try store.recordPull(group: group, serverSeq: 12, observedLamport: 3)
        try store.recordReadablePull(group: group, serverSeq: 9, observedLamport: 4)
        try store.recordReadablePull(group: group, serverSeq: 7, observedLamport: 2)
        #expect(try store.readableCursor(in: group) == 9, "it only moves forward")
        try store.setRecordVersion(record, lamport: 4, device: DeviceID(), serverSeq: 9)
        try store.resetPullCursor(in: group)
        #expect(try store.readableCursor(in: group) == 0)
        #expect(try store.syncState(for: group).serverSeq == 12, "the sealed app's place is untouched")
        #expect(try store.syncState(for: group).lamport == 4)
        #expect(try store.recordVersion(record)?.lamport == 4)
    }
}
