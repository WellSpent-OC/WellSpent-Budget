import Testing
import Foundation
import Fluent
import Vapor
import VaporTesting
@testable import WellSpentServerCore

private struct Last: Content { let tier: String; let endedOn: Date; let reason: String }
private struct Limits: Content { let properties: Int? }
private struct Answer: Content {
    let tier: String; let state: String; let limits: Limits; let graceUntil: Date?; let lastPlan: Last?
}

private func ask(_ session: V2Session, on app: Application) async throws -> Answer {
    var answer: Answer?
    try await app.testing().test(.GET, "api/v2/plan", headers: v2Bearer(session.token), afterResponse: { response async throws in
        #expect(response.status == .ok)
        answer = try response.content.decode(Answer.self)
    })
    return try #require(answer)
}

/// Puts `session`'s account on a paid plan in `state`.
private func pay(_ session: V2Session, state: String, renews: Bool, paidUntil: Date?, graceUntil: Date? = nil,
                 on app: Application) async throws {
    let plan = try await PlanRow.forUser(session.userID, on: app.db)
    plan.tier = "growth"; plan.period = "monthly"; plan.source = "apple"; plan.state = state
    plan.renews = renews; plan.paidUntil = paidUntil; plan.graceUntil = graceUntil
    try await plan.save(on: app.db)
}

@Suite("When paid time runs out", .serialized) struct PlanTimeTests {
    @Test("A canceled plan keeps its paid limits to the end of its paid time")
    func canceledKeepsPaidLimitsUntilItsEnd() async throws {
        try await withV2App { app, _ in
            app.plansEnabled = true
            let me = try await v2SignUp("time-canceled@example.com", on: app)
            try await pay(me, state: "canceled", renews: false, paidUntil: Date().addingTimeInterval(86_400), on: app)
            let answer = try await ask(me, on: app)
            #expect(answer.tier == "growth" && answer.state == "canceled" && answer.limits.properties == 5)
            #expect(answer.lastPlan == nil)
        }
    }

    @Test("Once its paid time ends, a plan that won't renew is free, and the card keeps the plan that ended")
    func aCanceledPlanEnds() async throws {
        try await withV2App { app, _ in
            app.plansEnabled = true
            let me = try await v2SignUp("time-ended@example.com", on: app)
            let ended = Date().addingTimeInterval(-3_600)
            try await pay(me, state: "canceled", renews: false, paidUntil: ended, on: app)
            let answer = try await ask(me, on: app)
            #expect(answer.tier == "free" && answer.state == "free" && answer.limits.properties == 1)
            #expect(answer.lastPlan?.tier == "growth" && answer.lastPlan?.reason == "ended")
            #expect(abs((answer.lastPlan?.endedOn ?? .distantPast).timeIntervalSince(ended)) < 1)
            // Saved: the next read doesn't end it again.
            let plan = try await PlanRow.forUser(me.userID, on: app.db)
            #expect(plan.tier == "free" && plan.lastTier == "growth" && plan.paidUntil == nil)
        }
    }

    @Test("A plan that renews waits for the store's word, even past its paid time")
    func aRenewingPlanWaitsForTheStore() async throws {
        try await withV2App { app, _ in
            app.plansEnabled = true
            let me = try await v2SignUp("time-renews@example.com", on: app)
            try await pay(me, state: "active", renews: true, paidUntil: Date().addingTimeInterval(-3_600), on: app)
            let answer = try await ask(me, on: app)
            #expect(answer.tier == "growth" && answer.state == "active" && answer.lastPlan == nil)
        }
    }

    @Test("Through the grace period a failed payment keeps the paid limits, and the answer says when they lock")
    func graceKeepsPaidLimits() async throws {
        try await withV2App { app, _ in
            app.plansEnabled = true
            let me = try await v2SignUp("time-grace@example.com", on: app)
            let until = Date().addingTimeInterval(86_400 * 10)
            try await pay(me, state: "grace", renews: true, paidUntil: Date().addingTimeInterval(-86_400 * 6),
                          graceUntil: until, on: app)
            let answer = try await ask(me, on: app)
            #expect(answer.state == "grace" && answer.limits.properties == 5)
            #expect(abs((answer.graceUntil ?? .distantPast).timeIntervalSince(until)) < 1)
        }
    }

    @Test("After the grace period, extras lock: free's limits, while the paid tier stays named")
    func afterGraceExtrasLock() async throws {
        try await withV2App { app, _ in
            app.plansEnabled = true
            let me = try await v2SignUp("time-retry@example.com", on: app)
            try await pay(me, state: "grace", renews: true, paidUntil: Date().addingTimeInterval(-86_400 * 17),
                          graceUntil: Date().addingTimeInterval(-60), on: app)
            let answer = try await ask(me, on: app)
            #expect(answer.tier == "growth" && answer.state == "billingProblem")
            #expect(answer.limits.properties == 1 && answer.graceUntil == nil)
        }
    }

    @Test("The clock leaves free and active plans alone")
    func theClockLeavesOthersAlone() {
        let free = PlanRow(userID: UUID())
        #expect(!PlanClock.advance(free))
        let active = PlanRow(userID: UUID())
        active.tier = "starter"; active.state = "active"; active.renews = true
        active.paidUntil = Date().addingTimeInterval(86_400)
        #expect(!PlanClock.advance(active) && active.tier == "starter")
    }
}
