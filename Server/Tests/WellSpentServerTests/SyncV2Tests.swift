import Testing
import Foundation
import Fluent
import Vapor
import VaporTesting
@testable import WellSpentServerCore
import WellSpentCrypto
import WellSpentModel

private struct Rec: Content {
    let id: UUID; let type: String; let budgetID: UUID?; let lamport: UInt64; let clientID: UUID
    let isDeleted: Bool; let body: String
    var createdBy: UUID? = nil; var updatedBy: UUID? = nil; var serverSeq: Int? = nil
}
private struct PushBody: Content { let records: [Rec] }
private struct PushReply: Content { let accepted: [UUID]; let rejected: [String: String]; let serverSeq: Int }
private struct PullReply: Content { let records: [Rec]; let serverSeq: Int; let hasMore: Bool }
private struct NewGroup: Content { let id: UUID }
private struct NewInvite: Content { let level: Int; let historyAccess: String; let expiresInDays: Int? }
private struct InviteCreated: Content { let id: UUID; let token: String; let expiresAt: Date }
private struct Accept: Content { let token: String }

private func json<T: Encodable>(_ value: T) throws -> String {
    String(decoding: try RecordCodec.encoder.encode(value), as: UTF8.self)
}

/// A device: one session and its own client ID.
private struct Device {
    let session: V2Session
    let clientID = UUID()
    var user: UUID { session.userID }
}

private func record(_ value: BudgetGroup, lamport: UInt64, on device: Device) throws -> Rec {
    Rec(id: value.id.uuid, type: "groupMeta", budgetID: nil, lamport: lamport, clientID: device.clientID,
        isDeleted: value.isDeleted, body: try json(value))
}
private func record(_ value: Budget, lamport: UInt64, on device: Device) throws -> Rec {
    Rec(id: value.id.uuid, type: "budget", budgetID: value.id.uuid, lamport: lamport, clientID: device.clientID,
        isDeleted: value.isDeleted, body: try json(value))
}
private func record(_ value: Transaction, lamport: UInt64, on device: Device) throws -> Rec {
    Rec(id: value.id.uuid, type: "transaction", budgetID: value.budgetID.uuid, lamport: lamport,
        clientID: device.clientID, isDeleted: value.isDeleted, body: try json(value))
}
private func record(_ value: MemberProfile, lamport: UInt64, on device: Device) throws -> Rec {
    Rec(id: value.id.uuid, type: "memberProfile", budgetID: nil, lamport: lamport, clientID: device.clientID,
        isDeleted: value.isDeleted, body: try json(value))
}

private func push(_ records: [Rec], to groupID: UUID, from device: Device, on app: Application)
    async throws -> (HTTPStatus, PushReply?) {
    var result: (HTTPStatus, PushReply?) = (.internalServerError, nil)
    try await app.testing().test(.POST, "api/v2/groups/\(groupID)/push", headers: v2Bearer(device.session.token),
                                 beforeRequest: { request in
        try request.content.encode(PushBody(records: records))
    }, afterResponse: { response async throws in
        result = (response.status, response.status == .ok ? try response.content.decode(PushReply.self) : nil)
    })
    return result
}

/// Pushes and expects every record taken.
private func pushAll(_ records: [Rec], to groupID: UUID, from device: Device, on app: Application) async throws {
    let (status, reply) = try await push(records, to: groupID, from: device, on: app)
    #expect(status == .ok && reply?.rejected == [:], "\(reply?.rejected ?? [:])")
}

private func pull(_ groupID: UUID, since: Int = 0, limit: Int? = nil, as device: Device,
                  on app: Application) async throws -> (HTTPStatus, PullReply?) {
    var result: (HTTPStatus, PullReply?) = (.internalServerError, nil)
    let query = "since=\(since)" + (limit.map { "&limit=\($0)" } ?? "")
    try await app.testing().test(.GET, "api/v2/groups/\(groupID)/pull?\(query)",
                                 headers: v2Bearer(device.session.token), afterResponse: { response async throws in
        result = (response.status, response.status == .ok ? try response.content.decode(PullReply.self) : nil)
    })
    return result
}

/// A group, its group record and one budget, made by a founder.
private func setUp(_ prefix: String, on app: Application) async throws -> (Device, UUID, Budget) {
    let founder = Device(session: try await v2SignUp("\(prefix)-founder@example.com", on: app))
    let groupID = UUID()
    try await app.testing().test(.POST, "api/v2/groups", headers: v2Bearer(founder.session.token),
                                 beforeRequest: { request in
        try request.content.encode(NewGroup(id: groupID))
    }, afterResponse: { response async throws in #expect(response.status == .created) })
    let budget = Budget(groupID: GroupID(groupID), name: "Groceries", limit: Money(minorUnits: 60_000))
    try await pushAll([try record(BudgetGroup(id: GroupID(groupID), name: "Household"), lamport: 1, on: founder),
                       try record(budget, lamport: 2, on: founder)], to: groupID, from: founder, on: app)
    return (founder, groupID, budget)
}

/// Brings someone in through an invite, at a level and with a history choice.
private func join(_ email: String, level: AccessLevel, history: String = "all", group groupID: UUID,
                  invitedBy founder: Device, on app: Application) async throws -> Device {
    let member = Device(session: try await v2SignUpConfirmed(email, on: app))
    var token = ""
    try await app.testing().test(.POST, "api/v2/groups/\(groupID)/invites", headers: v2Bearer(founder.session.token),
                                 beforeRequest: { request in
        try request.content.encode(NewInvite(level: level.rawValue, historyAccess: history, expiresInDays: nil))
    }, afterResponse: { response async throws in
        token = try response.content.decode(InviteCreated.self).token
    })
    try await app.testing().test(.POST, "api/v2/invites/accept", headers: v2Bearer(member.session.token),
                                 beforeRequest: { request in
        try request.content.encode(Accept(token: token))
    }, afterResponse: { response async throws in #expect(response.status == .ok) })
    return member
}

private func spend(_ merchant: String, _ cents: Int, in budget: Budget, by owner: UUID? = nil) -> Transaction {
    Transaction(budgetID: budget.id, groupID: budget.groupID, date: Date(timeIntervalSince1970: 1_790_000_000),
                merchant: merchant, amount: Money(minorUnits: -cents), createdBy: owner.map(UserID.init))
}

@Suite("Server, push and pull for readable sync", .serialized)
struct SyncV2Tests {
    /// What one device pushes, another device of the same person pulls, with
    /// the owner the server recorded.
    @Test func aRecordPushedOnOneDeviceIsPulledOnAnother() async throws {
        try await withV2App { app, _ in
            let (mac, groupID, budget) = try await setUp("v2-sync-devices", on: app)
            let lunch = spend("Hilltop", 1_420, in: budget)
            try await pushAll([try record(lunch, lamport: 3, on: mac)], to: groupID, from: mac, on: app)

            let desktop = Device(session: try #require(try await v2SignIn("v2-sync-devices-founder@example.com",
                                                                          v2Password, on: app).1))
            let (status, reply) = try await pull(groupID, as: desktop, on: app)
            #expect(status == .ok && reply?.hasMore == false && reply?.serverSeq == 3)
            #expect(reply?.records.map(\.type) == ["groupMeta", "budget", "transaction"])
            let pulled = try #require(reply?.records.last)
            #expect(pulled.createdBy == mac.user && pulled.updatedBy == mac.user && pulled.serverSeq == 3)
            let decoded = try RecordCodec.decoder.decode(Transaction.self, from: Data(pulled.body.utf8))
            #expect(decoded.merchant == "Hilltop" && decoded.createdBy == UserID(mac.user),
                    "the server writes the owner into a transaction that had none")
            #expect(try await pull(groupID, since: 3, as: desktop, on: app).1?.records.isEmpty == true)
        }
    }

    /// The apps' rule: the higher Lamport value wins; the same version sent
    /// again is taken once; an older one is refused with the reason the apps read.
    @Test func lastWriteWinsAndAResendIsTakenOnce() async throws {
        try await withV2App { app, _ in
            let (mac, groupID, budget) = try await setUp("v2-sync-lww", on: app)
            var lunch = spend("Hilltop", 1_420, in: budget)
            try await pushAll([try record(lunch, lamport: 5, on: mac)], to: groupID, from: mac, on: app)
            let (_, again) = try await push([try record(lunch, lamport: 5, on: mac)], to: groupID, from: mac, on: app)
            #expect(again?.accepted == [lunch.id.uuid] && again?.serverSeq == 3, "no new sequence for a resend")

            lunch.merchant = "Hilltop Grill"
            let (_, older) = try await push([try record(lunch, lamport: 4, on: mac)], to: groupID, from: mac, on: app)
            #expect(older?.rejected[lunch.id.uuid.uuidString] == RecordEnvelope.olderVersionRefusal)
            try await pushAll([try record(lunch, lamport: 6, on: mac)], to: groupID, from: mac, on: app)
            let stored = try #require(try await SyncRecordRow.find(lunch.id.uuid, on: app.db))
            #expect(stored.lamport == 6 && stored.body.contains("Hilltop Grill") && stored.firstSeq == 3)
        }
    }

    /// Someone at Add changes only their own entries; a manager changes anyone's.
    @Test func aWriterChangesOnlyTheirOwnTransactions() async throws {
        try await withV2App { app, _ in
            let (founder, groupID, budget) = try await setUp("v2-sync-owner", on: app)
            let writer = try await join("v2-sync-owner-writer@example.com", level: .write, group: groupID,
                                        invitedBy: founder, on: app)
            var rent = spend("Rent", 150_000, in: budget)
            try await pushAll([try record(rent, lamport: 3, on: founder)], to: groupID, from: founder, on: app)
            rent.createdBy = UserID(founder.user)
            rent.amount = Money(minorUnits: -1)
            let (_, theirs) = try await push([try record(rent, lamport: 4, on: writer)], to: groupID, from: writer, on: app)
            #expect(theirs?.rejected[rent.id.uuid.uuidString] == "only its owner or a manager can change it")

            var coffee = spend("Coffee", 500, in: budget)
            try await pushAll([try record(coffee, lamport: 5, on: writer)], to: groupID, from: writer, on: app)
            coffee.createdBy = UserID(writer.user)
            coffee.merchant = "Coffee, fixed by the founder"
            try await pushAll([try record(coffee, lamport: 6, on: founder)], to: groupID, from: founder, on: app)
            let stored = try #require(try await SyncRecordRow.find(coffee.id.uuid, on: app.db))
            #expect(stored.createdByUserID == writer.user && stored.updatedByUserID == founder.user,
                    "the owner stays the writer")
        }
    }

    @Test func aTransactionKeepsTheOwnerItWasMadeWith() async throws {
        try await withV2App { app, _ in
            let (founder, groupID, budget) = try await setUp("v2-sync-claim", on: app)
            let writer = try await join("v2-sync-claim-writer@example.com", level: .write, group: groupID,
                                        invitedBy: founder, on: app)
            let forged = spend("Not mine", 900, in: budget, by: founder.user)
            let (_, made) = try await push([try record(forged, lamport: 3, on: writer)], to: groupID, from: writer, on: app)
            #expect(made?.rejected[forged.id.uuid.uuidString] == "a transaction keeps the owner it was made with")

            var mine = spend("Mine", 900, in: budget, by: writer.user)
            try await pushAll([try record(mine, lamport: 4, on: writer)], to: groupID, from: writer, on: app)
            mine.createdBy = UserID(founder.user)
            let (_, moved) = try await push([try record(mine, lamport: 5, on: founder)], to: groupID, from: founder, on: app)
            #expect(moved?.rejected[mine.id.uuid.uuidString] == "a transaction keeps the owner it was made with",
                    "not even a manager hands a transaction to someone else")
        }
    }

    /// Budgets and the group take a manager; deleting the group takes the
    /// founder or an admin, and is final.
    @Test func budgetsAndTheGroupNeedAManagerAndADeleteIsFinal() async throws {
        try await withV2App { app, _ in
            let (founder, groupID, budget) = try await setUp("v2-sync-manage", on: app)
            let writer = try await join("v2-sync-manage-writer@example.com", level: .write, group: groupID,
                                        invitedBy: founder, on: app)
            let manager = try await join("v2-sync-manage-manager@example.com", level: .manage, group: groupID,
                                         invitedBy: founder, on: app)
            var renamed = budget
            renamed.name = "Food"
            #expect(try await push([try record(renamed, lamport: 3, on: writer)], to: groupID, from: writer, on: app)
                .1?.rejected[budget.id.uuid.uuidString] == "only a manager can change a budget")
            try await pushAll([try record(renamed, lamport: 3, on: manager)], to: groupID, from: manager, on: app)

            let household = BudgetGroup(id: GroupID(groupID), name: "Home")
            #expect(try await push([try record(household, lamport: 4, on: writer)], to: groupID, from: writer, on: app)
                .1?.rejected[groupID.uuidString] == "only a manager can change the group")
            var deleted = household
            deleted.isDeleted = true
            #expect(try await push([try record(deleted, lamport: 5, on: manager)], to: groupID, from: manager, on: app)
                .1?.rejected[groupID.uuidString] == "only the founder or an admin can delete the group")
            try await pushAll([try record(deleted, lamport: 5, on: founder)], to: groupID, from: founder, on: app)
            #expect(try await GroupRow.find(groupID, on: app.db)?.deletedAt != nil)

            #expect(try await push([try record(household, lamport: 99, on: founder)], to: groupID, from: founder,
                                   on: app).1?.rejected[groupID.uuidString] == SyncRulesV2.groupDeletedRefusal,
                    "a delete is final")
            let late = spend("After", 100, in: budget)
            #expect(try await push([try record(late, lamport: 6, on: writer)], to: groupID, from: writer, on: app)
                .1?.rejected[late.id.uuid.uuidString] == SyncRulesV2.groupDeletedRefusal)
            #expect(try await pull(groupID, as: writer, on: app).0 == .ok, "members still learn it was deleted")
        }
    }

    /// What is stored is what the record says it is, in the group and budget it
    /// was sent to.
    @Test func aRecordMustMatchWhereItWasSent() async throws {
        try await withV2App { app, _ in
            let (founder, groupID, budget) = try await setUp("v2-sync-binding", on: app)
            let (other, otherGroup, otherBudget) = try await setUp("v2-sync-binding-other", on: app)
            _ = other
            let lunch = spend("Hilltop", 1_420, in: budget)
            var wrongID = try record(lunch, lamport: 3, on: founder)
            wrongID = Rec(id: UUID(), type: wrongID.type, budgetID: wrongID.budgetID, lamport: 3,
                          clientID: founder.clientID, isDeleted: false, body: wrongID.body)
            var wrongBudget = try record(lunch, lamport: 3, on: founder)
            wrongBudget = Rec(id: lunch.id.uuid, type: "transaction", budgetID: UUID(), lamport: 3,
                              clientID: founder.clientID, isDeleted: false, body: wrongBudget.body)
            let elsewhere = spend("Elsewhere", 100, in: otherBudget)
            let notJSON = Rec(id: UUID(), type: "transaction", budgetID: budget.id.uuid, lamport: 3,
                              clientID: founder.clientID, isDeleted: false, body: "not json")
            let unknown = Rec(id: UUID(), type: "hologram", budgetID: nil, lamport: 3,
                              clientID: founder.clientID, isDeleted: false, body: "{}")
            let (_, reply) = try await push([wrongID, wrongBudget, try record(elsewhere, lamport: 3, on: founder),
                                             notJSON, unknown], to: groupID, from: founder, on: app)
            #expect(reply?.accepted.isEmpty == true)
            #expect(reply?.rejected[wrongID.id.uuidString] == "the record does not match where it was sent")
            #expect(reply?.rejected[lunch.id.uuid.uuidString] == "the record does not match where it was sent")
            #expect(reply?.rejected[elsewhere.id.uuid.uuidString] == "the record does not match where it was sent")
            #expect(reply?.rejected[notJSON.id.uuidString] == "the record does not match where it was sent")
            #expect(reply?.rejected[unknown.id.uuidString] == "unknown record type")

            // A transaction in this group may not name a budget that lives in another.
            let crossing = Transaction(budgetID: otherBudget.id, groupID: GroupID(groupID),
                                       date: Date(), merchant: "Crossing", amount: Money(minorUnits: -100))
            #expect(try await push([try record(crossing, lamport: 4, on: founder)], to: groupID, from: founder, on: app)
                .1?.rejected[crossing.id.uuid.uuidString] == "that budget is not in this group")
            _ = otherGroup
        }
    }

    /// A member profile sits on its owner's own ID, and nothing else may use
    /// an ID shaped like one.
    @Test func aMemberProfileSitsOnItsOwnersID() async throws {
        try await withV2App { app, _ in
            let (founder, groupID, budget) = try await setUp("v2-sync-profile", on: app)
            let writer = try await join("v2-sync-profile-writer@example.com", level: .write, group: groupID,
                                        invitedBy: founder, on: app)
            let mine = MemberProfile(groupID: GroupID(groupID), userID: UserID(writer.user), displayName: "Robin")
            try await pushAll([try record(mine, lamport: 3, on: writer)], to: groupID, from: writer, on: app)
            let theirs = MemberProfile(groupID: GroupID(groupID), userID: UserID(founder.user), displayName: "Not them")
            #expect(try await push([try record(theirs, lamport: 4, on: writer)], to: groupID, from: writer, on: app)
                .1?.rejected[theirs.id.uuid.uuidString] == "that ID belongs to a member profile")

            // On the sender's own ID, but naming someone else inside.
            var disguised = MemberProfile(groupID: GroupID(groupID), userID: UserID(founder.user), displayName: "Disguised")
            disguised.id = mine.id
            #expect(try await push([try record(disguised, lamport: 6, on: writer)], to: groupID, from: writer, on: app)
                .1?.rejected[mine.id.uuid.uuidString] == "that ID belongs to a member profile")

            let squatter = Transaction(id: RecordID.memberProfile(group: GroupID(groupID), user: UserID(UUID())),
                                       budgetID: budget.id, groupID: GroupID(groupID), date: Date(),
                                       merchant: "Squatter", amount: Money(minorUnits: -1))
            #expect(try await push([try record(squatter, lamport: 5, on: writer)], to: groupID, from: writer, on: app)
                .1?.rejected[squatter.id.uuid.uuidString] == "that ID belongs to a member profile")
        }
    }

    @Test func lamportValuesAreBounded() async throws {
        try await withV2App { app, _ in
            let (founder, groupID, budget) = try await setUp("v2-sync-lamport", on: app)
            let top = spend("Top", 1, in: budget)
            let ahead = spend("Ahead", 1, in: budget)
            let (_, reply) = try await push([try record(top, lamport: RecordEnvelope.lamportCeiling, on: founder),
                                             try record(ahead, lamport: 2 + RecordEnvelope.lamportLead + 1, on: founder)],
                                            to: groupID, from: founder, on: app)
            #expect(reply?.rejected[top.id.uuid.uuidString] == RecordEnvelope.lamportTooLargeRefusal)
            #expect(reply?.rejected[ahead.id.uuid.uuidString] == RecordEnvelope.lamportTooFarAheadRefusal)
        }
    }

    @Test func readersAndStrangersCannotPushAndRemovedMembersCannotPull() async throws {
        try await withV2App { app, _ in
            let (founder, groupID, budget) = try await setUp("v2-sync-readers", on: app)
            let reader = try await join("v2-sync-readers-reader@example.com", level: .read, group: groupID,
                                        invitedBy: founder, on: app)
            let stranger = Device(session: try await v2SignUp("v2-sync-readers-stranger@example.com", on: app))
            let lunch = spend("Hilltop", 1_420, in: budget)
            #expect(try await push([try record(lunch, lamport: 3, on: reader)], to: groupID, from: reader, on: app).0
                    == .forbidden)
            #expect(try await push([try record(lunch, lamport: 3, on: stranger)], to: groupID, from: stranger, on: app).0
                    == .forbidden)
            #expect(try await pull(groupID, as: reader, on: app).0 == .ok)
            #expect(try await v2Status(.DELETE, "api/v2/groups/\(groupID)/members/\(reader.user)",
                                       token: founder.session.token, on: app) == .noContent)
            #expect(try await pull(groupID, as: reader, on: app).0 == .forbidden)
        }
    }

    /// "From now on": the group, its budgets and its members, and only records
    /// first stored after joining, even when an older one is edited later.
    @Test func aFromNowMemberSeesOnlyWhatWasStoredAfterTheyJoined() async throws {
        try await withV2App { app, _ in
            let (founder, groupID, budget) = try await setUp("v2-sync-fromnow", on: app)
            var old = spend("Before", 100, in: budget)
            try await pushAll([try record(old, lamport: 3, on: founder)], to: groupID, from: founder, on: app)
            let partner = try await join("v2-sync-fromnow-partner@example.com", level: .write, history: "fromNow",
                                         group: groupID, invitedBy: founder, on: app)
            let new = spend("After", 200, in: budget)
            old.createdBy = UserID(founder.user)
            old.merchant = "Before, edited after"
            try await pushAll([try record(new, lamport: 4, on: founder), try record(old, lamport: 5, on: founder)],
                              to: groupID, from: founder, on: app)

            let seen = try #require(try await pull(groupID, as: partner, on: app).1)
            #expect(seen.records.map(\.type).sorted() == ["budget", "groupMeta", "transaction"])
            #expect(seen.records.first { $0.type == "transaction" }?.id == new.id.uuid)
            #expect(seen.serverSeq == 5 && seen.hasMore == false)

            let all = try #require(try await pull(groupID, as: founder, on: app).1)
            #expect(all.records.filter { $0.type == "transaction" }.count == 2)
        }
    }

    /// Two devices pushing to one group at once get sequence numbers that are
    /// unique, with no gaps, so a device pulling between them never skips one.
    /// Runs on both databases: on SQLite too, a push without the group's row
    /// held loses numbers when two arrive at once.
    @Test func twoDevicesPushingAtOnceGetEverySequenceInOrder() async throws {
        try await withV2App { app, _ in
            let (mac, groupID, budget) = try await setUp("v2-sync-race", on: app)
            let desktop = Device(session: try #require(try await v2SignIn("v2-sync-race-founder@example.com",
                                                                          v2Password, on: app).1))
            let fromMac = try (0 ..< 40).map { try record(spend("Mac \($0)", 100, in: budget), lamport: 3, on: mac) }
            let fromDesktop = try (0 ..< 40).map {
                try record(spend("Desktop \($0)", 100, in: budget), lamport: 3, on: desktop)
            }
            async let first = push(fromMac, to: groupID, from: mac, on: app)
            async let second = push(fromDesktop, to: groupID, from: desktop, on: app)
            let (a, b) = try await (first, second)
            #expect(a.1?.accepted.count == 40 && b.1?.accepted.count == 40)

            let all = try #require(try await pull(groupID, as: mac, on: app).1)
            #expect(all.records.count == 82 && all.hasMore == false)
            #expect(all.records.compactMap(\.serverSeq) == Array(1 ... 82), "every number once, in order")
        }
    }

    /// The pull reads the group before the records, so a push landing between
    /// the two can put records past the sequence it read. The cursor still
    /// moves past every record handed over, so none comes again.
    @Test func theCursorNeverFallsBehindWhatWasHandedOver() async throws {
        try await withV2App { app, _ in
            let (mac, groupID, budget) = try await setUp("v2-sync-cursor", on: app)
            try await pushAll([try record(spend("Lunch", 900, in: budget), lamport: 3, on: mac)],
                              to: groupID, from: mac, on: app)
            // As the pull saw it when a push was landing: behind the records.
            let group = try #require(try await GroupRow.find(groupID, on: app.db))
            group.lastSeq = 1
            try await group.save(on: app.db)
            let page = try #require(try await pull(groupID, as: mac, on: app).1)
            #expect(page.records.count == 3 && page.serverSeq == 3)
        }
    }

    /// A record may not take another group's ID, or that group's own record
    /// could never be stored.
    @Test func aRecordCannotTakeAnotherGroupsID() async throws {
        try await withV2App { app, _ in
            let (mac, groupID, budget) = try await setUp("v2-sync-group-id", on: app)
            let other = UUID()
            try await app.testing().test(.POST, "api/v2/groups", headers: v2Bearer(mac.session.token),
                                         beforeRequest: { request in
                try request.content.encode(NewGroup(id: other))
            }, afterResponse: { response async throws in #expect(response.status == .created) })
            let squatter = Transaction(id: RecordID(other), budgetID: budget.id, groupID: GroupID(groupID),
                                       date: Date(), merchant: "Squatter", amount: Money(minorUnits: -1))
            let (_, reply) = try await push([try record(squatter, lamport: 3, on: mac)], to: groupID, from: mac, on: app)
            #expect(reply?.rejected[other.uuidString] == "record ID does not match its type")

            // A record already stored keeps its ID, even if a group appears on it
            // later (the old API's founding route never checked readable records).
            var lunch = spend("Lunch", 900, in: budget)
            try await pushAll([try record(lunch, lamport: 4, on: mac)], to: groupID, from: mac, on: app)
            try await GroupRow(id: lunch.id.uuid, founderID: UUID()).create(on: app.db)
            lunch.createdBy = UserID(mac.user)
            lunch.merchant = "Lunch, edited"
            try await pushAll([try record(lunch, lamport: 5, on: mac)], to: groupID, from: mac, on: app)
        }
    }

    /// Pages in order. A page of records hidden by the history floor never
    /// leaves the cursor stuck.
    @Test func pullPagesAndNeverStalls() async throws {
        try await withV2App { app, _ in
            let (founder, groupID, budget) = try await setUp("v2-sync-pages", on: app)
            let spends = (0 ..< 5).map { spend("Spend \($0)", 100 + $0, in: budget) }
            try await pushAll(try spends.enumerated().map { try record($1, lamport: UInt64(3 + $0), on: founder) },
                              to: groupID, from: founder, on: app)
            var cursor = 0
            var seen: [UUID] = []
            for _ in 0 ..< 10 {
                let page = try #require(try await pull(groupID, since: cursor, limit: 3, as: founder, on: app).1)
                seen += page.records.map(\.id)
                cursor = page.serverSeq
                if !page.hasMore { break }
            }
            #expect(seen.count == 7 && cursor == 7)

            let late = try await join("v2-sync-pages-late@example.com", level: .read, history: "fromNow",
                                      group: groupID, invitedBy: founder, on: app)
            let page = try #require(try await pull(groupID, since: 2, limit: 3, as: late, on: app).1)
            #expect(page.records.isEmpty && page.hasMore == false && page.serverSeq == 7,
                    "the hidden records are stepped over, not asked for again")
        }
    }
}
