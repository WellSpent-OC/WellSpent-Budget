import Testing
import Foundation
@testable import WellSpentAppCore
import WellSpentCrypto
import WellSpentKeyStore
import WellSpentModel
import WellSpentStore
import WellSpentSync

/// One person's app: their own database and keys, on a shared server.
@MainActor
private struct App {
    let model: AppModel
    let sync: SyncCoordinator
    let transport: StubAccountTransport

    init(server: InMemoryTransport) throws {
        let store = Store(database: try WellSpentDatabase.inMemory())
        model = AppModel(store: store)
        let transport = StubAccountTransport(inner: server)
        self.transport = transport
        sync = SyncCoordinator(store: store, keyStore: InMemoryKeyStore(),
                               defaults: isolatedDefaults(), makeTransport: { _ in transport })
        let model = self.model
        sync.didSync = { model.reload() }
    }

    func sees(_ group: GroupID) -> Bool { model.groups.contains { $0.id == group } }
}

@Suite("Sharing, through the app", .serialized)
@MainActor
struct SharingFlowTests {

    @Test func shareJoinWaitFinishAndSeeEachOther() async throws {
        let server = InMemoryTransport()
        let robin = try App(server: server), leslie = try App(server: server)

        try await robin.sync.signUp(email: "robin@example.com", password: "a-long-password")
        let group = try #require(robin.model.addGroup(named: "Household"))
        let groceries = try #require(robin.model.addBudget(named: "Groceries",
                                                           limit: Money(minorUnits: 100_000), in: group))
        robin.model.addTransaction(merchant: "Hilltop", amount: Money(minorUnits: 4200),
                                   date: Date(), note: "")

        let link = try await robin.sync.share(group: group, groupName: "Household", level: .write,
                                              historyAccess: .all, myName: "Robin")

        // She joins and waits. Syncing while waiting is not an error.
        try await leslie.sync.signUp(email: "leslie@example.com", password: "a-long-password")
        try await leslie.sync.join(link, myName: "Leslie")
        #expect(leslie.sync.isWaitingToJoin(group))
        #expect(leslie.model.groups.map(\.name) == ["Household"])
        await leslie.sync.syncAll()
        #expect(leslie.sync.isSignedIn, "waiting is not a failure: \(leslie.sync.state)")
        #expect(leslie.sync.isWaitingToJoin(group))

        // His sync adds her; hers brings everything in.
        await robin.sync.syncAll()
        await leslie.sync.syncAll()
        #expect(!leslie.sync.isWaitingToJoin(group))
        #expect(leslie.model.summary(for: groceries)?.budget.name == "Groceries")
        leslie.model.selectedBudget = groceries
        #expect(leslie.model.transactions.map(\.merchant) == ["Hilltop"])
        #expect(leslie.model.isShared(group))
        #expect(leslie.model.addedBy(leslie.model.transactions[0], me: leslie.sync.userID) == "Robin")

        // She adds one. He sees it, and that it was her.
        leslie.model.addTransaction(merchant: "Costco", amount: Money(minorUnits: 9900),
                                     date: Date(), note: "")
        await leslie.sync.syncAll()
        await robin.sync.syncAll()
        robin.model.selectedBudget = groceries
        let costco = try #require(robin.model.transactions.first { $0.merchant == "Costco" })
        #expect(robin.model.addedBy(costco, me: robin.sync.userID) == "Leslie")
        let hilltop = try #require(robin.model.transactions.first { $0.merchant == "Hilltop" })
        #expect(robin.model.addedBy(hilltop, me: robin.sync.userID) == "You")
    }

    @Test func aUsedLinkSaysSoInWords() async throws {
        let server = InMemoryTransport()
        let robin = try App(server: server), leslie = try App(server: server)
        let mallory = try App(server: server)
        try await robin.sync.signUp(email: "robin@example.com", password: "a-long-password")
        let group = try #require(robin.model.addGroup(named: "Household"))
        let link = try await robin.sync.share(group: group, groupName: "Household", level: .read,
                                              historyAccess: .all, myName: "Robin")

        try await leslie.sync.signUp(email: "leslie@example.com", password: "a-long-password")
        try await leslie.sync.join(link, myName: "Leslie")

        try await mallory.sync.signUp(email: "m@example.com", password: "a-long-password")
        await #expect(throws: (any Error).self) { try await mallory.sync.join(link, myName: "M") }
        #expect(mallory.sync.failureMessage != nil)
        #expect(mallory.sync.pendingJoins.isEmpty)
    }

    @Test func theSheetsOnlyGoAheadWithWhatTheyNeed() {
        #expect(ShareSheet.canCreate(myName: "Robin", signedIn: true))
        #expect(!ShareSheet.canCreate(myName: " ", signedIn: true))
        #expect(!ShareSheet.canCreate(myName: "Robin", signedIn: false))

        let link = InviteLink(secret: Data(repeating: 1, count: 32), groupName: "Household",
                              inviterName: "Robin").url
        #expect(JoinSheet.canJoin(linkText: link, myName: "Leslie", signedIn: true))
        #expect(!JoinSheet.canJoin(linkText: "not a link", myName: "Leslie", signedIn: true))
        #expect(!JoinSheet.canJoin(linkText: link, myName: "", signedIn: true))
        #expect(!JoinSheet.canJoin(linkText: link, myName: "Leslie", signedIn: false))
    }

    @Test func theWaitingLineNamesWhoItIsWaitingOn() {
        let join = PendingJoin(groupID: GroupID(), groupName: "Household", inviterName: "Robin",
                               displayName: "Leslie", level: .write)
        #expect(SidebarView.waiting(for: join) == "Waiting for Robin to add you")
    }

    // MARK: - Deleting a shared group

    /// Robin's Household with one budget and one of his transactions, shared
    /// with Leslie at `level`, and joined.
    private func sharedHousehold(level: AccessLevel = .write) async throws
        -> (robin: App, leslie: App, group: GroupID, groceries: BudgetID) {
        let server = InMemoryTransport()
        let robin = try App(server: server), leslie = try App(server: server)
        try await robin.sync.signUp(email: "robin@example.com", password: "a-long-password")
        let group = try #require(robin.model.addGroup(named: "Household"))
        let groceries = try #require(robin.model.addBudget(named: "Groceries",
                                                           limit: Money(minorUnits: 100_000), in: group))
        robin.model.addTransaction(merchant: "Hilltop", amount: Money(minorUnits: 4200),
                                   date: Date(), note: "")
        let link = try await robin.sync.share(group: group, groupName: "Household", level: level,
                                              historyAccess: .all, myName: "Robin")
        try await leslie.sync.signUp(email: "leslie@example.com", password: "a-long-password")
        try await leslie.sync.join(link, myName: "Leslie")
        await robin.sync.syncAll()
        await leslie.sync.syncAll()
        #expect(leslie.sees(group), "joined: \(leslie.sync.state)")
        return (robin, leslie, group, groceries)
    }

    /// The blocker from the review of the first group delete. Deleting a group
    /// still waiting to join queued a delete on the placeholder. Once Robin's
    /// app added her, it went out against his real group and deleted it for
    /// everyone, while she still had it.
    @Test func decliningAWaitingGroupLeavesTheInvitersGroupAlone() async throws {
        let server = InMemoryTransport()
        let robin = try App(server: server), leslie = try App(server: server)
        try await robin.sync.signUp(email: "robin@example.com", password: "a-long-password")
        let group = try #require(robin.model.addGroup(named: "Household"))
        let groceries = try #require(robin.model.addBudget(named: "Groceries",
                                                           limit: Money(minorUnits: 100_000), in: group))
        let link = try await robin.sync.share(group: group, groupName: "Household", level: .write,
                                              historyAccess: .all, myName: "Robin")

        try await leslie.sync.signUp(email: "leslie@example.com", password: "a-long-password")
        try await leslie.sync.join(link, myName: "Leslie")
        // Renamed first, so her delete would outrank his record whatever the
        // device IDs.
        leslie.model.renameGroup(group, to: "Ours")
        leslie.model.deleteGroup(group, reach: leslie.sync.deleteReach(of: group))
        #expect(try leslie.model.store.outboxCount(in: group) == 0, "a declined invite queues nothing")

        // His app still adds her, because her answer is already on the server.
        await leslie.sync.syncAll()
        await robin.sync.syncAll()
        await leslie.sync.syncAll()
        await leslie.sync.syncAll()
        await robin.sync.syncAll()

        #expect(robin.sees(group), "his group is untouched")
        #expect(robin.model.summary(for: groceries) != nil)
        #expect(!leslie.sees(group), "declined stays declined")
        #expect(try leslie.model.store.pendingJoin(group) == nil)
    }

    /// The decision on who may delete a shared group for everyone: its founder
    /// or an admin. Anyone else removes it from their own Mac, and nothing is
    /// sent. Before, a member at the default Add role deleted it for everyone.
    @Test(arguments: [AccessLevel.read, .write, .manage])
    func aMemberBelowAdminDeletesTheGroupFromTheirMacOnly(level: AccessLevel) async throws {
        let (robin, leslie, group, groceries) = try await sharedHousehold(level: level)

        leslie.model.deleteGroup(group, reach: leslie.sync.deleteReach(of: group))
        await leslie.sync.syncAll()
        await robin.sync.syncAll()

        #expect(robin.sees(group), "Robin keeps it")
        #expect(robin.model.summary(for: groceries) != nil)
        #expect(!leslie.sees(group))
        #expect(try leslie.model.store.outboxCount(in: group) == 0)
        let reads = leslie.transport.logReads(of: group)
        await leslie.sync.syncAll()
        #expect(leslie.transport.logReads(of: group) == reads, "and her Mac is done with it")
    }

    @Test func theFounderDeletesASharedGroupForEveryone() async throws {
        let (robin, leslie, group, _) = try await sharedHousehold()

        robin.model.deleteGroup(group, reach: robin.sync.deleteReach(of: group))
        await robin.sync.syncAll()
        await leslie.sync.syncAll()

        #expect(!robin.sees(group))
        #expect(!leslie.sees(group))
        #expect(try robin.model.store.outboxCount(in: group) == 0)
    }

    /// A delete goes out without a pull first. A pull applied her rename over
    /// his delete, so the group came back on his Mac and nowhere else.
    @Test func aDeleteIsNotUndoneByAnEditItHadNotSeen() async throws {
        let (robin, leslie, group, _) = try await sharedHousehold()

        leslie.model.renameGroup(group, to: "Home")
        await leslie.sync.syncAll()
        robin.model.deleteGroup(group, reach: robin.sync.deleteReach(of: group))
        await robin.sync.syncAll()
        await leslie.sync.syncAll()

        #expect(!robin.sees(group), "his delete stays")
        #expect(try robin.model.store.group(group)?.isDeleted == true)
        #expect(!leslie.sees(group), "and reaches her")
    }

    /// Her edit was still queued when his delete reached her, and it outranks
    /// his delete of that transaction, so her pull keeps it and her push sends
    /// it. A real server would store it, because it is newer. Here the stub
    /// refuses it, as a server refuses a row for a reason no later sync can
    /// change, to show what happens to such a row once the group is gone:
    /// nothing in it can be edited again, so it is dropped rather than sent on
    /// every sync for a group she cannot see. An edit that loses to his delete
    /// never gets this far: her pull keeps it as a conflict copy and drops it.
    @Test func editsLeftOverFromAnotherMembersDeleteAreDropped() async throws {
        let (robin, leslie, group, groceries) = try await sharedHousehold()
        leslie.model.selectedBudget = groceries
        leslie.model.addTransaction(merchant: "Costco", amount: Money(minorUnits: 9900),
                                     date: Date(), note: "")
        await leslie.sync.syncAll()
        await robin.sync.syncAll()

        // He deletes the group, which deletes her transaction too.
        let costco = try #require(leslie.model.transactions.first { $0.merchant == "Costco" })
        robin.model.deleteGroup(group, reach: robin.sync.deleteReach(of: group))
        await robin.sync.syncAll()
        let stored = try await robin.transport.inner.pull(group: group, since: 0, limit: 500)
        let his = try #require(stored.envelopes.first { $0.recordID == costco.id })

        // Offline, she edits hers until her edit outranks his delete of it.
        var count = 0
        while try leslie.model.store.syncState(for: group).lamport <= his.lamport {
            count += 1
            var edited = costco
            edited.note = "membership \(count)"
            try leslie.model.store.save(edited)
        }

        leslie.transport.refuseEverything = "another record already has this ID"
        await leslie.sync.syncAll()
        #expect(!leslie.sees(group), "his delete arrived")
        #expect(try leslie.model.store.outboxCount(in: group) == 1, "her edit was sent and refused")
        await leslie.sync.syncAll()

        #expect(try leslie.model.store.outboxCount(in: group) == 0)
        let reads = leslie.transport.logReads(of: group)
        await leslie.sync.syncAll()
        #expect(leslie.transport.logReads(of: group) == reads)
    }

    /// The confirmation says who loses the group.
    @Test func theDeleteConfirmationSaysWhoLosesTheGroup() async throws {
        let server = InMemoryTransport()
        let robin = try App(server: server), leslie = try App(server: server)
        try await robin.sync.signUp(email: "robin@example.com", password: "a-long-password")
        let group = try #require(robin.model.addGroup(named: "Household"))
        let own = try #require(robin.model.addGroup(named: "Personal"))
        let link = try await robin.sync.share(group: group, groupName: "Household", level: .write,
                                              historyAccess: .all, myName: "Robin")
        try await leslie.sync.signUp(email: "leslie@example.com", password: "a-long-password")
        try await leslie.sync.join(link, myName: "Leslie")
        #expect(leslie.sync.deleteReach(of: group) == .declinesInvite)

        await robin.sync.syncAll()
        await leslie.sync.syncAll()
        #expect(robin.sync.deleteReach(of: group) == .everyone)
        #expect(leslie.sync.deleteReach(of: group) == .thisMacOnly)
        #expect(robin.sync.deleteReach(of: own) == .justYou)
    }

    // MARK: - Deletes made while a round is running

    /// A member below admin confirms Delete while a sync round is already
    /// waiting on the server. The round used to send whatever was queued by
    /// the time it pushed, so her budget deletes reached everyone even though
    /// the dialog said other members keep it. Now nothing is queued at all.
    @Test func aThisMacOnlyDeleteDuringARoundSendsNothing() async throws {
        let (robin, leslie, group, groceries) = try await sharedHousehold()

        let model = leslie.model
        leslie.transport.beforeNextPull(of: group) {
            model.deleteGroup(group, reach: .thisMacOnly)
        }
        await leslie.sync.syncAll()
        await robin.sync.syncAll()

        #expect(robin.model.summary(for: groceries) != nil, "Robin keeps every budget")
        #expect(!leslie.sees(group))
        #expect(try leslie.model.store.outboxCount(in: group) == 0)
    }

    /// Turning down a waiting group while a round is running. The round had
    /// listed it as live, so it went on to pull the inviter's group over the
    /// deleted placeholder, and the group came back fully joined.
    @Test func turningDownAnInviteDuringARoundSticks() async throws {
        let server = InMemoryTransport()
        let robin = try App(server: server), leslie = try App(server: server)
        try await robin.sync.signUp(email: "robin@example.com", password: "a-long-password")
        let group = try #require(robin.model.addGroup(named: "Household"))
        let link = try await robin.sync.share(group: group, groupName: "Household", level: .write,
                                              historyAccess: .all, myName: "Robin")
        try await leslie.sync.signUp(email: "leslie@example.com", password: "a-long-password")
        try await leslie.sync.join(link, myName: "Leslie")
        await robin.sync.syncAll()

        let model = leslie.model
        leslie.transport.beforeNextLogRead(of: group) { model.deleteGroup(group, reach: .declinesInvite) }
        await leslie.sync.syncAll()
        #expect(!leslie.sees(group), "the round does not join it after all")
        await leslie.sync.syncAll()
        #expect(!leslie.sees(group))
    }

    // MARK: - Coming back

    /// Turning an invite down by mistake used to be for good. A new link left
    /// the deleted placeholder where it was, and nothing ever synced it.
    @Test func aTurnedDownGroupComesBackWithANewLink() async throws {
        let server = InMemoryTransport()
        let robin = try App(server: server), leslie = try App(server: server)
        try await robin.sync.signUp(email: "robin@example.com", password: "a-long-password")
        let group = try #require(robin.model.addGroup(named: "Household"))
        let groceries = try #require(robin.model.addBudget(named: "Groceries",
                                                           limit: Money(minorUnits: 100_000), in: group))
        let first = try await robin.sync.share(group: group, groupName: "Household", level: .write,
                                               historyAccess: .all, myName: "Robin")
        try await leslie.sync.signUp(email: "leslie@example.com", password: "a-long-password")
        try await leslie.sync.join(first, myName: "Leslie")
        leslie.model.deleteGroup(group, reach: leslie.sync.deleteReach(of: group))
        await robin.sync.syncAll()

        let second = try await robin.sync.share(group: group, groupName: "Household", level: .write,
                                                historyAccess: .all, myName: "Robin")
        try await leslie.sync.join(second, myName: "Leslie")
        await leslie.sync.syncAll()
        await robin.sync.syncAll()
        await leslie.sync.syncAll()

        #expect(leslie.sees(group))
        #expect(leslie.model.summary(for: groceries) != nil)
        #expect(try leslie.model.store.pendingJoin(group) == nil)
    }

    /// The same for a group removed from this Mac only. Everything deleted
    /// here comes back from the server's copy, her own records included.
    /// Those are signed by her own device, and used to be skipped as echoes,
    /// so they stayed deleted on her Mac while everyone else still had them.
    @Test func aGroupRemovedFromThisMacComesBackWithANewLink() async throws {
        // Manage, because making a budget takes Manage.
        let (robin, leslie, group, groceries) = try await sharedHousehold(level: .manage)
        leslie.model.selectedBudget = groceries
        leslie.model.addTransaction(merchant: "Costco", amount: Money(minorUnits: 9900),
                                    date: Date(), note: "")
        let gas = try #require(leslie.model.addBudget(named: "Gas", limit: Money(minorUnits: 20_000),
                                                      in: group))
        leslie.model.addTransaction(merchant: "Milepost", amount: Money(minorUnits: 4500),
                                    date: Date(), note: "")
        await leslie.sync.syncAll()

        leslie.model.deleteGroup(group, reach: .thisMacOnly)
        await leslie.sync.syncAll()

        let link = try await robin.sync.share(group: group, groupName: "Household", level: .write,
                                              historyAccess: .all, myName: "Robin")
        try await leslie.sync.join(link, myName: "Leslie")
        await leslie.sync.syncAll()

        #expect(leslie.sees(group))
        leslie.model.selectedBudget = groceries
        #expect(Set(leslie.model.transactions.map(\.merchant)) == ["Hilltop", "Costco"])
        leslie.model.selectedBudget = gas
        #expect(leslie.model.transactions.map(\.merchant) == ["Milepost"], "her own budget is back")
    }

    /// Brought back with a new link before any sync let go of it. The join
    /// dropped what she had queued: her note on Costco, and Milepost, which
    /// had never been sent. A sync that ran first would have sent both, so
    /// the join now lets go first, the same way.
    @Test func whatWasQueuedGoesOutBeforeAGroupComesBack() async throws {
        let (robin, leslie, group, groceries) = try await sharedHousehold()
        leslie.model.selectedBudget = groceries
        leslie.model.addTransaction(merchant: "Costco", amount: Money(minorUnits: 9900),
                                    date: Date(), note: "")
        await leslie.sync.syncAll()
        var costco = try #require(leslie.model.transactions.first { $0.merchant == "Costco" })
        costco.note = "Party supplies"
        try leslie.model.store.save(costco)
        leslie.model.addTransaction(merchant: "Milepost", amount: Money(minorUnits: 4500),
                                    date: Date(), note: "")
        leslie.model.renameGroup(group, to: "Home")

        // The sync after the removal fails, so nothing has let go of it yet.
        leslie.transport.failLogReadOf = (group, .http(status: 503, reason: "down"))
        leslie.model.deleteGroup(group, reach: .thisMacOnly)
        await leslie.sync.syncAll()
        leslie.transport.failLogReadOf = nil

        let link = try await robin.sync.share(group: group, groupName: "Household", level: .write,
                                              historyAccess: .all, myName: "Robin")
        try await leslie.sync.join(link, myName: "Leslie")
        await leslie.sync.syncAll()
        await robin.sync.syncAll()

        for (name, app) in [("hers", leslie), ("his", robin)] {
            app.model.selectedBudget = groceries
            #expect(Set(app.model.transactions.map(\.merchant)) == ["Hilltop", "Costco", "Milepost"],
                    "\(name)")
            #expect(app.model.transactions.first { $0.merchant == "Costco" }?.note == "Party supplies",
                    "\(name)")
            #expect(try app.model.store.group(group)?.name == "Home", "\(name): her rename, not the link's name")
        }
    }

    /// Brought back with a new link while an invite of hers to it is still
    /// open, with nothing else queued. The join lets go first, so that invite
    /// is cancelled, as the next sync would have done. Nobody else holds its
    /// secret to finish it.
    @Test func aNewLinkCancelsTheRemovedGroupsOpenInvites() async throws {
        let (robin, leslie, group, _) = try await sharedHousehold(level: .manage)
        _ = try await leslie.sync.share(group: group, groupName: "Household", level: .write,
                                        historyAccess: .all, myName: "Leslie")
        leslie.model.deleteGroup(group, reach: .thisMacOnly)
        #expect(try leslie.model.store.outboxCount(in: group) == 0, "nothing else to send")

        let link = try await robin.sync.share(group: group, groupName: "Household", level: .write,
                                              historyAccess: .all, myName: "Robin")
        try await leslie.sync.join(link, myName: "Leslie")

        #expect(try leslie.model.store.sentInvites(in: group).isEmpty)
        #expect(leslie.transport.inner.inviteCount == 1, "only Robin's new link is left")
    }

    /// A new link answered while a round is letting go of the group. The join
    /// starts the group's pulls again from the beginning. The round's pull,
    /// still out, then wrote its own place back over that, so what the removal
    /// marked deleted here was never pulled again, and the group came back
    /// without its budget on her Mac only.
    @Test func aJoinDuringALettingGoRoundKeepsItsFreshStart() async throws {
        let (robin, leslie, group, groceries) = try await sharedHousehold()
        leslie.model.selectedBudget = groceries
        leslie.model.addTransaction(merchant: "Costco", amount: Money(minorUnits: 9900),
                                    date: Date(), note: "")
        leslie.model.deleteGroup(group, reach: .thisMacOnly)
        let link = try await robin.sync.share(group: group, groupName: "Household", level: .write,
                                              historyAccess: .all, myName: "Robin")

        let sync = leslie.sync
        leslie.transport.beforeNextPull(of: group) { _ = try? await sync.join(link, myName: "Leslie") }
        await leslie.sync.syncAll()
        #expect(leslie.sync.isWaitingToJoin(group), "the join went through")
        #expect(try leslie.model.store.syncState(for: group).serverSeq == 0, "and its fresh start stands")

        await leslie.sync.syncAll()
        leslie.model.selectedBudget = groceries
        #expect(Set(leslie.model.transactions.map(\.merchant)) == ["Hilltop", "Costco"])
    }

    // MARK: - Turning down an invite as the join completes

    /// The round that finishes a join deletes the pending join partway
    /// through, while the sidebar still says waiting. Turning the invite down
    /// then found no pending join and queued everything, and the pass after
    /// the join sent the inviter's budget deletes to everyone.
    @Test func turningDownAfterTheJoinCompletedSendsNothing() async throws {
        let (robin, leslie, group, groceries) = try await invitedAndAdded()

        // The dialog is opened while she is still waiting, and confirmed
        // during the pass that runs after the join completes.
        let shown = leslie.sync.deleteReach(of: group)
        #expect(shown == .declinesInvite)
        let model = leslie.model, sync = leslie.sync, transport = leslie.transport
        let seen = Seen()
        transport.beforeNextPull(of: group) {
            transport.beforeNextPull(of: group) {
                seen.reach = sync.deleteReach(of: group)
                model.deleteGroup(group, reach: shown)
            }
        }
        await leslie.sync.syncAll()
        await robin.sync.syncAll()

        #expect(robin.model.summary(for: groceries) != nil, "Robin keeps every budget")
        #expect(seen.reach == .thisMacOnly, "once in, a new dialog no longer offers to turn it down")
        #expect(!leslie.sees(group))
        // The join had already queued her name, and the pending join was gone,
        // so only the dialog's answer says this is a decline and drops it.
        #expect(try !robin.model.store.profiles(in: group).map(\.displayName).contains("Leslie"),
                "her name stays on her Mac")
    }

    /// Turned down while the join is being completed. Her name was written
    /// anyway, and went into the group she had just turned down.
    @Test func turningDownWhileTheJoinCompletesSendsNoName() async throws {
        let (robin, leslie, group, _) = try await invitedAndAdded()

        let model = leslie.model, transport = leslie.transport
        transport.beforeNextPull(of: group) {
            // After this pull, the next read of the log is the one the join makes.
            transport.beforeNextLogRead(of: group) { model.deleteGroup(group, reach: .declinesInvite) }
        }
        await leslie.sync.syncAll()
        await leslie.sync.syncAll()
        await robin.sync.syncAll()

        #expect(try !robin.model.store.profiles(in: group).map(\.displayName).contains("Leslie"))
        #expect(!leslie.sees(group))
    }

    /// Robin's Household with Groceries in it, shared with Leslie at Add. She
    /// has answered the link and his app has added her, but her app has not
    /// synced since, so she is still waiting.
    private func invitedAndAdded() async throws
        -> (robin: App, leslie: App, group: GroupID, groceries: BudgetID) {
        let server = InMemoryTransport()
        let robin = try App(server: server), leslie = try App(server: server)
        try await robin.sync.signUp(email: "robin@example.com", password: "a-long-password")
        let group = try #require(robin.model.addGroup(named: "Household"))
        let groceries = try #require(robin.model.addBudget(named: "Groceries",
                                                           limit: Money(minorUnits: 100_000), in: group))
        let link = try await robin.sync.share(group: group, groupName: "Household", level: .write,
                                              historyAccess: .all, myName: "Robin")
        try await leslie.sync.signUp(email: "leslie@example.com", password: "a-long-password")
        try await leslie.sync.join(link, myName: "Leslie")
        await robin.sync.syncAll()
        return (robin, leslie, group, groceries)
    }

    // MARK: - What a member owes others

    /// A Manage member who adds someone "from now on" owes them the group and
    /// its budgets, sealed under the new key. Removing the group from her Mac
    /// before that went out used to drop it, and the new member saw the group
    /// with no budgets.
    @Test func whatIsOwedToSomeoneJustAddedStillGoesOut() async throws {
        let (_, leslie, group, groceries) = try await sharedHousehold(level: .manage)
        let jamie = try App(server: leslie.transport.inner)
        try await jamie.sync.signUp(email: "jamie@example.com", password: "a-long-password")
        let link = try await leslie.sync.share(group: group, groupName: "Household", level: .write,
                                               historyAccess: .fromNow, myName: "Leslie")
        try await jamie.sync.join(link, myName: "Jamie")

        // Her next round adds him and queues the group and its budgets again,
        // under the new key. Then its pull fails, so none of that goes out.
        leslie.transport.failNextPull = (group, .http(status: 503, reason: "unreachable"))
        await leslie.sync.syncAll()
        #expect(try leslie.model.store.outboxCount(in: group) > 0)

        let reach = leslie.sync.deleteReach(of: group)
        #expect(reach == .thisMacOnly)
        leslie.model.deleteGroup(group, reach: reach)
        await leslie.sync.syncAll()
        await jamie.sync.syncAll()

        #expect(jamie.sees(group))
        #expect(jamie.model.summary(for: groceries) != nil, "the budget sealed for him arrived")
        #expect(try leslie.model.store.outboxCount(in: group) == 0, "and then she let go")
    }

    /// Her Manage member's Household, a "from now on" link to it, and Jamie's
    /// answer waiting for her next round.
    private func jamieAnswersAFromNowLink() async throws
        -> (leslie: App, jamie: App, group: GroupID, groceries: BudgetID) {
        let (_, leslie, group, groceries) = try await sharedHousehold(level: .manage)
        let jamie = try App(server: leslie.transport.inner)
        try await jamie.sync.signUp(email: "jamie@example.com", password: "a-long-password")
        let link = try await leslie.sync.share(group: group, groupName: "Household", level: .write,
                                               historyAccess: .fromNow, myName: "Leslie")
        try await jamie.sync.join(link, myName: "Jamie")
        return (leslie, jamie, group, groceries)
    }

    /// Removed from her Mac while the round that would add Jamie reads the
    /// log. The round added him anyway, then queued the group's delete in
    /// place of what he was owed, which her Mac drops. He had the group and
    /// could read nothing in it. Now nobody is added to a group this Mac has
    /// let go of, and the next round cancels the invite.
    @Test func nobodyIsAddedToAGroupRemovedDuringTheRound() async throws {
        let (leslie, jamie, group, _) = try await jamieAnswersAFromNowLink()

        let model = leslie.model
        leslie.transport.beforeNextLogRead(of: group) { model.deleteGroup(group, reach: .thisMacOnly) }
        await leslie.sync.syncAll()
        await leslie.sync.syncAll()

        let log = try await leslie.transport.inner.membershipLog(group: group, since: 0)
        let him = try #require(jamie.sync.userID)
        #expect(try MembershipLog.replay(log, scope: .group(group)).level(of: him) == AccessLevel.none,
                "he was not added")
        #expect(leslie.transport.inner.inviteCount == 0, "and the invite is gone")
        #expect(try leslie.model.store.sentInvites(in: group).isEmpty)
    }

    /// Removed from her Mac while the round reads the open invites, after
    /// every check the round makes before that. Only the check before each
    /// add stops Jamie being added to a group she has let go of.
    @Test func nobodyIsAddedWhenTheGroupIsRemovedDuringFinishInvites() async throws {
        let (leslie, jamie, group, _) = try await jamieAnswersAFromNowLink()

        let model = leslie.model
        leslie.transport.beforeNextInvitesRead(of: group) { model.deleteGroup(group, reach: .thisMacOnly) }
        await leslie.sync.syncAll()

        let log = try await leslie.transport.inner.membershipLog(group: group, since: 0)
        let him = try #require(jamie.sync.userID)
        #expect(try MembershipLog.replay(log, scope: .group(group)).level(of: him) == AccessLevel.none,
                "he was not added")
        #expect(try leslie.model.store.sentInvites(in: group).count == 1, "the invite is still open")
        await leslie.sync.syncAll()
        #expect(try leslie.model.store.sentInvites(in: group).isEmpty, "until letting go cancels it")
    }

    /// Removed from her Mac while the entry adding Jamie is on its way. The
    /// server has added him by then, so he is still owed the group and its
    /// budgets under the new key, though her Mac now holds them as deleted.
    @Test func aRemovalDuringTheAddStillSendsWhatIsOwed() async throws {
        let (leslie, jamie, group, groceries) = try await jamieAnswersAFromNowLink()

        let model = leslie.model
        leslie.transport.whileNextAppend(to: group) { model.deleteGroup(group, reach: .thisMacOnly) }
        await leslie.sync.syncAll()
        await leslie.sync.syncAll()
        await jamie.sync.syncAll()

        #expect(jamie.sees(group))
        #expect(jamie.model.summary(for: groceries) != nil, "the budget sealed for him arrived")
        #expect(!leslie.sees(group))
        #expect(try leslie.model.store.outboxCount(in: group) == 0, "and then she let go")
    }

    // MARK: - Letting go

    /// Letting go of a group pulls before it pushes. It only pushed, so what
    /// this Mac had queued went out over newer edits it had not seen. Here
    /// the re-seal Jamie is owed carried her old Groceries at a higher Lamport
    /// value than Robin's later change, and his change was lost on every Mac.
    @Test func lettingGoKeepsOtherMembersNewerEdits() async throws {
        let (robin, leslie, group, groceries) = try await sharedHousehold(level: .manage)
        let jamie = try App(server: leslie.transport.inner)
        try await jamie.sync.signUp(email: "jamie@example.com", password: "a-long-password")
        let link = try await leslie.sync.share(group: group, groupName: "Household", level: .write,
                                               historyAccess: .fromNow, myName: "Leslie")
        try await jamie.sync.join(link, myName: "Jamie")

        // Her saves run her clock ahead of his. Her next round adds Jamie and
        // queues what he is owed, then its pull fails, so nothing goes out.
        for name in ["Home", "Our home", "The house", "Home base", "Household"] {
            leslie.model.renameGroup(group, to: name)
        }
        leslie.transport.failNextPull = (group, .http(status: 503, reason: "unreachable"))
        await leslie.sync.syncAll()

        robin.model.updateBudget(groceries, name: "Groceries", limit: Money(minorUnits: 150_000))
        await robin.sync.syncAll()

        leslie.model.deleteGroup(group, reach: .thisMacOnly)
        await leslie.sync.syncAll()
        await robin.sync.syncAll()
        await jamie.sync.syncAll()

        #expect(robin.model.summary(for: groceries)?.budget.limit.minorUnits == 150_000,
                "Robin keeps his change")
        #expect(jamie.model.summary(for: groceries)?.budget.limit.minorUnits == 150_000,
                "and Jamie gets it, under the new key")
        #expect(try leslie.model.store.outboxCount(in: group) == 0)
    }

    /// The same for the group's own record. The group is deleted on her Mac,
    /// so a newer name pulled while letting go lost to that, and the re-seal
    /// Jamie is owed sent her old name over Robin's on every Mac.
    @Test func lettingGoKeepsAnotherMembersNewerGroupName() async throws {
        let (robin, leslie, group, groceries) = try await sharedHousehold(level: .manage)
        let jamie = try App(server: leslie.transport.inner)
        try await jamie.sync.signUp(email: "jamie@example.com", password: "a-long-password")
        let link = try await leslie.sync.share(group: group, groupName: "Household", level: .write,
                                               historyAccess: .fromNow, myName: "Leslie")
        try await jamie.sync.join(link, myName: "Jamie")

        // Her saves run her clock ahead of his. Her next round adds Jamie and
        // queues what he is owed, then its pull fails, so nothing goes out.
        for name in ["Food", "Food and drink", "Market", "Shop", "Groceries"] {
            leslie.model.updateBudget(groceries, name: name, limit: Money(minorUnits: 100_000))
        }
        leslie.transport.failNextPull = (group, .http(status: 503, reason: "unreachable"))
        await leslie.sync.syncAll()

        robin.model.renameGroup(group, to: "Our Place")
        await robin.sync.syncAll()

        leslie.model.deleteGroup(group, reach: .thisMacOnly)
        await leslie.sync.syncAll()
        await robin.sync.syncAll()
        await jamie.sync.syncAll()

        #expect(try robin.model.store.group(group)?.name == "Our Place", "Robin keeps his name")
        #expect(try jamie.model.store.group(group)?.name == "Our Place", "and Jamie gets it")
        #expect(jamie.model.summary(for: groceries) != nil, "with the budget he is owed")
        #expect(try leslie.model.store.group(group)?.isDeleted == true, "still removed from her Mac")
        #expect(try leslie.model.store.outboxCount(in: group) == 0)
    }

    /// An open invite to a group removed from this Mac is cancelled, even with
    /// nothing else queued for it. Only this Mac holds its secret, so nobody
    /// else could ever finish it, and an answer to it would wait for good.
    @Test func removingAGroupCancelsItsOpenInvites() async throws {
        let (_, leslie, group, _) = try await sharedHousehold(level: .manage)
        _ = try await leslie.sync.share(group: group, groupName: "Household", level: .write,
                                        historyAccess: .all, myName: "Leslie")
        #expect(try leslie.model.store.outboxCount(in: group) == 0, "nothing else to send")
        #expect(leslie.transport.inner.inviteCount == 1)

        leslie.model.deleteGroup(group, reach: .thisMacOnly)
        await leslie.sync.syncAll()

        #expect(leslie.transport.inner.inviteCount == 0, "the server no longer holds it")
        #expect(try leslie.model.store.sentInvites(in: group).isEmpty)
    }

    /// A group whose pull fails every time, as a page holding a record this
    /// build cannot read would. Removing it from this Mac used to end that.
    /// Once letting go pulled first, every round failed on it instead, for a
    /// group she could no longer see. Now what she queued goes out without the
    /// pull, and her Mac is done with it.
    @Test func removingAGroupWhosePullAlwaysFailsEndsItsFailures() async throws {
        let (robin, leslie, group, groceries) = try await sharedHousehold()
        leslie.model.selectedBudget = groceries
        leslie.model.addTransaction(merchant: "Costco", amount: Money(minorUnits: 9900),
                                    date: Date(), note: "")
        leslie.transport.failEveryPull = (group, .malformedResponse("a record this build cannot read"))
        await leslie.sync.syncAll()
        #expect(!leslie.sync.isSignedIn, "the group fails to sync")

        leslie.model.deleteGroup(group, reach: .thisMacOnly)
        await leslie.sync.syncAll()
        #expect(leslie.sync.isSignedIn, "and stops failing once removed: \(leslie.sync.state)")
        #expect(try leslie.model.store.outboxCount(in: group) == 0)
        let reads = leslie.transport.logReads(of: group)
        await leslie.sync.syncAll()
        #expect(leslie.transport.logReads(of: group) == reads, "her Mac is done with it")

        await robin.sync.syncAll()
        robin.model.selectedBudget = groceries
        #expect(robin.model.transactions.contains { $0.merchant == "Costco" }, "what she queued went out")
    }

    /// A new link to such a group still works. The join lets go of the group
    /// first, and that failing made the join fail too.
    @Test func aNewLinkWorksForAGroupWhosePullAlwaysFails() async throws {
        let (robin, leslie, group, groceries) = try await sharedHousehold()
        leslie.model.selectedBudget = groceries
        leslie.model.addTransaction(merchant: "Costco", amount: Money(minorUnits: 9900),
                                    date: Date(), note: "")
        leslie.transport.failEveryPull = (group, .malformedResponse("a record this build cannot read"))
        leslie.model.deleteGroup(group, reach: .thisMacOnly)

        let link = try await robin.sync.share(group: group, groupName: "Household", level: .write,
                                              historyAccess: .all, myName: "Robin")
        try await leslie.sync.join(link, myName: "Leslie")
        #expect(leslie.sees(group))
        #expect(leslie.sync.isWaitingToJoin(group))

        await robin.sync.syncAll()
        robin.model.selectedBudget = groceries
        #expect(robin.model.transactions.contains { $0.merchant == "Costco" }, "what she queued went out")
    }

    /// The join lets go first. When that fails in a way that clears up by
    /// itself, such as a server error, the join fails too and the queue stays
    /// for the next try. Answering anyway dropped what she had queued.
    @Test func aJoinKeepsTheQueueWhenLettingGoFailsForNow() async throws {
        let (robin, leslie, group, groceries) = try await sharedHousehold()
        leslie.model.selectedBudget = groceries
        leslie.model.addTransaction(merchant: "Costco", amount: Money(minorUnits: 9900),
                                    date: Date(), note: "")
        leslie.model.deleteGroup(group, reach: .thisMacOnly)
        let link = try await robin.sync.share(group: group, groupName: "Household", level: .write,
                                              historyAccess: .all, myName: "Robin")

        leslie.transport.failLogReadOf = (group, .http(status: 503, reason: "down"))
        await #expect(throws: (any Error).self) { try await leslie.sync.join(link, myName: "Leslie") }
        #expect(try leslie.model.store.outboxCount(in: group) == 1, "her queue is kept")

        leslie.transport.failLogReadOf = nil
        try await leslie.sync.join(link, myName: "Leslie")
        await robin.sync.syncAll()
        robin.model.selectedBudget = groceries
        #expect(robin.model.transactions.contains { $0.merchant == "Costco" }, "and goes out on the next try")
    }

    /// Sending without the pull leaves out the rows that owe a re-seal. They
    /// cannot be weighed without it, and the group's re-seal sent her old name
    /// over Robin's newer one, at a higher Lamport value, with no copy kept.
    @Test func sendingWithoutThePullLeavesReSealsOut() async throws {
        let (robin, leslie, group, groceries) = try await sharedHousehold(level: .manage)
        let jamie = try App(server: leslie.transport.inner)
        try await jamie.sync.signUp(email: "jamie@example.com", password: "a-long-password")
        let link = try await leslie.sync.share(group: group, groupName: "Household", level: .write,
                                               historyAccess: .fromNow, myName: "Leslie")
        try await jamie.sync.join(link, myName: "Jamie")

        // Her saves run her clock ahead of his. Her next round adds Jamie and
        // queues what he is owed, then its pull fails, so nothing goes out.
        for name in ["Food", "Food and drink", "Market", "Shop", "Groceries"] {
            leslie.model.updateBudget(groceries, name: name, limit: Money(minorUnits: 100_000))
        }
        leslie.transport.failNextPull = (group, .http(status: 503, reason: "unreachable"))
        await leslie.sync.syncAll()

        robin.model.renameGroup(group, to: "Our Place")
        await robin.sync.syncAll()

        leslie.transport.failEveryPull = (group, .malformedResponse("a record this build cannot read"))
        leslie.model.deleteGroup(group, reach: .thisMacOnly)
        await leslie.sync.syncAll()
        #expect(leslie.sync.isSignedIn, "she let go: \(leslie.sync.state)")
        await robin.sync.syncAll()

        #expect(try robin.model.store.group(group)?.name == "Our Place", "Robin keeps his name")
    }

    /// Her own edit on top of a re-seal still goes when sending without the
    /// pull. Only plain re-seals are left out. Leaving out every row that owed
    /// a re-seal dropped her new limit, which the dialog promised still goes.
    @Test func sendingWithoutThePullStillSendsHerOwnEdits() async throws {
        let (robin, leslie, group, groceries) = try await sharedHousehold(level: .manage)
        let jamie = try App(server: leslie.transport.inner)
        try await jamie.sync.signUp(email: "jamie@example.com", password: "a-long-password")
        let link = try await leslie.sync.share(group: group, groupName: "Household", level: .write,
                                               historyAccess: .fromNow, myName: "Leslie")
        try await jamie.sync.join(link, myName: "Jamie")

        // Her next round adds Jamie and queues what he is owed, then its pull
        // fails, so the re-seals stay queued. Then she changes the limit.
        leslie.transport.failNextPull = (group, .http(status: 503, reason: "unreachable"))
        await leslie.sync.syncAll()
        leslie.model.updateBudget(groceries, name: "Groceries", limit: Money(minorUnits: 250_000))

        leslie.transport.failEveryPull = (group, .malformedResponse("a record this build cannot read"))
        leslie.model.deleteGroup(group, reach: .thisMacOnly)
        await leslie.sync.syncAll()
        #expect(leslie.sync.isSignedIn, "she let go: \(leslie.sync.state)")
        await robin.sync.syncAll()
        await jamie.sync.syncAll()

        #expect(try robin.model.store.budget(groceries)?.limit.minorUnits == 250_000, "Robin has her limit")
        #expect(try jamie.model.store.budget(groceries)?.limit.minorUnits == 250_000, "and so does Jamie")
    }

    /// When even sending without the pull fails, for a reason no later round
    /// would change, letting go gives up after a few rounds. The queue and
    /// the open invites are dropped, and the failures end.
    @Test func lettingGoGivesUpOnAGroupThatCannotBeSentTo() async throws {
        let (_, leslie, group, groceries) = try await sharedHousehold(level: .manage)
        _ = try await leslie.sync.share(group: group, groupName: "Household", level: .write,
                                        historyAccess: .all, myName: "Leslie")
        leslie.model.selectedBudget = groceries
        leslie.model.addTransaction(merchant: "Costco", amount: Money(minorUnits: 9900),
                                    date: Date(), note: "")
        let unreadable = HTTPTransport.Failure.malformedResponse("a record this build cannot read")
        leslie.transport.failEveryPull = (group, unreadable)
        leslie.transport.failEveryPush = (group, unreadable)
        leslie.model.deleteGroup(group, reach: .thisMacOnly)

        for round in 1 ..< SyncCoordinator.letGoAttempts {
            await leslie.sync.syncAll()
            #expect(!leslie.sync.isSignedIn, "round \(round) still fails")
            #expect(try leslie.model.store.outboxCount(in: group) > 0, "and keeps the queue")
        }
        await leslie.sync.syncAll()
        #expect(leslie.sync.isSignedIn, "then it gives up: \(leslie.sync.state)")
        #expect(try leslie.model.store.outboxCount(in: group) == 0)
        #expect(try leslie.model.store.sentInvites(in: group).isEmpty)
        let reads = leslie.transport.logReads(of: group)
        await leslie.sync.syncAll()
        #expect(leslie.transport.logReads(of: group) == reads, "her Mac is done with it")
    }

    /// Letting go sends every queued row, not only the first two hundred. An
    /// imported statement is the usual way to have that many.
    @Test func lettingGoSendsMoreThanAPage() async throws {
        let (robin, leslie, group, groceries) = try await sharedHousehold()
        for index in 0 ..< 201 {
            try leslie.model.store.save(Transaction(budgetID: groceries, groupID: group, date: Date(),
                                                    merchant: "Line \(index)",
                                                    amount: Money(minorUnits: -100)))
        }
        leslie.model.deleteGroup(group, reach: .thisMacOnly)
        await leslie.sync.syncAll()
        await robin.sync.syncAll()

        #expect(try robin.model.store.transactions(in: groceries).count == 202, "Hilltop and all of hers")
        #expect(try leslie.model.store.outboxCount(in: group) == 0)
    }

    /// A group whose access history no longer checks out fails every sync,
    /// as after the server is restored from a backup. Removing it from this
    /// Mac used to end that. Letting go of it then kept trying, and every
    /// Sync ended in a failure about a group she could no longer see.
    @Test func removingAGroupThatCannotSyncEndsItsFailures() async throws {
        let (_, leslie, group, groceries) = try await sharedHousehold()
        leslie.model.selectedBudget = groceries
        leslie.model.addTransaction(merchant: "Costco", amount: Money(minorUnits: 9900),
                                    date: Date(), note: "")

        // An entry that does not chain onto the history her Mac holds.
        let server = leslie.transport.inner
        let stranger = IdentityKeyPair.generate(), strangerID = UserID()
        let held = try await server.membershipLog(group: group, since: 0)
        server.append(try MembershipLogEntry.signed(
            scope: .group(group), sequence: UInt64(held.count),
            previousHash: Data(repeating: 7, count: 32), action: .rotate,
            subjectUserID: strangerID, subjectKeys: nil, level: .read, epochAfter: .initial,
            author: stranger, authorUserID: strangerID), to: group)
        await leslie.sync.syncAll()
        #expect(!leslie.sync.isSignedIn, "the group fails to sync")

        leslie.model.deleteGroup(group, reach: .thisMacOnly)
        await leslie.sync.syncAll()
        #expect(leslie.sync.isSignedIn, "and stops failing once removed: \(leslie.sync.state)")
        #expect(try leslie.model.store.outboxCount(in: group) == 0)
        let reads = leslie.transport.logReads(of: group)
        await leslie.sync.syncAll()
        #expect(leslie.transport.logReads(of: group) == reads, "her Mac is done with it")
    }

    // MARK: - The dialog

    /// The dialog's Delete never sends more than is true when it is pressed.
    /// This one opened while the group still looked like hers alone, and is
    /// pressed after it was shared.
    @Test func theDialogNeverSendsMoreThanIsTrueWhenPressed() async throws {
        let (robin, leslie, group, groceries) = try await sharedHousehold()
        let household = try #require(leslie.model.group(named: group))

        SidebarView.confirm(.group(household, budgets: 1, reach: .justYou),
                            model: leslie.model, sync: leslie.sync)
        #expect(try leslie.model.store.outboxCount(in: group) == 0)
        await leslie.sync.syncAll()
        await robin.sync.syncAll()
        #expect(robin.model.summary(for: groceries) != nil)
        #expect(!leslie.sees(group))
    }

    // MARK: - A server that lies

    /// Who may delete for everyone is judged on the history this Mac has
    /// verified. A whole log fetched fresh could be one the server made up,
    /// founded by a key it chose and naming her as founder.
    @Test func aMadeUpLogCannotTurnAHideIntoADeleteForEveryone() async throws {
        let (robin, leslie, group, groceries) = try await sharedHousehold()
        let her = try #require(leslie.sync.userID)
        let chosen = IdentityKeyPair.generate()
        leslie.transport.madeUpLog = (group, [try MembershipLogEntry.signed(
            scope: .group(group), sequence: 0, previousHash: MembershipLogEntry.rootHash,
            action: .found, subjectUserID: her, subjectKeys: chosen.publicKeys,
            level: .superadmin, epochAfter: .initial, author: chosen, authorUserID: her)])

        // Queued as an older build queued it, or after a dialog that said
        // everyone and was out of date. Only sendDelete's check stands between
        // these rows and every other member.
        leslie.model.deleteGroup(group, reach: .everyone)
        await leslie.sync.syncAll()
        await robin.sync.syncAll()

        #expect(robin.model.summary(for: groceries) != nil, "Robin keeps every budget")
        #expect(try leslie.model.store.outboxCount(in: group) == 0)
    }

    /// Rows an older build queued for a group that was still waiting go
    /// nowhere, and the server is not even asked about the group.
    @Test func rowsQueuedForAWaitingGroupAreDroppedWithoutAsking() async throws {
        let server = InMemoryTransport()
        let robin = try App(server: server), leslie = try App(server: server)
        try await robin.sync.signUp(email: "robin@example.com", password: "a-long-password")
        let group = try #require(robin.model.addGroup(named: "Household"))
        let link = try await robin.sync.share(group: group, groupName: "Household", level: .write,
                                              historyAccess: .all, myName: "Robin")
        try await leslie.sync.signUp(email: "leslie@example.com", password: "a-long-password")
        try await leslie.sync.join(link, myName: "Leslie")

        var placeholder = try #require(try leslie.model.store.group(group))
        placeholder.isDeleted = true
        try leslie.model.store.save(placeholder)
        await leslie.sync.syncAll()

        #expect(try leslie.model.store.outboxCount(in: group) == 0)
        #expect(try leslie.model.store.pendingJoin(group) == nil)
        #expect(leslie.transport.logReads(of: group) == 0)
    }

    @Test func eachRoleSaysWhatItAllows() {
        #expect(InviteRole.view.level == .read)
        #expect(InviteRole.add.level == .write)
        #expect(InviteRole.manage.level == .manage)
        #expect(InviteRole.add.explanation.contains("their own"))
        #expect(!InviteRole.add.explanation.contains("budget"))
        #expect(InviteRole.manage.explanation.contains("budgets"))
    }

    /// Budgets take Manage. The screens ask one question, of the same log
    /// every other member's app and the server judge by, so someone at Add is
    /// never offered a change everyone else would refuse. A group nobody has
    /// shared is always its owner's to change, synced or not.
    @Test func onlyAManagerIsOfferedBudgetChanges() async throws {
        let (robin, leslie, group, _) = try await sharedHousehold()
        let hers = try #require(leslie.model.addGroup(named: "Personal"))
        #expect(robin.sync.mayManageBudgets(in: group))
        #expect(!leslie.sync.mayManageBudgets(in: group))
        #expect(leslie.sync.mayManageBudgets(in: hers), "never synced")
        await leslie.sync.syncAll()
        #expect(leslie.sync.mayManageBudgets(in: hers), "synced, and only hers")

        let club = try #require(robin.model.addGroup(named: "Book Club"))
        let link = try await robin.sync.share(group: club, groupName: "Book Club", level: .manage,
                                              historyAccess: .all, myName: "Robin")
        try await leslie.sync.join(link, myName: "Leslie")
        #expect(!leslie.sync.mayManageBudgets(in: club), "nothing to change while waiting")
        await robin.sync.syncAll()
        await leslie.sync.syncAll()
        #expect(leslie.sync.mayManageBudgets(in: club))
    }
}

/// What a hook saw, for checking after the round.
@MainActor
private final class Seen {
    var reach: GroupDeleteReach?
}
