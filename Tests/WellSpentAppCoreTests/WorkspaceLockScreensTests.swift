import Testing
import Foundation
@testable import WellSpentAppCore
import WellSpentCrypto
import WellSpentKeyStore
import WellSpentModel
import WellSpentPlans
import WellSpentStore
import WellSpentSync

/// One person's device on a shared in-memory server, with a pinned plan.
@MainActor
private struct Device {
    let sync: SyncCoordinator
    let model: AppModel

    init(_ email: String, on server: InMemoryReadableServer) async throws {
        let store = Store(database: try WellSpentDatabase.inMemory())
        let transport = StubReadableTransport(server: server)
        sync = SyncCoordinator(store: store, keyStore: InMemoryKeyStore(), defaults: isolatedDefaults(),
                               makeTransport: { _ in transport })
        model = AppModel(store: store)
        try await sync.signUp(email: email, password: "a-long-password")
        try await transport.verifyEmail(code: try #require(server.lastCode(for: email, purpose: .verify)))
    }

    /// A workspace showing `answer`, as a staging UI test pins it.
    func workspace(_ answer: PlanAnswer) async -> Workspace {
        let workspace = Workspace(model: model, sync: sync, pinnedPlan: answer)
        await workspace.plans.refresh()
        return workspace
    }
}

private func ended(locked: PlanAnswer.Locked?, open: PlanAnswer.Open? = nil) -> PlanAnswer {
    PlanAnswer(tier: .free, period: .none, state: .free, source: .none, paidUntil: nil, renews: false, nextTier: nil,
               limits: .init(properties: 1, groups: 1, invitedPerGroup: 1),
               used: .init(properties: 1, groups: 2, invitedPerGroup: 1), extensionsOpen: [], canSyncPriceLabs: false,
               refreshMinutes: 60, appleAccountToken: nil,
               lastPlan: .init(tier: .growth, endedOn: Date(), reason: .ended), locked: locked, open: open)
}

@MainActor
@Suite("The lock and pick screens, from the workspace", .serialized)
struct WorkspaceLockScreensTests {
    /// Robin pays for Household and Cabin, and shares Household with Leslie.
    private func shared() async throws -> (robin: Device, leslie: Device, household: GroupID, cabin: GroupID) {
        let server = InMemoryReadableServer()
        let robin = try await Device("robin@example.com", on: server)
        robin.model.addGroup(named: "Household")
        let household = try #require(robin.model.groups.first { $0.name == "Household" }).id
        robin.model.addGroup(named: "Cabin")
        let cabin = try #require(robin.model.groups.first { $0.name == "Cabin" }).id
        let link = try await robin.sync.share(group: household, groupName: "Household", level: .write,
                                              historyAccess: .all, myName: "Robin")
        _ = try await robin.sync.share(group: cabin, groupName: "Cabin", level: .write,
                                       historyAccess: .all, myName: "Robin")
        let leslie = try await Device("leslie@example.com", on: server)
        _ = try await leslie.sync.join(link, myName: "Leslie")
        await robin.sync.syncAll()
        robin.model.reload()
        leslie.model.reload()
        return (robin, leslie, household, cabin)
    }

    @Test func thePickListsThePayersGroupsAndTheirInvitedPeople() async throws {
        let world = try await shared()
        let leslie = try #require(world.leslie.sync.userID)
        let workspace = await world.robin.workspace(ended(locked: .init(groupIDs: [world.cabin.uuid], people: [],
                                                                          houseIDs: [])))
        let screen = try #require(workspace.pickScreen())
        #expect(screen.groups.map(\.name) == ["Household", "Cabin"])
        #expect(screen.group == world.household.uuid)
        #expect(screen.people == [PlanItem(id: leslie.uuid, name: "Leslie")])
        #expect(screen.propertyItems.isEmpty, "no Properties in this build")
        #expect(workspace.planLocks.isLocked(group: world.cabin.uuid))
    }

    @Test func groupsSomeoneWasInvitedIntoAreNotTheirsToPick() async throws {
        let world = try await shared()
        let workspace = await world.leslie.workspace(ended(locked: nil))
        #expect(try #require(workspace.pickScreen()).groups.isEmpty)
    }

    @Test func thePayerSeesTheirOwnLockedGroupWithTheOpenOneNamed() async throws {
        let world = try await shared()
        let open = PlanAnswer.Open(groupID: world.household.uuid, person: nil, houseIDs: [])
        let workspace = await world.robin.workspace(ended(locked: .init(groupIDs: [world.cabin.uuid], people: [],
                                                                          houseIDs: []), open: open))
        let card = try #require(workspace.lockedScreen(group: world.cabin))
        #expect(card.title == "This group is locked")
        #expect(card.lines.first == "Your free plan keeps 1 group open: Household.")
        #expect(workspace.lockedScreen(group: world.household) == nil)
    }

    @Test func aMemberSeesWhoPaysAndALockedOutPersonSeesWhy() async throws {
        let world = try await shared()
        let leslie = try #require(world.leslie.sync.userID)
        let member = await world.leslie.workspace(ended(locked: .init(groupIDs: [world.household.uuid], people: [],
                                                                        houseIDs: [])))
        #expect(member.lockedScreen(group: world.household)?.lines.first == "Robin's plan doesn't cover it right now.")
        let person = PlanAnswer.Person(groupID: world.household.uuid, userID: leslie.uuid)
        let out = await world.leslie.workspace(ended(locked: .init(groupIDs: [], people: [person], houseIDs: [])))
        let card = try #require(out.lockedScreen(group: world.household))
        #expect(card.lines.first == "Robin is on the free plan, which shares a group with 1 person.")
        #expect(card.actions == [.payForThisGroup])
    }

    @Test func thePlanCardNamesTheOpenGroupThenThePerson() async throws {
        let world = try await shared()
        let leslie = try #require(world.leslie.sync.userID)
        let open = PlanAnswer.Open(groupID: world.household.uuid,
                                   person: .init(groupID: world.household.uuid, userID: leslie.uuid), houseIDs: [UUID()])
        let workspace = await world.robin.workspace(ended(locked: nil, open: open))
        #expect(workspace.planOpenNames == ["Household", "Leslie"])
        #expect(await world.robin.workspace(ended(locked: nil)).planOpenNames.isEmpty)
    }

    @Test func withNoAnswerThereIsNothingToShow() async throws {
        let world = try await shared()
        let workspace = Workspace(model: world.robin.model, sync: world.robin.sync)
        #expect(workspace.pickScreen() == nil)
        #expect(workspace.lockedScreen(group: world.cabin) == nil)
        #expect(workspace.planLocks.isEmpty)
        #expect(workspace.planOpenNames.isEmpty)
    }
}
