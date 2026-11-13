import Foundation
import Fluent
import Vapor
import WellSpentCrypto
import WellSpentModel

// MARK: - Tiers

/// The four plans and what each allows. The same names are the store products'
/// middle part on Apple and Paddle (`app.wellspent.pro.<tier>.<period>`).
///
/// Every paid tier opens every feature. They differ only in how many houses
/// they allow. Free is 1 house, 1 group and 1 invited person, and never ends.
enum Tier: String, Codable, CaseIterable, Sendable {
    case free, starter, growth, portfolio

    /// How many houses, in every group this person pays for, added up.
    var maxProperties: Int {
        switch self {
        case .free: 1
        case .starter: 2
        case .growth: 5
        case .portfolio: 15
        }
    }

    /// How many groups this person may pay for. Nil is no limit. Groups they
    /// were invited into don't count.
    var maxGroups: Int? { self == .free ? 1 : nil }

    /// How many people a group they pay for may invite. Nil is no limit.
    var maxInvitedPerGroup: Int? { self == .free ? 1 : nil }

    /// The paid extensions this tier opens, by ID. A new paid extension adds a
    /// name here, so nothing in the core has to know about it.
    var extensionsOpen: [String] {
        self == .free ? [] : [Plans.propertiesExtension, Plans.taxExtension]
    }

    var canSyncPriceLabs: Bool { self != .free }
}

enum Plans {
    static let propertiesExtension = "wellspent.properties"
    static let taxExtension = "wellspent.tax"
    /// A house is a Properties record of this kind (`HouseRecordKind.house`).
    static let houseKind = "house"
    /// A stay at a house (`HouseRecordKind.stay`). Its body names the house.
    static let stayKind = "stay"
    /// Extensions only a paid plan opens. Properties isn't one: free has one
    /// house.
    static let paidExtensions: Set<String> = [taxExtension]
    /// How often an app reads PriceLabs, the same on every plan this release.
    static let refreshMinutes = 60

    /// `WELLSPENT_PLANS=on` turns on the plan routes. Off, they answer 404, so
    /// live keeps today's behavior until switch day.
    static func isOn(_ variable: String?) -> Bool { ServerSwitch.isOn(variable) }
}

struct PlansEnabledKey: StorageKey {
    typealias Value = Bool
}

extension Application {
    var plansEnabled: Bool {
        get { storage[PlansEnabledKey.self] ?? false }
        set { storage[PlansEnabledKey.self] = newValue }
    }
}

// MARK: - The plan record

/// One per account. Made the first time the account asks for it, on free, so
/// accounts from before plans need nothing done to them.
final class PlanRow: Model, @unchecked Sendable {
    static let schema = "plans"

    @ID(custom: "id", generatedBy: .user) var id: UUID?
    @Field(key: "user_id") var userID: UUID
    @Field(key: "tier") var tier: String
    /// "none", "monthly" or "yearly".
    @Field(key: "period") var period: String
    /// "none", "apple" or "paddle".
    @Field(key: "source") var source: String
    /// "free", "active", "grace", "billingProblem" or "canceled".
    @Field(key: "state") var state: String
    /// Apple's original transaction ID or Paddle's subscription ID.
    @OptionalField(key: "store_id") var storeID: String?
    /// Apple's "Production" or "Sandbox". Live takes both, since App Review
    /// and TestFlight buy in sandbox, so sandbox plans can be found and ended.
    /// Nil for a plan no store sold (`AddPlanStoreEnvironment`).
    @OptionalField(key: "store_environment") var storeEnvironment: String?
    @OptionalField(key: "paid_until") var paidUntil: Date?
    /// When a failed payment's grace period ends and extras lock (`AddPlanTime`).
    @OptionalField(key: "grace_until") var graceUntil: Date?
    /// The last paid plan, once it ended or was refunded, until the next
    /// purchase: its tier, when it ended, and "ended" or "refunded".
    @OptionalField(key: "last_tier") var lastTier: String?
    @OptionalField(key: "last_ended_on") var lastEndedOn: Date?
    @OptionalField(key: "last_reason") var lastReason: String?
    @Field(key: "renews") var renews: Bool
    /// A move down, waiting for the paid period to end.
    @OptionalField(key: "next_tier") var nextTier: String?
    /// Set by hand for an account over 15 houses.
    @OptionalField(key: "max_properties_override") var maxPropertiesOverride: Int?
    /// What stays open past a limit: the person's pick.
    @OptionalField(key: "open_group_id") var openGroupID: UUID?
    @OptionalField(key: "open_member_id") var openMemberID: UUID?
    @OptionalField(key: "open_pick_changed_at") var openPickChangedAt: Date?
    /// Given to Apple with each purchase, so Apple's notices find the account.
    /// Random, so Apple never sees an account's own ID.
    @Field(key: "apple_account_token") var appleAccountToken: UUID
    @Timestamp(key: "created_at", on: .create) var createdAt: Date?
    @Timestamp(key: "updated_at", on: .update) var updatedAt: Date?

    init() {}
    init(id: UUID = UUID(), userID: UUID) {
        self.id = id
        self.userID = userID
        tier = Tier.free.rawValue
        period = "none"
        source = "none"
        state = "free"
        renews = false
        appleAccountToken = UUID()
    }
}

struct CreatePlans: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema(PlanRow.schema)
            .field("id", .uuid, .identifier(auto: false))
            .field("user_id", .uuid, .required)
            .field("tier", .string, .required)
            .field("period", .string, .required)
            .field("source", .string, .required)
            .field("state", .string, .required)
            .field("store_id", .string)
            .field("paid_until", .datetime)
            .field("renews", .bool, .required)
            .field("next_tier", .string)
            .field("max_properties_override", .int)
            .field("open_group_id", .uuid)
            .field("open_member_id", .uuid)
            .field("open_pick_changed_at", .datetime)
            .field("apple_account_token", .uuid, .required)
            .field("created_at", .datetime)
            .field("updated_at", .datetime)
            .unique(on: "user_id")
            .unique(on: "apple_account_token")
            .create()
    }

    func revert(on database: any Database) async throws {
        try await database.schema(PlanRow.schema).delete()
    }
}

extension PlanRow {
    /// The account's plan, made on free the first time it's asked for. Two
    /// first asks at once both try to make it; the second finds the first's.
    static func forUser(_ userID: UUID, on db: any Database) async throws -> PlanRow {
        if let plan = try await PlanRow.query(on: db).filter(\.$userID == userID).first() {
            // Paid time that ran out since the last read (PlanClock).
            if PlanClock.advance(plan) { try await plan.save(on: db) }
            return plan
        }
        let plan = PlanRow(userID: userID)
        do {
            try await plan.create(on: db)
            return plan
        } catch {
            guard let made = try await PlanRow.query(on: db).filter(\.$userID == userID).first() else {
                throw error
            }
            return made
        }
    }
}

// MARK: - The answer

/// What an app asks for at sign-in, when it comes to the front, and after any
/// 402. The apps never decide what an account has; they show this.
struct PlanAnswer: Content, Equatable {
    struct Counts: Content, Equatable {
        /// Nil is no limit.
        let properties: Int?
        let groups: Int?
        let invitedPerGroup: Int?
    }

    let tier: Tier
    let period: String
    let state: String
    let source: String
    let paidUntil: Date?
    let renews: Bool
    let nextTier: Tier?
    let limits: Counts
    let used: Counts
    let extensionsOpen: [String]
    let canSyncPriceLabs: Bool
    let refreshMinutes: Int
    let appleAccountToken: UUID
    /// What's past a limit, and what the payer kept open. Both nil when
    /// nothing is locked. IDs only: the app names them from its own data.
    var locked: PlanLockedAnswer? = nil
    var open: PlanOpenAnswer? = nil
    /// When extras lock during a failed payment. Nil outside the grace period.
    var graceUntil: Date? = nil
    /// The last paid plan, once it ended or was refunded, until the next purchase.
    var lastPlan: PlanLastAnswer? = nil
}

/// `lastPlan`: the tier that ended, when, and "ended" or "refunded".
struct PlanLastAnswer: Content, Equatable {
    let tier: Tier
    let endedOn: Date
    let reason: String
}

/// How much of each limit an account uses, counting only the groups it pays
/// for: the ones it made, unless someone took one over, and the ones it took
/// over.
struct PlanUsage: Equatable {
    var properties = 0
    var groups = 0
    /// The most people invited into any one of those groups.
    var invitedPerGroup = 0

    static func of(_ userID: UUID, on db: any Database) async throws -> PlanUsage {
        let groups = try await PlanLocks.groupsPaid(by: userID, on: db)
        let groupIDs = groups.compactMap(\.id)
        var usage = PlanUsage(groups: groupIDs.count)
        guard !groupIDs.isEmpty else { return usage }

        let members = try await MembershipRow.query(on: db)
            .filter(\.$groupID ~~ groupIDs)
            .filter(\.$userID != userID)
            .all()
        let perGroup = Dictionary(grouping: members, by: \.groupID)
        usage.invitedPerGroup = perGroup.values.map(\.count).max() ?? 0

        // A house's extension and kind sit in the record's plain fields, beside
        // the body only Properties reads.
        let settings = try await SyncRecordRow.query(on: db)
            .filter(\.$groupID ~~ groupIDs)
            .filter(\.$recordType == RecordType.extensionSetting.rawValue)
            .filter(\.$isDeleted == false)
            .all()
        usage.properties = settings.filter { row in
            guard let record = try? RecordCodec.decoder.decode(ExtensionSetting.self, from: Data(row.body.utf8))
            else { return false }
            return record.extensionID == Plans.propertiesExtension && record.kind == Plans.houseKind
        }.count
        return usage
    }
}

extension PlanAnswer {
    init(_ plan: PlanRow, usage: PlanUsage) {
        // The paid tier stays named in billing problem; only its limits drop.
        let tier = plan.limitTier
        self.init(tier: Tier(rawValue: plan.tier) ?? .free, period: plan.period, state: plan.state, source: plan.source,
                  paidUntil: plan.paidUntil, renews: plan.renews,
                  nextTier: plan.nextTier.flatMap(Tier.init(rawValue:)),
                  limits: Counts(properties: plan.maxPropertiesOverride ?? tier.maxProperties,
                                 groups: tier.maxGroups, invitedPerGroup: tier.maxInvitedPerGroup),
                  used: Counts(properties: usage.properties, groups: usage.groups,
                               invitedPerGroup: usage.invitedPerGroup),
                  extensionsOpen: tier.extensionsOpen, canSyncPriceLabs: tier.canSyncPriceLabs,
                  refreshMinutes: Plans.refreshMinutes, appleAccountToken: plan.appleAccountToken)
        graceUntil = plan.state == "grace" ? plan.graceUntil : nil
        if let last = plan.lastTier.flatMap(Tier.init(rawValue:)), let endedOn = plan.lastEndedOn, let reason = plan.lastReason {
            lastPlan = PlanLastAnswer(tier: last, endedOn: endedOn, reason: reason)
        }
    }

    /// The whole answer for an account, with what its plan locks.
    static func of(_ userID: UUID, on db: any Database) async throws -> PlanAnswer {
        let locks = try await PayerLocks.of(userID, on: db)
        var answer = PlanAnswer(locks.plan, usage: try await PlanUsage.of(userID, on: db))
        answer.locked = locks.lockedAnswer
        answer.open = locks.openAnswer
        return answer
    }
}

// MARK: - Routes

func registerPlanRoutes(_ routes: any RoutesBuilder) {
    let authed = routes.grouped(SessionAuthenticator(), AuthenticatedUser.guardMiddleware())

    authed.get("plan") { request async throws -> PlanAnswer in
        guard request.application.plansEnabled else { throw Abort(.notFound) }
        let user = try request.auth.require(AuthenticatedUser.self)
        return try await PlanAnswer.of(user.id, on: request.db)
    }
}
