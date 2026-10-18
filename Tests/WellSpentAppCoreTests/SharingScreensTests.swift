import Testing
import Foundation
@testable import WellSpentAppCore
import WellSpentCrypto
import WellSpentKeyStore
import WellSpentModel
import WellSpentStore
import WellSpentSync

/// One person's device on a shared in-memory server, signed up and, unless
/// asked otherwise, with the email confirmed.
@MainActor
private struct Person {
    let store: Store
    let sync: SyncCoordinator
    let model: AppModel

    init(_ email: String, on server: InMemoryReadableServer, confirmed: Bool = true) async throws {
        let store = Store(database: try WellSpentDatabase.inMemory())
        let transport = StubReadableTransport(server: server)
        self.store = store
        sync = SyncCoordinator(store: store, keyStore: InMemoryKeyStore(), defaults: isolatedDefaults(),
                               makeTransport: { _ in transport })
        model = AppModel(store: store)
        try await sync.signUp(email: email, password: "a-long-password")
        if confirmed {
            try await sync.verifyEmail(code: try #require(server.lastCode(for: email, purpose: .verify)))
        }
    }
}

/// Robin's Household, shared with Leslie at `level` through the screens.
@MainActor
private func household(leslieAt level: InviteRole = .add) async throws
    -> (robin: Person, leslie: Person, group: GroupID) {
    let server = InMemoryReadableServer()
    let robin = try await Person("robin@example.com", on: server)
    robin.model.addGroup(named: "Household")
    let group = try #require(robin.model.groups.first)

    let share = ShareScreen(actions: robin.sync, group: group.id, groupName: group.name)
    share.myName = "Robin"
    share.role = level
    #expect(await share.create())
    let link = try #require(share.link)

    let leslie = try await Person("leslie@example.com", on: server)
    let join = JoinScreen(actions: leslie.sync, linkText: link.url)
    join.myName = "Leslie"
    #expect(await join.join())
    await robin.sync.syncAll()
    return (robin, leslie, group.id)
}

@Suite("Sharing screens", .serialized)
@MainActor
struct SharingScreensTests {
    // MARK: - Share

    @Test func theOwnerMayInviteAtEveryRoleAndGetsALink() async throws {
        let server = InMemoryReadableServer()
        let robin = try await Person("robin@example.com", on: server)
        robin.model.addGroup(named: "Household")
        let group = try #require(robin.model.groups.first)
        let share = ShareScreen(actions: robin.sync, group: group.id, groupName: group.name)

        #expect(share.title == "Share \u{201C}Household\u{201D}")
        #expect(share.roles == [.view, .add, .manage])
        #expect(share.role == .add)
        #expect(!share.canCreate, "a name is needed first")
        share.myName = "Robin"
        #expect(share.canCreate)
        #expect(share.createLabel == "Create Link")

        #expect(await share.create())
        let link = try #require(share.link)
        #expect(link.groupName == "Household" && link.inviterName == "Robin")
    }

    @Test func signedOutThereIsNoLink() throws {
        let sync = SyncCoordinator(store: Store(database: try WellSpentDatabase.inMemory()),
                                   keyStore: InMemoryKeyStore(), defaults: isolatedDefaults())
        let share = ShareScreen(actions: sync, group: GroupID(), groupName: "Household")
        share.myName = "Robin"
        #expect(share.notice == "Sign in first. Sharing goes through your account.")
        #expect(!share.canCreate)
    }

    /// Someone at Add cannot invite anyone, so no role is offered and the
    /// screen says why.
    @Test func aMemberAtAddMayNotInvite() async throws {
        let (_, leslie, group) = try await household(leslieAt: .add)
        let share = ShareScreen(actions: leslie.sync, group: group, groupName: "Household")
        share.myName = "Leslie"
        #expect(share.roles.isEmpty)
        #expect(share.notice == "Only a manager or admin can invite people to this group.")
        #expect(!share.canCreate)
    }

    /// A manager may invite at View and Add; Manage takes an admin, as the
    /// server decides.
    @Test func aManagerMayInviteAtViewAndAdd() async throws {
        let (_, leslie, group) = try await household(leslieAt: .manage)
        let share = ShareScreen(actions: leslie.sync, group: group, groupName: "Household")
        #expect(share.roles == [.view, .add])
    }

    // MARK: - Join

    @Test func joiningSaysWhoInvitedAndAddsTheGroup() async throws {
        let (_, leslie, group) = try await household()
        #expect(try leslie.store.group(group)?.name == "Household")
    }

    @Test func aPastedLinkSaysWhoInvitedYou() async throws {
        let server = InMemoryReadableServer()
        let leslie = try await Person("leslie@example.com", on: server)
        let link = try #require(InviteLink(secret: Data(repeating: 1, count: 32), groupName: "Household",
                                           inviterName: "Robin"))
        let join = JoinScreen(actions: leslie.sync, linkText: "not a link")
        #expect(join.linkProblem == "That is not a WellSpent invite link.")
        #expect(join.invitation == nil)
        join.linkText = link.url
        #expect(join.linkProblem == nil)
        #expect(join.invitation == "Robin invited you to \u{201C}Household\u{201D}.")
        #expect(!join.canJoin, "a name is needed")
        join.myName = "Leslie"
        #expect(join.canJoin)
    }

    /// An address not confirmed yet is said before anything is sent, and the
    /// refusal is in words if Join is pressed anyway.
    @Test func joiningNeedsAConfirmedEmail() async throws {
        let server = InMemoryReadableServer()
        let leslie = try await Person("leslie@example.com", on: server, confirmed: false)
        let link = try #require(InviteLink(secret: Data(repeating: 1, count: 32), groupName: "Household",
                                           inviterName: "Robin"))
        let join = JoinScreen(actions: leslie.sync, linkText: link.url)
        join.myName = "Leslie"
        #expect(join.notice == "Confirm your email first. Joining a shared group needs it.")
        #expect(join.offersEmailConfirmation)

        #expect(await !join.join())
        #expect(join.failure == "Confirm your email address first, then try again.")
    }

    // MARK: - Members

    @Test func theOwnerSeesEveryoneAndMayChangeThem() async throws {
        let (robin, _, group) = try await household(leslieAt: .add)
        let members = MembersScreen(actions: robin.sync, group: group, groupName: "Household")

        #expect(members.title == "People in \u{201C}Household\u{201D}")
        #expect(members.rows.map(\.label) == ["Robin (you)", "Leslie"])
        #expect(members.rows.map(\.levelTitle) == ["Owner", "Add"])
        let me = members.rows[0], leslie = members.rows[1]
        #expect(me.isFounder && me.levelChoices.isEmpty && !me.mayRemove)
        #expect(leslie.levelChoices == [.read, .write, .manage, .admin])
        #expect(leslie.mayRemove)
        #expect(!members.mayLeave, "the founder deletes the group instead")
        #expect(members.mayInvite)

        await members.setLevel(.read, for: leslie.id)
        #expect(members.failure == nil)
        #expect(members.rows[1].levelTitle == "View")

        members.askToRemove(leslie.id)
        #expect(members.removeQuestion == "Remove Leslie?")
        #expect(members.removeMessage == "Leslie loses \u{201C}Household\u{201D} on every device. What they added stays.")
        // The dialog may clear its question before the button runs; the
        // removal goes by who was asked about, not by what is still open.
        members.keepThem()
        members.remove(leslie.id)
        await members.pending?.value
        #expect(members.failure == nil)
        #expect(members.rows.map(\.label) == ["Robin (you)"])
    }

    /// Someone who joined after this device's last sync shows, with their
    /// name, once the screen refreshes as it opens.
    @Test func openingThePeopleScreenShowsWhoJustJoined() async throws {
        let server = InMemoryReadableServer()
        let robin = try await Person("robin@example.com", on: server)
        robin.model.addGroup(named: "Household")
        let group = try #require(robin.model.groups.first)
        let share = ShareScreen(actions: robin.sync, group: group.id, groupName: group.name)
        share.myName = "Robin"
        #expect(await share.create())
        let leslie = try await Person("leslie@example.com", on: server)
        let join = JoinScreen(actions: leslie.sync, linkText: try #require(share.link).url)
        join.myName = "Leslie"
        #expect(await join.join())

        let members = MembersScreen(actions: robin.sync, group: group.id, groupName: group.name)
        #expect(members.rows.map(\.label) == ["Robin (you)"], "not synced since Leslie joined")
        await members.refresh()
        #expect(members.rows.map(\.label) == ["Robin (you)", "Leslie"])
    }

    /// A member at Add changes nobody, removes nobody, and may leave.
    @Test func aMemberAtAddMayOnlyLeave() async throws {
        let (_, leslie, group) = try await household(leslieAt: .add)
        await leslie.sync.syncAll()
        let members = MembersScreen(actions: leslie.sync, group: group, groupName: "Household")

        #expect(members.rows.map(\.label) == ["Robin", "Leslie (you)"])
        #expect(members.rows.allSatisfy { $0.levelChoices.isEmpty && !$0.mayRemove })
        #expect(members.mayLeave)
        #expect(!members.mayInvite)
    }

    /// A manager may move someone between View and Add, not to Manage, and
    /// may not remove another manager: both take an admin.
    @Test func aManagersChoicesFollowTheServersRules() {
        let me = UserID(), founder = UserID(), adder = UserID(), manager = UserID()
        let actions = StubSharing(me: me, founder: founder,
                                  members: [me: .manage, founder: .superadmin, adder: .write, manager: .manage])
        let members = MembersScreen(actions: actions, group: GroupID(), groupName: "Household")
        let byID = Dictionary(uniqueKeysWithValues: members.rows.map { ($0.id, $0) })

        #expect(byID[adder]?.levelChoices == [.read, .write])
        #expect(byID[adder]?.mayRemove == true)
        #expect(byID[manager]?.levelChoices == [])
        #expect(byID[manager]?.mayRemove == false)
        #expect(byID[founder]?.levelChoices == [] && byID[founder]?.mayRemove == false)
    }

    /// A group still only on this device: its one member is this person, as
    /// its owner.
    @Test func aGroupNotSharedYetListsOnlyYou() {
        let me = UserID()
        let actions = StubSharing(me: me, founder: nil, members: [:])
        let members = MembersScreen(actions: actions, group: GroupID(), groupName: "Household")
        #expect(members.rows.map(\.label) == ["Someone (you)"])
        #expect(members.rows.map(\.levelTitle) == ["Owner"])
        #expect(ShareScreen(actions: actions, group: GroupID(), groupName: "Household").roles == [.view, .add, .manage])
    }

    // MARK: - A group's page

    /// One line under the group's name: whether it is shared, how many
    /// people are in it, and who made it.
    @Test func aGroupsPageSaysWhetherItIsSharedHowManyAreInItAndWhoMadeIt() async throws {
        let (robin, leslie, group) = try await household(leslieAt: .add)
        await leslie.sync.syncAll()
        #expect(MembersScreen(actions: robin.sync, group: group, groupName: "Household").summary
                == "Shared \u{00B7} 2 people \u{00B7} Made by you")
        #expect(MembersScreen(actions: leslie.sync, group: group, groupName: "Household").summary
                == "Shared \u{00B7} 2 people \u{00B7} Made by Robin")

        let bookClub = try #require(robin.model.addGroup(named: "Book Club"))
        #expect(MembersScreen(actions: robin.sync, group: bookClub, groupName: "Book Club").summary
                == "Not shared \u{00B7} 1 person \u{00B7} Made by you")
    }

    /// Who made it is left out when nobody here knows their name. A device
    /// that is signed out knows nobody, so it says only that it is not shared.
    @Test func whoMadeAGroupIsLeftOutWhenTheirNameIsNotKnown() throws {
        let me = UserID(), founder = UserID()
        let actions = StubSharing(me: me, founder: founder, members: [me: .write, founder: .superadmin])
        #expect(MembersScreen(actions: actions, group: GroupID(), groupName: "Household").summary
                == "Shared \u{00B7} 2 people")

        let signedOut = SyncCoordinator(store: Store(database: try WellSpentDatabase.inMemory()),
                                        keyStore: InMemoryKeyStore(), defaults: isolatedDefaults())
        #expect(MembersScreen(actions: signedOut, group: GroupID(), groupName: "Household").summary == "Not shared")
    }

    /// After a removal, a quiet line on the page says who went. No pop-up.
    @Test func afterRemovingSomeoneThePageSaysTheyWereRemoved() async throws {
        let (robin, _, group) = try await household(leslieAt: .add)
        let members = MembersScreen(actions: robin.sync, group: group, groupName: "Household")
        let leslie = try #require(members.rows.first { !$0.isYou })
        #expect(members.removedNote == nil)

        members.askToRemove(leslie.id)
        members.remove(leslie.id)
        await members.pending?.value
        #expect(members.failure == nil)
        #expect(members.removedNote == "Leslie was removed.")
        #expect(members.rows.map(\.label) == ["Robin (you)"])
        #expect(members.summary == "Not shared \u{00B7} 1 person \u{00B7} Made by you")
    }

    /// The line stays until the next change on the page. Asking about
    /// someone, then keeping them, is not a change. A removal that fails
    /// says why, and says nobody was removed.
    @Test func theRemovedLineStaysUntilTheNextChange() async {
        let me = UserID(), leslie = UserID(), other = UserID()
        let actions = StubSharing(me: me, founder: me, members: [me: .superadmin, leslie: .write, other: .read],
                                  names: [me: "Robin", leslie: "Leslie"])
        let members = MembersScreen(actions: actions, group: GroupID(), groupName: "Household")
        members.remove(leslie)
        await members.pending?.value
        #expect(members.removedNote == "Leslie was removed.")

        members.askToRemove(other)
        members.keepThem()
        #expect(members.removedNote == "Leslie was removed.")
        await members.setLevel(.write, for: other)
        #expect(members.failure == nil)
        #expect(members.removedNote == nil, "a change of level is the next change")

        actions.refusesRemoval = true
        members.remove(other)
        await members.pending?.value
        #expect(members.failure == "Something went wrong. Try again.")
        #expect(members.removedNote == nil)
        #expect(members.rows.contains { $0.id == other })
    }

    @Test func theWordsArePlain() {
        let words = [
            ShareScreen.Words.shareTitle("Household"), ShareScreen.Words.name, ShareScreen.Words.namePrompt,
            ShareScreen.Words.role, ShareScreen.Words.history, ShareScreen.Words.historyAll,
            ShareScreen.Words.historyFromNow, ShareScreen.Words.signInToShare, ShareScreen.Words.cannotInvite,
            ShareScreen.Words.linkNote, ShareScreen.Words.createLink, ShareScreen.Words.creating,
            ShareScreen.Words.send, ShareScreen.Words.copyLink, ShareScreen.Words.done, ShareScreen.Words.cancel,
            JoinScreen.Words.title, JoinScreen.Words.link, JoinScreen.Words.linkPrompt, JoinScreen.Words.name,
            JoinScreen.Words.namePrompt, JoinScreen.Words.notALink, JoinScreen.Words.signInToJoin,
            JoinScreen.Words.confirmToJoin, JoinScreen.Words.confirmEmail, JoinScreen.Words.join,
            JoinScreen.Words.joining, JoinScreen.Words.cancel,
            MembersScreen.Words.title("Household"), MembersScreen.Words.someone, MembersScreen.Words.you("Robin"),
            MembersScreen.Words.level, MembersScreen.Words.remove, MembersScreen.Words.removeTitle("Leslie"),
            MembersScreen.Words.removeMessage("Leslie", "Household"), MembersScreen.Words.removeButton,
            MembersScreen.Words.leave, MembersScreen.Words.invite, MembersScreen.Words.done,
            MembersScreen.Words.menuItem, MembersScreen.Words.leaveTitle("Household"), MembersScreen.Words.leaveButton,
            MembersScreen.Words.cancel, MembersScreen.Words.people, MembersScreen.Words.shared,
            MembersScreen.Words.notShared, MembersScreen.Words.peopleCount(1), MembersScreen.Words.peopleCount(3),
            MembersScreen.Words.madeByYou, MembersScreen.Words.madeBy("Robin"), MembersScreen.Words.removed("Leslie"),
        ] + AccessLevel.allCases.flatMap { [MembersScreen.Words.levelTitle($0), MembersScreen.Words.levelExplanation($0)] }
        for text in words {
            #expect(!text.contains("Mac"), "\(text)")
            #expect(!text.contains("\u{2014}") && !text.contains("--"), "\(text)")
            #expect(!text.contains(";"), "\(text)")
        }
    }
}

/// Sharing answers from a fixed list, for checking the rules alone.
@MainActor
private final class StubSharing: SharingActions {
    let account: String? = "me@example.com"
    let userID: UserID?
    let emailVerified = true
    private let founderID: UserID?
    private var list: [UserID: AccessLevel]
    private let names: [UserID: String]
    /// Set to refuse every removal, as a server would.
    var refusesRemoval = false

    init(me: UserID, founder: UserID?, members: [UserID: AccessLevel], names: [UserID: String] = [:]) {
        userID = me
        founderID = founder
        list = members
        self.names = names
    }

    func displayName(in group: GroupID) throws -> String? { nil }
    func share(group: GroupID, groupName: String, level: AccessLevel, historyAccess: HistoryAccess,
               myName: String) async throws -> InviteLink { throw CancellationError() }
    func join(_ link: InviteLink, myName: String) async throws -> PendingJoin { throw CancellationError() }
    func members(of group: GroupID) -> [UserID: AccessLevel] { list }
    func memberNames(in group: GroupID) -> [UserID: String] { names }
    func founder(of group: GroupID) -> UserID? { founderID }
    func setLevel(_ level: AccessLevel, of user: UserID, in group: GroupID) async throws { list[user] = level }
    func remove(_ user: UserID, from group: GroupID) async throws {
        if refusesRemoval { throw CancellationError() }
        list[user] = nil
    }
    func refresh(_ group: GroupID) async {}
    func mayAddEntries(in group: GroupID) -> Bool { members(of: group)[userID ?? UserID()].map { $0.allows(.write) } ?? true }
}
