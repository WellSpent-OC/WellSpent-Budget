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

/// PLAN-18 on the Mac: a group the free plan kept on this Mac says why at the
/// top of its page, and the group the server took doesn't.
@Suite("A group kept on this Mac, drawn", .serialized)
@MainActor
struct HeldGroupViewTests {
    private func texts(_ view: some View) throws -> [String] {
        try view.inspect().findAll(ViewType.Text.self).map { try $0.string() }
    }

    @Test func theHeldGroupsPageSaysItIsOnlyOnThisMac() async throws {
        let server = InMemoryReadableServer()
        server.seedAccount(email: "robin@example.com", password: "a-long-password")
        let store = Store(database: try WellSpentDatabase.inMemory())
        let transport = StubReadableTransport(server: server)
        let sync = SyncCoordinator(store: store, keyStore: InMemoryKeyStore(), defaults: isolatedDefaults(),
                                   makeTransport: { _ in transport })
        let workspace = Workspace(model: AppModel(store: store), sync: sync)
        let main = MainScreen(workspace: workspace)
        let model = workspace.model
        let home = try #require(model.addGroup(named: "Home").flatMap(model.group(named:)))
        let beach = try #require(model.addGroup(named: "Beach").flatMap(model.group(named:)))
        transport.refuseMakingPastThePlan = [beach.id]
        try await sync.signIn(email: "robin@example.com", password: "a-long-password")
        await sync.syncAll()

        let expected = HeldGroupScreen(group: "Beach", synced: "Home", device: .mac, platform: .appleStore)
        let page = try texts(GroupPage(sync: sync, group: beach, main: main, showingAccount: .constant(false)))
        #expect(page.contains(expected.notice), "no notice in \(page)")
        let other = try texts(GroupPage(sync: sync, group: home, main: main, showingAccount: .constant(false)))
        #expect(!other.contains { $0.contains("only on this Mac") }, "Home is on the server")
    }
}
#endif
