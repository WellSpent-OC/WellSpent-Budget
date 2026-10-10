import Testing
import Foundation
@testable import WellSpentAppCore
import WellSpentCrypto
import WellSpentKeyStore
import WellSpentModel
import WellSpentStore
import WellSpentSync

/// One person's device on a shared in-memory server.
@MainActor
private struct Person {
    let store: Store
    let transport: StubReadableTransport
    let sync: SyncCoordinator
    let model: AppModel

    init(_ email: String, on server: InMemoryReadableServer, confirmed: Bool = true) async throws {
        let store = Store(database: try WellSpentDatabase.inMemory())
        let transport = StubReadableTransport(server: server)
        self.store = store
        self.transport = transport
        sync = SyncCoordinator(store: store, keyStore: InMemoryKeyStore(), defaults: isolatedDefaults(),
                               makeTransport: { _ in transport })
        model = AppModel(store: store)
        try await sync.signUp(email: email, password: "a-long-password")
        if confirmed {
            try await transport.verifyEmail(code: try #require(server.lastCode(for: email, purpose: .verify)))
        }
    }

    func sees(_ group: GroupID) throws -> Bool { try store.group(group)?.isDeleted == false }
}

/// Another device of someone who has an account already: signed in, synced.
@MainActor
private func secondDevice(of email: String, on server: InMemoryReadableServer) async throws
    -> (store: Store, sync: SyncCoordinator, model: AppModel) {
    let store = Store(database: try WellSpentDatabase.inMemory())
    let transport = StubReadableTransport(server: server)
    let sync = SyncCoordinator(store: store, keyStore: InMemoryKeyStore(), defaults: isolatedDefaults(),
                               makeTransport: { _ in transport })
    try await sync.signIn(email: email, password: "a-long-password")
    await sync.syncAll()
    return (store, sync, AppModel(store: store))
}

@Suite("Sharing on readable sync", .serialized)
@MainActor
struct ReadableSharingTests {
    /// The whole round: Robin shares a group, Leslie joins with the link,
    /// sees Robin's budgets and his name, and Robin sees hers.
    @Test func aSharedGroupReachesThePersonWhoJoins() async throws {
        let server = InMemoryReadableServer()
        let robin = try await Person("robin@example.com", on: server)
        robin.model.addGroup(named: "Household")
        let group = try #require(robin.model.groups.first)
        robin.model.addBudget(named: "Groceries", limit: Money(minorUnits: 50_000), in: group.id)

        let link = try await robin.sync.share(group: group.id, groupName: group.name, level: .write,
                                              historyAccess: .all, myName: "Robin")
        #expect(link.groupName == "Household" && link.inviterName == "Robin")
        let pasted = try #require(InviteLink(parsing: link.url), "the link reads back as pasted")

        let leslie = try await Person("leslie@example.com", on: server)
        let joined = try await leslie.sync.join(pasted, myName: "Leslie")
        #expect(joined.groupID == group.id && joined.level == .write)
        #expect(try leslie.store.group(group.id)?.name == "Household")
        #expect(try leslie.store.budgets(in: group.id).map(\.name) == ["Groceries"])
        #expect(try leslie.store.profiles(in: group.id).map(\.displayName) == ["Robin", "Leslie"].sorted()
                || Set(try leslie.store.profiles(in: group.id).map(\.displayName)) == ["Robin", "Leslie"])
        #expect(!leslie.sync.mayManageBudgets(in: group.id))

        await robin.sync.syncAll()
        #expect(Set(try robin.store.profiles(in: group.id).map(\.displayName)) == ["Robin", "Leslie"])
        #expect(robin.sync.members(of: group.id).count == 2)
        #expect(robin.model.memberCount(in: group.id) == 2)
        #expect(robin.sync.deleteReach(of: group.id) == .everyone)
    }

    /// Joining needs a confirmed address. The app says so before asking the
    /// server, and the link still works once it is confirmed.
    @Test func joiningNeedsAConfirmedAddress() async throws {
        let server = InMemoryReadableServer()
        let robin = try await Person("robin@example.com", on: server)
        robin.model.addGroup(named: "Household")
        let group = try #require(robin.model.groups.first)
        let link = try await robin.sync.share(group: group.id, groupName: group.name, level: .read,
                                              historyAccess: .all, myName: "Robin")

        let leslie = try await Person("leslie@example.com", on: server, confirmed: false)
        await #expect(throws: SyncCoordinator.Failure.emailNotConfirmed) {
            try await leslie.sync.join(link, myName: "Leslie")
        }
        #expect(leslie.sync.state == .failed("Confirm your email address first, then try again."))
        try await leslie.transport.verifyEmail(code: try #require(server.lastCode(for: "leslie@example.com",
                                                                                   purpose: .verify)))
        try await leslie.sync.join(link, myName: "Leslie")
        #expect(try leslie.sees(group.id))
    }

    /// A link used twice, or cancelled, says so in words.
    @Test func aUsedOrCancelledLinkSaysWhy() async throws {
        let server = InMemoryReadableServer()
        let robin = try await Person("robin@example.com", on: server)
        robin.model.addGroup(named: "Household")
        let group = try #require(robin.model.groups.first)
        let link = try await robin.sync.share(group: group.id, groupName: group.name, level: .write,
                                              historyAccess: .all, myName: "Robin")
        let leslie = try await Person("leslie@example.com", on: server)
        try await leslie.sync.join(link, myName: "Leslie")
        let sam = try await Person("sam@example.com", on: server)
        await #expect(throws: SyncCoordinator.Failure.self) { try await sam.sync.join(link, myName: "Sam") }
        guard case .failed(let used) = sam.sync.state else { Issue.record("no reason shown"); return }
        #expect(used == "That invite has already been accepted.")

        let second = try await robin.sync.share(group: group.id, groupName: group.name, level: .write,
                                                historyAccess: .all, myName: "Robin")
        let open = try await robin.sync.invites(in: group.id)
        #expect(open.count == 1)
        try await robin.sync.cancelInvite(try #require(open.first).id, in: group.id)
        await #expect(throws: SyncCoordinator.Failure.self) { try await sam.sync.join(second, myName: "Sam") }
        #expect(sam.sync.state == .failed(SyncCoordinator.inviteProblem(404)))
    }

    /// Only someone who may give a level can invite at it, and the reason is
    /// in words.
    @Test func aWriterCannotInvite() async throws {
        let server = InMemoryReadableServer()
        let robin = try await Person("robin@example.com", on: server)
        robin.model.addGroup(named: "Household")
        let group = try #require(robin.model.groups.first)
        let link = try await robin.sync.share(group: group.id, groupName: group.name, level: .write,
                                              historyAccess: .all, myName: "Robin")
        let leslie = try await Person("leslie@example.com", on: server)
        try await leslie.sync.join(link, myName: "Leslie")
        await #expect(throws: SyncCoordinator.Failure.self) {
            _ = try await leslie.sync.share(group: group.id, groupName: group.name, level: .read,
                                            historyAccess: .all, myName: "Leslie")
        }
        #expect(leslie.sync.state == .failed("Only a manager or admin can invite people to this group."))
    }

    /// Leaving hides the group here and takes this person out on the server.
    /// A new link brings it back, whole.
    @Test func leavingAndComingBack() async throws {
        let server = InMemoryReadableServer()
        let robin = try await Person("robin@example.com", on: server)
        robin.model.addGroup(named: "Household")
        let group = try #require(robin.model.groups.first)
        robin.model.addBudget(named: "Groceries", limit: Money(minorUnits: 50_000), in: group.id)
        let first = try await robin.sync.share(group: group.id, groupName: group.name, level: .write,
                                               historyAccess: .all, myName: "Robin")
        let leslie = try await Person("leslie@example.com", on: server)
        try await leslie.sync.join(first, myName: "Leslie")

        try await leslie.sync.leave(group.id)
        #expect(try !leslie.sees(group.id))
        await robin.sync.syncAll()
        #expect(robin.sync.members(of: group.id).count == 1)
        await leslie.sync.syncAll()
        #expect(try !leslie.sees(group.id), "it stays hidden")

        // Changed while she was away.
        var renamed = try #require(try robin.store.budgets(in: group.id).first)
        renamed.name = "Food"
        try robin.store.save(renamed)
        await robin.sync.syncAll()

        let again = try await robin.sync.share(group: group.id, groupName: group.name, level: .write,
                                               historyAccess: .all, myName: "Robin")
        try await leslie.sync.join(again, myName: "Leslie")
        #expect(try leslie.sees(group.id))
        #expect(try leslie.store.budgets(in: group.id).map(\.name) == ["Food"], "taken in from the start")

        // Removed a second time: hidden again, not left on screen.
        try await robin.sync.remove(try #require(leslie.sync.userID), from: group.id)
        await leslie.sync.syncAll()
        #expect(try !leslie.sees(group.id), "removed again, hidden again")
    }

    /// A member below admin deletes a shared group, through the reach the
    /// delete dialog uses. What she saved before the delete still reaches
    /// Robin, none of the group is deleted for him, and she leaves it, on her
    /// other device too. A new link brings it back. Hidden but kept as a
    /// member, she could never come back: the server refuses an invite to
    /// someone already in the group.
    @Test func aMemberWhoDeletesASharedGroupLeavesItAndANewLinkBringsItBack() async throws {
        let server = InMemoryReadableServer()
        let robin = try await Person("robin@example.com", on: server)
        robin.model.addGroup(named: "Household")
        let group = try #require(robin.model.groups.first)
        let groceries = try #require(robin.model.addBudget(named: "Groceries", limit: Money(minorUnits: 50_000),
                                                           in: group.id))
        let first = try await robin.sync.share(group: group.id, groupName: group.name, level: .write,
                                               historyAccess: .all, myName: "Robin")
        let leslie = try await Person("leslie@example.com", on: server)
        try await leslie.sync.join(first, myName: "Leslie")
        await robin.sync.syncAll()
        await leslie.sync.syncAll()

        let laptopStore = Store(database: try WellSpentDatabase.inMemory())
        let laptopTransport = StubReadableTransport(server: server)
        let laptop = SyncCoordinator(store: laptopStore, keyStore: InMemoryKeyStore(), defaults: isolatedDefaults(),
                                     makeTransport: { _ in laptopTransport })
        try await laptop.signIn(email: "leslie@example.com", password: "a-long-password")
        await laptop.syncAll()
        #expect(try laptopStore.group(group.id)?.isDeleted == false, "her laptop has it")

        // Saved, not synced yet, then the delete.
        leslie.model.reload()
        leslie.model.selectedBudget = groceries
        leslie.model.addTransaction(merchant: "Costco", amount: Money(minorUnits: 9900), date: Date(), note: "")
        let reach = leslie.sync.deleteReach(of: group.id)
        #expect(reach == .thisMacOnly)
        leslie.model.deleteGroup(group.id, reach: reach)
        await leslie.sync.syncAll()

        #expect(leslie.sync.state == .signedIn(email: "leslie@example.com"))
        #expect(try !leslie.sees(group.id))
        #expect(try leslie.store.serverGroup(group.id)?.removedAt != nil, "she left")
        #expect(try leslie.store.outboxCount(in: group.id) == 0)
        await robin.sync.syncAll()
        #expect(robin.sync.members(of: group.id).count == 1)
        #expect(try robin.store.budgets(in: group.id).map(\.name) == ["Groceries"], "nothing deleted for him")
        #expect(try robin.store.transactions(in: groceries).map(\.merchant) == ["Costco"],
                "what she saved before the delete reached him")

        await laptop.syncAll()
        #expect(try laptopStore.group(group.id)?.isDeleted == true, "gone from her laptop too")

        let again = try await robin.sync.share(group: group.id, groupName: group.name, level: .write,
                                               historyAccess: .all, myName: "Robin")
        try await leslie.sync.join(again, myName: "Leslie")
        #expect(try leslie.sees(group.id))
        #expect(try leslie.store.budgets(in: group.id).map(\.name) == ["Groceries"])
        #expect(try leslie.store.transactions(in: groceries).map(\.merchant) == ["Costco"])
    }

    /// Deleted on both of her devices before either syncs. The first leaves;
    /// the second finds the group gone and notes it. Rejoined with a new link
    /// on the first, the second shows it again rather than leaving it again.
    @Test func deletedOnTwoDevicesThenRejoinedStaysJoined() async throws {
        let server = InMemoryReadableServer()
        let robin = try await Person("robin@example.com", on: server)
        robin.model.addGroup(named: "Household")
        let group = try #require(robin.model.groups.first)
        let first = try await robin.sync.share(group: group.id, groupName: group.name, level: .write,
                                               historyAccess: .all, myName: "Robin")
        let leslie = try await Person("leslie@example.com", on: server)
        try await leslie.sync.join(first, myName: "Leslie")
        let laptop = try await secondDevice(of: "leslie@example.com", on: server)
        #expect(try laptop.store.group(group.id)?.isDeleted == false)

        leslie.model.deleteGroup(group.id, reach: leslie.sync.deleteReach(of: group.id))
        laptop.model.deleteGroup(group.id, reach: laptop.sync.deleteReach(of: group.id))
        await leslie.sync.syncAll()
        await laptop.sync.syncAll()
        #expect(laptop.sync.state == .signedIn(email: "leslie@example.com"))
        #expect(try laptop.store.serverGroup(group.id)?.removedAt != nil, "the laptop notes she left")

        let again = try await robin.sync.share(group: group.id, groupName: group.name, level: .write,
                                               historyAccess: .all, myName: "Robin")
        try await leslie.sync.join(again, myName: "Leslie")
        await laptop.sync.syncAll()
        await robin.sync.syncAll()
        #expect(robin.sync.members(of: group.id).count == 2, "the laptop did not leave again")
        #expect(try laptop.store.group(group.id)?.isDeleted == false, "and shows it")
        await leslie.sync.syncAll()
        #expect(try leslie.sees(group.id))
    }

    /// A group the sealed app hid on one Mac only, which kept her in it on
    /// the server. Readable sync leaves it as it is, joined, and a new link
    /// brings it back, though the server answers that she is already in it.
    @Test func aGroupHiddenBeforeTheSwitchStaysJoinedAndALinkBringsItBack() async throws {
        let server = InMemoryReadableServer()
        let robin = try await Person("robin@example.com", on: server)
        robin.model.addGroup(named: "Household")
        let group = try #require(robin.model.groups.first)
        robin.model.addBudget(named: "Groceries", limit: Money(minorUnits: 50_000), in: group.id)
        let first = try await robin.sync.share(group: group.id, groupName: group.name, level: .write,
                                               historyAccess: .all, myName: "Robin")
        let leslie = try await Person("leslie@example.com", on: server)
        try await leslie.sync.join(first, myName: "Leslie")

        // As the sealed app's delete left it: hidden here, nothing queued,
        // no request to leave.
        var hidden = try #require(try leslie.store.group(group.id))
        hidden.isDeleted = true
        try leslie.store.save(hidden, queue: false)
        await leslie.sync.syncAll()
        await robin.sync.syncAll()
        #expect(robin.sync.members(of: group.id).count == 2, "not left")
        #expect(try !leslie.sees(group.id))

        let again = try await robin.sync.share(group: group.id, groupName: group.name, level: .write,
                                               historyAccess: .all, myName: "Robin")
        try await leslie.sync.join(again, myName: "Leslie")
        #expect(try leslie.sees(group.id))
        #expect(try leslie.store.budgets(in: group.id).map(\.name) == ["Groceries"])
        #expect(try await robin.transport.invites(in: group.id).count == 1, "the new link is still unused")
    }

    /// Deleted, then joined again with a new link before any sync sent the
    /// leave. The server answers that she is still in it, so it is shown
    /// again, and the request to leave is dropped: the next sync keeps her in.
    /// Costco, saved before the delete and never sent, is hers to see again,
    /// not only everyone else's: sent after the pulls were forgotten, it came
    /// back as her own echo and stayed deleted on her Mac.
    @Test func joiningBeforeTheLeaveWentKeepsHerIn() async throws {
        let server = InMemoryReadableServer()
        let robin = try await Person("robin@example.com", on: server)
        robin.model.addGroup(named: "Household")
        let group = try #require(robin.model.groups.first)
        let groceries = try #require(robin.model.addBudget(named: "Groceries", limit: Money(minorUnits: 50_000),
                                                           in: group.id))
        let first = try await robin.sync.share(group: group.id, groupName: group.name, level: .write,
                                               historyAccess: .all, myName: "Robin")
        let leslie = try await Person("leslie@example.com", on: server)
        try await leslie.sync.join(first, myName: "Leslie")

        leslie.model.reload()
        leslie.model.selectedBudget = groceries
        leslie.model.addTransaction(merchant: "Costco", amount: Money(minorUnits: 9900), date: Date(), note: "")
        leslie.model.deleteGroup(group.id, reach: leslie.sync.deleteReach(of: group.id))
        #expect(try leslie.store.leaveRequested(group.id))
        let again = try await robin.sync.share(group: group.id, groupName: group.name, level: .write,
                                               historyAccess: .all, myName: "Robin")
        try await leslie.sync.join(again, myName: "Leslie")
        #expect(try leslie.sees(group.id))
        #expect(try !leslie.store.leaveRequested(group.id), "coming back ends the request")

        for _ in 0..<3 { await leslie.sync.syncAll() }
        await robin.sync.syncAll()
        #expect(robin.sync.members(of: group.id).count == 2)
        #expect(try leslie.sees(group.id))
        #expect(try leslie.store.transactions(in: groceries).map(\.merchant) == ["Costco"], "hers again")
        #expect(try robin.store.transactions(in: groceries).map(\.merchant) == ["Costco"])
    }

    /// The founder deletes a shared group for everyone. The group's delete and
    /// its budget and entry deletes go in one send, since the server refuses
    /// anything sent into a deleted group: Leslie's copy is deleted whole, and
    /// nothing comes back to Robin as a conflict.
    @Test func aDeleteForEveryoneReachesEveryMember() async throws {
        let server = InMemoryReadableServer()
        let robin = try await Person("robin@example.com", on: server)
        robin.model.addGroup(named: "Household")
        let group = try #require(robin.model.groups.first)
        let groceries = try #require(robin.model.addBudget(named: "Groceries", limit: Money(minorUnits: 50_000),
                                                           in: group.id))
        robin.model.reload()
        robin.model.selectedBudget = groceries
        robin.model.addTransaction(merchant: "Hilltop", amount: Money(minorUnits: 4200), date: Date(), note: "")
        let hilltop = try #require(try robin.store.transactions(in: groceries).first)
        let link = try await robin.sync.share(group: group.id, groupName: group.name, level: .write,
                                              historyAccess: .all, myName: "Robin")
        let leslie = try await Person("leslie@example.com", on: server)
        try await leslie.sync.join(link, myName: "Leslie")
        await robin.sync.syncAll()
        #expect(try leslie.store.transactions(in: groceries).map(\.merchant) == ["Hilltop"])

        let reach = robin.sync.deleteReach(of: group.id)
        #expect(reach == .everyone)
        robin.model.deleteGroup(group.id, reach: reach)
        await robin.sync.syncAll()
        #expect(robin.sync.state == .signedIn(email: "robin@example.com"))
        #expect(try robin.store.outboxCount(in: group.id) == 0)
        #expect(try robin.store.conflicts(for: hilltop.id).isEmpty, "nothing came back refused")
        #expect(try robin.store.conflicts(for: RecordID(groceries.uuid)).isEmpty)

        await leslie.sync.syncAll()
        #expect(try !leslie.sees(group.id))
        #expect(try leslie.store.budget(groceries)?.isDeleted == true, "her copy of the budget is deleted")
        #expect(try leslie.store.transaction(hilltop.id)?.isDeleted == true, "and its entries")
    }

    /// Her delete of the group for everyone is still waiting to go when she
    /// opens a new link to it. The server says she is in it, and it is not
    /// shown again here: the next sync would send that delete with the group
    /// showing. The next sync deletes it as she asked.
    @Test func aLinkDoesNotBringBackAGroupWhoseDeleteIsWaiting() async throws {
        let server = InMemoryReadableServer()
        let robin = try await Person("robin@example.com", on: server)
        robin.model.addGroup(named: "Household")
        let group = try #require(robin.model.groups.first)
        let link = try await robin.sync.share(group: group.id, groupName: group.name, level: .write,
                                              historyAccess: .all, myName: "Robin")
        let leslie = try await Person("leslie@example.com", on: server)
        try await leslie.sync.join(link, myName: "Leslie")
        try await robin.sync.setLevel(.admin, of: try #require(leslie.sync.userID), in: group.id)
        await leslie.sync.syncAll()

        leslie.model.deleteGroup(group.id, reach: leslie.sync.deleteReach(of: group.id))
        #expect(try leslie.store.groupDeleteIsQueued(group.id))
        let again = try await robin.sync.share(group: group.id, groupName: group.name, level: .write,
                                               historyAccess: .all, myName: "Robin")
        await #expect(throws: (any Error).self) { try await leslie.sync.join(again, myName: "Leslie") }
        #expect(try !leslie.sees(group.id))

        await leslie.sync.syncAll()
        await robin.sync.syncAll()
        #expect(try robin.store.group(group.id)?.isDeleted == true, "deleted for everyone, as she asked")
    }

    /// The founder changes and removes members; the removed member's device
    /// hides the group on its next sync.
    @Test func theFounderChangesAndRemovesMembers() async throws {
        let server = InMemoryReadableServer()
        let robin = try await Person("robin@example.com", on: server)
        robin.model.addGroup(named: "Household")
        let group = try #require(robin.model.groups.first)
        let link = try await robin.sync.share(group: group.id, groupName: group.name, level: .write,
                                              historyAccess: .all, myName: "Robin")
        let leslie = try await Person("leslie@example.com", on: server)
        try await leslie.sync.join(link, myName: "Leslie")
        let leslieID = try #require(leslie.sync.userID)
        await robin.sync.syncAll()

        try await robin.sync.setLevel(.manage, of: leslieID, in: group.id)
        #expect(robin.sync.members(of: group.id)[leslieID] == .manage)
        await leslie.sync.syncAll()
        #expect(leslie.sync.mayManageBudgets(in: group.id))

        try await robin.sync.remove(leslieID, from: group.id)
        #expect(robin.sync.members(of: group.id)[leslieID] == nil)
        await leslie.sync.syncAll()
        #expect(try !leslie.sees(group.id))
    }
}
