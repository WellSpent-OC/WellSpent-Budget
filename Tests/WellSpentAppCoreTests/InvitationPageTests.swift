import Testing
import Foundation
@testable import WellSpentAppCore
import WellSpentCrypto
import WellSpentKeyStore
import WellSpentModel
import WellSpentStore
import WellSpentSync

/// One person's device on a shared in-memory server, with its window:
/// signed out, signed up with the address not confirmed yet, or confirmed.
@MainActor
private struct Device {
    enum Account { case signedOut, unconfirmed, confirmed }

    let sync: SyncCoordinator
    let workspace: Workspace
    let screen: MainScreen
    /// What this device's calls to the server go through.
    let transport: StubReadableTransport
    var model: AppModel { workspace.model }

    init(_ email: String, _ account: Account = .confirmed, on server: InMemoryReadableServer) async throws {
        let store = Store(database: try WellSpentDatabase.inMemory())
        let transport = StubReadableTransport(server: server)
        self.transport = transport
        sync = SyncCoordinator(store: store, keyStore: InMemoryKeyStore(), defaults: isolatedDefaults(),
                               makeTransport: { _ in transport })
        workspace = Workspace(model: AppModel(store: store), sync: sync)
        screen = MainScreen(workspace: workspace)
        guard account != .signedOut else { return }
        try await sync.signUp(email: email, password: "a-long-password")
        if account == .confirmed {
            try await sync.verifyEmail(code: try #require(server.lastCode(for: email, purpose: .verify)))
        }
    }
}

/// Robin's Household on `server`, with a Groceries budget, and the link he
/// made for it as "Robin": it invites at `role`, seeing `history`.
@MainActor
private func robinsLink(on server: InMemoryReadableServer, role: InviteRole = .add,
                        history: HistoryAccess = .all) async throws -> (group: GroupID, url: URL) {
    let robin = try await Device("robin@example.com", on: server)
    let group = try #require(robin.model.addGroup(named: "Household"))
    robin.model.addBudget(named: "Groceries", limit: .dollars(500), in: group)
    await robin.sync.syncAll()
    let share = ShareScreen(actions: robin.sync, group: group, groupName: "Household")
    share.myName = "Robin"
    share.role = role
    share.history = history
    #expect(await share.create())
    let link = try #require(share.link)
    return (group, try #require(URL(string: link.url)))
}

private let invitedToHousehold = "Robin invited you to \u{201C}Household\u{201D}."

/// Clicking an invite link: the app hands it to `Workspace.open(_:)`, on
/// any desktop, and the invitation page goes up on the right.
@Suite("An opened invite link", .serialized)
@MainActor
struct InvitationPageTests {
    // MARK: - What the page says

    /// Signed in and confirmed: who invited them and to which group, the
    /// level they would have and what it lets them do, and how much they
    /// would see. Then Your name, and Join once a name is in.
    @Test func aWholeLinkPutsUpItsInvitationFilledIn() async throws {
        let server = InMemoryReadableServer()
        let (_, url) = try await robinsLink(on: server)
        let leslie = try await Device("leslie@example.com", on: server)

        await leslie.workspace.open(url)

        let page = try #require(leslie.workspace.invitation)
        #expect(leslie.screen.invitation === page, "the window shows it")
        #expect(page.invitation == invitedToHousehold)
        #expect(page.levelLine == "You'd join at Add.")
        #expect(page.levelTitle == "Add")
        #expect(page.levelExplanation == "Adds transactions, and edits or deletes their own.")
        #expect(page.historyLine == "You'd see everything so far.")
        #expect(page.notice == nil)
        #expect(page.linkProblem == nil)
        #expect(page.failure == nil)
        #expect(!page.canJoin, "a name is needed first")
        page.myName = "Leslie"
        #expect(page.canJoin)
        #expect(page.joinLabel == "Join")
    }

    /// The level and the history are the invite's own: View, from now on.
    @Test func theInvitationSaysTheLevelAndHowMuchTheInviteGives() async throws {
        let server = InMemoryReadableServer()
        let (_, url) = try await robinsLink(on: server, role: .view, history: .fromNow)
        let leslie = try await Device("leslie@example.com", on: server)

        await leslie.workspace.open(url)

        let page = try #require(leslie.workspace.invitation)
        #expect(page.levelLine == "You'd join at View.")
        #expect(page.levelExplanation == "Sees every budget and transaction. Changes nothing.")
        #expect(page.historyLine == "You'd see the group's budgets, and only transactions added from now on.")
    }

    /// The page is up the moment the link opens, while the server is still
    /// being asked what the invite offers. A slow server never makes the
    /// click look like it did nothing.
    @Test func thePageIsUpBeforeTheServerAnswers() async throws {
        let server = InMemoryReadableServer()
        let (_, url) = try await robinsLink(on: server)
        let leslie = try await Device("leslie@example.com", on: server)
        let workspace = leslie.workspace

        await confirmation("the server is asked what the invite offers") { asked in
            leslie.transport.whilePreviewing = { @MainActor in
                #expect(workspace.invitation?.invitation == invitedToHousehold,
                        "the page was not up while the server was asked")
                #expect(workspace.invitation?.levelLine == nil, "the level is not known yet")
                asked()
            }
            await workspace.open(url)
        }

        #expect(workspace.invitation?.levelLine == "You'd join at Add.")
    }

    /// Join takes the group in. The page gives way to the group's own page.
    @Test func joiningFromTheInvitationOpensTheGroupsPage() async throws {
        let server = InMemoryReadableServer()
        let (group, url) = try await robinsLink(on: server)
        let leslie = try await Device("leslie@example.com", on: server)
        await leslie.workspace.open(url)
        let page = try #require(leslie.workspace.invitation)
        page.myName = "Leslie"

        #expect(await leslie.screen.joinInvitation())

        #expect(leslie.workspace.invitation == nil)
        #expect(leslie.screen.invitation == nil)
        #expect(leslie.model.groups.map(\.id).contains(group))
        #expect(leslie.screen.openGroup?.id == group)
        #expect(try leslie.sync.displayName(in: group) == "Leslie")
    }

    /// Another link opened while Join is still going through: its page
    /// stays up. The group just joined is on the left, and its page waits
    /// for a click.
    @Test func aLinkOpenedWhileJoiningStaysUp() async throws {
        let server = InMemoryReadableServer()
        let (group, url) = try await robinsLink(on: server)
        let leslie = try await Device("leslie@example.com", on: server)
        let workspace = leslie.workspace
        await workspace.open(url)
        let page = try #require(workspace.invitation)
        page.myName = "Leslie"
        let scheme = try #require(url.scheme)
        let another = try #require(URL(string: "\(scheme)://join"))
        leslie.transport.whileAccepting = { await workspace.open(another) }

        #expect(await leslie.screen.joinInvitation())

        #expect(leslie.model.groups.map(\.id).contains(group), "the first link's join went through")
        let shown = try #require(workspace.invitation, "the other link's page was taken down")
        #expect(shown !== page)
        #expect(shown.linkProblem
                == "Part of that invite link is missing. Ask the person who sent it to send it again.")
        #expect(leslie.screen.openGroup == nil)
    }

    // MARK: - Links that cannot be used

    /// A link with part of it missing says so, plainly. Nothing is asked of
    /// the server, and there is nothing to join. Something that is not a
    /// WellSpent link at all says that instead, in the Join step's words.
    @Test func aLinkWithPartOfItMissingSaysSo() async throws {
        let server = InMemoryReadableServer()
        let (_, url) = try await robinsLink(on: server)
        let leslie = try await Device("leslie@example.com", on: server)
        let scheme = try #require(url.scheme)
        let cut = try #require(URL(string: String(url.absoluteString.prefix("\(scheme)://join#s=".count + 20))))

        for broken in [cut, try #require(URL(string: "\(scheme)://join#g=Household&f=Robin")),
                       try #require(URL(string: "\(scheme)://join"))] {
            await leslie.workspace.open(broken)

            let page = try #require(leslie.workspace.invitation)
            #expect(page.invite == nil, "\(broken)")
            #expect(page.invitation == nil)
            #expect(page.linkProblem
                    == "Part of that invite link is missing. Ask the person who sent it to send it again.")
            #expect(page.terms == nil && page.failure == nil, "nothing was asked")
            page.myName = "Leslie"
            #expect(!page.canJoin)
            #expect(await !leslie.screen.joinInvitation())
        }

        await leslie.workspace.open(try #require(URL(string: "https://example.com/join")))
        #expect(leslie.workspace.invitation?.linkProblem == "That is not a WellSpent invite link.")
    }

    /// Each build has its own link type, so a click opens the build whose
    /// server made the invite. These tests run as staging, whose links start
    /// wellspent-staging://, and live's start wellspent://, as they always
    /// have. A link from the other build can still be pasted, or opened by
    /// hand. It says which app it is for. Nothing is asked of this build's
    /// server, which has never heard of the invite, and there is nothing to
    /// join.
    @Test func aLinkFromTheOtherBuildSaysWhichAppItIsFor() async throws {
        let server = InMemoryReadableServer()
        let (_, url) = try await robinsLink(on: server)
        let leslie = try await Device("leslie@example.com", on: server)
        #expect(leslie.sync.environment == .staging)
        #expect(url.scheme == "wellspent-staging", "a staging build makes staging's links")
        let rest = try #require(url.absoluteString.components(separatedBy: "://").last)
        let lives = try #require(URL(string: "wellspent://" + rest))

        await leslie.workspace.open(lives)

        let page = try #require(leslie.workspace.invitation)
        #expect(page.linkProblem == "That invite link is for WellSpent. Open it in WellSpent.")
        #expect(page.invite == nil && page.invitation == nil)
        #expect(page.terms == nil && page.failure == nil, "nothing was asked")
        page.myName = "Leslie"
        #expect(!page.canJoin)
        #expect(await !leslie.screen.joinInvitation())
    }

    /// An invite that is used or cancelled says so on the page, before Join
    /// is pressed. Asking changes nothing about the sync.
    @Test func anInviteThatIsGoneSaysWhyOnThePage() async throws {
        let server = InMemoryReadableServer()
        let (_, url) = try await robinsLink(on: server)
        let sam = try await Device("sam@example.com", on: server)
        let join = JoinScreen(actions: sam.sync, linkText: url.absoluteString)
        join.myName = "Sam"
        #expect(await join.join(), "a link works once, and Sam used it")
        let leslie = try await Device("leslie@example.com", on: server)

        await leslie.workspace.open(url)

        let page = try #require(leslie.workspace.invitation)
        #expect(page.invitation == invitedToHousehold, "what the link says still shows")
        #expect(page.levelLine == nil && page.historyLine == nil)
        #expect(page.failure == "That invite was not found. It may have been cancelled.")
        #expect(leslie.sync.state == .signedIn(email: "leslie@example.com"))
    }

    // MARK: - Signed out, or not confirmed yet

    /// Signed out: the page says who invited them, to what and at what
    /// level, and asks them to sign in first, with Sign in… in place of
    /// Join. The page stays while they sign up and confirm, then has Join.
    @Test func signedOutTheInvitationAsksThemToSignInFirst() async throws {
        let server = InMemoryReadableServer()
        let (group, url) = try await robinsLink(on: server)
        let leslie = try await Device("leslie@example.com", .signedOut, on: server)

        await leslie.workspace.open(url)

        let page = try #require(leslie.workspace.invitation)
        #expect(page.invitation == invitedToHousehold)
        #expect(page.levelLine == "You'd join at Add.", "anyone holding the link may ask what it offers")
        #expect(page.historyLine == "You'd see everything so far.")
        #expect(page.notice == "Sign in first, or create an account. Joining adds the group to your account.")
        #expect(page.offersSignIn)
        #expect(!page.offersEmailConfirmation)
        page.myName = "Leslie"
        #expect(!page.canJoin)

        try await leslie.sync.signUp(email: "leslie@example.com", password: "a-long-password")
        #expect(page.notice == "Confirm your email first. Joining a shared group needs it.")
        #expect(!page.offersSignIn)
        #expect(page.offersEmailConfirmation)

        try await leslie.sync.verifyEmail(code: try #require(server.lastCode(for: "leslie@example.com",
                                                                              purpose: .verify)))
        #expect(leslie.workspace.invitation === page, "the page stays through signing up")
        #expect(page.notice == nil)
        #expect(page.canJoin, "the name typed before is kept")
        #expect(await leslie.screen.joinInvitation())
        #expect(leslie.screen.openGroup?.id == group)
    }

    /// Signed out, the invite is asked of the server set now, and only when
    /// it is this build's: a staging build never sends a link to the live
    /// server. The page says why it cannot say more.
    @Test func signedOutTheLinkGoesOnlyToThisBuildsServer() async throws {
        let server = InMemoryReadableServer()
        let (_, url) = try await robinsLink(on: server)
        let live = "https://sync.wellspent.space"
        let transport = StubReadableTransport(server: server)
        let sync = SyncCoordinator(store: Store(database: try WellSpentDatabase.inMemory()),
                                   keyStore: InMemoryKeyStore(), defaults: isolatedDefaults(), serverAddress: live,
                                   environment: .staging, makeTransport: { _ in transport })
        let workspace = Workspace(model: AppModel(store: sync.store), sync: sync)

        await workspace.open(url)

        let page = try #require(workspace.invitation)
        #expect(page.invitation == invitedToHousehold)
        #expect(page.terms == nil)
        #expect(page.failure == AppEnvironment.staging.refusal(ofServerAt: try #require(URL(string: live))))
    }

    /// Signed out, the server says which one it is before the link goes to
    /// it, as before a sign-in. So the live server under another address,
    /// such as a bare IP address, is caught too, and the page says why.
    @Test func signedOutTheLinkGoesOnlyToAServerThatSaysItIsThisBuilds() async throws {
        let server = InMemoryReadableServer()
        let (_, url) = try await robinsLink(on: server)
        let transport = StubReadableTransport(server: server)
        transport.serverEnvironment = "live"
        let sync = SyncCoordinator(store: Store(database: try WellSpentDatabase.inMemory()),
                                   keyStore: InMemoryKeyStore(), defaults: isolatedDefaults(),
                                   serverAddress: "https://203.0.113.7", environment: .staging,
                                   makeTransport: { _ in transport })
        let workspace = Workspace(model: AppModel(store: sync.store), sync: sync)

        await workspace.open(url)

        let page = try #require(workspace.invitation)
        #expect(page.invitation == invitedToHousehold)
        #expect(transport.previews == 0, "the link went to a server that says it is the live one")
        #expect(page.terms == nil)
        #expect(page.failure == AppEnvironment.staging.refusal(ofServerSaying: "live"))
    }

    /// Signed in, the address not confirmed yet: the page asks them to
    /// confirm it first, with Confirm your email… in place of Join.
    @Test func unconfirmedTheInvitationAsksThemToConfirmTheirEmailFirst() async throws {
        let server = InMemoryReadableServer()
        let (_, url) = try await robinsLink(on: server)
        let leslie = try await Device("leslie@example.com", .unconfirmed, on: server)

        await leslie.workspace.open(url)

        let page = try #require(leslie.workspace.invitation)
        #expect(page.invitation == invitedToHousehold)
        #expect(page.levelLine == "You'd join at Add.")
        #expect(page.notice == "Confirm your email first. Joining a shared group needs it.")
        #expect(page.offersEmailConfirmation)
        #expect(!page.offersSignIn)
    }

    // MARK: - The window around it

    /// The page shows on the right in place of a budget or a group's page,
    /// with nothing picked or marked on the left. A click on a budget, or
    /// on a group's name, takes it down. The list letting go of its pick
    /// does not.
    @Test func theInvitationShowsUntilABudgetOrAGroupIsPicked() async throws {
        let server = InMemoryReadableServer()
        let (_, url) = try await robinsLink(on: server)
        let leslie = try await Device("leslie@example.com", on: server)
        let own = try #require(leslie.model.addGroup(named: "Own"))
        let rent = try #require(leslie.model.addBudget(named: "Rent", limit: .dollars(900), in: own))
        leslie.screen.openPage(of: own)

        await leslie.workspace.open(url)
        #expect(leslie.screen.invitation != nil)
        #expect(leslie.screen.openGroup == nil, "it shows in place of the group's page")
        #expect(leslie.screen.selectedBudget == nil, "nothing is picked on the left")
        #expect(leslie.screen.sections.allSatisfy { !$0.isPageOpen }, "and no group is marked")

        leslie.screen.selectedBudget = nil
        #expect(leslie.screen.invitation != nil, "the list letting go of its pick is not a click")

        leslie.screen.selectedBudget = rent
        #expect(leslie.screen.invitation == nil)
        #expect(leslie.workspace.invitation == nil)
        #expect(leslie.screen.selectedBudget == rent)

        await leslie.workspace.open(url)
        leslie.screen.openPage(of: own)
        #expect(leslie.screen.invitation == nil)
        #expect(leslie.screen.openGroup?.id == own)
    }

    /// Another link replaces the page that is up.
    @Test func anotherLinkReplacesThePage() async throws {
        let server = InMemoryReadableServer()
        let (_, url) = try await robinsLink(on: server)
        let leslie = try await Device("leslie@example.com", on: server)

        let scheme = try #require(url.scheme)
        await leslie.workspace.open(try #require(URL(string: "\(scheme)://join")))
        let broken = try #require(leslie.workspace.invitation)
        await leslie.workspace.open(url)

        let page = try #require(leslie.workspace.invitation)
        #expect(page !== broken)
        #expect(page.invitation == invitedToHousehold)
    }
}
