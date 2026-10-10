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

@MainActor
private func idleSync() throws -> SyncCoordinator {
    SyncCoordinator(store: Store(database: try WellSpentDatabase.inMemory()),
                    keyStore: InMemoryKeyStore(), defaults: isolatedDefaults())
}

@Suite("Sync views", .serialized)
@MainActor
struct SyncViewTests {

    // MARK: - The toolbar button

    /// One button covers four states, and each one has to say something different.
    /// A button that reads "Sync" while it is failing is how a person keeps
    /// pressing it.
    @Test func theButtonSaysWhatItWillDoInEveryState() {
        #expect(SyncButton.title(for: .signedOut) == "Sign in")
        #expect(SyncButton.title(for: .busy("Syncing")) == "Syncing")
        #expect(SyncButton.title(for: .signedIn(email: "robin@example.com")) == "Sync")
        #expect(SyncButton.title(for: .failed("no route to host")) == "Sync failed")

        #expect(SyncButton.icon(for: .signedOut) == "person.crop.circle.badge.plus")
        #expect(SyncButton.icon(for: .failed("x")) == "exclamationmark.triangle")
        #expect(SyncButton.icon(for: .busy("x")) == SyncButton.icon(for: .signedIn(email: "a@b.c")))
    }

    /// The reason a sync failed belongs where the person can read it, not only in
    /// the state enum.
    @Test func theTooltipCarriesTheReason() {
        #expect(SyncButton.help(for: .failed("the server said 503"), lastSyncedAt: nil)
                    .contains("503"))
        #expect(SyncButton.help(for: .signedOut, lastSyncedAt: nil).contains("Sign in"))

        let neverSynced = SyncButton.help(for: .signedIn(email: "robin@example.com"),
                                          lastSyncedAt: nil)
        #expect(neverSynced.contains("robin@example.com"))
        #expect(neverSynced.contains("Not synced yet"))

        let synced = SyncButton.help(for: .signedIn(email: "robin@example.com"),
                                     lastSyncedAt: Date())
        #expect(synced.contains("Last synced at"))
    }

    /// The account button opens the sheet: Sign in when signed out, the
    /// account when signed in. It never signs out on a click.
    @Test func theAccountButtonFollowsTheSession() throws {
        #expect(AccountButton.title(account: nil) == "Sign in")
        #expect(AccountButton.title(account: "robin@example.com") == "Account")
        #expect(AccountButton.icon(account: nil) != AccountButton.icon(account: "a@b.c"))
        #expect(AccountButton.help(account: "robin@example.com").contains("robin@example.com"))

        let sync = try idleSync()
        let button = AccountButton(sync: sync, showingAccount: .constant(false))
        let labels = try button.inspect().findAll(ViewType.Text.self).map { try $0.string() }
        #expect(labels.contains("Sign in"), "got \(labels)")
    }

    /// Clicked while signed in, it opens the account and signs nobody out.
    @Test func theAccountButtonNeverSignsOutOnAClick() async throws {
        let transport = StubReadableTransport()
        let sync = SyncCoordinator(store: Store(database: try WellSpentDatabase.inMemory()),
                                   keyStore: InMemoryKeyStore(), defaults: isolatedDefaults(),
                                   makeTransport: { _ in transport })
        try await sync.signUp(email: "robin@example.com", password: "a-long-password")
        var shown = false
        let button = AccountButton(sync: sync, showingAccount: Binding(get: { shown }, set: { shown = $0 }))

        try button.inspect().find(ViewType.Button.self).tap()

        #expect(shown)
        #expect(sync.account == "robin@example.com")
    }

    @Test func theButtonRendersAndIsDisabledWhileWorking() throws {
        let sync = try idleSync()
        let button = SyncButton(sync: sync, showingAccount: .constant(false))
        let labels = try button.inspect().findAll(ViewType.Text.self).map { try $0.string() }
        #expect(labels.contains("Sign in"), "got \(labels)")
        #expect(!sync.isBusy)
    }

    // MARK: - The account sheet

    /// Signed out, the sheet opens at signing in, with the ways to make an
    /// account or reset a password, and says where budgets go and who can
    /// read them.
    @Test func signedOutTheSheetOpensAtSignIn() throws {
        let sync = try idleSync()
        let texts = try AccountSheet(sync: sync).inspect()
            .findAll(ViewType.Text.self).map { try $0.string() }

        #expect(texts.contains("Sign in"), "got \(texts)")
        #expect(texts.contains(AccountFlow.Words.createAccount))
        #expect(texts.contains(AccountFlow.Words.forgotPassword))
        #expect(texts.contains(AccountFlow.Words.privacy))
        #expect(!texts.contains { $0.contains("encrypted before") || $0.contains("twelve words") })
    }

    /// Signed out by the server, the sheet says why.
    @Test func aPromptOpensTheSheetWithItsReason() throws {
        let sync = try idleSync()
        sync.endSession(reason: SyncCoordinator.sessionEndedReason)
        let texts = try AccountSheet(sync: sync).inspect()
            .findAll(ViewType.Text.self).map { try $0.string() }

        #expect(texts.contains(SyncCoordinator.sessionEndedReason), "got \(texts)")
    }

    /// Signed in, the sheet opens at the account, with the address still to
    /// confirm and the ways to sign out.
    @Test func signedInTheSheetOpensAtTheAccount() async throws {
        let transport = StubReadableTransport()
        let sync = SyncCoordinator(store: Store(database: try WellSpentDatabase.inMemory()),
                                   keyStore: InMemoryKeyStore(), defaults: isolatedDefaults(),
                                   makeTransport: { _ in transport })
        try await sync.signUp(email: "robin@example.com", password: "a-long-password")
        let texts = try AccountSheet(sync: sync).inspect()
            .findAll(ViewType.Text.self).map { try $0.string() }

        #expect(texts.contains("Your account"), "got \(texts)")
        #expect(texts.contains("Signed in as robin@example.com."))
        #expect(texts.contains(ConfirmEmailScreen.reason))
        #expect(texts.contains(AccountFlow.Words.signOut))
        #expect(texts.contains(AccountFlow.Words.signOutEverywhere))
    }

    // MARK: - The sidebar footer

    /// Somebody signed in is told their budgets go through the server;
    /// signed out, that they stay on this computer.
    @Test func theFooterSaysWhereBudgetsAreKept() async throws {
        let store = Store(database: try WellSpentDatabase.inMemory())
        let transport = StubReadableTransport()
        let sync = SyncCoordinator(store: store, keyStore: InMemoryKeyStore(),
                                   defaults: isolatedDefaults(),
                                   makeTransport: { _ in transport })

        #expect(SidebarView.footer(for: sync) == "Kept on this computer only")
        try await sync.signUp(email: "robin@example.com", password: "a-long-password")
        #expect(SidebarView.footer(for: sync) == "Syncs through WellSpent's server")
        // Still signed in when a sync fails, so still syncing through the server.
        transport.failSync = .http(status: 500, reason: "")
        await sync.syncAll()
        #expect(sync.isSignedIn == false, "the state is failed")
        #expect(SidebarView.footer(for: sync) == "Syncs through WellSpent's server")
    }

    /// Signed out, the sidebar's foot always offers a way in, whatever the
    /// window shows and whether a prompt was dismissed.
    @Test func signedOutTheFooterOffersSignIn() throws {
        let model = AppModel(store: Store(database: try WellSpentDatabase.inMemory()))
        let sync = try idleSync()
        var shown = false
        let sidebar = SidebarView(model: model, sync: sync, editor: .constant(nil),
                                  showingAccount: Binding(get: { shown }, set: { shown = $0 }))

        try sidebar.inspect().find(button: "Sign in").tap()

        #expect(shown, "the same account sheet the toolbar opens")
    }

    /// Groups waiting on their founder count in the sidebar's line only when
    /// this device holds nothing of them, a deleted copy included.
    @Test func onlyGroupsHeldNowhereCountAsWaiting() {
        let held = BudgetGroup(name: "Household", isDeleted: true)
        let elsewhere = GroupID()
        #expect(SidebarView.unseenWaiting([held.id, elsewhere], held: [held]) == 1)
        #expect(SidebarView.unseenWaiting([], held: [held]) == 0)
    }
}

#endif
