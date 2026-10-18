// SwiftUI and ViewInspector exist only on Apple systems.
#if canImport(SwiftUI)
import Testing
import Foundation
import SwiftUI
import ViewInspector
@testable import WellSpentAppCore
import WellSpentCrypto
import WellSpentKeyStore
import WellSpentModel
import WellSpentStore
import WellSpentSync

/// One person's side of a shared group: on a shared in-memory server, with
/// budgets and a window of their own. Signed up and confirmed unless asked
/// otherwise.
@MainActor
private struct Side {
    let sync: SyncCoordinator
    let workspace: Workspace
    let main: MainScreen
    var model: AppModel { workspace.model }

    init(_ email: String, on server: InMemoryReadableServer, signedIn: Bool = true,
         confirmed: Bool = true) async throws {
        let store = Store(database: try WellSpentDatabase.inMemory())
        let transport = StubReadableTransport(server: server)
        sync = SyncCoordinator(store: store, keyStore: InMemoryKeyStore(), defaults: isolatedDefaults(),
                               makeTransport: { _ in transport })
        workspace = Workspace(model: AppModel(store: store), sync: sync)
        main = MainScreen(workspace: workspace)
        guard signedIn else { return }
        try await sync.signUp(email: email, password: "a-long-password")
        if confirmed {
            try await sync.verifyEmail(code: try #require(server.lastCode(for: email, purpose: .verify)))
        }
    }
}

/// The editing and sharing sheets, drawn, and what they say in each state.
@Suite("Sheets", .serialized)
@MainActor
struct SheetTests {
    private func model() throws -> (AppModel, BudgetGroup, Budget) {
        let model = AppModel(store: Store(database: try WellSpentDatabase.inMemory()))
        let group = try #require(model.addGroup(named: "Household").flatMap(model.group(named:)))
        let id = try #require(model.addBudget(named: "Groceries", limit: Money(minorUnits: 50_000),
                                              in: group.id))
        return (model, group, try #require(model.budget(for: id)))
    }

    private func sync(_ model: AppModel) -> SyncCoordinator {
        SyncCoordinator(store: model.store, keyStore: InMemoryKeyStore(), defaults: isolatedDefaults())
    }

    private func texts(_ view: some View) throws -> [String] {
        try view.inspect().findAll(ViewType.Text.self).map { try $0.string() }
    }

    // MARK: - Budgets and groups

    @Test func newBudgetAsksForNameAmountAndGroup() throws {
        let (model, group, _) = try model()
        let shown = try texts(BudgetSheet(model: model, group: group.id))
        #expect(shown.contains("New Budget"))
        #expect(shown.contains("Starts again on the 1st of each month."))
        #expect(shown.contains("Add"))
        #expect(try BudgetSheet(model: model).inspect().find(ViewType.Picker.self) != nil,
                "a group to put it in")
    }

    /// A new budget can only go in a group this person manages. With none of
    /// those, it gets a new group of its own.
    @Test func aNewBudgetIsOfferedOnlyTheGroupsGiven() throws {
        let (model, group, _) = try model()
        let other = try #require(model.addGroup(named: "Book Club").flatMap(model.group(named:)))
        let picker = try BudgetSheet(model: model, groups: [other]).inspect().find(ViewType.Picker.self)
        let names = try picker.findAll(ViewType.Text.self).map { try $0.string() }
        #expect(names.contains("Book Club"))
        #expect(!names.contains(group.name))

        let none = BudgetSheet(model: model, groups: [])
        #expect((try? none.inspect().find(ViewType.Picker.self)) == nil)
        #expect(try texts(none).contains("New Budget"))
    }

    @Test func editingABudgetSaysSoAndOffersNoGroupChoice() throws {
        let (model, _, budget) = try model()
        let sheet = BudgetSheet(model: model, editing: budget)
        let shown = try texts(sheet)
        #expect(shown.contains("Edit Budget"))
        #expect(shown.contains("Save"))
        #expect((try? sheet.inspect().find(ViewType.Picker.self)) == nil,
                "budgets do not move between groups")
    }

    @Test func aBudgetWithNoGroupsYetAsksForOne() throws {
        let model = AppModel(store: Store(database: try WellSpentDatabase.inMemory()))
        let sheet = BudgetSheet(model: model)
        #expect(try texts(sheet).contains("New Budget"))
        #expect((try? sheet.inspect().find(ViewType.Picker.self)) == nil)
    }

    @Test func groupSheetsSayWhatAGroupIsFor() throws {
        let (model, group, _) = try model()
        let adding = try texts(GroupSheet(model: model))
        #expect(adding.contains("New Group"))
        #expect(adding.contains { $0.contains("what you will share") })
        #expect(try texts(GroupSheet(model: model, renaming: group)).contains("Rename Group"))
    }

    // MARK: - Sharing

    @Test func shareAsksWhatTheyCanDoAndWhatTheySee() throws {
        let (model, group, _) = try model()
        let shown = try texts(ShareSheet(sync: sync(model), group: group))
        #expect(shown.contains("Share \u{201C}Household\u{201D}"))
        for word in ["View", "Add", "Manage", "Everything so far", "Only from now on", "Create Link"] {
            #expect(shown.contains(word), "missing \(word) in \(shown)")
        }
        #expect(shown.contains(InviteRole.add.explanation), "Add is the default")
        #expect(shown.contains { $0.contains("Sign in first") }, "nobody is signed in here")
    }

    @Test func aCreatedLinkIsShownWithWhatToDoWithIt() throws {
        let (model, group, _) = try model()
        let link = InviteLink(secret: Data(repeating: 3, count: 32), groupName: "Household",
                              inviterName: "Robin")
        let shown = try texts(ShareSheet(sync: sync(model), group: group, created: link))
        #expect(shown.contains(link.url))
        #expect(shown.contains { $0.contains("works once and expires in 7 days") })
        #expect(shown.contains("Copy Link"))
        #expect(shown.contains("Done"))
    }

    @Test func joinSaysWhoInvitedYouOnceALinkIsPasted() throws {
        let (model, _, _) = try model()
        let empty = try texts(JoinSheet(sync: sync(model)))
        #expect(empty.contains("Join a Group"))
        #expect(!empty.contains { $0.contains("invited you") })

        let link = InviteLink(secret: Data(repeating: 4, count: 32), groupName: "Household",
                              inviterName: "Robin").url
        let pasted = try texts(JoinSheet(sync: sync(model), linkText: link))
        #expect(pasted.contains("Robin invited you to \u{201C}Household\u{201D}."))

        let anonymous = InviteLink(secret: Data(repeating: 4, count: 32), groupName: "",
                                   inviterName: "").url
        #expect(try texts(JoinSheet(sync: sync(model), linkText: anonymous))
                    .contains("Someone invited you to a group."))

        let wrong = try texts(JoinSheet(sync: sync(model), linkText: "https://example.com"))
        #expect(wrong.contains("That is not a WellSpent invite link."))
    }

    // MARK: - A group's page

    /// Robin's Household, with a Groceries budget, shared with Leslie at Add,
    /// both synced since. Each side has its coordinator, budgets and window.
    private func household() async throws -> (robin: Side, leslie: Side, group: GroupID) {
        let server = InMemoryReadableServer()
        let robin = try await Side("robin@example.com", on: server)
        let group = try #require(robin.model.addGroup(named: "Household"))
        robin.model.addBudget(named: "Groceries", limit: Money(minorUnits: 50_000), in: group)
        await robin.sync.syncAll()
        let share = ShareScreen(actions: robin.sync, group: group, groupName: "Household")
        share.myName = "Robin"
        #expect(await share.create())
        let leslie = try await Side("leslie@example.com", on: server)
        let join = JoinScreen(actions: leslie.sync, linkText: try #require(share.link).url)
        join.myName = "Leslie"
        #expect(await join.join())
        await leslie.sync.syncAll()
        await robin.sync.syncAll()
        return (robin, leslie, group)
    }

    /// The owner sees the name, the line under it, and everyone, with a
    /// level picker and Remove… where today's rules allow, and the Invite
    /// Someone… button. The founder deletes the group, so there is no Leave.
    @Test func theOwnersGroupPageShowsEveryoneAndWhatTheyMayChange() async throws {
        let (robin, _, id) = try await household()
        var invited = false
        let page = GroupPage(sync: robin.sync, group: try #require(robin.model.group(named: id)), main: robin.main,
                             showingAccount: .constant(false), invite: { invited = true })
        let shown = try texts(page)
        for word in ["Household", "Shared \u{00B7} 2 people \u{00B7} Made by you", "PEOPLE", "Robin (you)", "Leslie",
                     "Owner", MembersScreen.Words.levelExplanation(.superadmin),
                     MembersScreen.Words.levelExplanation(.write)] {
            #expect(shown.contains(word), "missing \(word) in \(shown)")
        }
        #expect(throws: Never.self, "Leslie's level can be changed") {
            _ = try page.inspect().find(ViewType.Picker.self)
        }
        #expect(throws: Never.self) { _ = try page.inspect().find(button: "Remove\u{2026}") }
        #expect((try? page.inspect().find(button: "Leave Group\u{2026}")) == nil)

        try page.inspect().find(button: "Invite Someone\u{2026}").tap()
        #expect(invited, "Invite Someone\u{2026} opens the Share sheet")
    }

    /// A member at Add sees labels only, no Remove and no Invite Someone…,
    /// and Leave Group…, which asks the window's question first.
    @Test func aMembersGroupPageShowsLabelsOnlyAndLeaveGroup() async throws {
        let (_, leslie, id) = try await household()
        let group = try #require(leslie.model.group(named: id))
        let page = GroupPage(sync: leslie.sync, group: group, main: leslie.main, showingAccount: .constant(false))
        let shown = try texts(page)
        for word in ["Shared \u{00B7} 2 people \u{00B7} Made by Robin", "Robin", "Leslie (you)", "Owner", "Add"] {
            #expect(shown.contains(word), "missing \(word) in \(shown)")
        }
        #expect((try? page.inspect().find(ViewType.Picker.self)) == nil, "labels only")
        #expect((try? page.inspect().find(button: "Remove\u{2026}")) == nil)
        #expect((try? page.inspect().find(button: "Invite Someone\u{2026}")) == nil, "Add cannot invite")

        try page.inspect().find(button: "Leave Group\u{2026}").tap()
        let pending = try #require(leslie.main.pendingDelete)
        #expect(pending.isLeave && pending.title == "Leave \u{201C}Household\u{201D}?")
        #expect(leslie.model.groups.map(\.id) == [id], "nothing goes before the answer")
    }

    /// After a removal, a quiet line on the page says who went.
    @Test func aGroupsPageSaysWhoWasRemoved() async throws {
        let (robin, _, id) = try await household()
        let group = try #require(robin.model.group(named: id))
        let members = MembersScreen(actions: robin.sync, group: id, groupName: "Household")
        members.remove(try #require(members.rows.first { !$0.isYou }).id)
        await members.pending?.value

        let page = GroupPage(sync: robin.sync, group: group, main: robin.main, showingAccount: .constant(false),
                             screen: members)
        let shown = try texts(page)
        #expect(shown.contains("Leslie was removed."), "got \(shown)")
        #expect(!shown.contains("Leslie"))
        #expect(shown.contains("Not shared \u{00B7} 1 person \u{00B7} Made by you"))
    }

    // MARK: - The invitation page

    /// Robin's Household on `server`, and the link he made for it at Add.
    private func robinsLink(on server: InMemoryReadableServer) async throws -> URL {
        let robin = try await Side("robin@example.com", on: server)
        let group = try #require(robin.model.addGroup(named: "Household"))
        let share = ShareScreen(actions: robin.sync, group: group, groupName: "Household")
        share.myName = "Robin"
        #expect(await share.create())
        let link = try #require(share.link)
        return try #require(URL(string: link.url))
    }

    /// The page for `side`, with the link opened on it.
    private func page(for side: Side, opening url: URL,
                      showingAccount: Binding<Bool> = .constant(false)) async throws -> InvitationPage {
        await side.workspace.open(url)
        return InvitationPage(sync: side.sync, screen: try #require(side.main.invitation), main: side.main,
                              showingAccount: showingAccount)
    }

    /// Who invited them and to what, the level and what it lets them do,
    /// how much they would see, Your name, and Join, which waits for a name.
    /// The link itself is not shown, and there is no Decline.
    @Test func theInvitationPageSaysWhoWhatAndHowMuchWithJoin() async throws {
        let server = InMemoryReadableServer()
        let url = try await robinsLink(on: server)
        let leslie = try await Side("leslie@example.com", on: server)
        let page = try await page(for: leslie, opening: url)

        let shown = try texts(page)
        for word in ["Robin invited you to \u{201C}Household\u{201D}.", "You'd join at Add.", InviteRole.add.explanation,
                     "You'd see everything so far.", "Your name"] {
            #expect(shown.contains(word), "missing \(word) in \(shown)")
        }
        #expect(!shown.contains { $0.contains(url.absoluteString) }, "the link itself is not shown")
        #expect(try page.inspect().find(button: "Join").isDisabled(), "a name is needed first")
        #expect((try? page.inspect().find(button: "Decline")) == nil)
        #expect((try? page.inspect().find(button: "Sign in\u{2026}")) == nil)
    }

    /// Signed out, the notice and Sign in… stand in place of Join, and Sign
    /// in… opens the account sheet. What the invite offers still shows.
    @Test func signedOutTheInvitationPageOffersSignInInPlaceOfJoin() async throws {
        let server = InMemoryReadableServer()
        let url = try await robinsLink(on: server)
        let leslie = try await Side("leslie@example.com", on: server, signedIn: false)
        var account = false
        let page = try await page(for: leslie, opening: url,
                                  showingAccount: Binding(get: { account }, set: { account = $0 }))

        let shown = try texts(page)
        #expect(shown.contains("Sign in first, or create an account. Joining adds the group to your account."),
                "got \(shown)")
        #expect(shown.contains("You'd join at Add."))
        #expect((try? page.inspect().find(button: "Join")) == nil, "the notice stands in its place")
        try page.inspect().find(button: "Sign in\u{2026}").tap()
        #expect(account, "Sign in\u{2026} opens the account sheet")
    }

    /// Not confirmed yet, the notice and Confirm your email… stand in place
    /// of Join, and the button opens the account sheet.
    @Test func unconfirmedTheInvitationPageOffersConfirmingInPlaceOfJoin() async throws {
        let server = InMemoryReadableServer()
        let url = try await robinsLink(on: server)
        let leslie = try await Side("leslie@example.com", on: server, confirmed: false)
        var account = false
        let page = try await page(for: leslie, opening: url,
                                  showingAccount: Binding(get: { account }, set: { account = $0 }))

        let shown = try texts(page)
        #expect(shown.contains("Confirm your email first. Joining a shared group needs it."), "got \(shown)")
        #expect((try? page.inspect().find(button: "Join")) == nil, "the notice stands in its place")
        try page.inspect().find(button: "Confirm your email\u{2026}").tap()
        #expect(account, "Confirm your email\u{2026} opens the account sheet")
    }

    /// A link with part of it missing: the page says so, with no name to
    /// type and no Join.
    @Test func aLinkWithPartOfItMissingPutsUpAPageThatSaysSo() async throws {
        let server = InMemoryReadableServer()
        let leslie = try await Side("leslie@example.com", on: server)
        let page = try await page(for: leslie, opening: try #require(URL(string: "wellspent://join#s=AbCd")))

        let shown = try texts(page)
        #expect(shown.contains("Join a Group"), "got \(shown)")
        #expect(shown.contains("Part of that invite link is missing. Ask the person who sent it to send it again."))
        #expect(!shown.contains("Your name"))
        #expect((try? page.inspect().find(button: "Join")) == nil)
    }

    /// The window shows the page on the right once a link is opened.
    @Test func theWindowShowsAnOpenedLinksInvitation() async throws {
        let server = InMemoryReadableServer()
        let url = try await robinsLink(on: server)
        let leslie = try await Side("leslie@example.com", on: server)
        await leslie.workspace.open(url)

        let shown = try texts(RootView(workspace: leslie.workspace))
        #expect(shown.contains("Robin invited you to \u{201C}Household\u{201D}."), "got \(shown)")
    }

    @Test func theInviteProblemsAreWords() {
        #expect(SyncCoordinator.inviteProblem(404).contains("not found"))
        #expect(SyncCoordinator.inviteProblem(409).contains("already been used"))
        #expect(SyncCoordinator.inviteProblem(410).contains("expired"))
        #expect(InviteRole.describing(.read) == "view this group")
        #expect(InviteRole.describing(.write) == "add transactions")
        #expect(InviteRole.describing(.manage) == "manage this group")
    }
}

#endif
