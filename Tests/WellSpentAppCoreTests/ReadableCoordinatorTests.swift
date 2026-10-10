import Testing
import Foundation
@testable import WellSpentAppCore
import WellSpentCrypto
import WellSpentKeyStore
import WellSpentModel
import WellSpentStore
import WellSpentSync

/// One device of one person: a database, a key store, and a coordinator on
/// a shared in-memory server.
@MainActor
private struct Device {
    let store: Store
    let keys = InMemoryKeyStore()
    let transport: StubReadableTransport
    let sync: SyncCoordinator
    let model: AppModel

    init(on server: InMemoryReadableServer) throws {
        let store = Store(database: try WellSpentDatabase.inMemory())
        let transport = StubReadableTransport(server: server)
        self.store = store
        self.transport = transport
        sync = SyncCoordinator(store: store, keyStore: keys, defaults: isolatedDefaults(),
                               makeTransport: { _ in transport })
        model = AppModel(store: store)
    }
}

@Suite("Readable sync coordinator", .serialized)
@MainActor
struct ReadableCoordinatorTests {
    /// A group made here goes up with the key its statement lines were
    /// fingerprinted with, so lines imported before it went up still match.
    @Test func aGroupMadeHereGoesUpWithItsImportKey() async throws {
        let server = InMemoryReadableServer()
        let mac = try Device(on: server)
        try await mac.sync.signUp(email: "robin@example.com", password: "a-long-password")
        mac.model.addGroup(named: "Household")
        let group = try #require(mac.model.groups.first)
        let key = try mac.store.localKey(for: .group(group.id)).rawBytes

        await mac.sync.syncAll()
        #expect(mac.sync.state == .signedIn(email: "robin@example.com"))
        #expect(server.importKey(of: group.id) == key)
        #expect(try mac.store.importKey(for: group.id) == key)
        #expect(try mac.store.serverGroup(group.id)?.movedAt != nil)
        #expect(mac.sync.mayManageBudgets(in: group.id))
        #expect(mac.sync.deleteReach(of: group.id) == .justYou)
    }

    /// Signed out by the server, even in a sync nobody asked for: the device
    /// says why, keeps its budgets, and forgets the session.
    @Test func aSessionEndedElsewhereSignsThisDeviceOutWithAReason() async throws {
        let server = InMemoryReadableServer()
        let mac = try Device(on: server)
        try await mac.sync.signUp(email: "robin@example.com", password: "a-long-password")
        mac.model.addGroup(named: "Household")
        await mac.sync.syncAll()
        let me = try #require(mac.sync.userID)

        server.endSessions(of: me)
        await mac.sync.syncAll(quietly: true)
        #expect(mac.sync.account == nil)
        #expect(mac.sync.state == .failed(SyncCoordinator.sessionEndedReason))
        #expect(mac.sync.signInPrompt == SyncCoordinator.SignInPrompt(email: "robin@example.com",
                                                                       reason: SyncCoordinator.sessionEndedReason))
        #expect(try mac.keys.load(.session) == nil)
        #expect(try mac.store.groups().map(\.name) == ["Household"], "nothing local is lost")

        try await mac.sync.signIn(email: "robin@example.com", password: "a-long-password")
        #expect(mac.sync.signInPrompt == nil)
    }

    /// A failure that is not about the session leaves the device signed in.
    @Test func aServerErrorDoesNotSignOut() async throws {
        let server = InMemoryReadableServer()
        let mac = try Device(on: server)
        try await mac.sync.signUp(email: "robin@example.com", password: "a-long-password")
        mac.transport.failSync = .http(status: 503, reason: "database unreachable")
        await mac.sync.syncAll()
        #expect(mac.sync.account == "robin@example.com")
        #expect(mac.sync.state == .failed(AccountWording.notAnswering))
    }

    /// A member at Add who deletes a shared group leaves it: they may not
    /// delete it for everyone. Here the delete is queued for everyone, as it
    /// is when a demotion has not reached this device yet. The dialog's own
    /// reach is tested in `ReadableSharingTests`.
    @Test func aMemberWhoDeletesASharedGroupLeavesIt() async throws {
        let server = InMemoryReadableServer()
        let founder = try Device(on: server)
        try await founder.sync.signUp(email: "founder@example.com", password: "a-long-password")
        founder.model.addGroup(named: "Household")
        let group = try #require(founder.model.groups.first)
        await founder.sync.syncAll()

        let partner = try Device(on: server)
        server.seedAccount(email: "partner@example.com", password: "a-long-password", verified: true)
        try await partner.sync.signIn(email: "partner@example.com", password: "a-long-password")
        let invite = try await founder.transport.createInvite(group: group.id, level: .write, history: .all, days: nil)
        _ = try await partner.transport.acceptInvite(token: invite.token)
        await partner.sync.syncAll()
        await founder.sync.syncAll()
        #expect(try partner.store.group(group.id)?.name == "Household")
        #expect(partner.sync.deleteReach(of: group.id) == .thisMacOnly)
        #expect(!partner.sync.mayManageBudgets(in: group.id))

        partner.model.deleteGroup(group.id, reach: .everyone)
        await partner.sync.syncAll()
        #expect(partner.sync.state == .signedIn(email: "partner@example.com"))
        #expect(try await founder.transport.members(of: group.id).count == 1, "the partner left")
        await founder.sync.syncAll()
        #expect(try founder.store.group(group.id)?.isDeleted == false, "the group stays for the founder")
    }

    /// Removed from a group, a member's device hides it.
    @Test func aRemovedMembersDeviceHidesTheGroup() async throws {
        let server = InMemoryReadableServer()
        let founder = try Device(on: server)
        try await founder.sync.signUp(email: "founder@example.com", password: "a-long-password")
        founder.model.addGroup(named: "Household")
        let group = try #require(founder.model.groups.first)
        await founder.sync.syncAll()

        let partner = try Device(on: server)
        server.seedAccount(email: "partner@example.com", password: "a-long-password", verified: true)
        try await partner.sync.signIn(email: "partner@example.com", password: "a-long-password")
        let invite = try await founder.transport.createInvite(group: group.id, level: .write, history: .all, days: nil)
        _ = try await partner.transport.acceptInvite(token: invite.token)
        await partner.sync.syncAll()
        let partnerID = try #require(partner.sync.userID)

        try await founder.transport.remove(partnerID, from: group.id)
        await partner.sync.syncAll()
        #expect(try partner.store.group(group.id)?.isDeleted == true)
        #expect(try partner.store.serverGroup(group.id)?.removedAt != nil, "what it knew is kept")

        // Added back: the group comes back too.
        let again = try await founder.transport.createInvite(group: group.id, level: .write, history: .all, days: nil)
        _ = try await partner.transport.acceptInvite(token: again.token)
        await partner.sync.syncAll()
        #expect(try partner.store.group(group.id)?.isDeleted == false)
        #expect(try partner.store.group(group.id)?.name == "Household")
    }

    /// A group this account founded, missing from one listing (a server
    /// restored from an older backup, say), is neither hidden nor deleted:
    /// nobody can remove a founder, so the app says something is wrong.
    @Test func aFoundersGroupMissingFromOneListingIsLeftAlone() async throws {
        let server = InMemoryReadableServer()
        let mac = try Device(on: server)
        try await mac.sync.signUp(email: "robin@example.com", password: "a-long-password")
        mac.model.addGroup(named: "Household")
        let group = try #require(mac.model.groups.first)
        await mac.sync.syncAll()

        mac.transport.leaveOutOfNextListing = [group.id]
        await mac.sync.syncAll()
        #expect(mac.sync.state == .failed(SyncCoordinator.missingOnServerReason))
        #expect(mac.sync.missingOnServer == [group.id])
        #expect(try mac.store.group(group.id)?.isDeleted == false, "not hidden")

        for _ in 0 ..< 3 { await mac.sync.syncAll() }
        #expect(mac.sync.state == .signedIn(email: "robin@example.com"))
        #expect(server.records(in: group.id).first { $0.id.uuid == group.id.uuid }?.isDeleted == false,
                "nothing deleted it for everyone")
    }

    /// The reply to a group's first send is lost: the next round finds it on
    /// the server, notes it there, and it can be shared. Its import key is
    /// the one this Mac's imports use.
    @Test func aLostReplyToAGroupsFirstSendIsRecovered() async throws {
        let server = InMemoryReadableServer()
        let mac = try Device(on: server)
        try await mac.sync.signUp(email: "robin@example.com", password: "a-long-password")
        mac.model.addGroup(named: "Household")
        let group = try #require(mac.model.groups.first)
        mac.transport.loseNextCreateReply = true
        await mac.sync.syncAll()
        guard case .failed = mac.sync.state else { Issue.record("the lost reply should show"); return }
        let key = try #require(try mac.store.oldestGroupKey(group.id))
        #expect(server.importKey(of: group.id) == key, "the key went with the first send")

        await mac.sync.syncAll()
        #expect(try mac.store.serverGroup(group.id)?.movedAt != nil)
        _ = try await mac.sync.share(group: group.id, groupName: "Household", level: .write,
                                     historyAccess: .all, myName: "Robin")
    }

    /// Signed out, or in as someone else, while a sync waits on the network:
    /// the round stops, and never acts on the first account's list as the
    /// second account.
    @Test func aSyncThatOutlivesItsSessionLeavesTheNewStateAlone() async throws {
        let server = InMemoryReadableServer()
        let mac = try Device(on: server)
        try await mac.sync.signUp(email: "robin@example.com", password: "a-long-password")
        let sync = mac.sync
        mac.transport.whileListing = { await sync.signOut() }
        await mac.sync.syncAll()
        #expect(mac.sync.state == .signedOut)
        #expect(mac.sync.signInPrompt == nil, "a deliberate sign-out gives no reason to sign in")

        mac.transport.whileListing = nil
        try await mac.sync.signIn(email: "robin@example.com", password: "a-long-password")
        mac.model.addGroup(named: "Robin's")
        await mac.sync.syncAll()
        server.seedAccount(email: "leslie@example.com", password: "a-long-password")
        mac.transport.whileListing = {
            await sync.signOut()
            try? await sync.signIn(email: "leslie@example.com", password: "a-long-password")
        }
        await mac.sync.syncAll()
        #expect(mac.sync.state == .signedIn(email: "leslie@example.com"),
                "Robin's groups were not synced as Leslie")
    }

    /// Any call that finds the session ended signs the device out, not only a sync.
    @Test func aSharingCallThatFindsTheSessionEndedSignsOut() async throws {
        let server = InMemoryReadableServer()
        let mac = try Device(on: server)
        try await mac.sync.signUp(email: "robin@example.com", password: "a-long-password")
        mac.model.addGroup(named: "Household")
        let group = try #require(mac.model.groups.first)
        await mac.sync.syncAll()
        server.endSessions(of: try #require(mac.sync.userID))
        await #expect(throws: (any Error).self) {
            _ = try await mac.sync.invites(in: group.id)
        }
        #expect(mac.sync.account == nil)
        #expect(mac.sync.signInPrompt?.reason == SyncCoordinator.sessionEndedReason)
    }

    /// Signing out everywhere while the server cannot be reached changes
    /// nothing: this device stays signed in, and can try again.
    @Test func aFailedSignOutEverywhereChangesNothing() async throws {
        let server = InMemoryReadableServer()
        let mac = try Device(on: server)
        try await mac.sync.signUp(email: "robin@example.com", password: "a-long-password")
        mac.transport.failSignOutEverywhere = URLError(.notConnectedToInternet)
        await #expect(throws: URLError.self) { try await mac.sync.signOutEverywhere() }
        await mac.sync.syncAll()
        #expect(mac.sync.isSignedIn)
        mac.transport.failSignOutEverywhere = nil
        try await mac.sync.signOutEverywhere()
        #expect(mac.sync.state == .signedOut)
    }

    /// A group from before the switch, on a device that has never held it,
    /// waits until its founder's device has moved it.
    @Test func aGroupWithNoKeyYetWaitsForItsFounder() async throws {
        let server = InMemoryReadableServer()
        let robin = server.seedAccount(email: "robin@example.com", password: "a-long-password")
        let group = GroupID()
        server.seedLegacyGroup(id: group, founder: robin)
        let desktop = try Device(on: server)
        try await desktop.sync.signIn(email: "robin@example.com", password: "a-long-password")
        await desktop.sync.syncAll()
        #expect(desktop.sync.waitingForFounder == [group])
        #expect(try desktop.store.group(group) == nil, "nothing is made here, even for its founder")
    }
}

/// What each group needs on a round, decided from this Mac and the server's list.
@Suite("Sync plan")
struct SyncPlanTests {
    private static let founder = UserID()

    private func listed(_ id: GroupID, key: Data = Data(repeating: 1, count: 32), level: AccessLevel = .superadmin,
                        deleted: Bool = false) -> ServerGroup {
        ServerGroup(id: id, founderID: Self.founder, level: level, importKey: key, historyFloor: 0, deleted: deleted)
    }

    @Test func groupsOnTheServerOnly() throws {
        let store = Store(database: try WellSpentDatabase.inMemory())
        let ready = GroupID(), waiting = GroupID(), deleted = GroupID()
        let actions = try SyncPlan.actions(store: store, listed: [
            listed(ready), listed(waiting, key: Data()), listed(deleted, deleted: true),
        ], me: Self.founder)
        #expect(actions == [.placeholder(listed(ready)), .waitForFounder(waiting)])
    }

    @Test func groupsHeldHere() throws {
        let store = Store(database: try WellSpentDatabase.inMemory())
        func held(deleted: Bool = false) throws -> GroupID {
            let group = BudgetGroup(name: "G", isDeleted: deleted)
            try store.save(group, queue: false)
            return group.id
        }
        let live = try held()
        func fromBefore() throws -> GroupID {
            let id = try held()
            try store.append(MembershipLogEntry(scope: .group(id), sequence: 0,
                                                previousHash: MembershipLogEntry.rootHash, action: .found,
                                                subjectUserID: UserID(), subjectKeys: nil, level: .superadmin,
                                                epochAfter: .initial, at: Date(), authorUserID: UserID(),
                                                deviceID: nil, devicePublicKey: nil, authorSignature: Data()),
                             in: id)
            return id
        }
        let mine = try fromBefore(), joined = try fromBefore(), joinedWaiting = try fromBefore()
        let other = UserID()
        let joinedListing = ServerGroup(id: joined, founderID: other, level: .write,
                                        importKey: Data(repeating: 2, count: 32), historyFloor: 0, deleted: false)
        let deleting = BudgetGroup(name: "D", isDeleted: true)
        try store.save(deleting)                                    // its delete queued
        let hiddenAndBack = try held(deleted: true)                 // removed, then added back
        try store.saveServerGroup(ServerGroupInfo(groupID: hiddenAndBack, founderID: UserID(), level: .write,
                                                  importKey: Data()))
        try store.markRemoved(hiddenAndBack)
        let hiddenWithEdits = try held(deleted: true)
        try store.saveServerGroup(ServerGroupInfo(groupID: hiddenWithEdits, founderID: UserID(), level: .write,
                                                  importKey: Data()))
        try store.markMoved(hiddenWithEdits)
        try store.save(Budget(groupID: hiddenWithEdits, name: "B", limit: Money(minorUnits: 1)))
        let removed = try held()
        try store.saveServerGroup(ServerGroupInfo(groupID: removed, founderID: UserID(), level: .write,
                                                  importKey: Data()))
        let newHere = try held()
        let mineButMissing = try held()
        try store.saveServerGroup(ServerGroupInfo(groupID: mineButMissing, founderID: Self.founder, level: .superadmin,
                                                  importKey: Data()))

        let actions = try SyncPlan.actions(store: store, listed: [
            listed(live, level: .write), listed(mine), joinedListing,
            ServerGroup(id: joinedWaiting, founderID: other, level: .write, importKey: Data(), historyFloor: 0,
                        deleted: false),
            listed(deleting.id), listed(hiddenAndBack), listed(hiddenWithEdits, level: .write),
        ], me: Self.founder)
        #expect(actions.contains(.sync(live, level: .write)))
        #expect(actions.contains(.moveAsCreator(mine, level: .superadmin)))
        #expect(actions.contains(.adopt(joinedListing)))
        #expect(actions.contains(.waitForFounder(joinedWaiting)))
        #expect(actions.contains(.sendDelete(deleting.id, level: .superadmin)))
        #expect(actions.contains(.rejoin(listed(hiddenAndBack))))
        #expect(actions.contains(.letGo(hiddenWithEdits, level: .write)))
        #expect(actions.contains(.removed(removed)))
        #expect(actions.contains(.create(newHere)))
        #expect(actions.contains(.missingOnServer(mineButMissing)))
        #expect(actions.count == 10)
    }

    /// A group deleted here is left only when this person asked to leave it,
    /// with a delete made on readable sync. Never by its founder, who cannot
    /// leave, nor once the server deleted it. One the sealed app hid on this
    /// Mac only asked nothing, so it stays hidden and joined.
    @Test func onlyAGroupThisPersonAskedToLeaveIsLeft() throws {
        let store = Store(database: try WellSpentDatabase.inMemory())
        let other = UserID()
        func hidden(askingToLeave: Bool = true) throws -> GroupID {
            let group = BudgetGroup(name: "G", isDeleted: true)
            try store.save(group, queue: false)
            try store.saveServerGroup(ServerGroupInfo(groupID: group.id, founderID: other, level: .write,
                                                      importKey: Data(repeating: 2, count: 32)))
            try store.markMoved(group.id)
            if askingToLeave { try store.requestLeave(group.id) }
            return group.id
        }
        let member = try hidden(), hiddenBefore = try hidden(askingToLeave: false)
        let founded = try hidden(), deletedThere = try hidden()
        func listing(_ id: GroupID, founder: UserID, deleted: Bool = false) -> ServerGroup {
            ServerGroup(id: id, founderID: founder, level: .write, importKey: Data(repeating: 2, count: 32),
                        historyFloor: 0, deleted: deleted)
        }

        let actions = try SyncPlan.actions(store: store, listed: [
            listing(member, founder: other), listing(hiddenBefore, founder: other),
            listing(founded, founder: Self.founder), listing(deletedThere, founder: other, deleted: true),
        ], me: Self.founder)
        #expect(actions == [.leave(member, level: .write)])

        try store.markRemoved(member)
        #expect(try !store.leaveRequested(member), "leaving ends the request")
    }

    /// Deleted here, and no longer listed because this person left it on
    /// another device: noted as removed, like a live one. Otherwise, listed
    /// again after a rejoin, it would be left a second time.
    @Test func aGroupDeletedHereAndNoLongerListedIsNotedAsRemoved() throws {
        let store = Store(database: try WellSpentDatabase.inMemory())
        let group = BudgetGroup(name: "G", isDeleted: true)
        try store.save(group, queue: false)
        try store.saveServerGroup(ServerGroupInfo(groupID: group.id, founderID: UserID(), level: .write,
                                                  importKey: Data(repeating: 2, count: 32)))
        try store.markMoved(group.id)
        try store.requestLeave(group.id)

        #expect(try SyncPlan.actions(store: store, listed: [], me: Self.founder) == [.removed(group.id)])
    }
}
