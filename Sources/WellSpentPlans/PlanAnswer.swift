import Foundation

/// The server's answer to "what plan does this account have?", from
/// `GET /api/v2/plan`. The server is the only judge. The apps show this
/// answer and never decide on their own.
public struct PlanAnswer: Codable, Equatable, Sendable {
    public enum Period: String, Codable, Sendable {
        case none, monthly, yearly
    }

    public enum State: String, Codable, Sendable {
        /// The free plan. It never ends.
        case free
        /// A paid plan, renewing.
        case active
        /// A renewal failed. Paid limits still apply while the store retries.
        case grace
        /// The grace period is over and the store is still retrying. Free limits apply.
        case billingProblem
        /// Renewal is off. Paid limits apply until `paidUntil`.
        case canceled
    }

    /// Where the paid plan was bought.
    public enum Source: String, Codable, Sendable {
        case none, apple, paddle
    }

    /// Numbers the plan allows, or is using. Nil means no limit.
    public struct Counts: Codable, Equatable, Sendable {
        public let properties: Int?
        public let groups: Int?
        /// Invited people in one group. In `used`, the most in any one group
        /// this plan pays for.
        public let invitedPerGroup: Int?

        public init(properties: Int?, groups: Int?, invitedPerGroup: Int?) {
            self.properties = properties
            self.groups = groups
            self.invitedPerGroup = invitedPerGroup
        }
    }

    /// The paid plan that ended or was refunded, until they buy again.
    public struct LastPlan: Codable, Equatable, Sendable {
        public enum Reason: String, Codable, Sendable { case ended, refunded }
        public let tier: PlanTier
        public let endedOn: Date
        public let reason: Reason

        public init(tier: PlanTier, endedOn: Date, reason: Reason) {
            self.tier = tier
            self.endedOn = endedOn
            self.reason = reason
        }
    }

    /// A person in a group, by id. The app has the names; the server sends ids only.
    public struct Person: Codable, Hashable, Sendable {
        public let groupID: UUID
        public let userID: UUID

        public init(groupID: UUID, userID: UUID) {
            self.groupID = groupID
            self.userID = userID
        }
    }

    /// What's past the plan and locked until someone pays.
    public struct Locked: Codable, Equatable, Sendable {
        public let groupIDs: [UUID]
        public let people: [Person]
        public let houseIDs: [UUID]

        public init(groupIDs: [UUID], people: [Person], houseIDs: [UUID]) {
            self.groupIDs = groupIDs
            self.people = people
            self.houseIDs = houseIDs
        }
    }

    /// What stays open on the free plan: the person's pick, or the first ones.
    public struct Open: Codable, Equatable, Sendable {
        public let groupID: UUID?
        public let person: Person?
        public let houseIDs: [UUID]

        public init(groupID: UUID?, person: Person?, houseIDs: [UUID]) {
            self.groupID = groupID
            self.person = person
            self.houseIDs = houseIDs
        }
    }

    public let tier: PlanTier
    public let period: Period
    public let state: State
    public let source: Source
    public let paidUntil: Date?
    public let renews: Bool
    public let nextTier: PlanTier?
    public let limits: Counts
    public let used: Counts
    /// The extensions this plan opens, by id: "wellspent.properties".
    public let extensionsOpen: [String]
    public let canSyncPriceLabs: Bool
    public let refreshMinutes: Int
    /// Fixed for the account and never its user id. The apps hand it to Apple
    /// with every purchase, so Apple's notices to the server name the account.
    public let appleAccountToken: UUID?
    /// When extras lock during a failed payment. Nil outside the grace period.
    public let graceUntil: Date?
    public let lastPlan: LastPlan?
    /// Nil when nothing is locked.
    public let locked: Locked?
    public let open: Open?

    public init(tier: PlanTier, period: Period, state: State, source: Source, paidUntil: Date?, renews: Bool,
                nextTier: PlanTier?, limits: Counts, used: Counts, extensionsOpen: [String],
                canSyncPriceLabs: Bool, refreshMinutes: Int, appleAccountToken: UUID?, graceUntil: Date? = nil,
                lastPlan: LastPlan? = nil, locked: Locked? = nil, open: Open? = nil) {
        self.tier = tier
        self.period = period
        self.state = state
        self.source = source
        self.paidUntil = paidUntil
        self.renews = renews
        self.nextTier = nextTier
        self.limits = limits
        self.used = used
        self.extensionsOpen = extensionsOpen
        self.canSyncPriceLabs = canSyncPriceLabs
        self.refreshMinutes = refreshMinutes
        self.appleAccountToken = appleAccountToken
        self.graceUntil = graceUntil
        self.lastPlan = lastPlan
        self.locked = locked
        self.open = open
    }

    /// Reads the server's JSON, with its ISO 8601 dates.
    public static func decode(_ data: Data) throws -> PlanAnswer {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(PlanAnswer.self, from: data)
    }

    /// Writes it the same way, for the cache.
    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(self)
    }
}
