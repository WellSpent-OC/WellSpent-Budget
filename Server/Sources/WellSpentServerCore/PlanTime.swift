import Foundation
import Vapor
import Fluent

// MARK: - When paid time runs out

/// What happens to a plan as time passes, with no word from the store. Run
/// each time the plan is read, so there is no daily job to miss:
///
/// - A plan that won't renew (canceled) keeps its paid limits to `paid_until`,
///   then ends: free, with the ended plan kept as `lastPlan`.
/// - A failed payment keeps the paid limits through the store's grace period
///   (`grace_until`). After that the plan is in billing problem: free's limits,
///   while the store keeps trying.
///
/// A plan that renews and has passed `paid_until` waits for the store's notice
/// of the renewal or of the failure. The store decides those, not the clock.
enum PlanClock {
    /// Moves `plan` on to `now`. True when anything changed.
    @discardableResult
    static func advance(_ plan: PlanRow, to now: Date = Date()) -> Bool {
        switch plan.state {
        case "active", "canceled":
            guard !plan.renews, let until = plan.paidUntil, until <= now else { return false }
            end(plan, on: until, reason: "ended")
            return true
        case "grace":
            guard let until = plan.graceUntil, until <= now else { return false }
            plan.state = "billingProblem"
            return true
        default:
            return false
        }
    }

    /// Ends a paid plan: free from here, the ended plan kept for the card.
    /// The store's ID stays, so a later notice still finds the account.
    static func end(_ plan: PlanRow, on endedOn: Date, reason: String) {
        plan.lastTier = plan.tier
        plan.lastEndedOn = endedOn
        plan.lastReason = reason
        plan.tier = Tier.free.rawValue
        plan.period = "none"
        plan.state = "free"
        plan.paidUntil = nil
        plan.renews = false
        plan.nextTier = nil
        plan.graceUntil = nil
    }

    /// A new purchase clears the ended plan from the card.
    static func clearLastPlan(_ plan: PlanRow) {
        plan.lastTier = nil
        plan.lastEndedOn = nil
        plan.lastReason = nil
    }
}

extension PlanRow {
    /// The tier whose limits apply now: the paid tier in active, grace and
    /// canceled, free's in billing problem.
    var limitTier: Tier {
        state == "billingProblem" ? .free : (Tier(rawValue: tier) ?? .free)
    }
}

/// The plan's time fields: the grace end, and the last paid plan.
struct AddPlanTime: AsyncMigration {
    static var fields: [(FieldKey, DatabaseSchema.DataType)] {
        [("grace_until", .datetime), ("last_tier", .string), ("last_ended_on", .datetime), ("last_reason", .string)]
    }

    // One field per change: SQLite adds one column at a time.
    func prepare(on database: any Database) async throws {
        for (key, type) in Self.fields {
            try await database.schema(PlanRow.schema).field(key, type).update()
        }
    }

    func revert(on database: any Database) async throws {
        for (key, _) in Self.fields.reversed() {
            try await database.schema(PlanRow.schema).deleteField(key).update()
        }
    }
}
