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

    /// A change at a locked house waits with no sheet. Opening the house
    /// shows its locked card, the same rule as a locked group.
    @Test func aLockedHouseOpensNoSheet() throws {
        let sync = try idle()
        sync.noteRefusal(PlanLimitRefusal(sheet: "locked", limit: "maxProperties", refused: [RecordID(UUID())]))
        #expect(sync.planSheet == nil)
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

    /// Scenario PLAN-18. A free account brings two groups. The server makes
    /// the first and refuses the second, which stays on this device, and the
    /// app knows which one. Once the server takes it, it isn't held any more.
    @Test func aGroupPastTheFreePlanIsHeldOnThisDevice() async throws {
        let server = InMemoryReadableServer()
        server.seedAccount(email: "robin@example.com", password: "a-long-password")
        let store = Store(database: try WellSpentDatabase.inMemory())
        let transport = StubReadableTransport(server: server)
        let sync = SyncCoordinator(store: store, keyStore: InMemoryKeyStore(), defaults: isolatedDefaults(),
                                   makeTransport: { _ in transport })
        let model = AppModel(store: store)
        model.addGroup(named: "Home")
        model.addGroup(named: "Beach")
        let beach = try #require(model.groups.first { $0.name == "Beach" }).id
        transport.refuseMakingPastThePlan = [beach]
        try await sync.signIn(email: "robin@example.com", password: "a-long-password")
        await sync.syncAll()
        #expect(sync.heldOnThisDevice == [beach])
        // Its marker and notice say so, and See Plans is one click: no
        // Choose a plan opens by itself (plan item 35).
        #expect(sync.planSheet == nil, "a group kept on this device opened Choose a plan")

        transport.refuseMakingPastThePlan = []
        await sync.syncAll()
        #expect(sync.heldOnThisDevice.isEmpty, "once the server takes it, it isn't held")
    }

    /// Scenario PROP-58. A house past the plan is refused when its records are
    /// pushed. The engine sets them aside and the round goes on, so the
    /// refusal comes back inside the round's report, not thrown. It still
    /// offers Choose a plan, once.
    @Test func aRefusalAtPushStillOffersChooseAPlan() async throws {
        let server = InMemoryReadableServer()
        server.seedAccount(email: "robin@example.com", password: "a-long-password")
        let store = Store(database: try WellSpentDatabase.inMemory())
        let transport = StubReadableTransport(server: server)
        let sync = SyncCoordinator(store: store, keyStore: InMemoryKeyStore(), defaults: isolatedDefaults(),
                                   makeTransport: { _ in transport })
        let model = AppModel(store: store)
        model.addGroup(named: "Rentals")
        try await sync.signIn(email: "robin@example.com", password: "a-long-password")
        await sync.syncAll()
        #expect(sync.planSheet == nil, "nothing was past the plan yet")

        let group = try #require(model.groups.first { $0.name == "Rentals" }).id
        transport.refusePushedPastThePlan = .budget
        #expect(model.addBudget(named: "Pool House", limit: Money(minorUnits: 50_000), in: group) != nil)
        await sync.syncAll()
        #expect(sync.lastReport?.planRefusal?.limit == "maxProperties", "the server refused nothing")
        let sheet = try #require(sync.planSheet, "a refusal at push opened no Choose a plan")
        #expect(sheet.limit == "maxProperties")
        #expect(sync.heldOnThisDevice.isEmpty, "a refused house held a group")
    }

    /// The notice names the group the free plan does sync: one Robin made,
    /// since the server counts the groups he pays for. A group he only
    /// joined, listed first, is not it.
    @Test func theNoticeNamesHisOwnSyncedGroupNotOneHeJoined() async throws {
        let server = InMemoryReadableServer()
        server.seedAccount(email: "robin@example.com", password: "a-long-password")
        let store = Store(database: try WellSpentDatabase.inMemory())
        let transport = StubReadableTransport(server: server)
        let sync = SyncCoordinator(store: store, keyStore: InMemoryKeyStore(), defaults: isolatedDefaults(),
                                   makeTransport: { _ in transport })
        let model = AppModel(store: store)
        let workspace = Workspace(model: model, sync: sync)
        model.addGroup(named: "Home")
        model.addGroup(named: "Beach")
        let beach = try #require(model.groups.first { $0.name == "Beach" }).id
        transport.refuseMakingPastThePlan = [beach]
        try await sync.signIn(email: "robin@example.com", password: "a-long-password")
        await sync.syncAll()
        // Leslie's Alps, which Robin joined, listed before his own groups.
        model.addGroup(named: "Alps")
        let alps = try #require(model.groups.first { $0.name == "Alps" }).id
        try store.saveServerGroup(ServerGroupInfo(groupID: alps, founderID: UserID(), level: .write, importKey: Data()))
        model.reload()
        #expect(model.groups.first?.name == "Alps", "the joined group isn't listed first: \(model.groups.map(\.name))")

        let held = try #require(workspace.heldScreen(group: beach, device: .mac, buyingIsOpen: false))
        #expect(held.notice.contains("and Home is that group"), "it names the wrong group: \(held.notice)")
    }
}
