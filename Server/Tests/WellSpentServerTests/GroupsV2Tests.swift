import Testing
import Foundation
import Fluent
import Vapor
import VaporTesting
@testable import WellSpentServerCore
import WellSpentCrypto

private struct NewGroup: Content { let id: UUID; var importKey: Data? = nil }
private struct GroupReply: Content {
    let id: UUID; let founderID: UUID; let level: Int; let importKey: Data; let historyFloor: Int; let deleted: Bool
}
private struct Member: Content { let userID: UUID; let level: Int }
private struct Level: Content { let level: Int }
private struct NewInvite: Content { let level: Int; let historyAccess: String; let expiresInDays: Int? }
private struct InviteCreated: Content { let id: UUID; let token: String; let expiresAt: Date }
private struct Pending: Content { let id: UUID; let level: Int; let historyAccess: String; let inviterUserID: UUID }
private struct Preview: Content { let groupID: UUID; let level: Int; let historyAccess: String }
private struct Accept: Content { let token: String }

private func create(_ groupID: UUID, importKey: Data? = nil, as session: V2Session,
                    on app: Application) async throws -> (HTTPStatus, GroupReply?) {
    var result: (HTTPStatus, GroupReply?) = (.internalServerError, nil)
    try await app.testing().test(.POST, "api/v2/groups", headers: v2Bearer(session.token), beforeRequest: { request in
        try request.content.encode(NewGroup(id: groupID, importKey: importKey))
    }, afterResponse: { response async throws in
        result = (response.status, [.ok, .created].contains(response.status)
                  ? try response.content.decode(GroupReply.self) : nil)
    })
    return result
}

private func groups(of session: V2Session, on app: Application) async throws -> [GroupReply] {
    var list: [GroupReply] = []
    try await app.testing().test(.GET, "api/v2/groups", headers: v2Bearer(session.token),
                                 afterResponse: { response async throws in
        list = try response.content.decode([GroupReply].self)
    })
    return list
}

private func members(of groupID: UUID, as session: V2Session, on app: Application) async throws -> (HTTPStatus, [Member]) {
    var result: (HTTPStatus, [Member]) = (.internalServerError, [])
    try await app.testing().test(.GET, "api/v2/groups/\(groupID)/members", headers: v2Bearer(session.token),
                                 afterResponse: { response async throws in
        result = (response.status, response.status == .ok ? try response.content.decode([Member].self) : [])
    })
    return result
}

private func invite(_ groupID: UUID, level: AccessLevel, history: String = "all", days: Int? = nil,
                    as session: V2Session, on app: Application) async throws -> (HTTPStatus, InviteCreated?) {
    var result: (HTTPStatus, InviteCreated?) = (.internalServerError, nil)
    try await app.testing().test(.POST, "api/v2/groups/\(groupID)/invites", headers: v2Bearer(session.token),
                                 beforeRequest: { request in
        try request.content.encode(NewInvite(level: level.rawValue, historyAccess: history, expiresInDays: days))
    }, afterResponse: { response async throws in
        result = (response.status, response.status == .created ? try response.content.decode(InviteCreated.self) : nil)
    })
    return result
}

private func accept(_ token: String, as session: V2Session, on app: Application) async throws -> (HTTPStatus, GroupReply?) {
    var result: (HTTPStatus, GroupReply?) = (.internalServerError, nil)
    try await app.testing().test(.POST, "api/v2/invites/accept", headers: v2Bearer(session.token),
                                 beforeRequest: { request in
        try request.content.encode(Accept(token: token))
    }, afterResponse: { response async throws in
        result = (response.status, response.status == .ok ? try response.content.decode(GroupReply.self) : nil)
    })
    return result
}

/// Founds a group and brings in one member at a level, through an invite.
private func groupWith(_ level: AccessLevel, founder: String, member: String, on app: Application)
    async throws -> (groupID: UUID, founder: V2Session, member: V2Session) {
    let owner = try await v2SignUpConfirmed(founder, on: app)
    let joiner = try await v2SignUpConfirmed(member, on: app)
    let groupID = UUID()
    #expect(try await create(groupID, as: owner, on: app).0 == .created)
    let token = try #require(try await invite(groupID, level: level, as: owner, on: app).1?.token)
    #expect(try await accept(token, as: joiner, on: app).0 == .ok)
    return (groupID, owner, joiner)
}

private func setLevel(_ groupID: UUID, _ subject: UUID, to level: AccessLevel, as session: V2Session,
                      on app: Application) async throws -> HTTPStatus {
    try await v2Status(.PATCH, "api/v2/groups/\(groupID)/members/\(subject)", token: session.token,
                       body: Level(level: level.rawValue), on: app)
}

@Suite("Server, groups and sharing for readable sync", .serialized)
struct GroupsV2Tests {
    @Test func aFounderCreatesAGroupAndEveryDeviceCanListIt() async throws {
        try await withV2App { app, _ in
            let email = "v2-groups-founder@example.com"
            let mac = try await v2SignUpConfirmed(email, on: app)
            let groupID = UUID()
            let (created, reply) = try await create(groupID, as: mac, on: app)
            #expect(created == .created)
            #expect(reply?.level == AccessLevel.superadmin.rawValue && reply?.founderID == mac.userID)
            #expect(reply?.importKey.count == 32 && reply?.historyFloor == 0 && reply?.deleted == false)

            let desktop = try #require(try await v2SignIn(email, v2Password, on: app).1)
            let listed = try await groups(of: desktop, on: app)
            #expect(listed.map(\.id) == [groupID], "a second device finds the group")
            #expect(listed.first?.importKey == reply?.importKey, "and the same import key")
        }
    }

    /// A lost reply is sent again; someone else cannot claim the same ID.
    @Test func creatingAgainAnswersTheSameAndNobodyElseCanTakeTheID() async throws {
        try await withV2App { app, _ in
            let robin = try await v2SignUpConfirmed("v2-groups-again@example.com", on: app)
            let mallory = try await v2SignUpConfirmed("v2-groups-taker@example.com", on: app)
            let groupID = UUID()
            let first = try await create(groupID, as: robin, on: app).1
            let (again, second) = try await create(groupID, as: robin, on: app)
            #expect(again == .ok && second?.importKey == first?.importKey)
            #expect(try await create(groupID, as: mallory, on: app).0 == .conflict)
            #expect(try await groups(of: mallory, on: app).isEmpty)
        }
    }

    /// A group someone is not in reads the same as one that does not exist.
    @Test func onlyMembersSeeMembers() async throws {
        try await withV2App { app, _ in
            let (groupID, founder, member) = try await groupWith(.write, founder: "v2-members-founder@example.com",
                                                                  member: "v2-members-member@example.com", on: app)
            let stranger = try await v2SignUpConfirmed("v2-members-stranger@example.com", on: app)
            let (seen, list) = try await members(of: groupID, as: member, on: app)
            #expect(seen == .ok)
            #expect(Set(list.map(\.userID)) == [founder.userID, member.userID])
            #expect(try await members(of: groupID, as: stranger, on: app).0 == .forbidden)
            #expect(try await members(of: UUID(), as: stranger, on: app).0 == .forbidden)
        }
    }

    /// The ladder, as the signed log enforced it: a manager moves people below
    /// Manage, raising anyone to Manage or above takes an admin, nobody gives
    /// more than they hold, and the founder's level never changes.
    @Test func levelChangesFollowTheLadder() async throws {
        try await withV2App { app, _ in
            let (groupID, founder, manager) = try await groupWith(.manage, founder: "v2-ladder-founder@example.com",
                                                                   member: "v2-ladder-manager@example.com", on: app)
            let viewer = try await v2SignUpConfirmed("v2-ladder-viewer@example.com", on: app)
            let token = try #require(try await invite(groupID, level: .read, as: manager, on: app).1?.token)
            #expect(try await accept(token, as: viewer, on: app).0 == .ok)

            #expect(try await setLevel(groupID, viewer.userID, to: .write, as: manager, on: app) == .noContent)
            #expect(try await setLevel(groupID, viewer.userID, to: .manage, as: manager, on: app) == .forbidden,
                    "raising to Manage takes an admin")
            #expect(try await setLevel(groupID, viewer.userID, to: .read, as: viewer, on: app) == .forbidden,
                    "a member below Manage changes nobody")
            #expect(try await setLevel(groupID, founder.userID, to: .read, as: manager, on: app) == .forbidden)
            #expect(try await setLevel(groupID, viewer.userID, to: .superadmin, as: founder, on: app) == .badRequest,
                    "nobody is given superadmin")
            #expect(try await setLevel(groupID, manager.userID, to: .admin, as: founder, on: app) == .noContent)
            #expect(try await setLevel(groupID, founder.userID, to: .read, as: manager, on: app) == .forbidden,
                    "not even an admin changes the founder")
            #expect(try await setLevel(groupID, viewer.userID, to: .admin, as: manager, on: app) == .noContent,
                    "an admin can make an admin")
            let levels = Dictionary(uniqueKeysWithValues: try await members(of: groupID, as: founder, on: app).1
                .map { ($0.userID, $0.level) })
            #expect(levels[viewer.userID] == AccessLevel.admin.rawValue)
            #expect(levels[founder.userID] == AccessLevel.superadmin.rawValue)
        }
    }

    @Test func removingFollowsTheLadderAndAnyoneButTheFounderCanLeave() async throws {
        try await withV2App { app, _ in
            let (groupID, founder, manager) = try await groupWith(.manage, founder: "v2-remove-founder@example.com",
                                                                   member: "v2-remove-manager@example.com", on: app)
            let writer = try await v2SignUpConfirmed("v2-remove-writer@example.com", on: app)
            let other = try await v2SignUpConfirmed("v2-remove-other@example.com", on: app)
            for joiner in [writer, other] {
                let token = try #require(try await invite(groupID, level: .write, as: founder, on: app).1?.token)
                #expect(try await accept(token, as: joiner, on: app).0 == .ok)
            }
            let path = { (user: UUID) in "api/v2/groups/\(groupID)/members/\(user)" }

            #expect(try await v2Status(.DELETE, path(manager.userID), token: writer.token, on: app) == .forbidden)
            #expect(try await v2Status(.DELETE, path(writer.userID), token: manager.token, on: app) == .noContent)
            #expect(try await members(of: groupID, as: writer, on: app).0 == .forbidden, "removed is out at once")
            #expect(try await v2Status(.DELETE, path(founder.userID), token: manager.token, on: app) == .forbidden)
            #expect(try await v2Status(.DELETE, path(founder.userID), token: founder.token, on: app) == .forbidden,
                    "the founder cannot leave")
            #expect(try await v2Status(.DELETE, path(other.userID), token: other.token, on: app) == .noContent,
                    "anyone else can leave")
            #expect(try await v2Status(.DELETE, path(manager.userID), token: manager.token, on: app) == .noContent)
            #expect(try await members(of: groupID, as: founder, on: app).1.map(\.userID) == [founder.userID])
        }
    }

    @Test func invitesNeedManageAndCannotGiveMoreThanTheInviterMay() async throws {
        try await withV2App { app, _ in
            let (groupID, founder, writer) = try await groupWith(.write, founder: "v2-inv-rules-founder@example.com",
                                                                  member: "v2-inv-rules-writer@example.com", on: app)
            #expect(try await invite(groupID, level: .read, as: writer, on: app).0 == .forbidden)
            let manager = try await v2SignUpConfirmed("v2-inv-rules-manager@example.com", on: app)
            let token = try #require(try await invite(groupID, level: .manage, as: founder, on: app).1?.token)
            #expect(try await accept(token, as: manager, on: app).0 == .ok)
            #expect(try await invite(groupID, level: .manage, as: manager, on: app).0 == .forbidden,
                    "inviting at Manage takes an admin")
            #expect(try await invite(groupID, level: .write, as: manager, on: app).0 == .created)
            #expect(try await invite(groupID, level: .superadmin, as: founder, on: app).0 == .badRequest)
            #expect(try await invite(groupID, level: .read, history: "someday", as: founder, on: app).0 == .badRequest)
            #expect(try await invite(groupID, level: .read, days: 31, as: founder, on: app).0 == .badRequest)
        }
    }

    /// An invite adds one person, once, at its level; "from now on" starts their
    /// history at the group's current sequence.
    @Test func anInviteAddsOnePersonOnceAtItsLevelAndHistory() async throws {
        try await withV2App { app, _ in
            let founder = try await v2SignUpConfirmed("v2-accept-founder@example.com", on: app)
            let partner = try await v2SignUpConfirmed("v2-accept-partner@example.com", on: app)
            let late = try await v2SignUpConfirmed("v2-accept-late@example.com", on: app)
            let groupID = UUID()
            #expect(try await create(groupID, as: founder, on: app).0 == .created)
            let group = try #require(try await GroupRow.find(groupID, on: app.db))
            group.lastSeq = 41
            try await group.save(on: app.db)

            let created = try #require(try await invite(groupID, level: .write, history: "fromNow",
                                                        as: founder, on: app).1)
            var preview: Preview?
            try await app.testing().test(.POST, "api/v2/invites/preview", beforeRequest: { request in
                try request.content.encode(Accept(token: created.token))
            }, afterResponse: { response async throws in
                #expect(response.status == .ok)
                preview = try response.content.decode(Preview.self)
            })
            #expect(preview?.groupID == groupID && preview?.historyAccess == "fromNow",
                    "the link shows what it is for without signing in")

            let (joined, reply) = try await accept(created.token, as: partner, on: app)
            #expect(joined == .ok && reply?.level == AccessLevel.write.rawValue && reply?.historyFloor == 41)
            #expect(try await accept(created.token, as: late, on: app).0 == .conflict, "an invite works once")

            let again = try #require(try await invite(groupID, level: .read, as: founder, on: app).1)
            #expect(try await accept(again.token, as: partner, on: app).0 == .conflict, "already a member")
            #expect(try await accept(again.token, as: late, on: app).0 == .ok, "and the invite was not used up")
            #expect(try await accept("not-a-token", as: late, on: app).0 == .notFound)
        }
    }

    /// An invite speaks for whoever made it, as they are now: a removed admin
    /// cannot let herself back in, and a demoted one's invite is void.
    @Test func anInviteIsVoidOnceItsMakerCanNoLongerGiveThatLevel() async throws {
        try await withV2App { app, _ in
            let (groupID, founder, admin) = try await groupWith(.manage, founder: "v2-void-founder@example.com",
                                                                 member: "v2-void-admin@example.com", on: app)
            #expect(try await setLevel(groupID, admin.userID, to: .admin, as: founder, on: app) == .noContent)
            let backDoor = try #require(try await invite(groupID, level: .admin, as: admin, on: app).1?.token)
            let forFriend = try #require(try await invite(groupID, level: .admin, as: admin, on: app).1?.token)
            let friend = try await v2SignUpConfirmed("v2-void-friend@example.com", on: app)

            #expect(try await setLevel(groupID, admin.userID, to: .manage, as: founder, on: app) == .noContent)
            #expect(try await accept(forFriend, as: friend, on: app).0 == .gone, "demoted, so the invite is void")

            #expect(try await v2Status(.DELETE, "api/v2/groups/\(groupID)/members/\(admin.userID)",
                                       token: founder.token, on: app) == .noContent)
            #expect(try await accept(backDoor, as: admin, on: app).0 == .gone, "removed, so it is void")
            let remaining = try await members(of: groupID, as: founder, on: app).1.map(\.userID)
            #expect(remaining == [founder.userID])
        }
    }

    /// Nobody gives more history than they have.
    @Test func aFromNowMembersInviteStartsWhereTheyDid() async throws {
        try await withV2App { app, _ in
            let founder = try await v2SignUpConfirmed("v2-floor-founder@example.com", on: app)
            let partner = try await v2SignUpConfirmed("v2-floor-partner@example.com", on: app)
            let second = try await v2SignUpConfirmed("v2-floor-second@example.com", on: app)
            let groupID = UUID()
            #expect(try await create(groupID, as: founder, on: app).0 == .created)
            let group = try #require(try await GroupRow.find(groupID, on: app.db))
            group.lastSeq = 41
            try await group.save(on: app.db)
            let token = try #require(try await invite(groupID, level: .manage, history: "fromNow",
                                                      as: founder, on: app).1?.token)
            #expect(try await accept(token, as: partner, on: app).1?.historyFloor == 41)
            let everything = try #require(try await invite(groupID, level: .write, history: "all",
                                                           as: partner, on: app).1?.token)
            #expect(try await accept(everything, as: second, on: app).1?.historyFloor == 41)
        }
    }

    /// The old API took any expiry a client sent. Previewing and accepting
    /// both refuse a row that claims longer than an invite may last, so the
    /// link never shows an invite that cannot be accepted.
    @Test func anInviteClaimingMoreThanThirtyDaysIsRefused() async throws {
        try await withV2App { app, _ in
            let founder = try await v2SignUpConfirmed("v2-long-invite-founder@example.com", on: app)
            let joiner = try await v2SignUpConfirmed("v2-long-invite-joiner@example.com", on: app)
            let groupID = UUID()
            #expect(try await create(groupID, as: founder, on: app).0 == .created)
            let token = "an-old-api-token"
            try await InviteRow(inviteHash: inviteTokenHash(token), groupID: groupID, inviterUserID: founder.userID,
                                level: AccessLevel.read.rawValue, historyAccess: "all",
                                expiresAt: Date().addingTimeInterval(60 * 86_400)).create(on: app.db)
            var previewed: HTTPStatus?
            try await app.testing().test(.POST, "api/v2/invites/preview", beforeRequest: { request in
                try request.content.encode(Accept(token: token))
            }, afterResponse: { response async throws in
                previewed = response.status
            })
            #expect(previewed == .gone)
            #expect(try await accept(token, as: joiner, on: app).0 == .gone)
        }
    }

    @Test func joiningNeedsAConfirmedAddress() async throws {
        try await withV2App { app, _ in
            let founder = try await v2SignUpConfirmed("v2-confirm-founder@example.com", on: app)
            let unconfirmed = try await v2SignUp("v2-confirm-joiner@example.com", on: app)
            let groupID = UUID()
            #expect(try await create(groupID, as: founder, on: app).0 == .created)
            let token = try #require(try await invite(groupID, level: .write, as: founder, on: app).1?.token)
            #expect(try await accept(token, as: unconfirmed, on: app).0 == .forbidden)
        }
    }

    /// A group made before readable sync keeps the key its past imports used,
    /// once set it stays, and a group cannot take a record's ID.
    @Test func aGroupKeepsTheImportKeyItIsGivenAndCannotTakeARecordsID() async throws {
        try await withV2App { app, _ in
            let founder = try await v2SignUpConfirmed("v2-import-key@example.com", on: app)
            let groupID = UUID()
            #expect(try await create(groupID, as: founder, on: app).0 == .created)
            let group = try #require(try await GroupRow.find(groupID, on: app.db))
            group.importKey = nil
            try await group.save(on: app.db)

            #expect(try await create(groupID, as: founder, on: app).1?.importKey == Data(),
                    "sent without a key, a group made before readable sync keeps waiting for its founder's")
            let old = Data(repeating: 7, count: 32)
            #expect(try await create(groupID, importKey: old, as: founder, on: app).1?.importKey == old)
            #expect(try await create(groupID, importKey: Data(repeating: 9, count: 32), as: founder, on: app).1?.importKey
                    == old, "a key once set stays")
            #expect(try await create(UUID(), importKey: Data([1, 2]), as: founder, on: app).0 == .badRequest)

            let taken = SyncRecordRow(id: UUID(), groupID: groupID, budgetID: nil, recordType: "budget", body: "{}",
                                      createdBy: founder.userID, clientID: UUID(), lamport: 1, isDeleted: false,
                                      serverSeq: 1)
            try await taken.create(on: app.db)
            #expect(try await create(try #require(taken.id), as: founder, on: app).0 == .conflict)
            let someonesProfile = RecordID.memberProfile(group: GroupID(groupID), user: UserID(UUID())).uuid
            #expect(try await create(someonesProfile, as: founder, on: app).0 == .conflict,
                    "nor an ID shaped like a member profile's")
        }
    }

    @Test func anExpiredInviteIsRefusedAndPendingOnesCanBeCancelled() async throws {
        try await withV2App { app, _ in
            let (groupID, founder, writer) = try await groupWith(.write, founder: "v2-cancel-founder@example.com",
                                                                  member: "v2-cancel-writer@example.com", on: app)
            let joiner = try await v2SignUpConfirmed("v2-cancel-joiner@example.com", on: app)
            let old = try #require(try await invite(groupID, level: .read, as: founder, on: app).1)
            let row = try #require(try await InviteRow.find(old.id, on: app.db))
            row.expiresAt = Date().addingTimeInterval(-1)
            try await row.save(on: app.db)
            #expect(try await accept(old.token, as: joiner, on: app).0 == .gone)

            let live = try #require(try await invite(groupID, level: .read, as: founder, on: app).1)
            var pending: [Pending] = []
            try await app.testing().test(.GET, "api/v2/groups/\(groupID)/invites", headers: v2Bearer(founder.token),
                                         afterResponse: { response async throws in
                pending = try response.content.decode([Pending].self)
            })
            #expect(pending.map(\.id) == [live.id], "neither expired nor used invites are listed")

            let cancel = "api/v2/groups/\(groupID)/invites/\(live.id)"
            #expect(try await v2Status(.DELETE, cancel, token: writer.token, on: app) == .forbidden)
            #expect(try await v2Status(.DELETE, cancel, token: founder.token, on: app) == .noContent)
            #expect(try await accept(live.token, as: joiner, on: app).0 == .notFound)
        }
    }

    /// Only someone who may manage the group sees its invites. Someone at Add
    /// or View, and anyone outside it, is refused.
    @Test func onlyAManagerSeesTheGroupsInvites() async throws {
        try await withV2App { app, _ in
            let (groupID, founder, writer) = try await groupWith(.write, founder: "v2-see-inv-founder@example.com",
                                                                  member: "v2-see-inv-writer@example.com", on: app)
            let reader = try await v2SignUpConfirmed("v2-see-inv-reader@example.com", on: app)
            let token = try #require(try await invite(groupID, level: .read, as: founder, on: app).1?.token)
            #expect(try await accept(token, as: reader, on: app).0 == .ok)
            let stranger = try await v2SignUpConfirmed("v2-see-inv-stranger@example.com", on: app)
            _ = try #require(try await invite(groupID, level: .read, as: founder, on: app).1)

            let path = "api/v2/groups/\(groupID)/invites"
            #expect(try await v2Status(.GET, path, token: founder.token, on: app) == .ok)
            #expect(try await v2Status(.GET, path, token: writer.token, on: app) == .forbidden, "at Add")
            #expect(try await v2Status(.GET, path, token: reader.token, on: app) == .forbidden, "at View")
            #expect(try await v2Status(.GET, path, token: stranger.token, on: app) == .forbidden, "not in it")
        }
    }

    /// Cancelling an invite that isn't there, or one of another group's
    /// through this group, is not found, and the other group's stays.
    @Test func cancellingAnInviteThatIsNotTheGroupsIsNotFound() async throws {
        try await withV2App { app, _ in
            let founder = try await v2SignUpConfirmed("v2-cancel-none-founder@example.com", on: app)
            let mine = UUID()
            let other = UUID()
            #expect(try await create(mine, as: founder, on: app).0 == .created)
            #expect(try await create(other, as: founder, on: app).0 == .created)
            let theirs = try #require(try await invite(other, level: .read, as: founder, on: app).1)

            #expect(try await v2Status(.DELETE, "api/v2/groups/\(mine)/invites/\(UUID())",
                                       token: founder.token, on: app) == .notFound)
            #expect(try await v2Status(.DELETE, "api/v2/groups/\(mine)/invites/\(theirs.id)",
                                       token: founder.token, on: app) == .notFound)
            #expect(try await v2Status(.DELETE, "api/v2/groups/\(other)/invites/\(theirs.id)",
                                       token: founder.token, on: app) == .noContent, "it was still there")
        }
    }

    /// Removing someone who isn't in the group is not found, whether nobody
    /// has that ID or it's someone outside the group, and nobody is removed.
    @Test func removingSomeoneNotInTheGroupIsNotFound() async throws {
        try await withV2App { app, _ in
            let (groupID, founder, _) = try await groupWith(.write, founder: "v2-rm-none-founder@example.com",
                                                             member: "v2-rm-none-writer@example.com", on: app)
            let outsider = try await v2SignUpConfirmed("v2-rm-none-outsider@example.com", on: app)

            #expect(try await v2Status(.DELETE, "api/v2/groups/\(groupID)/members/\(UUID())",
                                       token: founder.token, on: app) == .notFound)
            #expect(try await v2Status(.DELETE, "api/v2/groups/\(groupID)/members/\(outsider.userID)",
                                       token: founder.token, on: app) == .notFound)
            #expect(try await members(of: groupID, as: founder, on: app).1.count == 2)
        }
    }
}
