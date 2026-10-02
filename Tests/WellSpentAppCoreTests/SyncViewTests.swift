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

    /// The account button is Sign in or Sign out, never both, and says who is
    /// signed in.
    @Test func theAccountButtonTogglesWithTheSession() throws {
        #expect(AccountButton.title(account: nil) == "Sign in")
        #expect(AccountButton.title(account: "robin@example.com") == "Sign out")
        #expect(AccountButton.icon(account: nil) != AccountButton.icon(account: "a@b.c"))
        #expect(AccountButton.help(account: "robin@example.com").contains("robin@example.com"))

        let sync = try idleSync()
        let button = AccountButton(sync: sync, showingAccount: .constant(false))
        let labels = try button.inspect().findAll(ViewType.Text.self).map { try $0.string() }
        #expect(labels.contains("Sign in"), "got \(labels)")
    }

    @Test func theButtonRendersAndIsDisabledWhileWorking() throws {
        let sync = try idleSync()
        let button = SyncButton(sync: sync, showingAccount: .constant(false))
        let labels = try button.inspect().findAll(ViewType.Text.self).map { try $0.string() }
        #expect(labels.contains("Sign in"), "got \(labels)")
        #expect(!sync.isBusy)
    }

    // MARK: - The account sheet

    /// Checked here so a person is not told by the server what could be seen on
    /// screen. Ten characters is the server's floor, not a guess.
    @Test func theSubmitButtonNeedsAnAddressAnEmailAndALongEnoughPassword() {
        let server = "http://127.0.0.1:8080"
        #expect(AccountSheet.canSubmit(email: "robin@example.com",
                                       password: "a-long-password", server: server))

        #expect(!AccountSheet.canSubmit(email: "robin", password: "a-long-password", server: server))
        #expect(!AccountSheet.canSubmit(email: "@example.com", password: "a-long-password", server: server))
        #expect(!AccountSheet.canSubmit(email: "robin@", password: "a-long-password", server: server))
        #expect(!AccountSheet.canSubmit(email: "robin@example.com", password: "short", server: server))
        #expect(!AccountSheet.canSubmit(email: "robin@example.com",
                                        password: "a-long-password", server: "wellspent"))
        #expect(!AccountSheet.canSubmit(email: "robin@example.com",
                                        password: "a-long-password", server: "ftp://example.com"))
        #expect(AccountSheet.canSubmit(email: "robin@example.com",
                                       password: "a-long-password", server: "https://sync.example.com"))
    }

    @Test func theSheetSaysWhereTheDataGoesAndThatItIsSealedFirst() throws {
        let sync = try idleSync()
        let texts = try AccountSheet(sync: sync).inspect()
            .findAll(ViewType.Text.self).map { try $0.string() }

        #expect(texts.contains { $0.contains("encrypted before they leave this Mac") },
                "got \(texts)")
        #expect(texts.contains("Sign in"))
        #expect(texts.contains("Create an account"))
    }

    /// A device with no key cannot sign in, and the sheet has to say that before
    /// the password is typed rather than after it is rejected.
    @Test func theSheetWarnsWhenThisMacHasNoKey() throws {
        let sync = try idleSync()
        #expect(!sync.hasIdentity)

        let texts = try AccountSheet(sync: sync).inspect()
            .findAll(ViewType.Text.self).map { try $0.string() }
        #expect(texts.contains { $0.contains("pairing a second device is not built") },
                "got \(texts)")
    }

    // MARK: - The recovery code

    @Test func theRecoverySheetShowsAllTwelveWordsAndWhyTheyMatter() throws {
        let sync = try idleSync()
        let words = try RecoveryCode.encode(entropy: RecoveryCode.generateEntropy())
        let enrolment = SyncCoordinator.Enrolment(email: "robin@example.com",
                                                  recoveryWords: words)

        let texts = try RecoveryWordsSheet(sync: sync, enrolment: enrolment).inspect()
            .findAll(ViewType.Text.self).map { try $0.string() }

        for word in words {
            #expect(texts.contains(word), "word \(word) missing from \(texts)")
        }
        for number in 1...12 {
            #expect(texts.contains("\(number)"))
        }
        #expect(texts.contains { $0.contains("only way") }, "the stake, said plainly")
        #expect(texts.contains { $0.contains("cannot open it") })
    }

    @Test func anEnrolmentBoxIsIdentifiedByItsAccount() {
        let box = EnrolmentBox(SyncCoordinator.Enrolment(email: "robin@example.com",
                                                         recoveryWords: ["a", "b"]))
        #expect(box.id == "robin@example.com")
    }

    // MARK: - The sidebar footer

    /// "Encrypted on this Mac" was true until syncing existed. Somebody signed in
    /// should be told their data goes somewhere, and that it is sealed before it
    /// does.
    @Test func theFooterChangesOnceDataLeavesThisMac() async throws {
        let store = Store(database: try WellSpentDatabase.inMemory())
        let transport = StubAccountTransport()
        let sync = SyncCoordinator(store: store, keyStore: InMemoryKeyStore(),
                                   defaults: isolatedDefaults(),
                                   makeTransport: { _ in transport })

        #expect(SidebarView.footer(for: sync) == "Encrypted on this Mac")
        try await sync.signUp(email: "robin@example.com", password: "a-long-password")
        #expect(SidebarView.footer(for: sync) == "Encrypted here and on the server")
    }
}
