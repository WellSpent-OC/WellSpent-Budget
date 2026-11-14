import Foundation
import Fluent
import Vapor
import WellSpentCrypto
import WellSpentModel

// What a plan leaves open past its limits, and how the server holds the rest.
//
// Nothing is deleted. A group, a person or a house past the payer's limit is
// locked: pulls leave it out, and pushes to it are refused with a 402 that
// names the upgrade sheet. The payer picks what stays open; until they do,
// the oldest stays open. Paying opens everything up to the new limits.

// MARK: - Refusals

/// A refusal with a body the apps read: the plan's 402, and the pick's 409
/// and 422. One shape, so every app reads one thing.
struct PlanRefusal: Error, Content {
    var status: Int
    var reason: String
    var limit: String?
    var tier: Tier?
    var neededTier: Tier?
    var sheet: String?
    var refused: [UUID]?
    var nextChangeOn: Date?

    /// A 402 for a record, group or invitation past the payer's limit.
    static func limit(_ limit: String, sheet: String, tier: Tier, refused: [UUID] = []) -> PlanRefusal {
        PlanRefusal(status: 402, reason: "plan_limit", limit: limit, tier: tier,
                    neededTier: Tier.lowest(allowing: limit, past: tier), sheet: sheet, refused: refused)
    }

    static func pick(_ reason: String, status: Int, nextChangeOn: Date? = nil) -> PlanRefusal {
        PlanRefusal(status: status, reason: reason, nextChangeOn: nextChangeOn)
    }
}

/// Answers a `PlanRefusal` with its own body, not Vapor's `{error, reason}`.
struct PlanRefusalMiddleware: AsyncMiddleware {
    func respond(to request: Request, chainingTo next: any AsyncResponder) async throws -> Response {
        do {
            return try await next.respond(to: request)
        } catch let refusal as PlanRefusal {
            let response = Response(status: HTTPResponseStatus(statusCode: refusal.status))
            try response.content.encode(refusal, using: RecordCodec.jsonEncoderForAPI)
            return response
        }
    }
}

extension RecordCodec {
    /// The API's dates, as everywhere under /api/v2.
    static var jsonEncoderForAPI: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

extension Tier {
    /// The cheapest plan above `tier` that lifts `limit`. Houses need the size
    /// that fits one more; everything else opens on any paid plan.
    static func lowest(allowing limit: String, past tier: Tier) -> Tier {
        let above = Tier.allCases.drop { $0 != tier }.dropFirst()
        if limit == PlanLimit.properties {
            return above.first { $0.maxProperties > tier.maxProperties } ?? .portfolio
        }
        return above.first ?? .portfolio
    }
}

enum PlanLimit {
    static let properties = "maxProperties"
    static let groups = "maxGroups"
    static let invited = "maxInvitedPerGroup"
    static let extensions = "extensionsOpen"
    static let locked = "locked"
}

enum PlanSheet {
    static let addHouse = "add_house"
    static let addGroup = "add_group"
    static let invite = "invite"
    static let taxes = "taxes"
    static let locked = "locked"
}

// MARK: - Who pays, and the pick of houses

extension GroupRow {
    /// Who pays for the group: whoever took it over, or else its founder.
    var payerID: UUID { paidByUserID ?? founderID }
}

/// The houses a payer keeps open past their limit, one row each.
final class OpenHouseRow: Model, @unchecked Sendable {
    static let schema = "open_houses"

    @ID(custom: "id", generatedBy: .user) var id: UUID?
    @Field(key: "user_id") var userID: UUID
    @Field(key: "house_id") var houseID: UUID

    init() {}
    init(userID: UUID, houseID: UUID) {
        self.id = UUID()
        self.userID = userID
        self.houseID = houseID
    }
}

struct AddPlanLocks: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema(GroupRow.schema).field("paid_by_user_id", .uuid).update()
        try await database.schema(MembershipRow.schema).field("created_at", .datetime).update()
        try await database.schema(OpenHouseRow.schema)
            .field("id", .uuid, .identifier(auto: false))
            .field("user_id", .uuid, .required)
            .field("house_id", .uuid, .required)
            .unique(on: "user_id", "house_id")
            .create()
    }

    func revert(on database: any Database) async throws {
        try await database.schema(OpenHouseRow.schema).delete()
        try await database.schema(MembershipRow.schema).deleteField("created_at").update()
        try await database.schema(GroupRow.schema).deleteField("paid_by_user_id").update()
    }
}

// MARK: - What one payer's plan leaves open

/// One house: its record and its group. Its stays name it by the record's ID.
struct HouseRef: Equatable {
    let id: UUID
    let groupID: UUID
}

/// Everything one payer pays for, and what of it is locked.
struct PayerLocks {
    struct Person: Hashable, Content {
        let groupID: UUID
        let userID: UUID
    }

    let payerID: UUID
    let plan: PlanRow
    let tier: Tier
    let maxProperties: Int
    /// The groups they pay for that still exist, oldest first.
    let groups: [UUID]
    let lockedGroups: Set<UUID>
    let openGroup: UUID?
    /// Invited people past the limit, in groups that are otherwise open.
    let lockedPeople: Set<Person>
    let openPerson: Person?
    let houses: [HouseRef]
    let lockedHouses: Set<UUID>

    var openHouses: [UUID] { houses.map(\.id).filter { !lockedHouses.contains($0) } }
    var isLocking: Bool { !lockedGroups.isEmpty || !lockedPeople.isEmpty || !lockedHouses.isEmpty }

    static func of(_ payerID: UUID, on db: any Database) async throws -> PayerLocks {
        let plan = try await PlanRow.forUser(payerID, on: db)
        let tier = plan.limitTier
        let maxProperties = plan.maxPropertiesOverride ?? tier.maxProperties

        let groups = try await PlanLocks.groupsPaid(by: payerID, on: db)
        let groupIDs = groups.compactMap(\.id)

        var openGroups = Set(groupIDs)
        var openGroup: UUID?
        if let max = tier.maxGroups, groupIDs.count > max {
            let pick = plan.openGroupID.flatMap { groupIDs.contains($0) ? $0 : nil } ?? groupIDs.first
            openGroup = pick
            openGroups = Set([pick].compactMap { $0 })
        }
        let lockedGroups = Set(groupIDs).subtracting(openGroups)

        var lockedPeople: Set<Person> = []
        var openPerson: Person?
        if let max = tier.maxInvitedPerGroup, !openGroups.isEmpty {
            // Who joined first: by sequence, then by when, then by ID, so the
            // order is the same on every ask.
            let members = try await MembershipRow.query(on: db)
                .filter(\.$groupID ~~ Array(openGroups))
                .filter(\.$userID != payerID)
                .all()
                .sorted { ($0.joinedAtSequence, $0.createdAt ?? .distantPast, $0.id?.uuidString ?? "")
                    < ($1.joinedAtSequence, $1.createdAt ?? .distantPast, $1.id?.uuidString ?? "") }
            for (groupID, invited) in Dictionary(grouping: members, by: \.groupID) where invited.count > max {
                let ordered = invited.map(\.userID)
                let keep = plan.openMemberID.flatMap { ordered.contains($0) ? $0 : nil } ?? ordered.first
                if let keep { openPerson = Person(groupID: groupID, userID: keep) }
                for user in ordered where user != keep { lockedPeople.insert(Person(groupID: groupID, userID: user)) }
            }
        }

        let houses = try await PlanLocks.houses(in: groupIDs, on: db)
        // Houses in a locked group are locked with it. Of the rest, the picked
        // ones stay open first, then the oldest, up to the limit.
        let candidates = houses.filter { openGroups.contains($0.groupID) }
        let picked = Set(try await OpenHouseRow.query(on: db).filter(\.$userID == payerID).all().map(\.houseID))
        let ordered = candidates.filter { picked.contains($0.id) } + candidates.filter { !picked.contains($0.id) }
        let open = Set(ordered.prefix(maxProperties).map(\.id))
        let lockedHouses = Set(houses.map(\.id)).subtracting(open)

        return PayerLocks(payerID: payerID, plan: plan, tier: tier, maxProperties: maxProperties,
                          groups: groupIDs, lockedGroups: lockedGroups, openGroup: openGroup,
                          lockedPeople: lockedPeople, openPerson: openPerson, houses: houses,
                          lockedHouses: lockedHouses)
    }

    /// Whether this person can use the group at all.
    func isLocked(group: UUID, for user: UUID) -> Bool {
        lockedGroups.contains(group) || lockedPeople.contains(Person(groupID: group, userID: user))
    }

    /// Whether a stay's house is locked. A stay names its house by the house
    /// record's ID, as Properties writes it.
    func isLockedHouse(named houseID: String) -> Bool {
        UUID(uuidString: houseID).map(lockedHouses.contains) ?? false
    }
}

enum PlanLocks {
    /// The groups someone pays for that still exist, oldest first.
    static func groupsPaid(by payerID: UUID, on db: any Database) async throws -> [GroupRow] {
        try await GroupRow.query(on: db)
            .group(.or) { payer in
                payer.filter(\.$paidByUserID == payerID)
                payer.group(.and) { founder in
                    founder.filter(\.$paidByUserID == nil)
                    founder.filter(\.$founderID == payerID)
                }
            }
            .filter(\.$deletedAt == nil)
            .sort(\.$createdAt).sort(\.$id)
            .all()
    }

    /// Every house in these groups that isn't deleted, oldest first.
    static func houses(in groupIDs: [UUID], on db: any Database) async throws -> [HouseRef] {
        guard !groupIDs.isEmpty else { return [] }
        let rows = try await SyncRecordRow.query(on: db)
            .filter(\.$groupID ~~ groupIDs)
            .filter(\.$recordType == RecordType.extensionSetting.rawValue)
            .filter(\.$isDeleted == false)
            .sort(\.$firstSeq).sort(\.$id)
            .all()
        return rows.compactMap { row in
            guard let record = PlanRecord(row.body, type: .extensionSetting), record.isHouse,
                  let id = row.id else { return nil }
            return HouseRef(id: id, groupID: row.groupID)
        }
    }

    /// The locks that apply to a group: its payer's. Nil when plans are off.
    static func forGroup(_ group: GroupRow, on request: Request) async throws -> PayerLocks? {
        guard request.application.plansEnabled else { return nil }
        return try await PayerLocks.of(group.payerID, on: request.db)
    }

    /// Refuses a locked group or person with the 402 the app opens the locked
    /// sheet for.
    static func requireOpen(_ group: GroupRow, user: UUID, locks: PayerLocks?) throws {
        guard let locks, let id = group.id, locks.isLocked(group: id, for: user) else { return }
        let limit = locks.lockedGroups.contains(id) ? PlanLimit.groups : PlanLimit.invited
        throw PlanRefusal.limit(limit, sheet: PlanSheet.locked, tier: locks.tier)
    }
}

/// The plain fields of an extension record the plan reads: which extension,
/// which kind, its key, and for a stay the house it's at. The rest of the
/// body is the extension's own.
struct PlanRecord {
    let extensionID: String
    let kind: String
    let sourceKey: String?
    let isDeleted: Bool
    /// For a stay: its house's record ID.
    let houseKey: String?

    private struct StayHouse: Decodable { let houseID: String }

    init?(_ body: String, type: RecordType) {
        let data = Data(body.utf8)
        let decoder = RecordCodec.decoder
        let record: (String, String, String?, Bool, String)
        switch type {
        case .extensionSetting:
            guard let value = try? decoder.decode(ExtensionSetting.self, from: data) else { return nil }
            record = (value.extensionID, value.kind, value.sourceKey, value.isDeleted, value.body)
        case .extensionEntry:
            guard let value = try? decoder.decode(ExtensionEntry.self, from: data) else { return nil }
            record = (value.extensionID, value.kind, value.sourceKey, value.isDeleted, value.body)
        default:
            return nil
        }
        (extensionID, kind, sourceKey, isDeleted) = (record.0, record.1, record.2, record.3)
        houseKey = record.0 == Plans.propertiesExtension && record.1 == Plans.stayKind
            ? (try? JSONDecoder().decode(StayHouse.self, from: Data(record.4.utf8)))?.houseID : nil
    }

    var isHouse: Bool { extensionID == Plans.propertiesExtension && kind == Plans.houseKind }

    /// Whether the plan locks this record: a locked house, a stay at one, or a
    /// paid extension's record on a plan that doesn't open it.
    func isLocked(id: UUID, locks: PayerLocks, group: UUID) -> Bool {
        if Plans.paidExtensions.contains(extensionID), !locks.tier.extensionsOpen.contains(extensionID) { return true }
        if isHouse { return locks.lockedHouses.contains(id) }
        if let houseKey { return locks.isLockedHouse(named: houseKey) }
        return false
    }
}

// MARK: - The push check

extension PlanLocks {
    /// Checks a push before any of it is written. Anything past a limit
    /// refuses the whole push, naming each record, so the app sets those aside
    /// and sends the rest again.
    static func checkPush(_ records: [SyncRecordV2], group: GroupRow, locks: PayerLocks,
                          on db: any Database) async throws {
        guard let groupID = group.id else { return }
        var lockedRefused: [UUID] = []
        var taxRefused: [UUID] = []
        var newHouses: [UUID] = []
        for record in records {
            let type = RecordType(rawValue: record.type)
            // Removing something never needs a plan: it only frees room.
            guard !record.isDeleted, type == .extensionSetting || type == .extensionEntry,
                  let inside = PlanRecord(record.body, type: type) else { continue }
            if Plans.paidExtensions.contains(inside.extensionID),
               !locks.tier.extensionsOpen.contains(inside.extensionID) {
                taxRefused.append(record.id); continue
            }
            if inside.isLocked(id: record.id, locks: locks, group: groupID) {
                lockedRefused.append(record.id); continue
            }
            if inside.isHouse, !record.isDeleted, !locks.houses.contains(where: { $0.id == record.id }) {
                newHouses.append(record.id)
            }
        }
        if !taxRefused.isEmpty {
            throw PlanRefusal.limit(PlanLimit.extensions, sheet: PlanSheet.taxes, tier: locks.tier, refused: taxRefused)
        }
        if !lockedRefused.isEmpty {
            throw PlanRefusal.limit(PlanLimit.locked, sheet: PlanSheet.locked, tier: locks.tier, refused: lockedRefused)
        }
        // A deleted house frees its place in the same push.
        let deleting = Set(records.filter(\.isDeleted).map(\.id))
        let kept = locks.houses.filter { !deleting.contains($0.id) }.count
        if kept + newHouses.count > locks.maxProperties {
            let room = max(0, locks.maxProperties - kept)
            throw PlanRefusal.limit(PlanLimit.properties, sheet: PlanSheet.addHouse, tier: locks.tier,
                                    refused: Array(newHouses.dropFirst(room)))
        }
    }
}

// MARK: - The answer's locked and open

struct PlanLockedAnswer: Content, Equatable {
    let groupIDs: [UUID]
    let people: [PayerLocks.Person]
    let houseIDs: [UUID]
}

struct PlanOpenAnswer: Content, Equatable {
    let groupID: UUID?
    let person: PayerLocks.Person?
    let houseIDs: [UUID]
    /// When the open group last changed; the next change waits 30 days.
    let groupChangedAt: Date?
}

extension PayerLocks {
    var lockedAnswer: PlanLockedAnswer? {
        guard isLocking else { return nil }
        return PlanLockedAnswer(groupIDs: groups.filter(lockedGroups.contains),
                                people: lockedPeople.sorted { ($0.groupID.uuidString, $0.userID.uuidString)
                                    < ($1.groupID.uuidString, $1.userID.uuidString) },
                                houseIDs: houses.map(\.id).filter(lockedHouses.contains))
    }

    var openAnswer: PlanOpenAnswer? {
        guard isLocking else { return nil }
        return PlanOpenAnswer(groupID: openGroup ?? groups.first { !lockedGroups.contains($0) },
                              person: openPerson, houseIDs: openHouses, groupChangedAt: plan.openPickChangedAt)
    }
}

// MARK: - The pick, and taking over a group

struct PlanPickRequest: Content {
    let groupID: UUID?
    let person: PayerLocks.Person?
    let houseIDs: [UUID]?
}

enum PlanPickRules {
    /// The open group can change once in this many days, so a free account
    /// can't switch its one group back and forth to reach every group.
    static let groupChangeDays = 30

    static func nextChange(after changed: Date?) -> Date? {
        changed.map { $0.addingTimeInterval(TimeInterval(groupChangeDays) * 86_400) }
    }
}

func registerPlanLockRoutes(_ routes: any RoutesBuilder) {
    let authed = routes.grouped(SessionAuthenticator(), AuthenticatedUser.guardMiddleware())

    authed.on(.POST, "plan", "pick", body: .collect(maxSize: "64kb")) { request async throws -> PlanAnswer in
        let pick = try request.content.decode(PlanPickRequest.self)
        guard request.application.plansEnabled else { throw Abort(.notFound) }
        let user = try request.auth.require(AuthenticatedUser.self)
        try await request.db.transaction { db in
            let locks = try await PayerLocks.of(user.id, on: db)
            let plan = locks.plan
            if let group = pick.groupID {
                guard locks.groups.contains(group) else { throw PlanRefusal.pick("notYours", status: 422) }
                if group != (plan.openGroupID ?? locks.openGroup) {
                    if let next = PlanPickRules.nextChange(after: plan.openPickChangedAt), next > Date() {
                        throw PlanRefusal.pick("pickTooSoon", status: 409, nextChangeOn: next)
                    }
                    plan.openGroupID = group
                    plan.openPickChangedAt = Date()
                }
            }
            if let person = pick.person {
                guard locks.groups.contains(person.groupID), person.userID != user.id,
                      try await MembershipRow.query(on: db).filter(\.$groupID == person.groupID)
                        .filter(\.$userID == person.userID).first() != nil else {
                    throw PlanRefusal.pick("notYours", status: 422)
                }
                plan.openMemberID = person.userID
            }
            if let houseIDs = pick.houseIDs {
                let mine = Set(locks.houses.map(\.id))
                guard Set(houseIDs).isSubset(of: mine) else { throw PlanRefusal.pick("notYours", status: 422) }
                guard Set(houseIDs).count <= locks.maxProperties else { throw PlanRefusal.pick("tooMany", status: 422) }
                try await OpenHouseRow.query(on: db).filter(\.$userID == user.id).delete()
                for house in Set(houseIDs) { try await OpenHouseRow(userID: user.id, houseID: house).create(on: db) }
            }
            try await plan.save(on: db)
        }
        return try await PlanAnswer.of(user.id, on: request.db)
    }

    /// A member of a locked group pays to open it: the group's payer becomes
    /// them, so their own plan's limits apply.
    authed.post("groups", ":groupID", "pay") { request async throws -> PlanAnswer in
        let groupID = try request.parameters.require("groupID", as: UUID.self)
        guard request.application.plansEnabled else { throw Abort(.notFound) }
        let user = try request.auth.require(AuthenticatedUser.self)
        let (group, _) = try await requireMembership(groupID, user: user.id, needed: .read, on: request.db)
        guard group.deletedAt == nil else { throw Abort(.gone, reason: SyncRulesV2.groupDeletedRefusal) }
        if group.payerID != user.id {
            // Taking over needs a plan with room for the group. Free never
            // has it: two free accounts could otherwise open each other's.
            let mine = try await PayerLocks.of(user.id, on: request.db)
            if mine.tier == .free || mine.tier.maxGroups.map({ mine.groups.count >= $0 }) == true {
                throw PlanRefusal.limit(PlanLimit.groups, sheet: PlanSheet.locked, tier: mine.tier)
            }
            group.paidByUserID = user.id
            try await group.save(on: request.db)
        }
        return try await PlanAnswer.of(user.id, on: request.db)
    }
}
