import Testing
import Foundation
@testable import WellSpentAppCore
import WellSpentKeyStore
import WellSpentStore
import WellSpentSync

/// An address copied from a link arrives as "mailto:name@example.com". The
/// account is the plain address, on the app and on the server alike, so the
/// person signs in next time by typing it. From the go/no-go test on
/// 2026-10-15, where a pasted address made an account that could not sign in.
@Suite("An address pasted from a link", .serialized)
@MainActor
struct PastedAddressTests {
    @Test func signingUpWithAMailtoAddressMakesThePlainAccount() async throws {
        let server = InMemoryReadableServer()
        let store = Store(database: try WellSpentDatabase.inMemory())
        let transport = StubReadableTransport(server: server)
        let sync = SyncCoordinator(store: store, keyStore: InMemoryKeyStore(), defaults: isolatedDefaults(),
                                   makeTransport: { _ in transport })
        try await sync.signUp(email: " MailTo:Robin@Example.com ", password: "a-long-password")
        #expect(sync.account == "robin@example.com")
        try await sync.verifyEmail(code: try #require(server.lastCode(for: "robin@example.com", purpose: .verify)))
        await sync.signOut()

        try await sync.signIn(email: "robin@example.com", password: "a-long-password")
        #expect(sync.account == "robin@example.com", "the plain address signs in")
    }
}
