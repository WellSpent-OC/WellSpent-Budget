import Testing
import Foundation
import Fluent
import Vapor
import VaporTesting
import WellSpentCrypto
import WellSpentModel
@testable import WellSpentServerCore

private struct V2Plan: Content, Equatable {
    struct Counts: Content, Equatable { let properties: Int?; let groups: Int?; let invitedPerGroup: Int? }
    let tier: String
    let period: String
    let state: String
    let source: String
    let paidUntil: Date?
    let renews: Bool
    let nextTier: String?
    let limits: Counts
    let used: Counts
    let extensionsOpen: [String]
    let canSyncPriceLabs: Bool
    let refreshMinutes: Int
    let appleAccountToken: UUID
}

private func askPlan(_ token: String?, on app: Application) async throws -> (HTTPStatus, V2Plan?) {
    var result: (HTTPStatus, V2Plan?) = (.internalServerError, nil)
    try await app.testing().test(.GET, "api/v2/plan", headers: token.map(v2Bearer) ?? [:]) { response async throws in
        result = (response.status, response.status == .ok ? try response.content.decode(V2Plan.self) : nil)
    }
    return result
}

private func makeGroup(founder: UUID, deleted: Bool = false, on db: any Database) async throws -> UUID {
    let group = GroupRow(id: UUID(), founderID: founder)
    if deleted { group.deletedAt = Date() }
    try await group.create(on: db)
    return try group.requireID()
}

private func addMember(_ user: UUID, to group: UUID, on db: any Database) async throws {
    try await MembershipRow(groupID: group, userID: user, level: 1, joinedAtSequence: 0).create(on: db)
}

private func addExtensionRecord(_ extensionID: String, kind: String, in group: UUID, by user: UUID,
                                deleted: Bool = false, on db: any Database) async throws {
    let record = ExtensionSetting(groupID: GroupID(group), extensionID: extensionID, kind: kind,
                                  body: "{}", isDeleted: deleted)
    let body = String(decoding: try RecordCodec.encoder.encode(record), as: UTF8.self)
    try await SyncRecordRow(id: record.id.uuid, groupID: group, budgetID: nil,
                            recordType: RecordType.extensionSetting.rawValue, body: body, createdBy: user,
                            clientID: UUID(), lamport: 1, isDeleted: deleted, serverSeq: Int.random(in: 1 ... 1_000_000)).create(on: db)
}

@Suite("The plan answer") struct PlansTests {
    @Test("While plans are off, the plan answer isn't there")
    func offIsNotFound() async throws {
        try await withV2App { app, _ in
            let session = try await v2SignUp("off@example.com", on: app)
            let (status, _) = try await askPlan(session.token, on: app)
            #expect(status == .notFound)
        }
    }

    @Test("Only a signed-in account can ask")
    func needsSignIn() async throws {
        try await withV2App { app, _ in
            app.plansEnabled = true
            let (status, _) = try await askPlan(nil, on: app)
            #expect(status == .unauthorized)
        }
    }

    @Test("A new account is on free, with free's limits, and keeps the same plan")
    func newAccountIsFree() async throws {
        try await withV2App { app, _ in
            app.plansEnabled = true
            let session = try await v2SignUp("new@example.com", on: app)
            let (status, plan) = try await askPlan(session.token, on: app)
            #expect(status == .ok)
            let free = try #require(plan)
            #expect(free.tier == "free" && free.state == "free" && free.source == "none" && free.period == "none")
            #expect(free.paidUntil == nil && !free.renews && free.nextTier == nil)
            #expect(free.limits == .init(properties: 1, groups: 1, invitedPerGroup: 1))
            #expect(free.used == .init(properties: 0, groups: 0, invitedPerGroup: 0))
            #expect(free.extensionsOpen.isEmpty && !free.canSyncPriceLabs)
            #expect(free.refreshMinutes == 60)
            #expect(free.appleAccountToken != session.userID)

            let (_, again) = try await askPlan(session.token, on: app)
            #expect(again == free)
            #expect(try await PlanRow.query(on: app.db).filter(\.$userID == session.userID).count() == 1)
        }
    }

    @Test("Used counts the groups this account made, their invited people, and their houses")
    func usageCounts() async throws {
        try await withV2App { app, _ in
            app.plansEnabled = true
            let session = try await v2SignUp("host@example.com", on: app)
            let other = try await v2SignUp("other@example.com", on: app)
            let me = session.userID
            let db = app.db

            let home = try await makeGroup(founder: me, on: db)
            let rentals = try await makeGroup(founder: me, on: db)
            _ = try await makeGroup(founder: me, deleted: true, on: db)
            let theirs = try await makeGroup(founder: other.userID, on: db)

            // Two invited into Rentals, one into Home: the most in one group is 2.
            try await addMember(me, to: home, on: db)
            try await addMember(other.userID, to: home, on: db)
            try await addMember(me, to: rentals, on: db)
            try await addMember(UUID(), to: rentals, on: db)
            try await addMember(UUID(), to: rentals, on: db)
            // Being invited into someone else's group doesn't count.
            try await addMember(me, to: theirs, on: db)

            // Two houses count. A stay, settings, a removed house, another
            // extension's house and a house in their group don't.
            try await addExtensionRecord(Plans.propertiesExtension, kind: "house", in: rentals, by: me, on: db)
            try await addExtensionRecord(Plans.propertiesExtension, kind: "house", in: home, by: me, on: db)
            try await addExtensionRecord(Plans.propertiesExtension, kind: "settings", in: rentals, by: me, on: db)
            try await addExtensionRecord(Plans.propertiesExtension, kind: "house", in: rentals, by: me,
                                         deleted: true, on: db)
            try await addExtensionRecord("wellspent.wartable", kind: "house", in: rentals, by: me, on: db)
            try await addExtensionRecord(Plans.propertiesExtension, kind: "house", in: theirs, by: me, on: db)

            let (_, plan) = try await askPlan(session.token, on: app)
            #expect(plan?.used == .init(properties: 2, groups: 2, invitedPerGroup: 2))
        }
    }

    @Test("Each paid tier opens every feature and differs only in houses")
    func tiers() {
        #expect(Tier.allCases.map(\.maxProperties) == [1, 2, 5, 15])
        for tier in [Tier.starter, .growth, .portfolio] {
            #expect(tier.maxGroups == nil && tier.maxInvitedPerGroup == nil)
            #expect(tier.extensionsOpen == ["wellspent.properties", "wellspent.tax"] && tier.canSyncPriceLabs)
        }
        #expect(Tier.free.maxGroups == 1 && Tier.free.maxInvitedPerGroup == 1)
        #expect(Plans.isOn("on") && !Plans.isOn(nil) && !Plans.isOn("yes"))
    }
}
