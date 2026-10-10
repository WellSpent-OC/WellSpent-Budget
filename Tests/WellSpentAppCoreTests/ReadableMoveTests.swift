import Testing
import Foundation
@testable import WellSpentAppCore
@testable import WellSpentStore
import WellSpentCrypto
import WellSpentKeyStore
import WellSpentModel
import WellSpentSync

/// Whole seconds, as the record codec sends dates.
private let noon = Date(timeIntervalSince1970: 1_790_000_000)

/// A device as the sealed app left it: records saved and stamped with the
/// sealed device's versions, the group's signed history, its first key,
/// a sealed record set aside, and a re-seal waiting to go out.
@MainActor
private struct OldMac {
    let store: Store
    let keys: InMemoryKeyStore
    let device: DeviceKeyPair
    let transport: StubReadableTransport
    let sync: SyncCoordinator

    init(on server: InMemoryReadableServer) throws {
        let store = Store(database: try WellSpentDatabase.inMemory())
        let keys = InMemoryKeyStore()
        let device = DeviceKeyPair()
        // The sealed app's device key, whose ID the readable app keeps.
        try keys.storeDevice(device)
        let transport = StubReadableTransport(server: server)
        self.store = store
        self.keys = keys
        self.device = device
        self.transport = transport
        sync = SyncCoordinator(store: store, keyStore: keys, defaults: isolatedDefaults(),
                               makeTransport: { _ in transport })
    }

    /// Saves `records` as pulled or pushed by the sealed app, at Lamport 1, 2, ...
    func holdFromBefore(_ group: BudgetGroup, founder: UserID, records: [any SyncedRecord]) throws -> Data {
        try store.save(group, queue: false)
        var lamport: UInt64 = 1
        try store.setRecordVersion(RecordID(group.id.uuid), lamport: lamport, device: device.id, author: founder,
                                   serverSeq: lamport)
        for record in records {
            lamport += 1
            switch record {
            case let budget as Budget: try store.save(budget, queue: false)
            case let transaction as Transaction: try store.save(transaction, queue: false)
            case let statement as ImportedStatement: try store.save(statement, queue: false)
            case let receipt as Receipt: try store.save(receipt, queue: false)
            case let profile as MemberProfile: try store.save(profile, queue: false)
            default: Issue.record("unexpected record")
            }
            try store.setRecordVersion(RecordID(record.id.uuid), lamport: lamport, device: device.id,
                                       author: founder, serverSeq: lamport)
        }
        try store.recordPull(group: group.id, serverSeq: lamport, observedLamport: lamport)
        try store.append(MembershipLogEntry(scope: .group(group.id), sequence: 0,
                                            previousHash: MembershipLogEntry.rootHash, action: .found,
                                            subjectUserID: founder, subjectKeys: nil, level: .superadmin,
                                            epochAfter: .initial, at: noon, authorUserID: founder,
                                            deviceID: device.id, devicePublicKey: nil, authorSignature: Data()),
                         in: group.id)
        let key = ScopedKey.generate(scope: .group(group.id))
        try store.cache(key)
        try store.cache(ScopedKey.generate(scope: .group(group.id), epoch: Epoch(1)))
        // A record a newer sealed app made, set aside, and a re-seal owed.
        let envelope = try RecordCodec.sealData(
            Data("{}".utf8), recordID: RecordID(), recordType: RecordType(rawValue: "future"), groupID: group.id,
            budgetID: nil, scopeKey: key, lamport: lamport, author: founder, device: device,
            membershipSequence: 0)
        try store.deferEnvelope(envelope, serverSeq: lamport, unreadable: true)
        try store.queueReseal(of: group.id)
        return key.rawBytes
    }
}

@MainActor
private func household(founder: UserID) -> (BudgetGroup, Budget, [any SyncedRecord]) {
    let group = BudgetGroup(name: "Household", createdAt: noon, updatedAt: noon)
    let food = Budget(groupID: group.id, name: "Food", limit: Money(minorUnits: 60_000), createdAt: noon,
                      updatedAt: noon)
    let fuel = Budget(groupID: group.id, name: "Fuel", limit: Money(minorUnits: 20_000), createdAt: noon,
                      updatedAt: noon)
    let records: [any SyncedRecord] = [
        food, fuel,
        Transaction(budgetID: food.id, groupID: group.id, date: noon, merchant: "Market",
                    amount: Money(minorUnits: -4_200), createdAt: noon, updatedAt: noon),
        Transaction(budgetID: fuel.id, groupID: group.id, date: noon, merchant: "Shell",
                    amount: Money(minorUnits: -5_100), source: .statement, importFingerprint: "LINE-1",
                    createdBy: founder, createdAt: noon, updatedAt: noon),
        ImportedStatement(groupID: group.id, filename: "september.csv", format: "csv", importedAt: noon,
                          rowCount: 1, addedCount: 1, createdAt: noon, updatedAt: noon),
        Receipt(groupID: group.id, budgetID: food.id, filename: "till.jpg", byteCount: 1,
                plaintextSHA256: Data([1]), capturedAt: noon, createdAt: noon, updatedAt: noon),
        MemberProfile(groupID: group.id, userID: founder, displayName: "Robin", updatedAt: noon),
    ]
    return (group, food, records)
}

@Suite("The one-time move", .serialized)
@MainActor
struct ReadableMoveTests {
    /// The founder's Mac sends everything up once, with the key its past
    /// imports used, and the check matches. A second device then signs in
    /// and finds the same totals. Running again changes nothing.
    @Test func theFoundersMacSendsEverythingUpOnceAndChecksIt() async throws {
        let server = InMemoryReadableServer()
        let robin = server.seedAccount(email: "robin@example.com", password: "a-long-password")
        let mac = try OldMac(on: server)
        let (group, _, records) = household(founder: robin)
        let oldKey = try mac.holdFromBefore(group, founder: robin, records: records)
        server.seedLegacyGroup(id: group.id, founder: robin, maxLamport: UInt64(records.count + 1))

        try await mac.sync.signIn(email: "robin@example.com", password: "a-long-password")
        await mac.sync.syncAll()
        #expect(mac.sync.state == .signedIn(email: "robin@example.com"))
        #expect(server.records(in: group.id).count == records.count + 1, "the group and every record")
        #expect(server.importKey(of: group.id) == oldKey)
        #expect(try mac.store.importKey(for: group.id) == oldKey, "past imports still match")
        #expect(try mac.store.deferredCount(in: group.id) == 0)
        #expect(try mac.store.outboxCount(in: group.id) == 0)
        let check = try #require(mac.sync.moveChecks[group.id])
        #expect(check.matches && check.importKeyMatched && check.attempts == 1)
        #expect(check.server == check.before)
        #expect(try mac.store.serverGroup(group.id)?.movedAt != nil)

        let seqs = server.records(in: group.id).map(\.serverSeq)
        let again = await mac.sync.syncAll()
        #expect(again.conflicts == 0)
        #expect(server.records(in: group.id).map(\.serverSeq) == seqs, "nothing new was stored")

        let desktop = try OldMac(on: server)
        try await desktop.sync.signIn(email: "robin@example.com", password: "a-long-password")
        await desktop.sync.syncAll()
        #expect(try desktop.store.groupTotals(in: group.id) == mac.store.groupTotals(in: group.id))
        #expect(try desktop.store.importKey(for: group.id) == oldKey)
    }

    /// Interrupted after sending, before checking: the next round sends the
    /// same records again, which the server takes as no-ops, and checks.
    @Test func anInterruptedMoveFinishesOnTheNextRound() async throws {
        let server = InMemoryReadableServer()
        let robin = server.seedAccount(email: "robin@example.com", password: "a-long-password")
        let mac = try OldMac(on: server)
        let (group, _, records) = household(founder: robin)
        _ = try mac.holdFromBefore(group, founder: robin, records: records)
        server.seedLegacyGroup(id: group.id, founder: robin, maxLamport: UInt64(records.count + 1))
        try await mac.sync.signIn(email: "robin@example.com", password: "a-long-password")

        // Half a move: the key given, everything queued and sent, no check saved.
        _ = try await mac.transport.createGroup(id: group.id, importKey: mac.store.oldestGroupKey(group.id))
        try mac.store.prepareResend(of: group.id, scope: .everything, me: robin)
        _ = try await mac.sync.engine().sync(group: group.id, level: .superadmin)
        let stored = server.records(in: group.id).count

        await mac.sync.syncAll()
        #expect(server.records(in: group.id).count == stored)
        #expect(mac.sync.moveChecks[group.id]?.matches == true)
        #expect(try mac.store.conflicts(for: RecordID(group.id.uuid)).isEmpty)
    }

    /// Signed in with another account than the one that made the group: the
    /// move stops, says why, and sends nothing.
    @Test func aMoveByAnotherAccountStopsAndSaysWhy() async throws {
        let server = InMemoryReadableServer()
        let robin = server.seedAccount(email: "robin@example.com", password: "a-long-password")
        let mac = try OldMac(on: server)
        let (group, _, records) = household(founder: UserID())
        _ = try mac.holdFromBefore(group, founder: UserID(), records: records)
        server.seedLegacyGroup(id: group.id, founder: robin)

        try await mac.sync.signIn(email: "robin@example.com", password: "a-long-password")
        await mac.sync.syncAll()
        #expect(mac.sync.state == .failed(SyncCoordinator.notYourGroupsReason))
        #expect(server.records(in: group.id).isEmpty)
        #expect(server.importKey(of: group.id) == nil)
        #expect(try mac.store.serverGroup(group.id)?.movedAt == nil)
    }

    /// A group joined before the switch waits for its founder. Once the
    /// founder has moved it, the member takes the founder's copy, with no
    /// conflicts, and sends only their own entries.
    @Test func aJoinedGroupWaitsThenSendsOnlyItsOwnEntries() async throws {
        let server = InMemoryReadableServer()
        let robin = server.seedAccount(email: "robin@example.com", password: "a-long-password")
        let leslie = server.seedAccount(email: "leslie@example.com", password: "a-long-password")
        let (group, food, records) = household(founder: robin)
        let lesliesOwn = Transaction(budgetID: food.id, groupID: group.id, date: noon, merchant: "Bakery",
                                     amount: Money(minorUnits: -800), createdBy: leslie, createdAt: noon,
                                     updatedAt: noon)
        let lesliesName = MemberProfile(groupID: group.id, userID: leslie, displayName: "Leslie", updatedAt: noon)
        let everything = records + [lesliesOwn, lesliesName]
        server.seedLegacyGroup(id: group.id, founder: robin, maxLamport: UInt64(everything.count + 1))
        server.seedMember(leslie, in: group.id, level: .write)

        let robinsMac = try OldMac(on: server)
        _ = try robinsMac.holdFromBefore(group, founder: robin, records: everything)
        let lesliesMac = try OldMac(on: server)
        // Her copies of Robin's records carry his device's versions, as
        // pulled. The sealed app wrote an entry's owner in as it arrived.
        let robinsDevice = robinsMac.device.id
        try lesliesMac.store.save(group, queue: false)
        for (index, record) in everything.enumerated() {
            switch record {
            case let budget as Budget: try lesliesMac.store.save(budget, queue: false)
            case var transaction as Transaction:
                transaction.createdBy = transaction.createdBy ?? robin
                try lesliesMac.store.save(transaction, queue: false)
            case let statement as ImportedStatement: try lesliesMac.store.save(statement, queue: false)
            case let receipt as Receipt: try lesliesMac.store.save(receipt, queue: false)
            case let profile as MemberProfile: try lesliesMac.store.save(profile, queue: false)
            default: break
            }
            let mineToo = record.id.uuid == lesliesOwn.id.uuid || record.id.uuid == lesliesName.id.uuid
            try lesliesMac.store.setRecordVersion(RecordID(record.id.uuid), lamport: UInt64(index + 2),
                                                  device: mineToo ? lesliesMac.device.id : robinsDevice,
                                                  author: mineToo ? leslie : robin, serverSeq: 0)
        }
        try lesliesMac.store.setRecordVersion(RecordID(group.id.uuid), lamport: 1, device: robinsDevice,
                                              author: robin, serverSeq: 0)
        try lesliesMac.store.append(MembershipLogEntry(scope: .group(group.id), sequence: 0,
                                                       previousHash: MembershipLogEntry.rootHash, action: .found,
                                                       subjectUserID: robin, subjectKeys: nil, level: .superadmin,
                                                       epochAfter: .initial, at: noon, authorUserID: robin,
                                                       deviceID: robinsDevice, devicePublicKey: nil,
                                                       authorSignature: Data()), in: group.id)

        try await lesliesMac.sync.signIn(email: "leslie@example.com", password: "a-long-password")
        await lesliesMac.sync.syncAll()
        #expect(lesliesMac.sync.waitingForFounder == [group.id])
        #expect(server.records(in: group.id).isEmpty, "nothing sent before the founder")

        try await robinsMac.sync.signIn(email: "robin@example.com", password: "a-long-password")
        await robinsMac.sync.syncAll()
        let robinsCheck = try #require(robinsMac.sync.moveChecks[group.id])
        #expect(robinsCheck.awaitingOwners == 2, "her entry and her name are hers to send")
        #expect(!server.records(in: group.id).contains { $0.id == lesliesOwn.id })

        let report = await lesliesMac.sync.syncAll()
        #expect(report.conflicts == 0)
        #expect(lesliesMac.sync.waitingForFounder.isEmpty)
        #expect(server.records(in: group.id).contains { $0.id == lesliesOwn.id })
        #expect(server.records(in: group.id).contains { $0.id == lesliesName.id })
        #expect(lesliesMac.sync.moveChecks[group.id]?.matches == true)
        #expect(try lesliesMac.store.serverGroup(group.id)?.movedAt != nil)

        // Robin's next round takes in her entries, and his totals now match hers.
        await robinsMac.sync.syncAll()
        #expect(try robinsMac.store.groupTotals(in: group.id) == lesliesMac.store.groupTotals(in: group.id))
    }

    /// An entry an old import filed in this group under another group's
    /// budget reaches no server. It stays here, the check leaves it out, and
    /// the report counts it.
    @Test func anEntryUnderAnotherGroupsBudgetStaysHereAndIsCounted() async throws {
        let server = InMemoryReadableServer()
        let robin = server.seedAccount(email: "robin@example.com", password: "a-long-password")
        let mac = try OldMac(on: server)
        let (group, _, records) = household(founder: robin)
        let business = BudgetGroup(name: "Business", createdAt: noon, updatedAt: noon)
        let office = Budget(groupID: business.id, name: "Office", limit: Money(minorUnits: 5_000), createdAt: noon,
                            updatedAt: noon)
        try mac.store.save(business, queue: false)
        try mac.store.save(office, queue: false)
        let misfiled = Transaction(budgetID: office.id, groupID: group.id, date: noon, merchant: "Printer",
                                   amount: Money(minorUnits: -1_500), createdBy: robin, createdAt: noon,
                                   updatedAt: noon)
        _ = try mac.holdFromBefore(group, founder: robin, records: records + [misfiled])
        server.seedLegacyGroup(id: group.id, founder: robin, maxLamport: UInt64(records.count + 2))

        try await mac.sync.signIn(email: "robin@example.com", password: "a-long-password")
        await mac.sync.syncAll()
        let check = try #require(mac.sync.moveChecks[group.id])
        #expect(check.matches)
        #expect(check.strandedEntries == 1)
        #expect(!server.records(in: group.id).contains { $0.id == misfiled.id })
        #expect(try mac.store.transaction(misfiled.id) != nil, "kept here")
    }

    /// A member removed before their own move, then added back after the
    /// founder's: the group shows again, and their own entries from before
    /// the switch still go up.
    @Test func aMemberRemovedBeforeTheirMoveAndAddedBackStillSendsTheirEntries() async throws {
        let server = InMemoryReadableServer()
        let robin = server.seedAccount(email: "robin@example.com", password: "a-long-password")
        let leslie = server.seedAccount(email: "leslie@example.com", password: "a-long-password", verified: true)
        let (group, food, records) = household(founder: robin)
        let lesliesOwn = Transaction(budgetID: food.id, groupID: group.id, date: noon, merchant: "Bakery",
                                     amount: Money(minorUnits: -800), createdBy: leslie, createdAt: noon,
                                     updatedAt: noon)
        server.seedLegacyGroup(id: group.id, founder: robin, maxLamport: UInt64(records.count + 2))
        server.seedMember(leslie, in: group.id, level: .write)
        let robinsMac = try OldMac(on: server)
        _ = try robinsMac.holdFromBefore(group, founder: robin, records: records)
        let lesliesMac = try OldMac(on: server)
        var hers = records
        for (index, record) in hers.enumerated() {
            if var transaction = record as? Transaction, transaction.createdBy == nil {
                transaction.createdBy = robin
                hers[index] = transaction
            }
        }
        _ = try lesliesMac.holdFromBefore(group, founder: robin, records: hers + [lesliesOwn])

        try await lesliesMac.sync.signIn(email: "leslie@example.com", password: "a-long-password")
        await lesliesMac.sync.syncAll()                                   // waits for Robin
        try await robinsMac.sync.signIn(email: "robin@example.com", password: "a-long-password")
        try await robinsMac.transport.remove(leslie, from: group.id)
        await lesliesMac.sync.syncAll()                                   // removed: hidden
        #expect(try lesliesMac.store.group(group.id)?.isDeleted == true)

        await robinsMac.sync.syncAll()                                    // Robin moves
        let invite = try await robinsMac.transport.createInvite(group: group.id, level: .write, history: .all,
                                                                days: nil)
        _ = try await lesliesMac.transport.acceptInvite(token: invite.token)
        await lesliesMac.sync.syncAll()                                   // back, and her move runs
        #expect(try lesliesMac.store.group(group.id)?.isDeleted == false)
        #expect(server.records(in: group.id).contains { $0.id == lesliesOwn.id }, "her entry went up")
        #expect(try lesliesMac.store.serverGroup(group.id)?.movedAt != nil)
    }

    /// A group deleted here before the switch sends only its delete.
    @Test func aGroupDeletedBeforeTheSwitchSendsOnlyItsDelete() async throws {
        let server = InMemoryReadableServer()
        let robin = server.seedAccount(email: "robin@example.com", password: "a-long-password")
        let mac = try OldMac(on: server)
        var (group, _, records) = household(founder: robin)
        _ = try mac.holdFromBefore(group, founder: robin, records: records)
        group.isDeleted = true
        try mac.store.save(group, queue: false)
        server.seedLegacyGroup(id: group.id, founder: robin, maxLamport: UInt64(records.count + 1))

        try await mac.sync.signIn(email: "robin@example.com", password: "a-long-password")
        await mac.sync.syncAll()
        #expect(server.records(in: group.id).map(\.id) == [RecordID(group.id.uuid)])
        #expect(server.records(in: group.id).first?.isDeleted == true)
        #expect(mac.sync.moveChecks[group.id]?.matches == true)
    }
}
