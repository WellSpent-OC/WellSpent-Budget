import Testing
import Foundation
@testable import WellSpentAppCore
import WellSpentCrypto
import WellSpentKeyStore
import WellSpentModel
import WellSpentStore
import WellSpentSync

/// One person's whole app, on a shared server that can be told to lie.
@MainActor
private struct Person {
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
}

@Suite("Keys the app makes for itself", .serialized)
@MainActor
struct TrustFlowTests {

    /// A group with only this person in it gets its keys made here. The sync
    /// judged that on the whole log the server sent, and a server can make
    /// one up, even with this person's real public keys in it, since those
    /// are not secret. Two such chains made Leslie's Mac make keys, at an
    /// epoch the server picked, on her first sync after answering a link:
    /// one founded by someone the server made up, who adds her and then
    /// lowers himself to nothing, and one founded under her own ID with the
    /// server's keys, later switched to her real ones. A key held is never
    /// replaced, so she would have skipped the real ones. Keys are now made
    /// only for a group she founded with her own key, on the verified log.
    @Test(arguments: [false, true])
    func aMadeUpLogNamingThisPersonAloneMintsNothing(foundedUnderHerID: Bool) async throws {
        let server = InMemoryTransport()
        let robin = try Person(server: server), leslie = try Person(server: server)
        try await robin.sync.signUp(email: "robin@example.com", password: "a-long-password")
        let group = try #require(robin.model.addGroup(named: "Household"))
        _ = robin.model.addBudget(named: "Groceries", limit: Money(minorUnits: 100_000), in: group)
        let link = try await robin.sync.share(group: group, groupName: "Household", level: .write,
                                              historyAccess: .all, myName: "Robin")
        try await leslie.sync.signUp(email: "leslie@example.com", password: "a-long-password")
        try await leslie.sync.join(link, myName: "Leslie")
        let her = try #require(leslie.sync.userID)
        let herKeys = try #require(server.identityKeys(of: her))

        let made = IdentityKeyPair.generate(), madeID = UserID()
        var chain: [MembershipLogEntry] = []
        func append(_ action: MembershipAction, subject: UserID, keys: IdentityPublicKeys? = nil,
                    level: AccessLevel, epoch: UInt32, author: UserID) throws {
            chain.append(try MembershipLogEntry.signed(
                scope: .group(group), sequence: UInt64(chain.count),
                previousHash: chain.last?.hash ?? MembershipLogEntry.rootHash, action: action,
                subjectUserID: subject, subjectKeys: keys, level: level, epochAfter: Epoch(epoch),
                author: made, authorUserID: author))
        }
        // The made-up chain's own keys sign, under whichever name it gives them.
        let signer = foundedUnderHerID ? her : madeID
        try append(.found, subject: signer, keys: made.publicKeys, level: .superadmin, epoch: 0,
                   author: signer)
        if !foundedUnderHerID {
            try append(.add, subject: her, keys: herKeys, level: .write, epoch: 0, author: madeID)
        }
        for epoch in UInt32(1) ... 3 {
            try append(.rotate, subject: signer, level: .superadmin, epoch: epoch, author: signer)
        }
        if foundedUnderHerID {
            try append(.rotateIdentity, subject: her, keys: herKeys, level: .superadmin, epoch: 3, author: her)
        } else {
            try append(.changeLevel, subject: madeID, level: .none, epoch: 3, author: madeID)
        }
        let state = try MembershipLog.replay(chain, scope: .group(group))
        #expect(state.members == [her], "a log naming her its only member")
        #expect(state.keys[her] == herKeys, "with her real public keys")

        leslie.transport.madeUpLog = (group, chain)
        await leslie.sync.syncAll()
        #expect(try leslie.model.store.cachedKey(scope: .group(group), epoch: Epoch(3)) == nil)
    }
}
