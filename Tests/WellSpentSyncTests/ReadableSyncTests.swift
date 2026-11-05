import Testing
import Foundation
@testable import WellSpentSync
@testable import WellSpentStore
import WellSpentCrypto
import WellSpentModel

/// Whole seconds, as the record codec sends dates, so copies compare equal.
private let noon = Date(timeIntervalSince1970: 1_790_000_000)

/// One device: its own database, its own session, its own engine.
private struct Device {
    let store: Store
    let client: InMemoryReadableSession
    let engine: ReadableSyncEngine
    let user: UserID
    let clientID: DeviceID

    init(on server: InMemoryReadableServer, email: String, password: String = "a long password",
         clientID: DeviceID = DeviceID()) async throws {
        let store = Store(database: try WellSpentDatabase.inMemory())
        let client = server.client()
        let user = try await client.signIn(email: email, password: password, deviceLabel: nil).userID
        self.store = store
        self.client = client
        self.user = user
        self.clientID = clientID
        engine = ReadableSyncEngine(store: store, transport: client, clientID: clientID, userID: user)
    }

    @discardableResult
    func sync(_ group: GroupID, level: AccessLevel = .superadmin) async throws -> SyncReport {
        try await engine.sync(group: group, level: level)
    }
}

/// A group founded on the server and on the founder's device, with one budget.
private struct Household {
    let server: InMemoryReadableServer
    let founder: Device
    let group: BudgetGroup
    let budget: Budget

    init(founderClient: DeviceID = DeviceID()) async throws {
        let server = InMemoryReadableServer()
        server.seedAccount(email: "founder@example.com", password: "a long password")
        let founder = try await Device(on: server, email: "founder@example.com", clientID: founderClient)
        let group = BudgetGroup(name: "Household", createdAt: noon, updatedAt: noon)
        let budget = Budget(groupID: group.id, name: "Food", limit: Money(minorUnits: 10_000), createdAt: noon,
                            updatedAt: noon)
        _ = try await founder.client.createGroup(id: group.id, importKey: nil)
        try founder.store.save(group)
        try founder.store.save(budget)
        try await founder.sync(group.id)
        (self.server, self.founder, self.group, self.budget) = (server, founder, group, budget)
    }

    /// Another device of the founder's own account.
    func founderAgain() async throws -> Device {
        let device = try await Device(on: server, email: "founder@example.com")
        try device.store.placeholderGroup(group.id, name: "")
        return device
    }

    /// Someone invited at `level`.
    func member(_ email: String, level: AccessLevel) async throws -> Device {
        server.seedAccount(email: email, password: "a long password", verified: true)
        let device = try await Device(on: server, email: email)
        let invite = try await founder.client.createInvite(group: group.id, level: level, history: .all, days: nil)
        _ = try await device.client.acceptInvite(token: invite.token)
        try device.store.placeholderGroup(group.id, name: "")
        return device
    }

    func spend(_ amount: Int, by user: UserID?, merchant: String = "Market",
               fingerprint: String? = nil) -> Transaction {
        Transaction(budgetID: budget.id, groupID: group.id, date: noon, merchant: merchant,
                    amount: Money(minorUnits: amount), source: fingerprint == nil ? .manual : .statement,
                    importFingerprint: fingerprint, createdBy: user, createdAt: noon, updatedAt: noon)
    }
}

/// A server whose first page arrives and whose next one fails.
private actor FailsAfterOnePage: ReadableSyncTransport {
    let first: WireRecord
    private var asked = 0
    init(first: WireRecord) { self.first = first }
    func push(_ records: [WireRecord], group: GroupID) async throws -> PushResult {
        PushResult(accepted: [], rejected: [:], serverSeq: 0)
    }
    func pull(group: GroupID, since: UInt64, limit: Int) async throws -> ReadablePull {
        asked += 1
        guard asked == 1 else { throw URLError(.networkConnectionLost) }
        return ReadablePull(records: [first], serverSeq: 1, hasMore: true)
    }
}

/// A server that hands over fixed pages, for records no honest server stores.
private struct Scripted: ReadableSyncTransport {
    let pages: [ReadablePull]
    func push(_ records: [WireRecord], group: GroupID) async throws -> PushResult {
        PushResult(accepted: records.map(\.id), rejected: [:], serverSeq: 0)
    }
    func pull(group: GroupID, since: UInt64, limit: Int) async throws -> ReadablePull {
        pages.first { ($0.records.first?.serverSeq ?? 0) > since } ?? ReadablePull(records: [], serverSeq: since,
                                                                                  hasMore: false)
    }
}

private func body<T: Encodable>(_ value: T) throws -> String {
    String(decoding: try RecordCodec.encoder.encode(value), as: UTF8.self)
}

@Suite("Readable sync, end to end")
struct ReadableSyncTests {
    /// Two devices on one account: everything made on one reaches the other,
    /// edits go both ways, and a device's own records coming back are echoes.
    @Test func twoDevicesOnOneAccountShareEverything() async throws {
        let home = try await Household()
        let lunch = home.spend(-1_250, by: home.founder.user)
        try home.founder.store.save(lunch)
        try await home.founder.sync(home.group.id)

        let desktop = try await home.founderAgain()
        let first = try await desktop.sync(home.group.id)
        #expect(first.applied == 3 && first.conflicts == 0)
        #expect(try desktop.store.group(home.group.id)?.name == "Household")
        #expect(try desktop.store.transactions(in: home.budget.id).map(\.id) == [lunch.id])

        var edited = try #require(try desktop.store.transaction(lunch.id))
        edited.merchant = "Cafe"
        try desktop.store.save(edited)
        try await desktop.sync(home.group.id)

        let back = try await home.founder.sync(home.group.id)
        #expect(try home.founder.store.transaction(lunch.id)?.merchant == "Cafe")
        #expect(back.conflicts == 0)
        let again = try await home.founder.sync(home.group.id)
        #expect(again.applied == 0 && again.conflicts == 0)
        #expect(try home.founder.store.outboxCount(in: home.group.id) == 0)
    }

    /// Two people edit the same entry offline. Both end with the same
    /// winner, and the losing edit is kept as a conflict copy, not dropped.
    @Test func concurrentEditsConvergeAndTheLoserIsKept() async throws {
        let home = try await Household()
        let partner = try await home.member("partner@example.com", level: .manage)
        let lunch = home.spend(-1_250, by: home.founder.user)
        try home.founder.store.save(lunch)
        try await home.founder.sync(home.group.id)
        try await partner.sync(home.group.id, level: .manage)

        var mine = try #require(try home.founder.store.transaction(lunch.id))
        mine.merchant = "Founder's edit"
        try home.founder.store.save(mine)
        var theirs = try #require(try partner.store.transaction(lunch.id))
        theirs.merchant = "Partner's edit"
        try partner.store.save(theirs)

        try await home.founder.sync(home.group.id)
        try await partner.sync(home.group.id, level: .manage)
        try await home.founder.sync(home.group.id)

        let winner = try #require(try home.founder.store.transaction(lunch.id)?.merchant)
        #expect(try partner.store.transaction(lunch.id)?.merchant == winner)
        let copies = try home.founder.store.conflicts(for: lunch.id).count + partner.store.conflicts(for: lunch.id).count
        #expect(copies >= 1, "the losing edit is kept somewhere")
        let server = try #require(home.server.records(in: home.group.id).first { $0.id == lunch.id })
        #expect(try RecordCodec.decoder.decode(Transaction.self, from: Data(server.body.utf8)).merchant == winner)
    }

    /// A group's delete is final: a rename made elsewhere at the same time
    /// does not bring it back.
    @Test func deletingAGroupIsFinal() async throws {
        let home = try await Household()
        let admin = try await home.member("admin@example.com", level: .admin)
        try await admin.sync(home.group.id, level: .admin)

        var renamed = try #require(try admin.store.group(home.group.id))
        renamed.name = "Renamed"
        try admin.store.save(renamed)
        var gone = home.group
        gone.isDeleted = true
        try home.founder.store.save(gone)

        try await home.founder.sync(home.group.id)
        try await admin.sync(home.group.id, level: .admin)
        try await home.founder.sync(home.group.id)
        #expect(try admin.store.group(home.group.id)?.isDeleted == true)
        #expect(try home.founder.store.group(home.group.id)?.isDeleted == true)
    }

    /// Pulled from the start, a budget edited since sorts after its own
    /// transactions. The transaction waits for it, then lands, in one pull.
    @Test func aTransactionThatArrivesBeforeItsBudgetWaitsForIt() async throws {
        let home = try await Household()
        try home.founder.store.save(home.spend(-500, by: home.founder.user))
        try await home.founder.sync(home.group.id)
        var renamed = home.budget
        renamed.name = "Groceries"
        try home.founder.store.save(renamed)
        try await home.founder.sync(home.group.id)

        let desktop = try await home.founderAgain()
        let report = try await desktop.sync(home.group.id)
        #expect(report.deferred == 1)
        #expect(try desktop.store.transactions(in: home.budget.id).count == 1)
        #expect(try desktop.store.setAsideCount(in: home.group.id) == 0)
    }

    /// Records no honest server stores: a type from a newer app is set aside
    /// for an update; one that is not what it says, or that would use up this
    /// Mac's clock, is passed over. The pull still reaches the end.
    @Test func recordsThisBuildCannotUseAreSetAsideOrPassedOver() async throws {
        let store = Store(database: try WellSpentDatabase.inMemory())
        let group = BudgetGroup(name: "G", createdAt: noon, updatedAt: noon)
        try store.save(group, queue: false)
        let sender = UserID(), device = DeviceID()
        let future = WireRecord(id: RecordID(), type: RecordType(rawValue: "future"), budgetID: nil, lamport: 2,
                                clientID: device, isDeleted: false, body: "{}", updatedBy: sender, serverSeq: 1)
        let elsewhere = BudgetGroup(name: "Elsewhere")
        let wrongGroup = WireRecord(id: RecordID(UUID()), type: .budget, budgetID: nil, lamport: 3, clientID: device,
                                    isDeleted: false,
                                    body: try body(Budget(groupID: elsewhere.id, name: "B", limit: Money(minorUnits: 1))),
                                    updatedBy: sender, serverSeq: 2)
        let tooBig = WireRecord(id: RecordID(group.id.uuid), type: .groupMeta, budgetID: nil,
                                lamport: RecordEnvelope.lamportCeiling, clientID: device, isDeleted: false,
                                body: try body(group), updatedBy: sender, serverSeq: 3)
        let engine = ReadableSyncEngine(
            store: store, transport: Scripted(pages: [ReadablePull(records: [future, wrongGroup, tooBig],
                                                                   serverSeq: 3, hasMore: false)]),
            clientID: DeviceID(), userID: UserID())
        let report = try await engine.pull(group: group.id)
        #expect(report.deferred == 1 && report.ignored == 2)
        #expect(try store.setAsideRecords(in: group.id).map(\.recordID) == [future.id])
        #expect(try store.readableCursor(in: group.id) == 3)
        #expect(try store.syncState(for: group.id).lamport < RecordEnvelope.lamportCeiling)
    }

    /// The version on file, sent again with content that differs only
    /// because this Mac changed it without a new version: not news, and
    /// not a conflict.
    @Test func theVersionOnFileSentAgainIsNotNews() async throws {
        let store = Store(database: try WellSpentDatabase.inMemory())
        let group = BudgetGroup(name: "G", createdAt: noon, updatedAt: noon)
        let budget = Budget(groupID: group.id, name: "B", limit: Money(minorUnits: 1), createdAt: noon,
                            updatedAt: noon)
        try store.save(group, queue: false)
        try store.save(budget, queue: false)
        let device = DeviceID(), author = UserID()
        var mine = Transaction(budgetID: budget.id, groupID: group.id, date: noon, merchant: "Here",
                               amount: Money(minorUnits: -1), createdBy: author, createdAt: noon, updatedAt: noon)
        try store.save(mine, queue: false)
        try store.setRecordVersion(mine.id, lamport: 5, device: device, author: author, serverSeq: 1)
        mine.merchant = "There"
        let again = WireRecord(id: mine.id, type: .transaction, budgetID: budget.id, lamport: 5, clientID: device,
                               isDeleted: false, body: try body(mine), updatedBy: author, serverSeq: 2)
        let engine = ReadableSyncEngine(
            store: store, transport: Scripted(pages: [ReadablePull(records: [again], serverSeq: 2, hasMore: false)]),
            clientID: DeviceID(), userID: UserID())
        let report = try await engine.pull(group: group.id)
        #expect(report.conflicts == 0 && report.echoes == 1)
        #expect(try store.conflicts(for: mine.id).isEmpty)
    }

    /// The version on file sent again while an edit of it waits here: still
    /// not news. The edit stays queued, and no conflict copy is made.
    @Test func theVersionOnFileSentAgainLeavesAWaitingEditAlone() async throws {
        let store = Store(database: try WellSpentDatabase.inMemory())
        let group = BudgetGroup(name: "G", createdAt: noon, updatedAt: noon)
        let budget = Budget(groupID: group.id, name: "B", limit: Money(minorUnits: 1), createdAt: noon,
                            updatedAt: noon)
        try store.save(group, queue: false)
        try store.save(budget, queue: false)
        let device = DeviceID(), author = UserID()
        let onFile = Transaction(budgetID: budget.id, groupID: group.id, date: noon, merchant: "Server",
                                 amount: Money(minorUnits: -1), createdBy: author, createdAt: noon, updatedAt: noon)
        try store.save(onFile, queue: false)
        try store.setRecordVersion(onFile.id, lamport: 5, device: device, author: author, serverSeq: 1)
        try store.recordReadablePull(group: group.id, serverSeq: 0, observedLamport: 5)
        var edited = onFile
        edited.merchant = "Edited here"
        try store.save(edited)
        let again = WireRecord(id: onFile.id, type: .transaction, budgetID: budget.id, lamport: 5, clientID: device,
                               isDeleted: false, body: try body(onFile), updatedBy: author, serverSeq: 2)
        let engine = ReadableSyncEngine(
            store: store, transport: Scripted(pages: [ReadablePull(records: [again], serverSeq: 2, hasMore: false)]),
            clientID: DeviceID(), userID: author)
        let report = try await engine.pull(group: group.id, level: .write)
        #expect(report.conflicts == 0 && report.echoes == 1)
        #expect(try store.conflicts(for: onFile.id).isEmpty)
        #expect(try store.queuedPush(onFile.id) != nil, "the edit still goes out")
        #expect(try store.transaction(onFile.id)?.merchant == "Edited here")
    }

    /// A row whose import mark was set aside here on arrival is the same row
    /// when it comes back with its mark, even with no author on file to
    /// match its version by.
    @Test func aRowWithItsMarkSetAsideHereIsTheSameRow() async throws {
        let store = Store(database: try WellSpentDatabase.inMemory())
        let group = BudgetGroup(name: "G", createdAt: noon, updatedAt: noon)
        let budget = Budget(groupID: group.id, name: "B", limit: Money(minorUnits: 1), createdAt: noon,
                            updatedAt: noon)
        try store.save(group, queue: false)
        try store.save(budget, queue: false)
        let device = DeviceID(), author = UserID()
        let theirs = Transaction(budgetID: budget.id, groupID: group.id, date: noon, merchant: "Shell",
                                 amount: Money(minorUnits: -700), source: .statement, importFingerprint: "LINE-1",
                                 createdBy: author, createdAt: noon, updatedAt: noon)
        var held = theirs
        held.importFingerprint = nil
        try store.save(held, queue: false)
        try store.holdFingerprint("LINE-1", for: theirs.id)
        try store.setRecordVersion(theirs.id, lamport: 5, device: device, author: nil, serverSeq: 1)
        let again = WireRecord(id: theirs.id, type: .transaction, budgetID: budget.id, lamport: 5, clientID: device,
                               isDeleted: false, body: try body(theirs), updatedBy: author, serverSeq: 2)
        let engine = ReadableSyncEngine(
            store: store, transport: Scripted(pages: [ReadablePull(records: [again], serverSeq: 2, hasMore: false)]),
            clientID: DeviceID(), userID: UserID())
        let report = try await engine.pull(group: group.id)
        #expect(report.conflicts == 0 && report.echoes == 1)
    }

    /// Two people import the same bank line. Each keeps a row; the other's
    /// arrives without the fingerprint here, which is held to send back out.
    @Test func theSameBankLineFromTwoPeopleKeepsBothRows() async throws {
        let home = try await Household()
        let partner = try await home.member("partner@example.com", level: .write)
        try await partner.sync(home.group.id, level: .write)
        let ours = home.spend(-700, by: home.founder.user, fingerprint: "LINE-1")
        let theirs = home.spend(-700, by: partner.user, fingerprint: "LINE-1")
        try home.founder.store.save(ours)
        try partner.store.save(theirs)

        try await home.founder.sync(home.group.id)
        let report = try await partner.sync(home.group.id, level: .write)
        #expect(report.unsaved == 0)
        #expect(try partner.store.transaction(theirs.id)?.importFingerprint == "LINE-1")
        #expect(try partner.store.transaction(ours.id)?.importFingerprint == nil)
        #expect(try partner.store.heldFingerprint(for: ours.id) == "LINE-1")
        #expect(try partner.store.transactions(in: home.budget.id).count == 2)

        // Taken in again from the start, the row is the version on file, with
        // its mark set aside here: no conflict copy, however often.
        for _ in 0 ..< 2 {
            try partner.store.resetPullCursor(in: home.group.id)
            #expect(try await partner.sync(home.group.id, level: .write).conflicts == 0)
        }
        #expect(try partner.store.conflicts(for: ours.id).isEmpty)
    }

    /// A manager demoted while an edit to a budget waits: the edit is kept
    /// as a conflict copy, and the server's budget comes back. Dropped
    /// quietly, it showed on this Mac only, for good.
    @Test func anEditThisPersonMayNoLongerSendIsKeptAndUndone() async throws {
        let home = try await Household()
        let manager = try await home.member("manager@example.com", level: .manage)
        try await manager.sync(home.group.id, level: .manage)
        var raised = try #require(try manager.store.budget(home.budget.id))
        raised.limit = Money(minorUnits: 99_000)
        try manager.store.save(raised)
        try await home.founder.client.setLevel(.write, of: manager.user, in: home.group.id)

        let refused = try await manager.sync(home.group.id, level: .write)
        #expect(refused.conflicts == 1 && refused.rejected == 1)
        #expect(try manager.store.outboxCount(in: home.group.id) == 0)
        try await manager.sync(home.group.id, level: .write)
        #expect(try manager.store.budget(home.budget.id)?.limit == home.budget.limit)
        #expect(try manager.store.conflicts(for: RecordID(home.budget.id.uuid)).count == 1)
    }

    /// A deleted row here gives its bank line's mark up to a live copy
    /// coming in, so the next import here sees the line as imported.
    @Test func aDeletedRowGivesItsMarkToALiveOneComingIn() async throws {
        let home = try await Household()
        let partner = try await home.member("partner@example.com", level: .write)
        try await partner.sync(home.group.id, level: .write)
        var mine = home.spend(-700, by: partner.user, fingerprint: "LINE-1")
        try partner.store.save(mine)
        try await partner.sync(home.group.id, level: .write)
        mine.isDeleted = true
        try partner.store.save(mine)
        try await partner.sync(home.group.id, level: .write)

        let theirs = home.spend(-700, by: home.founder.user, fingerprint: "LINE-1")
        try home.founder.store.save(theirs)
        try await home.founder.sync(home.group.id)
        try await partner.sync(home.group.id, level: .write)
        #expect(try partner.store.transaction(theirs.id)?.importFingerprint == "LINE-1")
        #expect(try partner.store.transaction(mine.id)?.importFingerprint == nil)
        #expect(try partner.store.heldFingerprint(for: mine.id) == "LINE-1")
        #expect(try partner.store.existingFingerprints(["LINE-1"], in: home.group.id) == ["LINE-1"])
    }

    /// After the switch a founder sends everything up once. A member's
    /// device already holds the same records, at the same Lamport values, from
    /// before. Taking them in is not a conflict: only the version changes.
    @Test func theSameContentSentAgainIsNotAConflict() async throws {
        let founderClient = DeviceID()
        let home = try await Household(founderClient: founderClient)
        let partner = try await home.member("partner@example.com", level: .write)
        let lunch = home.spend(-900, by: home.founder.user)
        let partnersOwn = home.spend(-100, by: partner.user)
        for store in [home.founder.store, partner.store] {
            try store.save(home.group, queue: false)
            try store.save(home.budget, queue: false)
            try store.save(lunch, queue: false)
            try store.setRecordVersion(lunch.id, lamport: 5, device: founderClient, author: home.founder.user,
                                       serverSeq: 0)
        }
        try partner.store.save(partnersOwn, queue: false)
        try partner.store.setRecordVersion(partnersOwn.id, lamport: 6, device: partner.clientID, author: partner.user,
                                           serverSeq: 0)

        try home.founder.store.prepareResend(of: home.group.id, scope: .everything, me: home.founder.user)
        try await home.founder.sync(home.group.id)
        try partner.store.prepareResend(of: home.group.id, scope: .ownRecords, me: partner.user)
        let report = try await partner.sync(home.group.id, level: .write)

        #expect(report.conflicts == 0)
        #expect(try partner.store.conflicts(for: lunch.id).isEmpty)
        #expect(try partner.store.recordVersion(lunch.id)?.device == founderClient)
        #expect(home.server.records(in: home.group.id).contains { $0.id == partnersOwn.id },
                "the member's own entry went up")
        #expect(try partner.store.outboxCount(in: home.group.id) == 0)
    }

    /// An edit sent without a pull, older than the server's version, is
    /// refused. It is kept as a conflict copy and leaves the queue.
    @Test func anEditRefusedAsOlderIsKeptAndLeavesTheQueue() async throws {
        let home = try await Household()
        let desktop = try await home.founderAgain()
        let lunch = home.spend(-1_250, by: home.founder.user)
        try home.founder.store.save(lunch)
        try await home.founder.sync(home.group.id)
        try await desktop.sync(home.group.id)

        for _ in 0 ..< 3 {
            var newer = try #require(try home.founder.store.transaction(lunch.id))
            newer.merchant += "!"
            try home.founder.store.save(newer)
        }
        try await home.founder.sync(home.group.id)
        var stale = try #require(try desktop.store.transaction(lunch.id))
        stale.merchant = "Stale"
        try desktop.store.save(stale)
        let report = try await desktop.engine.pushWithoutPulling(group: home.group.id, level: .superadmin)

        #expect(report.conflicts == 1)
        #expect(try desktop.store.outboxCount(in: home.group.id) == 0)
        #expect(try desktop.store.conflicts(for: lunch.id).count == 1)
        #expect(try desktop.store.transaction(lunch.id)?.merchant == "Stale",
                "a send that skips the pull on purpose reads nothing back either")

        // The next pull starts over and puts back the server's copy.
        try await desktop.sync(home.group.id)
        #expect(try desktop.store.transaction(lunch.id)?.merchant == "Market!!!")
    }

    /// An edit the server refuses as older, of a record whose newest version
    /// this Mac had already marked as seen: the next pull starts over and the
    /// server's copy replaces this Mac's.
    @Test func anOlderRefusalBringsBackAVersionAlreadyMarkedSeen() async throws {
        let home = try await Household()
        let desktop = try await home.founderAgain()
        let lunch = home.spend(-1_250, by: home.founder.user)
        try home.founder.store.save(lunch)
        try await home.founder.sync(home.group.id)
        try await desktop.sync(home.group.id)

        // A copy here that differs from the version on file, with an edit
        // queued below it: how a clock that lagged once left things.
        var stale = try #require(try desktop.store.transaction(lunch.id))
        stale.merchant = "Stale"
        try desktop.store.save(stale, queue: false)
        try desktop.store.database.write { db in
            try OutboxRow(recordId: lunch.id.dbValue, recordType: "transaction", budgetGroupId: home.group.id.dbValue,
                          budgetId: home.budget.id.dbValue, lamport: 1, isDeleted: false, queuedAt: noon,
                          isReseal: false, editLamport: nil).insert(db)
        }
        let refused = try await desktop.engine.pushWithoutPulling(group: home.group.id, level: .superadmin)
        #expect(refused.conflicts == 1)
        try await desktop.sync(home.group.id)
        #expect(try desktop.store.transaction(lunch.id)?.merchant == "Market")
    }

    /// A pull that fails partway still moves the clock past every version it
    /// saved, so an edit made after it is newer than what it was made on.
    @Test func anEditAfterAPartialPullIsNewerThanWhatItSaw() async throws {
        let store = Store(database: try WellSpentDatabase.inMemory())
        let group = BudgetGroup(name: "G", createdAt: noon, updatedAt: noon)
        let budget = Budget(groupID: group.id, name: "B", limit: Money(minorUnits: 1), createdAt: noon,
                            updatedAt: noon)
        try store.save(group, queue: false)
        try store.save(budget, queue: false)
        let spent = Transaction(budgetID: budget.id, groupID: group.id, date: noon, merchant: "Server",
                                amount: Money(minorUnits: -1), createdAt: noon, updatedAt: noon)
        let incoming = WireRecord(id: spent.id, type: .transaction, budgetID: budget.id, lamport: 50,
                                  clientID: DeviceID(), isDeleted: false, body: try body(spent),
                                  updatedBy: UserID(), serverSeq: 1)
        let engine = ReadableSyncEngine(store: store, transport: FailsAfterOnePage(first: incoming),
                                        clientID: DeviceID(), userID: UserID())
        await #expect(throws: URLError.self) { try await engine.pull(group: group.id) }
        var edited = try #require(try store.transaction(spent.id))
        edited.merchant = "Here"
        try store.save(edited)
        #expect((try store.queuedPush(spent.id)?.lamport ?? 0) > 50)
    }

    /// Refused for who sent it: the edit is kept as a conflict copy, and the
    /// next pull puts back the server's copy, which only this Mac had lost.
    @Test func anEditRefusedForWhoSentItIsUndoneByTheNextPull() async throws {
        let home = try await Household()
        let writer = try await home.member("writer@example.com", level: .write)
        let receipt = Receipt(groupID: home.group.id, budgetID: home.budget.id, filename: "till.jpg", byteCount: 1,
                              plaintextSHA256: Data([1]), capturedAt: noon, createdAt: noon, updatedAt: noon)
        try home.founder.store.save(receipt)
        try await home.founder.sync(home.group.id)
        try await writer.sync(home.group.id, level: .write)

        var renamed = try #require(try writer.store.receipt(receipt.id))
        renamed.filename = "not mine to rename.jpg"
        try writer.store.save(renamed)
        let refused = try await writer.sync(home.group.id, level: .write)
        #expect(refused.rejected == 1 && refused.conflicts == 1)
        #expect(try writer.store.outboxCount(in: home.group.id) == 0)

        try await writer.sync(home.group.id, level: .write)
        #expect(try writer.store.receipt(receipt.id)?.filename == "till.jpg")
    }

    /// A refused edit is kept as a conflict copy, and the server's copy comes
    /// back in the same round. It came back only at the next round, up to two
    /// minutes later, and meanwhile the refused edit was what showed.
    @Test func aRefusedEditIsReplacedByTheServersCopyInTheSameRound() async throws {
        let home = try await Household()
        let writer = try await home.member("writer@example.com", level: .write)
        let lunch = home.spend(-1_250, by: home.founder.user)
        try home.founder.store.save(lunch)
        try await home.founder.sync(home.group.id)
        try await writer.sync(home.group.id, level: .write)

        var renamed = try #require(try writer.store.transaction(lunch.id))
        renamed.merchant = "Not mine to rename"
        try writer.store.save(renamed)
        let refused = try await writer.sync(home.group.id, level: .write)

        #expect(refused.rejected == 1 && refused.conflicts == 1)
        #expect(try writer.store.transaction(lunch.id)?.merchant == "Market")
        #expect(try writer.store.conflicts(for: lunch.id).count == 1)
        #expect(try writer.store.outboxCount(in: home.group.id) == 0)
    }

    /// A row the server finds too far ahead of the group stays queued.
    @Test func aRowTooFarAheadStaysQueued() async throws {
        let home = try await Household()
        try home.founder.store.recordPull(group: home.group.id, serverSeq: 0,
                                          observedLamport: RecordEnvelope.lamportLead * 2)
        try home.founder.store.save(home.spend(-1, by: home.founder.user))
        let report = try await home.founder.sync(home.group.id)
        #expect(report.rejected == 1)
        #expect(try home.founder.store.outboxCount(in: home.group.id) == 1)
    }

    /// More than a page each way: every record goes up, and every one comes down.
    @Test func moreThanAPageGoesBothWays() async throws {
        let home = try await Household()
        for index in 0 ..< 450 {
            try home.founder.store.save(home.spend(-index - 1, by: home.founder.user, merchant: "Shop \(index)"))
        }
        let up = try await home.founder.sync(home.group.id)
        #expect(up.pushed == 450)
        #expect(try home.founder.store.outboxCount(in: home.group.id) == 0)

        let desktop = try await home.founderAgain()
        let down = try await desktop.sync(home.group.id)
        #expect(down.pulled == 452)
        #expect(try desktop.store.transactions(in: home.budget.id).count == 450)
    }
}

@Suite("Syncing extension records and repeats")
struct ExtensionRecordSyncTests {
    private func house(_ home: Household, body: String = #"{"percent":100}"#) -> ExtensionSetting {
        ExtensionSetting(groupID: home.group.id, extensionID: "test.extension", kind: "house", sourceKey: "listing-1",
                         body: body, updatedAt: noon)
    }

    @Test func aRecordReachesAMemberWithItsBodyUntouched() async throws {
        let home = try await Household()
        let record = house(home)
        try home.founder.store.save(record)
        try await home.founder.sync(home.group.id)
        let member = try await home.member("member@example.com", level: .read)
        try await member.sync(home.group.id, level: .read)
        let held: ExtensionSetting? = try member.store.extensionRecord(record.id)
        #expect(held == record)
        let listed: [ExtensionSetting] = try member.store.extensionRecords(in: home.group.id, extensionID: "test.extension",
                                                                           kind: "house")
        #expect(listed == [record])
    }

    @Test func savingWithNothingChangedSendsNothing() async throws {
        let home = try await Household()
        let record = house(home)
        try home.founder.store.save(record)
        try await home.founder.sync(home.group.id)
        var again = record
        again.updatedAt = noon.addingTimeInterval(60)
        try home.founder.store.save(again)
        #expect(try home.founder.store.pendingPushes(in: home.group.id, following: nil, limit: 10).isEmpty)
    }

    @Test func aLosingVersionLeavesNoConflictCopy() async throws {
        let home = try await Household()
        let first = home.founder
        let second = try await home.founderAgain()
        try first.store.save(house(home, body: #"{"percent":50}"#))
        try second.store.save(house(home, body: #"{"percent":20}"#))
        let one = try await first.sync(home.group.id)
        let two = try await second.sync(home.group.id)
        let three = try await first.sync(home.group.id)
        #expect(one.conflicts + two.conflicts + three.conflicts == 0)
        #expect(try first.store.conflicts(for: house(home).id).isEmpty)
        #expect(try second.store.conflicts(for: house(home).id).isEmpty)
        let a: ExtensionSetting? = try first.store.extensionRecord(house(home).id)
        let b: ExtensionSetting? = try second.store.extensionRecord(house(home).id)
        #expect(a?.body == b?.body)
    }

    @Test func aMemberBelowManageIsHeldBackWithNoConflictCopy() async throws {
        let home = try await Household()
        let member = try await home.member("member@example.com", level: .write)
        try member.store.save(house(home))
        let report = try await member.sync(home.group.id, level: .write)
        #expect(report.conflicts == 0)
        #expect(try member.store.conflicts(for: house(home).id).isEmpty)
        #expect(try member.store.pendingPushes(in: home.group.id, following: nil, limit: 10).isEmpty)
    }

    @Test func aMarkAndARepeatSurviveAnotherMembersEdit() async throws {
        let home = try await Household()
        let link = RecordID(), rule = RecordID()
        var bill = home.spend(-900, by: home.founder.user)
        bill.id = .repeatMade(group: home.group.id, rule: rule, month: "2026-11")
        bill.extensionLink = link
        bill.repeatRuleID = rule
        bill.repeatMonth = "2026-11"
        try home.founder.store.save(bill)
        try await home.founder.sync(home.group.id)
        let manager = try await home.member("manager@example.com", level: .manage)
        try await manager.sync(home.group.id, level: .manage)
        var edit = try #require(try manager.store.transaction(bill.id))
        #expect(edit.extensionLink == link)
        edit.note = "Paid early"
        try manager.store.save(edit)
        try await manager.sync(home.group.id, level: .manage)
        try await home.founder.sync(home.group.id)
        let back = try #require(try home.founder.store.transaction(bill.id))
        #expect(back.note == "Paid early")
        #expect(back.extensionLink == link)
        #expect(back.repeatRuleID == rule)
        #expect(back.repeatMonth == "2026-11")
    }

    @Test func aRepeatRuleSyncsAndItsFirstSenderOwnsIt() async throws {
        let home = try await Household()
        let rule = RepeatRule(groupID: home.group.id, budgetID: home.budget.id, name: "Phone",
                              amount: Money(minorUnits: -4_000), day: 31, firstMonth: "2026-11",
                              createdAt: noon, updatedAt: noon)
        try home.founder.store.save(rule)
        try await home.founder.sync(home.group.id)
        #expect(try home.founder.store.repeatRule(rule.id)?.createdBy == home.founder.user)
        let member = try await home.member("member@example.com", level: .read)
        try await member.sync(home.group.id, level: .read)
        #expect(try member.store.repeatRules(in: home.group.id).map(\.createdBy) == [home.founder.user])
    }
}

@Suite("Transaction fields an older app does not know")
struct TransactionOptionalFieldTests {
    @Test func aPlainEntryWritesNoNewKeysAndAnOldBodyReadsBack() throws {
        let plain = Transaction(budgetID: BudgetID(), groupID: GroupID(), date: noon, merchant: "Market",
                                amount: Money(minorUnits: -100))
        let text = String(decoding: try RecordCodec.encoder.encode(plain), as: UTF8.self)
        for key in ["extensionLink", "repeatRuleID", "repeatMonth"] { #expect(!text.contains(key)) }
        let back = try RecordCodec.decoder.decode(Transaction.self, from: Data(text.utf8))
        #expect(back.extensionLink == nil && back.repeatRuleID == nil && back.repeatMonth == nil)
        #expect(back.idIsRight)
    }

    @Test func anIDIsRightOnlyForItsRuleAndMonth() {
        let group = GroupID(), rule = RecordID(), id = RecordID.repeatMade(group: group, rule: rule, month: "2026-11")
        func entry(_ id: RecordID, _ rule: RecordID?, _ month: String?, in home: GroupID? = nil) -> Transaction {
            Transaction(id: id, budgetID: BudgetID(), groupID: home ?? group, date: noon, merchant: "M",
                        amount: Money(minorUnits: -1), repeatRuleID: rule, repeatMonth: month)
        }
        #expect(entry(id, rule, "2026-11").idIsRight)
        #expect(!entry(id, rule, "2026-12").idIsRight)
        #expect(!entry(id, nil, nil).idIsRight)
        #expect(!entry(id, rule, nil).idIsRight)
        #expect(!entry(RecordID(), rule, "2026-11").idIsRight)
        // Knowing a rule's ID doesn't let anyone take its month in another group.
        #expect(!entry(id, rule, "2026-11", in: GroupID()).idIsRight)
    }

    @Test func namesDoNotCollide() {
        let group = GroupID()
        let house = RecordID.extensionRecord(group: group, extensionID: "e", kind: "a", sourceKey: "b/c")
        #expect(house.isNameBased)
        #expect(house != .extensionRecord(group: group, extensionID: "e", kind: "a/b", sourceKey: "c"))
        #expect(house != .extensionRecord(group: GroupID(), extensionID: "e", kind: "a", sourceKey: "b/c"))
        #expect(house == .extensionRecord(group: group, extensionID: "e", kind: "a", sourceKey: "b/c"))
    }
}

@Suite("Repeats made at Lamport 0")
struct MadeRepeatSyncTests {
    private func rule(_ home: Household, owner: UserID?) -> RepeatRule {
        RepeatRule(groupID: home.group.id, budgetID: home.budget.id, name: "Phone", amount: Money(minorUnits: -8_500),
                   day: 14, firstMonth: "2026-11", createdBy: owner, createdAt: noon, updatedAt: noon)
    }

    @Test func aMadeBillIsTheSameBytesFromEveryDevice() throws {
        let group = GroupID(), budget = BudgetID(), id = RecordID()
        let rule = RepeatRule(id: id, groupID: group, budgetID: budget, name: "Phone", amount: Money(minorUnits: -8_500),
                              day: 14, firstMonth: "2026-11", createdAt: noon, updatedAt: noon)
        let one = try #require(rule.made(in: "2026-12")), two = try #require(rule.made(in: "2026-12"))
        #expect(one == two)
        #expect(one.idIsRight)
        #expect(one.createdAt == noon && one.updatedAt == noon)
    }

    // Scenario REPEAT-05
    @Test func twoDevicesMakeOneBillAndNeitherConflicts() async throws {
        let home = try await Household()
        let other = try await home.founderAgain()
        let rule = rule(home, owner: home.founder.user)
        try home.founder.store.save(rule)
        try await home.founder.sync(home.group.id)
        try await other.sync(home.group.id)
        let made = try #require(rule.made(in: "2026-12"))
        #expect(try home.founder.store.saveMade(made))
        #expect(try other.store.saveMade(made))
        let first = try await home.founder.sync(home.group.id)
        let second = try await other.sync(home.group.id)
        let third = try await home.founder.sync(home.group.id)
        #expect(first.rejected == 0 && first.conflicts == 0)
        #expect(second.conflicts == 0)
        #expect(third.conflicts == 0)
        #expect(try home.founder.store.outboxCount(in: home.group.id) == 0)
        #expect(try other.store.outboxCount(in: home.group.id) == 0)
        #expect(home.server.records(in: home.group.id).filter { $0.id == made.id }.count == 1)
        #expect(try home.founder.store.transaction(made.id) == other.store.transaction(made.id))
    }

    /// An offline device's made copy can't undo an edit made anywhere.
    @Test func aRealEditBeatsAMadeCopyAndNobodyGetsAConflict() async throws {
        let home = try await Household()
        let offline = try await home.founderAgain()
        let rule = rule(home, owner: home.founder.user)
        try home.founder.store.save(rule)
        try await home.founder.sync(home.group.id)
        try await offline.sync(home.group.id)
        var edited = try #require(rule.made(in: "2026-12"))
        #expect(try home.founder.store.saveMade(edited))
        edited.amount = Money(minorUnits: -9_200)
        try home.founder.store.save(edited)
        try await home.founder.sync(home.group.id)

        #expect(try offline.store.saveMade(try #require(rule.made(in: "2026-12"))))
        let report = try await offline.sync(home.group.id)
        #expect(report.conflicts == 0)
        #expect(try offline.store.transaction(edited.id)?.amount == Money(minorUnits: -9_200))
        #expect(try offline.store.outboxCount(in: home.group.id) == 0)
        #expect(try offline.store.conflicts(for: edited.id).isEmpty)
    }

    // Scenario REPEAT-09
    @Test func aDeletedMonthIsNeverMadeAgain() async throws {
        let home = try await Household()
        let rule = rule(home, owner: home.founder.user)
        let made = try #require(rule.made(in: "2026-12"))
        #expect(try home.founder.store.saveMade(made))
        #expect(try !home.founder.store.saveMade(made), "already held")
        try home.founder.store.trash(made)
        #expect(try !home.founder.store.saveMade(made), "a delete counts as made")
        let held = try home.founder.store.transaction(made.id)
        #expect(held?.isDeleted == true)
    }

    /// Someone else already stored this month's bill. A member's made copy goes
    /// quietly, with no conflict, and the owner's bill is what they end up with.
    @Test func aMadeBillTheServerWontTakeGoesQuietly() async throws {
        let home = try await Household()
        let member = try await home.member("member@example.com", level: .write)
        try await member.sync(home.group.id, level: .write)
        let made = try #require(rule(home, owner: home.founder.user).made(in: "2026-12"))
        #expect(try home.founder.store.saveMade(made))
        try await home.founder.sync(home.group.id)
        #expect(try member.store.saveMade(made))
        let report = try await member.sync(home.group.id, level: .write)
        #expect(report.conflicts == 0)
        #expect(try member.store.outboxCount(in: home.group.id) == 0)
        #expect(try member.store.conflicts(for: made.id).isEmpty)
        try await member.sync(home.group.id, level: .write)
        #expect(try member.store.transaction(made.id) != nil, "the owner's copy")
        #expect(home.server.records(in: home.group.id).filter { $0.id == made.id }.count == 1)
    }
}
