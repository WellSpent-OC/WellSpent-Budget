import Testing
import Foundation
import Fluent
import Vapor
import VaporTesting
import WellSpentCrypto
import WellSpentModel
@testable import WellSpentServerCore

private struct Rec: Content {
    let id: UUID; let type: String; let budgetID: UUID?; let lamport: UInt64; let clientID: UUID
    let isDeleted: Bool; var body: String
}
private struct PushBody: Content { let records: [Rec] }
private struct PullReply: Content { let records: [Rec]; let serverSeq: Int; let hasMore: Bool }
private struct NewGroup: Content { let id: UUID }
private struct NewInvite: Content { let level: Int; let historyAccess: String; let expiresInDays: Int? }
private struct InviteCreated: Content { let token: String }
private struct Accept: Content { let token: String }
private struct Person: Content, Hashable { let groupID: UUID; let userID: UUID }
private struct Pick: Content { var groupID: UUID? = nil; var person: Person? = nil; var houseIDs: [UUID]? = nil }

private struct Refusal: Content {
    let reason: String
    let limit: String?
    let tier: String?
    let neededTier: String?
    let sheet: String?
    let refused: [UUID]?
    let nextChangeOn: Date?
}

private struct Answer: Content {
    struct Locked: Content { let groupIDs: [UUID]; let people: [Person]; let houseIDs: [UUID] }
    struct Open: Content { let groupID: UUID?; let person: Person?; let houseIDs: [UUID]; let groupChangedAt: Date? }
    let tier: String
    let locked: Locked?
    let open: Open?
}

/// What came back: the status, and the body read as a refusal or an answer.
private struct Reply {
    var status: HTTPStatus = .internalServerError
    var refusal: Refusal?
    var answer: Answer?
    var pulled: PullReply?
}

private func call(_ method: HTTPMethod, _ path: String, as session: V2Session, body: (any Content)? = nil,
                  on app: Application) async throws -> Reply {
    var reply = Reply()
    try await app.testing().test(method, "api/v2/" + path, headers: v2Bearer(session.token), beforeRequest: { request in
        if let body { try request.content.encode(body) }
    }, afterResponse: { response async throws in
        reply.status = response.status
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let data = Data(buffer: response.body)
        reply.refusal = try? decoder.decode(Refusal.self, from: data)
        reply.answer = try? decoder.decode(Answer.self, from: data)
        reply.pulled = try? decoder.decode(PullReply.self, from: data)
    })
    return reply
}

private func newGroup(as session: V2Session, on app: Application) async throws -> (HTTPStatus, UUID) {
    let id = UUID()
    let reply = try await call(.POST, "groups", as: session, body: NewGroup(id: id), on: app)
    return (reply.status, id)
}

private func invite(_ group: UUID, as session: V2Session, on app: Application) async throws -> Reply {
    try await call(.POST, "groups/\(group)/invites", as: session,
                   body: NewInvite(level: AccessLevel.write.rawValue, historyAccess: "all", expiresInDays: nil), on: app)
}

/// Someone new joins through an invitation, made while plans are off.
private func join(_ email: String, _ group: UUID, invitedBy founder: V2Session, on app: Application) async throws -> V2Session {
    let member = try await v2SignUpConfirmed(email, on: app)
    var token = ""
    try await app.testing().test(.POST, "api/v2/groups/\(group)/invites", headers: v2Bearer(founder.token),
                                 beforeRequest: { request in
        try request.content.encode(NewInvite(level: AccessLevel.write.rawValue, historyAccess: "all", expiresInDays: nil))
    }, afterResponse: { response async throws in token = try response.content.decode(InviteCreated.self).token })
    let accepted = try await call(.POST, "invites/accept", as: member, body: Accept(token: token), on: app)
    #expect(accepted.status == .ok)
    return member
}

private func house(_ listing: String, in group: UUID) -> ExtensionSetting {
    ExtensionSetting(groupID: GroupID(group), extensionID: Plans.propertiesExtension, kind: Plans.houseKind,
                     sourceKey: listing, body: "{}")
}

/// A stay names its house by the house record's ID, as Properties writes it.
private func stay(_ key: String, at house: ExtensionSetting, in group: UUID) -> ExtensionEntry {
    ExtensionEntry(groupID: GroupID(group), extensionID: Plans.propertiesExtension, kind: Plans.stayKind,
                   sourceKey: key, body: #"{"houseID":"\#(house.id.uuid.uuidString)"}"#)
}

private func rec(_ value: ExtensionSetting, lamport: UInt64 = 1) throws -> Rec {
    Rec(id: value.id.uuid, type: "extensionSetting", budgetID: nil, lamport: lamport, clientID: UUID(),
        isDeleted: value.isDeleted, body: String(decoding: try RecordCodec.encoder.encode(value), as: UTF8.self))
}

private func rec(_ value: ExtensionEntry, lamport: UInt64 = 1) throws -> Rec {
    Rec(id: value.id.uuid, type: "extensionEntry", budgetID: nil, lamport: lamport, clientID: UUID(),
        isDeleted: value.isDeleted, body: String(decoding: try RecordCodec.encoder.encode(value), as: UTF8.self))
}

private func push(_ records: [Rec], to group: UUID, as session: V2Session, on app: Application) async throws -> Reply {
    try await call(.POST, "groups/\(group)/push", as: session, body: PushBody(records: records), on: app)
}

private func setTier(_ tier: Tier, for user: UUID, on db: any Database) async throws {
    let plan = try await PlanRow.forUser(user, on: db)
    plan.tier = tier.rawValue
    try await plan.save(on: db)
}

@Suite("Plan limits and locks", .serialized) struct PlanLocksTests {
    @Test("On free, a second group, a second invitation and a second house each get their upgrade sheet")
    func freeLimitsRefuseWithTheirSheet() async throws {
        try await withV2App { app, _ in
            app.plansEnabled = true
            let host = try await v2SignUpConfirmed("locks-free@example.com", on: app)
            let (made, group) = try await newGroup(as: host, on: app)
            #expect(made == .created)

            let (second, _) = try await newGroup(as: host, on: app)
            #expect(second == .paymentRequired)

            #expect(try await invite(group, as: host, on: app).status == .created)
            let another = try await invite(group, as: host, on: app)
            #expect(another.status == .paymentRequired)
            #expect(another.refusal?.sheet == "invite" && another.refusal?.neededTier == "starter")

            let first = house("listing-1", in: group), extra = house("listing-2", in: group)
            #expect(try await push([try rec(first)], to: group, as: host, on: app).status == .ok)
            let refused = try await push([try rec(extra)], to: group, as: host, on: app)
            #expect(refused.status == .paymentRequired)
            #expect(refused.refusal?.reason == "plan_limit" && refused.refusal?.limit == "maxProperties")
            #expect(refused.refusal?.sheet == "add_house" && refused.refusal?.tier == "free")
            #expect(refused.refusal?.neededTier == "starter" && refused.refusal?.refused == [extra.id.uuid])
            #expect(try await SyncRecordRow.find(extra.id.uuid, on: app.db) == nil)

            let tax = ExtensionEntry(groupID: GroupID(group), extensionID: Plans.taxExtension, kind: "line",
                                     sourceKey: "commission", body: "{}")
            let taxes = try await push([try rec(tax)], to: group, as: host, on: app)
            #expect(taxes.status == .paymentRequired && taxes.refusal?.sheet == "taxes")
        }
    }

    @Test("A push with anything past a limit writes none of it")
    func aRefusedPushWritesNothing() async throws {
        try await withV2App { app, _ in
            app.plansEnabled = true
            let host = try await v2SignUp("locks-whole@example.com", on: app)
            let (_, group) = try await newGroup(as: host, on: app)
            let one = house("a", in: group), two = house("b", in: group)
            let reply = try await push([try rec(one), try rec(two)], to: group, as: host, on: app)
            #expect(reply.status == .paymentRequired && reply.refusal?.refused == [two.id.uuid])
            #expect(try await SyncRecordRow.find(one.id.uuid, on: app.db) == nil)
        }
    }

    @Test("Removing a house frees its place in the same push")
    func aRemovedHouseFreesItsPlace() async throws {
        try await withV2App { app, _ in
            app.plansEnabled = true
            let host = try await v2SignUp("locks-swap@example.com", on: app)
            let (_, group) = try await newGroup(as: host, on: app)
            var old = house("old", in: group)
            #expect(try await push([try rec(old)], to: group, as: host, on: app).status == .ok)
            old.isDeleted = true
            let swap = try await push([try rec(old, lamport: 2), try rec(house("new", in: group))],
                                      to: group, as: host, on: app)
            #expect(swap.status == .ok)
        }
    }

    @Test("Past free's one group, the oldest stays open and the rest are locked, until the payer picks")
    func lockedGroupsAndThePick() async throws {
        try await withV2App { app, _ in
            let host = try await v2SignUp("locks-two@example.com", on: app)
            let (_, home) = try await newGroup(as: host, on: app)
            let (_, rentals) = try await newGroup(as: host, on: app)
            let (_, beach) = try await newGroup(as: host, on: app)
            app.plansEnabled = true

            let answer = try await call(.GET, "plan", as: host, on: app).answer
            #expect(answer?.locked?.groupIDs == [rentals, beach] && answer?.open?.groupID == home)
            #expect(answer?.open?.groupChangedAt == nil)
            #expect(try await call(.GET, "groups/\(home)/pull?since=0", as: host, on: app).status == .ok)
            let locked = try await call(.GET, "groups/\(rentals)/pull?since=0", as: host, on: app)
            #expect(locked.status == .paymentRequired && locked.refusal?.sheet == "locked")
            #expect(try await push([try rec(house("x", in: rentals))], to: rentals, as: host, on: app).status
                    == .paymentRequired)

            let picked = try await call(.POST, "plan/pick", as: host, body: Pick(groupID: rentals), on: app)
            #expect(picked.status == .ok && picked.answer?.open?.groupID == rentals)
            #expect(picked.answer?.locked?.groupIDs == [home, beach] && picked.answer?.open?.groupChangedAt != nil)
            #expect(try await call(.GET, "groups/\(rentals)/pull?since=0", as: host, on: app).status == .ok)

            let tooSoon = try await call(.POST, "plan/pick", as: host, body: Pick(groupID: beach), on: app)
            #expect(tooSoon.status == .conflict && tooSoon.refusal?.reason == "pickTooSoon")
            #expect(tooSoon.refusal?.nextChangeOn != nil)
            // Picking the group already open changes nothing, so it isn't refused.
            #expect(try await call(.POST, "plan/pick", as: host, body: Pick(groupID: rentals), on: app).status == .ok)

            let stranger = try await v2SignUp("locks-stranger@example.com", on: app)
            let (_, theirs) = try await newGroup(as: stranger, on: app)
            let notYours = try await call(.POST, "plan/pick", as: host, body: Pick(groupID: theirs), on: app)
            #expect(notYours.status == .unprocessableEntity && notYours.refusal?.reason == "notYours")
        }
    }

    @Test("Past free's one invited person, the first to join stays open and the others are locked out")
    func lockedPeople() async throws {
        try await withV2App { app, _ in
            let host = try await v2SignUpConfirmed("locks-payer@example.com", on: app)
            let (_, group) = try await newGroup(as: host, on: app)
            let first = try await join("locks-first@example.com", group, invitedBy: host, on: app)
            let second = try await join("locks-second@example.com", group, invitedBy: host, on: app)
            app.plansEnabled = true

            #expect(try await call(.GET, "groups/\(group)/pull?since=0", as: first, on: app).status == .ok)
            #expect(try await call(.GET, "groups/\(group)/pull?since=0", as: second, on: app).status == .paymentRequired)
            let answer = try await call(.GET, "plan", as: host, on: app).answer
            #expect(answer?.locked?.people == [Person(groupID: group, userID: second.userID)])
            #expect(answer?.open?.person == Person(groupID: group, userID: first.userID))

            // People change any time: no 30-day wait.
            let swapped = try await call(.POST, "plan/pick", as: host,
                                         body: Pick(person: Person(groupID: group, userID: second.userID)), on: app)
            #expect(swapped.status == .ok)
            #expect(try await call(.GET, "groups/\(group)/pull?since=0", as: second, on: app).status == .ok)
            #expect(try await call(.GET, "groups/\(group)/pull?since=0", as: first, on: app).status == .paymentRequired)
        }
    }

    @Test("A locked house and its stays are left out of pulls, refused on push, and open once picked")
    func lockedHouses() async throws {
        try await withV2App { app, _ in
            let host = try await v2SignUp("locks-houses@example.com", on: app)
            let (_, group) = try await newGroup(as: host, on: app)
            let kept = house("kept", in: group), held = house("held", in: group)
            let heldStay = stay("s1", at: held, in: group), keptStay = stay("s2", at: kept, in: group)
            #expect(try await push([try rec(kept), try rec(held), try rec(keptStay), try rec(heldStay)],
                                   to: group, as: host, on: app).status == .ok)
            app.plansEnabled = true

            let pulled = try await call(.GET, "groups/\(group)/pull?since=0", as: host, on: app).pulled
            let ids = Set(pulled?.records.map(\.id) ?? [])
            #expect(ids.contains(kept.id.uuid) && ids.contains(keptStay.id.uuid))
            #expect(!ids.contains(held.id.uuid) && !ids.contains(heldStay.id.uuid))
            let refused = try await push([try rec(stay("s3", at: held, in: group))], to: group, as: host, on: app)
            #expect(refused.status == .paymentRequired && refused.refusal?.sheet == "locked")

            let answer = try await call(.GET, "plan", as: host, on: app).answer
            #expect(answer?.locked?.houseIDs == [held.id.uuid] && answer?.open?.houseIDs == [kept.id.uuid])

            let tooMany = try await call(.POST, "plan/pick", as: host,
                                         body: Pick(houseIDs: [kept.id.uuid, held.id.uuid]), on: app)
            #expect(tooMany.status == .unprocessableEntity && tooMany.refusal?.reason == "tooMany")
            let picked = try await call(.POST, "plan/pick", as: host, body: Pick(houseIDs: [held.id.uuid]), on: app)
            #expect(picked.answer?.open?.houseIDs == [held.id.uuid] && picked.answer?.locked?.houseIDs == [kept.id.uuid])

            // Removing a locked house is allowed: it only frees room.
            var gone = kept
            gone.isDeleted = true
            #expect(try await push([try rec(gone, lamport: 2)], to: group, as: host, on: app).status == .ok)
            #expect(try await SyncRecordRow.find(kept.id.uuid, on: app.db)?.isDeleted == true)
        }
    }

    @Test("Paying opens everything up to the new limits")
    func payingOpensEverything() async throws {
        try await withV2App { app, _ in
            let host = try await v2SignUp("locks-pays@example.com", on: app)
            let (_, home) = try await newGroup(as: host, on: app)
            let (_, rentals) = try await newGroup(as: host, on: app)
            app.plansEnabled = true
            #expect(try await call(.GET, "groups/\(rentals)/pull?since=0", as: host, on: app).status == .paymentRequired)

            try await setTier(.starter, for: host.userID, on: app.db)
            let answer = try await call(.GET, "plan", as: host, on: app).answer
            #expect(answer?.tier == "starter" && answer?.locked == nil && answer?.open == nil)
            #expect(try await call(.GET, "groups/\(rentals)/pull?since=0", as: host, on: app).status == .ok)
            #expect(try await call(.GET, "groups/\(home)/pull?since=0", as: host, on: app).status == .ok)
        }
    }

    @Test("Anyone in a locked group can pay to open it, and the group's payer becomes them")
    func aMemberTakesOverPaying() async throws {
        try await withV2App { app, _ in
            let host = try await v2SignUpConfirmed("locks-founder@example.com", on: app)
            let (_, group) = try await newGroup(as: host, on: app)
            _ = try await join("locks-stayer@example.com", group, invitedBy: host, on: app)
            let locked = try await join("locks-taker@example.com", group, invitedBy: host, on: app)
            app.plansEnabled = true
            #expect(try await call(.GET, "groups/\(group)/pull?since=0", as: locked, on: app).status == .paymentRequired)

            // On free they can't take it over, even with no group of their own:
            // two free accounts could otherwise open each other's groups.
            let free = try await call(.POST, "groups/\(group)/pay", as: locked, on: app)
            #expect(free.status == .paymentRequired && free.refusal?.sheet == "locked")
            #expect(try await GroupRow.find(group, on: app.db)?.paidByUserID == nil)

            try await setTier(.starter, for: locked.userID, on: app.db)
            #expect(try await call(.POST, "groups/\(group)/pay", as: locked, on: app).status == .ok)
            #expect(try await GroupRow.find(group, on: app.db)?.paidByUserID == locked.userID)
            #expect(try await call(.GET, "groups/\(group)/pull?since=0", as: locked, on: app).status == .ok)
            // The founder no longer pays for it, so it leaves their count.
            #expect(try await PlanUsage.of(host.userID, on: app.db).groups == 0)
        }
    }

    @Test("While plans are off, nothing is limited or locked")
    func offLimitsNothing() async throws {
        try await withV2App { app, _ in
            let host = try await v2SignUp("locks-off-limits@example.com", on: app)
            let (_, group) = try await newGroup(as: host, on: app)
            #expect(try await newGroup(as: host, on: app).0 == .created)
            #expect(try await push([try rec(house("a", in: group)), try rec(house("b", in: group))],
                                   to: group, as: host, on: app).status == .ok)
            #expect(try await call(.POST, "plan/pick", as: host, body: Pick(), on: app).status == .notFound)
        }
    }
}
