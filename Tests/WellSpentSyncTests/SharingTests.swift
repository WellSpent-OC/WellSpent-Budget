import Testing
import Foundation
import Crypto
@testable import WellSpentSync
import WellSpentCrypto
import WellSpentModel
import WellSpentStore

/// One person on one device, talking to a shared in-memory server.
private final class Person {
    let userID = UserID()
    let identity = IdentityKeyPair.generate()
    let device = DeviceKeyPair()
    let store: Store
    let keyRing: KeyRing
    let session: InMemorySession
    let engine: SyncEngine
    let sharing: Sharing

    init(server: InMemoryTransport) throws {
        store = Store(database: try WellSpentDatabase.inMemory())
        keyRing = KeyRing(store: store, identity: identity, userID: userID)
        session = server.session(for: userID, keys: identity.publicKeys)
        engine = SyncEngine(store: store, keyRing: keyRing, transport: session,
                            identity: identity, device: device, userID: userID)
        sharing = Sharing(store: store, keyRing: keyRing, transport: session,
                          identity: identity, device: device, userID: userID)
    }

    /// What the app does for a group made on this device: found it on the
    /// server and mint its keys.
    func found(_ group: GroupID, name: String, budgets: [Budget]) async throws {
        let founding = try MembershipLogEntry.signed(
            scope: .group(group), sequence: 0, previousHash: MembershipLogEntry.rootHash,
            action: .found, subjectUserID: userID, subjectKeys: identity.publicKeys,
            level: .superadmin, epochAfter: .initial,
            deviceID: device.id, devicePublicKey: device.publicKey,
            author: identity, authorUserID: userID)
        try await session.appendMembership(founding, group: group, wrappedKeys: [])
        try keyRing.remember(ScopedKey.generate(scope: .group(group), epoch: .initial))
        try store.save(BudgetGroup(id: group, name: name))
        for budget in budgets {
            try keyRing.remember(ScopedKey.generate(scope: .budget(budget.id), epoch: .initial))
            try store.save(budget)
        }
    }

    /// What the app does on every sync of a group.
    @discardableResult
    func sync(_ group: GroupID) async throws -> SyncReport {
        try await sharing.prepare(group: group)
        try await sharing.finishInvites(group: group)
        var report = try await engine.sync(group: group)
        if try await sharing.completeJoin(group: group) {
            report = try await engine.sync(group: group)
        }
        return report
    }

    func spend(_ merchant: String, in budget: Budget) throws -> Transaction {
        let transaction = Transaction(budgetID: budget.id, groupID: budget.groupID, date: Date(),
                                      merchant: merchant, amount: Money(minorUnits: -1000))
        try store.save(transaction)
        return transaction
    }
}

@Suite("Sharing a group")
struct SharingTests {
    let server = InMemoryTransport()
    let group = GroupID()

    private func household(_ robin: Person) async throws -> Budget {
        let groceries = Budget(groupID: group, name: "Groceries", limit: Money(minorUnits: 100_000))
        try await robin.found(group, name: "Household", budgets: [groceries])
        return groceries
    }

    @Test func inviteJoinFinishThenBothWaysAndNames() async throws {
        let robin = try Person(server: server), leslie = try Person(server: server)
        let groceries = try await household(robin)
        let his = try robin.spend("Hilltop", in: groceries)
        try await robin.sync(group)

        let link = try await robin.sharing.createInvite(
            group: group, groupName: "Household", level: .write, historyAccess: .all,
            inviterName: "Robin")
        #expect(link.url.hasPrefix("wellspent://join#"))
        #expect(InviteLink(parsing: "  \(link.url)\n") == link, "survives being pasted")

        // She answers. The group shows as waiting, under the link's name.
        let join = try await leslie.sharing.join(link, displayName: "Leslie")
        #expect(join.groupName == "Household")
        #expect(try leslie.store.group(group)?.name == "Household")
        #expect(try leslie.store.pendingJoins().count == 1)

        // His next sync adds her. The invite is used up.
        try await robin.sync(group)
        #expect(server.inviteCount == 0)

        // Her next sync brings everything in and ends the wait.
        try await leslie.sync(group)
        #expect(try leslie.store.pendingJoins().isEmpty)
        let received = try #require(try leslie.store.transaction(his.id))
        #expect(received.merchant == "Hilltop")
        #expect(received.createdBy == robin.userID)

        // She adds one; he gets it, with her as its owner, and her name.
        let hers = try leslie.spend("Costco", in: groceries)
        try await leslie.sync(group)
        try await robin.sync(group)
        #expect(try robin.store.transaction(hers.id)?.createdBy == leslie.userID)
        #expect(try robin.store.profiles(in: group).map(\.displayName) == ["Leslie"])
    }

    @Test func aBudgetAddedAfterSharingReachesEveryone() async throws {
        let robin = try Person(server: server), leslie = try Person(server: server)
        _ = try await household(robin)
        try await robin.sync(group)
        // Manage, because making a budget takes Manage.
        let link = try await robin.sharing.createInvite(
            group: group, groupName: "Household", level: .manage, historyAccess: .all,
            inviterName: "Robin")
        try await leslie.sharing.join(link, displayName: "Leslie")
        try await robin.sync(group)
        try await leslie.sync(group)

        // She makes a budget in the shared group and spends from it.
        let gas = Budget(groupID: group, name: "Gas", limit: Money(minorUnits: 20_000))
        try leslie.store.save(gas)
        let fillUp = try leslie.spend("Milepost", in: gas)
        let report = try await leslie.sync(group)
        #expect(report.rejected == 0)

        let his = try await robin.sync(group)
        #expect(his.undecryptable == 0, "he got the key she published")
        #expect(try robin.store.budget(gas.id)?.name == "Gas")
        #expect(try robin.store.transaction(fillUp.id)?.merchant == "Milepost")
    }

    @Test func fromNowOnHidesWhatCameBefore() async throws {
        let robin = try Person(server: server), partner = try Person(server: server)
        let groceries = try await household(robin)
        let before = try robin.spend("before", in: groceries)
        try await robin.sync(group)

        let link = try await robin.sharing.createInvite(
            group: group, groupName: "Household", level: .write, historyAccess: .fromNow,
            inviterName: "Robin")
        try await partner.sharing.join(link, displayName: "Jamie")
        try await robin.sync(group)

        let after = try robin.spend("after", in: groceries)
        try await robin.sync(group)

        try await partner.sync(group)
        #expect(try partner.store.transaction(before.id) == nil, "sealed under a key they never got")
        #expect(try partner.store.budget(groceries.id)?.name == "Groceries",
                "the budget itself is visible, re-sealed under the new key")
        #expect(try partner.store.transaction(after.id)?.merchant == "after")
    }

    /// A "from now on" invite queues the group and its budgets again, so they
    /// are sealed under the new key. Those rows hold no edit of their own.
    /// They used to outrank a newer edit pulled from another member in the
    /// same sync, and the push then sent the old text over it, on every Mac.
    /// The pulled edit now wins, and the re-seal sends it under the new key.
    @Test func aFromNowReSealKeepsAnotherMembersNewerEdit() async throws {
        let robin = try Person(server: server), leslie = try Person(server: server)
        let jamie = try Person(server: server)
        let groceries = try await household(robin)
        try await robin.sync(group)
        // A manager, because changing a budget takes Manage.
        let link = try await robin.sharing.createInvite(
            group: group, groupName: "Household", level: .manage, historyAccess: .all,
            inviterName: "Robin")
        try await leslie.sharing.join(link, displayName: "Leslie")
        try await robin.sync(group)
        try await leslie.sync(group)
        try await robin.sync(group)

        // She lowers the limit and sends it.
        var lowered = try #require(try leslie.store.budget(groceries.id))
        lowered.limit = Money(minorUnits: 40_000)
        try leslie.store.save(lowered)
        try await leslie.sync(group)

        // Jamie answers a "from now on" link. Robin's next sync adds him and
        // queues the re-seal, then pulls her change.
        let fromNow = try await robin.sharing.createInvite(
            group: group, groupName: "Household", level: .read, historyAccess: .fromNow,
            inviterName: "Robin")
        try await jamie.sharing.join(fromNow, displayName: "Jamie")
        try await robin.sync(group)
        try await leslie.sync(group)
        try await jamie.sync(group)

        for (name, person) in [("Robin", robin), ("Leslie", leslie), ("Jamie", jamie)] {
            #expect(try person.store.budget(groceries.id)?.limit.minorUnits == 40_000,
                    "\(name) has her change")
        }
    }

    /// The re-seal a member added "from now on" is owed goes out even when a
    /// newer version is pulled in the same sync, with or without an edit of
    /// his own queued under it. Over an edit, the two shared one row, and the
    /// edit losing dropped the row, re-seal and all, so Jamie could never read
    /// the budget. His edit is still kept as a conflict copy. Alone, the
    /// re-seal moves above the version pulled, or the server refuses it as
    /// older.
    @Test(arguments: [true, false])
    func aReSealOwedStillGoesOutWhenANewerVersionArrives(renamedFirst: Bool) async throws {
        let robin = try Person(server: server), leslie = try Person(server: server)
        let jamie = try Person(server: server)
        let groceries = try await household(robin)
        try await robin.sync(group)
        // A manager, because changing a budget takes Manage.
        let link = try await robin.sharing.createInvite(
            group: group, groupName: "Household", level: .manage, historyAccess: .all,
            inviterName: "Robin")
        try await leslie.sharing.join(link, displayName: "Leslie")
        try await robin.sync(group)
        try await leslie.sync(group)
        try await robin.sync(group)

        // She saves several changes, so her clock runs ahead of his, and
        // sends them.
        for merchant in ["a", "b", "c", "d", "e"] { _ = try leslie.spend(merchant, in: groceries) }
        var lowered = try #require(try leslie.store.budget(groceries.id))
        lowered.limit = Money(minorUnits: 40_000)
        try leslie.store.save(lowered)
        try await leslie.sync(group)

        if renamedFirst {
            var renamed = try #require(try robin.store.budget(groceries.id))
            renamed.name = "Food"
            try robin.store.save(renamed)
        }
        let fromNow = try await robin.sharing.createInvite(
            group: group, groupName: "Household", level: .read, historyAccess: .fromNow,
            inviterName: "Robin")
        try await jamie.sharing.join(fromNow, displayName: "Jamie")
        try await robin.sync(group)
        try await jamie.sync(group)

        #expect(try jamie.store.budget(groceries.id)?.limit.minorUnits == 40_000,
                "Jamie can read the budget, sealed under the new key")
        if renamedFirst {
            #expect(try robin.store.conflicts(for: RecordID(groceries.id.uuid))
                .contains { $0.payloadJSON.contains("Food") }, "his rename is kept")
        }
    }

    /// Removing a group from this Mac only leaves the rows queued before it.
    /// Joining again with a new link pulls the group from the start, and such
    /// a row used to outrank the server's copy: the record stayed deleted
    /// here, and the push sent her old edit, live, to everyone else. Joining
    /// again now drops those rows, so this Mac takes the server's copy.
    @Test func joiningAgainDropsRowsLeftFromARemovalHere() async throws {
        let robin = try Person(server: server), leslie = try Person(server: server)
        let groceries = try await household(robin)
        try await robin.sync(group)
        let link = try await robin.sharing.createInvite(
            group: group, groupName: "Household", level: .write, historyAccess: .all,
            inviterName: "Robin")
        try await leslie.sharing.join(link, displayName: "Leslie")
        try await robin.sync(group)
        try await leslie.sync(group)
        let hers = try leslie.spend("Costco", in: groceries)
        try await leslie.sync(group)
        try await robin.sync(group)

        // Offline, she edits hers several times, then removes the group from
        // this Mac only. That marks everything deleted here and queues nothing.
        for note in ["a", "b", "c", "d", "e"] {
            var edited = try #require(try leslie.store.transaction(hers.id))
            edited.note = note
            try leslie.store.save(edited)
        }
        for transaction in try leslie.store.transactions(in: groceries.id) {
            try leslie.store.trash(transaction, queue: false)
        }
        var budget = try #require(try leslie.store.budget(groceries.id))
        budget.isDeleted = true
        try leslie.store.save(budget, queue: false)
        var removed = try #require(try leslie.store.group(group))
        removed.isDeleted = true
        try leslie.store.save(removed, queue: false)

        // He changes hers meanwhile, at a lower Lamport value than her edits.
        var his = try #require(try robin.store.transaction(hers.id))
        his.merchant = "Costco Wholesale"
        try robin.store.save(his)
        try await robin.sync(group)
        #expect(try leslie.store.syncState(for: group).lamport > robin.store.syncState(for: group).lamport)

        // She joins again with a new link, before anything sent her leftovers.
        let again = try await robin.sharing.createInvite(
            group: group, groupName: "Household", level: .write, historyAccess: .all,
            inviterName: "Robin")
        try await leslie.sharing.join(again, displayName: "Leslie")
        try await robin.sync(group)
        try await leslie.sync(group)
        try await robin.sync(group)

        let mine = try #require(try leslie.store.transaction(hers.id))
        #expect(!mine.isDeleted, "the server's copy came back")
        #expect(mine.merchant == "Costco Wholesale")
        #expect(try robin.store.transaction(hers.id)?.merchant == "Costco Wholesale",
                "her old edit did not go out")
    }

    @Test func anAnswerNotSealedWithTheLinkIsRefused() async throws {
        let robin = try Person(server: server), mallory = try Person(server: server)
        _ = try await household(robin)
        try await robin.sync(group)
        let link = try await robin.sharing.createInvite(
            group: group, groupName: "Household", level: .write, historyAccess: .all,
            inviterName: "Robin")

        // The server, or anyone who learned the invite's hash, answers it without
        // the secret. Sealed with a different one, it cannot open.
        let realID = try InviteSecret(bytes: link.secret).id
        let lookup = try await mallory.session.lookupInvite(id: realID)
        let guess = InviteSecret()
        let forged = try InviteCrypto.sealAcceptance(
            InviteAcceptance(accepterUserID: mallory.userID, accepterKeys: mallory.identity.publicKeys,
                             displayName: "Leslie"),
            invite: lookup.invite(id: realID), secret: guess)
        try await mallory.session.acceptInvite(id: realID, sealed: forged)

        let added = try await robin.sharing.finishInvites(group: group)
        #expect(added.isEmpty)
        #expect(server.inviteCount == 0, "the spoiled invite is removed")
        let log = try await robin.session.membershipLog(group: group, since: 0)
        #expect(log.count == 1, "nobody was added")
    }

    @Test func anExpiredInviteIsCleanedUpAndAddsNobody() async throws {
        let robin = try Person(server: server)
        _ = try await household(robin)
        try await robin.sync(group)
        _ = try await robin.sharing.createInvite(
            group: group, groupName: "Household", level: .write, historyAccess: .all,
            inviterName: "Robin", now: Date().addingTimeInterval(-8 * 24 * 60 * 60))

        let added = try await robin.sharing.finishInvites(group: group)
        #expect(added.isEmpty)
        #expect(server.inviteCount == 0)
        #expect(try robin.store.sentInvites(in: group).isEmpty)
    }

    @Test func onlyManagersInviteAndOnlyAdminsMakeManagers() async throws {
        let robin = try Person(server: server), leslie = try Person(server: server)
        _ = try await household(robin)
        try await robin.sync(group)

        let link = try await robin.sharing.createInvite(
            group: group, groupName: "Household", level: .write, historyAccess: .all,
            inviterName: "Robin")
        try await leslie.sharing.join(link, displayName: "Leslie")
        try await robin.sync(group)
        try await leslie.sync(group)

        await #expect(throws: SharingError.notAllowed(needed: .manage)) {
            try await leslie.sharing.createInvite(
                group: group, groupName: "Household", level: .read, historyAccess: .all,
                inviterName: "Leslie")
        }
        #expect(Sharing.levelNeededToAdd(at: .read) == .manage)
        #expect(Sharing.levelNeededToAdd(at: .write) == .manage)
        #expect(Sharing.levelNeededToAdd(at: .manage) == .admin)
    }

    @Test func aLinkThatIsNotOursDoesNotParse() {
        #expect(InviteLink(parsing: "https://example.com/join#s=abc") == nil)
        #expect(InviteLink(parsing: "wellspent://join#s=tooshort") == nil)
        #expect(InviteLink(parsing: "") == nil)

        let link = InviteLink(secret: Data(repeating: 7, count: 32), groupName: "Side Business & Co",
                              inviterName: "Robin")
        #expect(InviteLink(parsing: link.url) == link, "names with symbols survive")
    }
}
