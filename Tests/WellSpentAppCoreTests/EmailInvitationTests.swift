import Testing
import Foundation
@testable import WellSpentAppCore
import WellSpentCrypto
import WellSpentKeyStore
import WellSpentModel
import WellSpentStore
import WellSpentSync

@MainActor
private struct EmailPerson {
    let transport: StubReadableTransport
    let sync: SyncCoordinator
    let workspace: Workspace
    let main: MainScreen
    var model: AppModel { workspace.model }

    init(_ email: String, on server: InMemoryReadableServer, confirmed: Bool = true) async throws {
        let store = Store(database: try WellSpentDatabase.inMemory())
        let transport = StubReadableTransport(server: server)
        self.transport = transport
        sync = SyncCoordinator(store: store, keyStore: InMemoryKeyStore(), defaults: isolatedDefaults(),
                               makeTransport: { _ in transport })
        workspace = Workspace(model: AppModel(store: store), sync: sync)
        main = MainScreen(workspace: workspace)
        try await sync.signUp(email: email, password: "a-long-password")
        if confirmed {
            try await sync.verifyEmail(code: try #require(server.lastCode(for: email, purpose: .verify)))
        }
    }

    func offer(to email: String = "leslie@example.com", role: InviteRole = .add,
               history: HistoryAccess = .all, groupID: GroupID? = nil) async throws -> (GroupID, SentEmailInvite) {
        let group = try #require(groupID ?? model.addGroup(named: "Household"))
        if groupID == nil {
            model.addBudget(named: "Groceries", limit: Money(minorUnits: 50_000), in: group)
            model.addBudget(named: "Travel", limit: Money(minorUnits: 20_000), in: group)
        }
        let screen = EmailInviteScreen(actions: sync, group: group, groupName: "Household")
        screen.email = email
        screen.inviteeName = "Leslie"
        screen.myName = "Robin"
        screen.role = role
        screen.history = history
        #expect(await screen.send(), "\(screen.failure ?? "send failed")")
        return (group, try #require(screen.sent))
    }
}

@Suite("Email group invitations", .serialized)
@MainActor
struct EmailInvitationTests {
    @Test func pendingIsSeparateFromMembershipAndAcceptBringsEveryBudget() async throws {
        let server = InMemoryReadableServer()
        let robin = try await EmailPerson("robin@example.com", on: server)
        let leslie = try await EmailPerson("leslie@example.com", on: server)
        let (group, sent) = try await robin.offer()
        let people = MembersScreen(actions: robin.sync, group: group, groupName: "Household")
        #expect(people.pendingInvites.map(\.id) == [sent.id])
        #expect(people.pendingInvites.first?.status == "pending")
        #expect(people.rows.count == 1, "the invited person is not a member yet")
        await leslie.sync.syncAll()
        let invitation = try #require(leslie.main.incomingInvitations.first)
        #expect(invitation.id == sent.id && invitation.groupName == "Household")
        #expect(try leslie.sync.store.group(group) == nil)
        #expect(leslie.main.sections.allSatisfy { $0.group.id != group })
        #expect(await leslie.main.acceptInvitation(invitation))
        #expect(leslie.main.incomingInvitations.isEmpty)
        #expect(leslie.main.openGroup?.id == group)
        #expect(Set(try leslie.sync.store.budgets(in: group).map(\.name)) == ["Groceries", "Travel"])
        #expect(leslie.sync.mayAddEntries(in: group))
        #expect(!leslie.sync.mayManageBudgets(in: group))
        await robin.sync.syncAll()
        people.reload()
        #expect(people.pendingInvites.isEmpty)
        #expect(people.rows.contains { $0.name == "Leslie" })
    }

    @Test func rejectClosesTheInvitationAndASeparateNewInviteCanBeAccepted() async throws {
        let server = InMemoryReadableServer()
        let robin = try await EmailPerson("robin@example.com", on: server)
        let leslie = try await EmailPerson("leslie@example.com", on: server)
        let (group, first) = try await robin.offer()
        await leslie.sync.syncAll()
        let invitation = try #require(leslie.main.incomingInvitations.first)
        #expect(await leslie.main.rejectInvitation(invitation))
        #expect(leslie.main.incomingInvitations.isEmpty)
        #expect(try leslie.sync.store.group(group) == nil)
        do {
            _ = try await leslie.transport.acceptInvitation(first.id)
            Issue.record("a rejected invitation was accepted")
        } catch ReadableTransportError.http(let status, _) { #expect(status == 409) }
        await robin.sync.syncAll()
        let people = MembersScreen(actions: robin.sync, group: group, groupName: "Household")
        #expect(people.pendingInvites.first?.status == "rejected")
        #expect(!people.canCancelInvite(first.id))
        let (_, replacement) = try await robin.offer(groupID: group)
        #expect(replacement.id != first.id)
        #expect(people.pendingInvites.map(\.id) == [replacement.id])
        for cancel in [false, true] {
            do {
                if cancel { try await robin.transport.cancelInvite(first.id, in: group) }
                else { try await leslie.transport.rejectInvitation(first.id) }
                Issue.record("a retired rejection became reusable")
            } catch ReadableTransportError.http(let status, _) { #expect(status == 409) }
        }
        await leslie.sync.syncAll()
        let fresh = try #require(leslie.main.incomingInvitations.first)
        #expect(fresh.id == replacement.id)
        #expect(await leslie.main.acceptInvitation(fresh))
        do {
            try await robin.transport.cancelInvite(replacement.id, in: group)
            Issue.record("an accepted invitation was cancelled")
        } catch ReadableTransportError.http(let status, _) { #expect(status == 409) }
        await robin.sync.syncAll()
        #expect(people.pendingInvites.isEmpty)
    }

    @Test func anAcceptedGroupOpensWhenItsFirstDownloadFailsAndSyncCanRetry() async throws {
        let server = InMemoryReadableServer()
        let robin = try await EmailPerson("robin@example.com", on: server)
        let leslie = try await EmailPerson("leslie@example.com", on: server)
        let (group, _) = try await robin.offer()
        await leslie.sync.syncAll()
        let invitation = try #require(leslie.main.incomingInvitations.first)
        leslie.transport.failNextPull = URLError(.networkConnectionLost)
        #expect(await leslie.main.acceptInvitation(invitation), "the server already accepted membership")
        #expect(leslie.main.openGroup?.id == group)
        #expect(leslie.main.incomingInvitations.isEmpty)
        #expect(leslie.main.syncFailure != nil, "the failed download must remain visible outside the removed invitation row")
        #expect(try leslie.sync.store.budgets(in: group).isEmpty)
        await leslie.main.syncNow()
        #expect(leslie.main.syncFailure == nil)
        #expect(Set(try leslie.sync.store.budgets(in: group).map(\.name)) == ["Groceries", "Travel"])
    }

    @Test func anOlderServersMissingInboxDoesNotPreventBudgetSync() async throws {
        let server = InMemoryReadableServer()
        let robin = try await EmailPerson("robin@example.com", on: server)
        let leslie = try await EmailPerson("leslie@example.com", on: server)
        let (group, _) = try await robin.offer()
        await leslie.sync.syncAll()
        let invitation = try #require(leslie.main.incomingInvitations.first)
        #expect(await leslie.main.acceptInvitation(invitation))
        robin.transport.failIncomingInvitations = .http(status: 404, reason: "Not Found")
        leslie.transport.failIncomingInvitations = .http(status: 404, reason: "Not Found")
        robin.model.addBudget(named: "Books", limit: Money(minorUnits: 10_000), in: group)
        await robin.sync.syncAll()
        await leslie.sync.syncAll()
        #expect(robin.sync.lastSyncedAt != nil && leslie.sync.lastSyncedAt != nil)
        #expect(robin.sync.state == .signedIn(email: "robin@example.com"))
        #expect(leslie.sync.state == .signedIn(email: "leslie@example.com"))
        #expect(try leslie.sync.store.budgets(in: group).contains { $0.name == "Books" })
    }

    @Test(arguments: [false, true])
    func anOlderInboxReplyCannotRestoreAnAnsweredInvitation(accept: Bool) async throws {
        let server = InMemoryReadableServer()
        let robin = try await EmailPerson("robin@example.com", on: server)
        let leslie = try await EmailPerson("leslie@example.com", on: server)
        _ = try await robin.offer()
        try await leslie.sync.refreshIncomingInvitations()
        let invitation = try #require(leslie.main.incomingInvitations.first)
        leslie.transport.whileListingInvitations = { @MainActor in
            if accept { #expect(await leslie.main.acceptInvitation(invitation)) }
            else { #expect(await leslie.main.rejectInvitation(invitation)) }
        }
        try await leslie.sync.refreshIncomingInvitations()
        #expect(leslie.main.incomingInvitations.isEmpty)
    }

    @Test func anOlderMissingInboxReplyCannotClearOtherInvitationsAfterAResponse() async throws {
        let server = InMemoryReadableServer()
        let robin = try await EmailPerson("robin@example.com", on: server)
        let leslie = try await EmailPerson("leslie@example.com", on: server)
        let (_, first) = try await robin.offer()
        let secondGroup = try #require(robin.model.addGroup(named: "Trips"))
        let (_, second) = try await robin.offer(groupID: secondGroup)
        try await leslie.sync.refreshIncomingInvitations()
        let invitation = try #require(leslie.main.incomingInvitations.first { $0.id == first.id })
        leslie.transport.failIncomingInvitations = .http(status: 404, reason: "Not Found")
        leslie.transport.whileListingInvitations = { @MainActor in
            #expect(await leslie.main.rejectInvitation(invitation))
        }
        try await leslie.sync.refreshIncomingInvitations()
        #expect(leslie.main.incomingInvitations.map(\.id) == [second.id])
    }

    @Test(arguments: [false, true])
    func anOlderOutgoingReplyCannotUndoSendingOrCancelling(send: Bool) async throws {
        let server = InMemoryReadableServer()
        let robin = try await EmailPerson("robin@example.com", on: server)
        let (group, first) = try await robin.offer()
        robin.transport.whileListingOutgoingInvitations = { @MainActor in
            if send {
                _ = try? await robin.offer(to: "pat@example.com", groupID: group)
            } else {
                try? await robin.sync.cancelInvite(first.id, in: group)
            }
        }
        await robin.sync.refresh(group)
        let pending = robin.sync.pendingInvites(in: group)
        if send { #expect(Set(pending.compactMap(\.email)) == ["leslie@example.com", "pat@example.com"]) }
        else { #expect(pending.isEmpty) }
    }

    @Test func acceptingAHiddenGroupKeepsQueuedEditsWhenItsFirstPushFails() async throws {
        let server = InMemoryReadableServer()
        let robin = try await EmailPerson("robin@example.com", on: server)
        let leslie = try await EmailPerson("leslie@example.com", on: server)
        let (group, _) = try await robin.offer()
        try await leslie.sync.refreshIncomingInvitations()
        #expect(await leslie.main.acceptInvitation(try #require(leslie.main.incomingInvitations.first)))
        let budget = try #require(try leslie.sync.store.budgets(in: group).first { $0.name == "Groceries" })
        leslie.model.selectedBudget = budget.id
        leslie.model.addTransaction(merchant: "Saved offline", amount: Money(minorUnits: 9900), date: Date(), note: "")
        leslie.model.deleteGroup(group, reach: .thisMacOnly)
        let queued = try leslie.sync.store.outboxCount(in: group)
        #expect(queued > 0)
        try await robin.transport.remove(try #require(leslie.sync.userID), from: group)
        _ = try await robin.offer(groupID: group)
        try await leslie.sync.refreshIncomingInvitations()
        let invitation = try #require(leslie.main.incomingInvitations.first)
        leslie.transport.failNextPush = URLError(.networkConnectionLost)
        #expect(await leslie.main.acceptInvitation(invitation))
        #expect(leslie.main.incomingInvitations.isEmpty && leslie.main.openGroup?.id == group)
        #expect(leslie.main.syncFailure != nil)
        #expect(try leslie.sync.store.outboxCount(in: group) == queued)
        #expect(try leslie.sync.store.serverGroup(group)?.removedAt != nil, "the restoration can resume after relaunch")
        await leslie.main.syncNow()
        #expect(leslie.main.syncFailure == nil)
        #expect(try leslie.sync.store.outboxCount(in: group) == 0)
        #expect(try leslie.sync.store.serverGroup(group)?.removedAt == nil)
        #expect(try leslie.sync.store.transactions(in: budget.id).map(\.merchant) == ["Saved offline"])
        await robin.sync.syncAll()
        #expect(try robin.sync.store.transactions(in: budget.id).map(\.merchant) == ["Saved offline"])
    }

    @Test func onlyTheConfirmedRecipientCanSeeOrAnswerAnInvitation() async throws {
        let server = InMemoryReadableServer()
        let robin = try await EmailPerson("robin@example.com", on: server)
        let leslie = try await EmailPerson("leslie@example.com", on: server, confirmed: false)
        let pat = try await EmailPerson("pat@example.com", on: server)
        let (_, sent) = try await robin.offer(to: " mailto:LESLIE@example.com ")
        await leslie.sync.syncAll()
        await pat.sync.syncAll()
        #expect(leslie.main.incomingInvitations.isEmpty)
        #expect(pat.main.incomingInvitations.isEmpty)
        for reject in [false, true] {
            do {
                if reject { try await pat.transport.rejectInvitation(sent.id) }
                else { _ = try await pat.transport.acceptInvitation(sent.id) }
                Issue.record("another account answered the invitation")
            } catch ReadableTransportError.http(let status, _) { #expect(status == 404) }
        }
        do {
            _ = try await leslie.transport.acceptInvitation(sent.id)
            Issue.record("an unconfirmed account accepted")
        } catch ReadableTransportError.http(let status, _) { #expect(status == 403) }
        try await leslie.sync.verifyEmail(code: try #require(server.lastCode(for: "leslie@example.com", purpose: .verify)))
        #expect(leslie.main.incomingInvitations.map(\.id) == [sent.id])
    }

    @Test func viewAndFromNowStillReceiveAllBudgetNamesAndTheInvitedName() async throws {
        let server = InMemoryReadableServer()
        let robin = try await EmailPerson("robin@example.com", on: server)
        let (group, _) = try await robin.offer(role: .view, history: .fromNow)
        let leslie = try await EmailPerson("leslie@example.com", on: server)
        // The invitation existed before this account was created and confirmed.
        let invitation = try #require(leslie.main.incomingInvitations.first)
        #expect(await leslie.main.acceptInvitation(invitation))
        #expect(Set(try leslie.sync.store.budgets(in: group).map(\.name)) == ["Groceries", "Travel"])
        #expect(try leslie.sync.displayName(in: group) == "Leslie")
        #expect(!leslie.sync.mayAddEntries(in: group))
    }

    @Test func duplicatePendingIsRefusedAndCancellationRemovesItFromBothSides() async throws {
        let server = InMemoryReadableServer()
        let robin = try await EmailPerson("robin@example.com", on: server)
        let leslie = try await EmailPerson("leslie@example.com", on: server)
        let (group, sent) = try await robin.offer()
        do {
            _ = try await robin.sync.sendEmailInvitation(group: group, groupName: "Household", email: "leslie@example.com",
                inviteeName: "Leslie", myName: "Robin", level: .write, history: .all)
            Issue.record("a second pending invite was sent")
        } catch {}
        let people = MembersScreen(actions: robin.sync, group: group, groupName: "Household")
        #expect(people.canCancelInvite(sent.id))
        await people.cancelInvite(sent.id)
        #expect(people.pendingInvites.isEmpty)
        try await robin.transport.cancelInvite(sent.id, in: group)
        await leslie.sync.syncAll()
        #expect(leslie.main.incomingInvitations.isEmpty)
        #expect(try leslie.sync.store.group(group) == nil)
    }

    @Test func aLateInboxResponseCannotReappearAfterSignOut() async throws {
        let server = InMemoryReadableServer()
        let robin = try await EmailPerson("robin@example.com", on: server)
        let leslie = try await EmailPerson("leslie@example.com", on: server)
        _ = try await robin.offer()
        let sync = leslie.sync
        leslie.transport.whileListingInvitations = { await sync.signOut() }
        await sync.syncAll()
        #expect(sync.state == .signedOut)
        #expect(sync.incomingInvitations.isEmpty && sync.outgoingInvitations.isEmpty)
    }

    @Test func anEmailedLinkPrefillsTheInvitedNameAndAcceptsWithoutOverwritingIt() async throws {
        let server = InMemoryReadableServer()
        let robin = try await EmailPerson("robin@example.com", on: server)
        let leslie = try await EmailPerson("leslie@example.com", on: server)
        let (group, sent) = try await robin.offer(role: .view)
        let token = try #require(server.emailedInvitationToken(for: sent.id))
        let url = try #require(URL(string: "\(leslie.sync.environment.inviteScheme)://join#s=\(token)&g=Household&f=Robin"))
        await leslie.workspace.open(url)
        let page = try #require(leslie.main.invitation)
        #expect(page.isAddressedInvitation && page.canJoin)
        #expect(page.myName == "Leslie" && page.joinLabel == "Accept")
        page.myName = "Another name"
        #expect(await leslie.main.joinInvitation())
        #expect(leslie.main.openGroup?.id == group)
        #expect(try leslie.sync.displayName(in: group) == "Leslie")
        #expect(!leslie.sync.mayAddEntries(in: group))
        #expect(Set(try leslie.sync.store.budgets(in: group).map(\.name)) == ["Groceries", "Travel"])
    }

    @Test func anEmailedLinkCannotJoinAnotherAccountEvenWithTheRightName() async throws {
        let server = InMemoryReadableServer()
        let robin = try await EmailPerson("robin@example.com", on: server)
        let pat = try await EmailPerson("pat@example.com", on: server)
        let (group, sent) = try await robin.offer()
        let token = try #require(server.emailedInvitationToken(for: sent.id))
        let url = try #require(URL(string: "\(pat.sync.environment.inviteScheme)://join#s=\(token)&g=Household&f=Robin"))
        await pat.workspace.open(url)
        let page = try #require(pat.main.invitation)
        #expect(page.myName == "Leslie")
        #expect(await !pat.main.joinInvitation())
        #expect(page.failure != nil)
        #expect(try pat.sync.store.group(group) == nil)
        #expect(pat.main.openGroup == nil)
    }

    @Test func changingAPastedLinkClearsItsAddressedNameAndKeepsLegacyJoining() async throws {
        let server = InMemoryReadableServer()
        let robin = try await EmailPerson("robin@example.com", on: server)
        let leslie = try await EmailPerson("leslie@example.com", on: server)
        let (group, sent) = try await robin.offer()
        let token = try #require(server.emailedInvitationToken(for: sent.id))
        let addressed = "\(leslie.sync.environment.inviteScheme)://join#s=\(token)&g=Household&f=Robin"
        let legacy = try await robin.sync.share(group: group, groupName: "Household", level: .write,
                                               historyAccess: .all, myName: "Robin")
        let page = JoinScreen(actions: leslie.sync, linkText: addressed)
        await page.lookUp()
        #expect(page.isAddressedInvitation && page.myName == "Leslie")
        page.linkText = legacy.url
        #expect(page.terms == nil && page.myName.isEmpty && !page.isAddressedInvitation)
        await page.lookUp()
        #expect(page.joinLabel == "Join" && !page.canJoin)
        page.myName = "My chosen name"
        #expect(await page.join())
        #expect(try leslie.sync.displayName(in: group) == "My chosen name")
    }

    @Test func aLookupOrJoinCannotUseTheInvitationThatWasReplacedWhileWaiting() async throws {
        let server = InMemoryReadableServer()
        let robin = try await EmailPerson("robin@example.com", on: server)
        let leslie = try await EmailPerson("leslie@example.com", on: server)
        let (group, sent) = try await robin.offer()
        let token = try #require(server.emailedInvitationToken(for: sent.id))
        let addressed = "\(leslie.sync.environment.inviteScheme)://join#s=\(token)&g=Household&f=Robin"
        let page = JoinScreen(actions: leslie.sync, linkText: addressed)
        leslie.transport.whilePreviewing = { @MainActor in page.linkText = "" }
        await page.lookUp()
        #expect(page.terms == nil && page.myName.isEmpty)
        page.linkText = addressed
        page.myName = "Leslie"
        #expect(await !page.join())
        #expect(page.joined == nil && page.terms == nil)
        #expect(try leslie.sync.store.group(group) == nil)
        #expect(try await leslie.transport.incomingInvitations().map(\.id) == [sent.id])
    }

    @Test func joiningThroughAnOldLinkThenLeavingDoesNotReviveTheEmailInvitation() async throws {
        let server = InMemoryReadableServer()
        let robin = try await EmailPerson("robin@example.com", on: server)
        let leslie = try await EmailPerson("leslie@example.com", on: server)
        let (group, addressed) = try await robin.offer()
        let link = try await robin.sync.share(group: group, groupName: "Household", level: .write,
                                               historyAccess: .all, myName: "Robin")
        _ = try await leslie.sync.join(link, myName: "Leslie")
        try await leslie.sync.leave(group)
        await leslie.sync.syncAll()
        #expect(leslie.main.incomingInvitations.isEmpty)
        do {
            _ = try await leslie.transport.acceptInvitation(addressed.id)
            Issue.record("joining through a link left an email invitation reusable")
        } catch ReadableTransportError.http(let status, _) { #expect(status == 404) }
    }

    @Test func anAcceptReplyAfterAccountSwitchDoesNotJoinTheNewAccountsLocalStore() async throws {
        let server = InMemoryReadableServer()
        let robin = try await EmailPerson("robin@example.com", on: server)
        let leslie = try await EmailPerson("leslie@example.com", on: server)
        let (group, _) = try await robin.offer()
        await leslie.sync.syncAll()
        let invitation = try #require(leslie.main.incomingInvitations.first)
        server.seedAccount(email: "pat@example.com", password: "a-long-password", verified: true)
        let sync = leslie.sync
        leslie.transport.whileAcceptingEmailInvitation = {
            await sync.signOut()
            try? await sync.signIn(email: "pat@example.com", password: "a-long-password")
        }
        #expect(await !leslie.main.acceptInvitation(invitation))
        #expect(sync.account == "pat@example.com")
        #expect(sync.incomingInvitations.isEmpty)
        #expect(try sync.store.group(group) == nil)
        #expect(leslie.main.openGroup == nil)
    }

    @Test func aRejectReplyAfterSignOutDoesNotChangeTheSignedOutState() async throws {
        let server = InMemoryReadableServer()
        let robin = try await EmailPerson("robin@example.com", on: server)
        let leslie = try await EmailPerson("leslie@example.com", on: server)
        _ = try await robin.offer()
        await leslie.sync.syncAll()
        let invitation = try #require(leslie.main.incomingInvitations.first)
        let sync = leslie.sync
        leslie.transport.whileRejectingEmailInvitation = { await sync.signOut() }
        #expect(await !leslie.main.rejectInvitation(invitation))
        #expect(sync.state == .signedOut)
        #expect(leslie.main.incomingInvitations.isEmpty)
        #expect(leslie.main.invitationFailure(for: invitation.id) == nil)
    }

    @Test func emailFormNeedsBothNamesAndValidEmailAndDefaultsToAddWithAllHistory() async throws {
        let robin = try await EmailPerson("robin@example.com", on: InMemoryReadableServer())
        let group = try #require(robin.model.addGroup(named: "Household"))
        let screen = EmailInviteScreen(actions: robin.sync, group: group, groupName: "Household")
        #expect(screen.role == .add && screen.history == .all)
        screen.myName = "Robin"
        screen.inviteeName = "Leslie"
        screen.email = "leslie@example"
        #expect(!screen.canSend)
        screen.email = "leslie@example.com"
        #expect(screen.canSend)
        screen.inviteeName = " \n "
        #expect(!screen.canSend)
        for invalid in [String(repeating: "x", count: 51), "Les\u{0001}lie", "Les\u{200B}lie"] {
            screen.inviteeName = invalid
            #expect(!screen.canSend)
            #expect(screen.notice == EmailInviteScreen.Words.nameProblem)
        }
        screen.inviteeName = String(repeating: "x", count: 50)
        #expect(screen.canSend)

        let unconfirmed = try await EmailPerson("pat@example.com", on: InMemoryReadableServer(), confirmed: false)
        let ownGroup = try #require(unconfirmed.model.addGroup(named: "Household"))
        let waiting = EmailInviteScreen(actions: unconfirmed.sync, group: ownGroup, groupName: "Household")
        waiting.email = "leslie@example.com"
        waiting.inviteeName = "Leslie"
        waiting.myName = "Pat"
        #expect(!waiting.canSend)
        #expect(waiting.notice == "Confirm your email before inviting someone.")
    }
}
