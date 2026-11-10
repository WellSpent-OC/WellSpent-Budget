import Testing
import Foundation
@testable import WellSpentAppCore
import WellSpentCrypto
import WellSpentKeyStore
import WellSpentModel
import WellSpentPlans
import WellSpentStore
import WellSpentSync

@MainActor
@Suite("Past the plan, in the app", .serialized)
struct PlanRefusalTests {
    private func idle() throws -> SyncCoordinator {
        SyncCoordinator(store: Store(database: try WellSpentDatabase.inMemory()), keyStore: InMemoryKeyStore(),
                        defaults: isolatedDefaults())
    }

    /// A refused house offers the upgrade sheet once. The same records
    /// refused again on the next timed sync don't open it again; new ones do.
    @Test func theSheetIsOfferedOncePerRefusal() throws {
        let sync = try idle()
        let house = RecordID(UUID())
        let refusal = PlanLimitRefusal(sheet: "add_house", limit: "maxProperties", refused: [house])
        sync.noteRefusal(refusal)
        #expect(sync.planSheet == refusal)
        sync.planSheetShown()
        #expect(sync.planSheet == nil)
        sync.noteRefusal(refusal)
        #expect(sync.planSheet == nil, "the same records don't ask twice")
        let another = PlanLimitRefusal(sheet: "add_house", limit: "maxProperties", refused: [RecordID(UUID())])
        sync.noteRefusal(another)
        #expect(sync.planSheet == another)
    }

    /// A locked group shows its own card, so it opens no sheet; nor does a
    /// round with nothing refused.
    @Test func aLockedGroupOrNothingOpensNoSheet() throws {
        let sync = try idle()
        sync.noteRefusal(PlanLimitRefusal(sheet: "locked", limit: "maxGroups"))
        sync.noteRefusal(nil)
        #expect(sync.planSheet == nil)
        // A refusal with no records named, such as a second group, always asks.
        let group = PlanLimitRefusal(sheet: "add_group", limit: "maxGroups")
        sync.noteRefusal(group)
        #expect(sync.planSheet == group)
    }

    /// Paying, or a pick, opens what was locked. Pulls had left it out, behind
    /// each group's cursor, so every group is read again from the start.
    @Test func aPlanThatOpensSomethingReadsEveryGroupAgain() async throws {
        let server = InMemoryReadableServer()
        server.seedAccount(email: "robin@example.com", password: "a-long-password")
        let store = Store(database: try WellSpentDatabase.inMemory())
        let transport = StubReadableTransport(server: server)
        let sync = SyncCoordinator(store: store, keyStore: InMemoryKeyStore(), defaults: isolatedDefaults(),
                                   makeTransport: { _ in transport })
        try await sync.signIn(email: "robin@example.com", password: "a-long-password")
        let model = AppModel(store: store)
        model.addGroup(named: "Household")
        let group = try #require(model.groups.first).id
        // As if it had synced up to here.
        try store.recordReadablePull(group: group, serverSeq: 7, observedLamport: 3)
        #expect(try store.readableCursor(in: group) == 7)

        let file = FileManager.default.temporaryDirectory.appendingPathComponent("plan-\(UUID()).json")
        func pin(_ locked: String) throws {
            let json = #"{"tier":"free","period":"none","state":"free","source":"none","paidUntil":null,"renews":false,"nextTier":null,"limits":{"properties":1},"used":{"properties":1},"extensionsOpen":[],"canSyncPriceLabs":false,"refreshMinutes":60,"appleAccountToken":null\#(locked)}"#
            try Data(json.utf8).write(to: file, options: .atomic)
        }
        try pin(#","locked":{"groupIDs":["\#(UUID())"],"people":[],"houseIDs":[]}"#)
        let workspace = Workspace(model: model, sync: sync, pinnedPlan: PinnedPlanService(file: file.path))
        await workspace.plans.refresh()
        #expect(try store.readableCursor(in: group) > 0, "a first answer opens nothing")

        try pin("")
        await workspace.plans.refresh()
        #expect(try store.readableCursor(in: group) == 0, "every group is read again from the start")
    }
}
