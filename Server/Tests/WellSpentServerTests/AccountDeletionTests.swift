import Testing
import Foundation
import Fluent
import Vapor
import VaporTesting
import WellSpentCrypto
import WellSpentModel
@testable import WellSpentServerCore

private struct Delete: Content { let password: String }
private struct NewGroup: Content { let id: UUID }
private struct NewInvite: Content { let level: Int; let historyAccess: String; let expiresInDays: Int? }
private struct InviteCreated: Content { let token: String }
private struct Accept: Content { let token: String }
private struct Rec: Content {
    let id: UUID; let type: String; let budgetID: UUID?; let lamport: UInt64; let clientID: UUID
    let isDeleted: Bool; let body: String
}
private struct PushBody: Content { let records: [Rec] }
private struct Refusal: Content { let reason: String }

/// v2SignUp's password, which every test account here uses.
private let password = v2Password

private func deleteAccount(_ session: V2Session, password: String = password,
                           on app: Application) async throws -> (HTTPStatus, Refusal?) {
    var result: (HTTPStatus, Refusal?) = (.internalServerError, nil)
    try await app.testing().test(.POST, "api/v2/account/delete", headers: v2Bearer(session.token),
                                 beforeRequest: { request in
        try request.content.encode(Delete(password: password))
    }, afterResponse: { response async throws in
        result = (response.status, try? response.content.decode(Refusal.self))
    })
    return result
}

private func newGroup(_ session: V2Session, on app: Application) async throws -> UUID {
    let id = UUID()
    #expect(try await v2Status(.POST, "api/v2/groups", token: session.token, body: NewGroup(id: id), on: app) == .created)
    return id
}

private func join(_ email: String, _ group: UUID, invitedBy founder: V2Session, level: AccessLevel = .write,
                  on app: Application) async throws -> V2Session {
    let member = try await v2SignUpConfirmed(email, on: app)
    var token = ""
    try await app.testing().test(.POST, "api/v2/groups/\(group)/invites", headers: v2Bearer(founder.token),
                                 beforeRequest: { request in
        try request.content.encode(NewInvite(level: level.rawValue, historyAccess: "all", expiresInDays: nil))
    }, afterResponse: { response async throws in token = try response.content.decode(InviteCreated.self).token })
    #expect(try await v2Status(.POST, "api/v2/invites/accept", token: member.token, body: Accept(token: token), on: app) == .ok)
    return member
}

/// A budget and a profile in the group, pushed by this person.
private func addBudgetAndProfile(_ group: UUID, by session: V2Session, on app: Application) async throws -> UUID {
    let budget = Budget(groupID: GroupID(group), name: "Groceries", limit: Money(minorUnits: 10_000))
    let profile = MemberProfile(groupID: GroupID(group), userID: UserID(session.userID), displayName: "Sam")
    func rec<T: Encodable>(_ value: T, _ id: UUID, _ type: String, budget: UUID?) throws -> Rec {
        Rec(id: id, type: type, budgetID: budget, lamport: 1, clientID: UUID(), isDeleted: false,
            body: String(decoding: try RecordCodec.encoder.encode(value), as: UTF8.self))
    }
    let records = [try rec(budget, budget.id.uuid, "budget", budget: budget.id.uuid),
                   try rec(profile, profile.id.uuid, "memberProfile", budget: nil)]
    #expect(try await v2Status(.POST, "api/v2/groups/\(group)/push", token: session.token,
                               body: PushBody(records: records), on: app) == .ok)
    return budget.id.uuid
}

private struct RefusingPaddle: PaddleCanceling {
    func cancel(subscriptionID: String) async throws { throw Abort(.badGateway) }
}

private final class RecordingPaddle: PaddleCanceling, @unchecked Sendable {
    var canceled: [String] = []
    func cancel(subscriptionID: String) async throws { canceled.append(subscriptionID) }
}

@Suite("Deleting an account", .serialized) struct AccountDeletionTests {
    @Test("While deletion is off, the route isn't there and nothing is deleted")
    func offIsNotFound() async throws {
        try await withV2App { app, _ in
            let me = try await v2SignUp("delete-off@example.com", on: app)
            #expect(try await deleteAccount(me, on: app).0 == .notFound)
            #expect(try await UserRow.find(me.userID, on: app.db) != nil)
            #expect(try await v2Me(me.token, on: app) != nil)
        }
    }

    @Test("Deleting an account removes it, its sign-ins and the groups only it was in")
    func deletesTheAccountAndItsOwnGroups() async throws {
        try await withV2App { app, _ in
            let me = try await v2SignUp("delete-leaving@example.com", on: app)
            let group = try await newGroup(me, on: app)
            let budget = try await addBudgetAndProfile(group, by: me, on: app)

            #expect(try await deleteAccount(me, on: app).0 == .noContent)
            #expect(try await UserRow.find(me.userID, on: app.db) == nil)
            #expect(try await SessionRow.query(on: app.db).filter(\.$userID == me.userID).count() == 0)
            #expect(try await GroupRow.find(group, on: app.db) == nil)
            #expect(try await SyncRecordRow.find(budget, on: app.db) == nil)
            #expect(try await PlanRow.query(on: app.db).filter(\.$userID == me.userID).count() == 0)
            // The old session no longer works, and the address can sign up again.
            #expect(try await v2Me(me.token, on: app) == nil)
            _ = try await v2SignUp("delete-leaving@example.com", on: app)
        }
    }

    @Test("A wrong password deletes nothing, and doesn't sign the person out")
    func aWrongPasswordDeletesNothing() async throws {
        try await withV2App { app, _ in
            let me = try await v2SignUp("delete-careful@example.com", on: app)
            #expect(try await deleteAccount(me, password: "not it at all", on: app).0 == .forbidden)
            #expect(try await UserRow.find(me.userID, on: app.db) != nil)
            #expect(try await v2Me(me.token, on: app) != nil)
        }
    }

    @Test("A shared group stays for the others and passes to the next manager, who then pays for it")
    func aSharedGroupPassesOn() async throws {
        try await withV2App { app, _ in
            let founder = try await v2SignUpConfirmed("delete-founder@example.com", on: app)
            let group = try await newGroup(founder, on: app)
            let budget = try await addBudgetAndProfile(group, by: founder, on: app)
            let writer = try await join("delete-writer@example.com", group, invitedBy: founder, on: app)
            let manager = try await join("delete-manager@example.com", group, invitedBy: founder, level: .manage, on: app)
            let before = try #require(try await GroupRow.find(group, on: app.db)).lastSeq

            #expect(try await deleteAccount(founder, on: app).0 == .noContent)
            let after = try #require(try await GroupRow.find(group, on: app.db))
            #expect(after.founderID == manager.userID && after.payerID == manager.userID)
            let level = try await MembershipRow.query(on: app.db).filter(\.$groupID == group)
                .filter(\.$userID == manager.userID).first()?.level
            #expect(level == AccessLevel.superadmin.rawValue)
            #expect(try await MembershipRow.query(on: app.db).filter(\.$groupID == group).count() == 2)
            // The budget is the group's and stays. Their profile goes, at a new sequence.
            #expect(try await SyncRecordRow.find(budget, on: app.db)?.isDeleted == false)
            let profile = RecordID.memberProfile(group: GroupID(group), user: UserID(founder.userID)).uuid
            let row = try #require(try await SyncRecordRow.find(profile, on: app.db))
            #expect(row.isDeleted && row.serverSeq == before + 1 && after.lastSeq == before + 1)
            #expect(try await v2Status(.GET, "api/v2/groups/\(group)/pull?since=0", token: writer.token, on: app) == .ok)
        }
    }

    @Test("Without a manager left, the group passes to whoever joined first")
    func noManagerPassesToTheFirstMember() async throws {
        try await withV2App { app, _ in
            let founder = try await v2SignUpConfirmed("delete-only@example.com", on: app)
            let group = try await newGroup(founder, on: app)
            let first = try await join("delete-first@example.com", group, invitedBy: founder, on: app)
            _ = try await join("delete-second@example.com", group, invitedBy: founder, on: app)
            #expect(try await deleteAccount(founder, on: app).0 == .noContent)
            #expect(try await GroupRow.find(group, on: app.db)?.founderID == first.userID)
        }
    }

    @Test("A member who leaves this way takes only themselves out of the group")
    func aMemberLeavesOnlyThemselves() async throws {
        try await withV2App { app, _ in
            let founder = try await v2SignUpConfirmed("delete-stays@example.com", on: app)
            let group = try await newGroup(founder, on: app)
            let member = try await join("delete-goes@example.com", group, invitedBy: founder, on: app)
            #expect(try await deleteAccount(member, on: app).0 == .noContent)
            #expect(try await GroupRow.find(group, on: app.db)?.founderID == founder.userID)
            #expect(try await MembershipRow.query(on: app.db).filter(\.$groupID == group).count() == 1)
        }
    }

    @Test("A group they founded but left, with someone still in it, isn't deleted with them")
    func aFoundedGroupWithMembersSurvives() async throws {
        try await withV2App { app, _ in
            let founder = try await v2SignUp("delete-left@example.com", on: app)
            let group = try await newGroup(founder, on: app)
            // Not reachable through the app today, where a founder can't leave.
            try await MembershipRow.query(on: app.db).filter(\.$groupID == group).delete()
            try await MembershipRow(groupID: group, userID: UUID(), level: AccessLevel.write.rawValue,
                                    joinedAtSequence: 0).create(on: app.db)
            #expect(try await deleteAccount(founder, on: app).0 == .noContent)
            #expect(try await GroupRow.find(group, on: app.db) != nil)
        }
    }

    @Test("A website plan is canceled through Paddle first, and if Paddle refuses, nothing is deleted")
    func aPaddlePlanIsCanceledFirst() async throws {
        try await withV2App { app, _ in
            let me = try await v2SignUp("delete-paying@example.com", on: app)
            let plan = try await PlanRow.forUser(me.userID, on: app.db)
            (plan.tier, plan.source, plan.state, plan.storeID) = ("starter", "paddle", "active", "sub_123")
            try await plan.save(on: app.db)

            let (status, refusal) = try await deleteAccount(me, on: app)
            #expect(status == .conflict && refusal?.reason == "paddleCancelFailed")
            app.paddleCanceler = RefusingPaddle()
            #expect(try await deleteAccount(me, on: app).0 == .conflict)
            #expect(try await UserRow.find(me.userID, on: app.db) != nil)

            let paddle = RecordingPaddle()
            app.paddleCanceler = paddle
            #expect(try await deleteAccount(me, on: app).0 == .noContent)
            #expect(paddle.canceled == ["sub_123"])
        }
    }

    @Test("An Apple plan doesn't stop the delete: only Apple can cancel it")
    func anApplePlanDoesNotBlock() async throws {
        try await withV2App { app, _ in
            let me = try await v2SignUp("delete-apple@example.com", on: app)
            let plan = try await PlanRow.forUser(me.userID, on: app.db)
            (plan.tier, plan.source, plan.state) = ("growth", "apple", "active")
            try await plan.save(on: app.db)
            #expect(try await deleteAccount(me, on: app).0 == .noContent)
        }
    }
}
