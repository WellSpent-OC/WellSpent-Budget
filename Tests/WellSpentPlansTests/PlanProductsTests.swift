import Foundation
import Testing
import WellSpentPlans

struct PlanProductsTests {
    @Test func theSixProductIDsAreTheOnesInAppStoreConnect() {
        #expect(PlanProduct.all.map(\.id) == [
            "app.wellspent.pro.starter.monthly", "app.wellspent.pro.starter.yearly",
            "app.wellspent.pro.growth.monthly", "app.wellspent.pro.growth.yearly",
            "app.wellspent.pro.portfolio.monthly", "app.wellspent.pro.portfolio.yearly",
        ])
    }

    @Test func anIDReadsBackAsItsProduct() {
        for product in PlanProduct.all {
            #expect(PlanProduct(id: product.id) == product)
        }
        #expect(PlanProduct(id: "com.wellspent.starter.monthly") == nil)
        #expect(PlanProduct(id: "app.wellspent.pro.free.monthly") == nil)
    }

    @Test func eachPaidTierIsAPlanTier() {
        #expect(PaidTier.allCases.map(\.tier) == [.starter, .growth, .portfolio])
    }
}

struct PlanAnswerTests {
    @Test func theServersAnswerReads() throws {
        let json = """
        {"tier": "growth", "period": "yearly", "state": "billingProblem", "source": "apple",
         "paidUntil": "2026-12-09T17:00:00Z", "renews": true, "nextTier": "starter",
         "limits": {"properties": 5, "groups": null, "invitedPerGroup": null},
         "used": {"properties": 3, "groups": 2, "invitedPerGroup": 4},
         "extensionsOpen": ["wellspent.properties", "wellspent.tax"], "canSyncPriceLabs": true,
         "refreshMinutes": 60, "appleAccountToken": "6F9619FF-8B86-D011-B42D-00C04FC964FF",
         "graceUntil": "2026-12-25T17:00:00Z",
         "lastPlan": {"tier": "starter", "endedOn": "2026-10-09T17:00:00Z", "reason": "refunded"},
         "locked": {"groupIDs": ["6F9619FF-8B86-D011-B42D-00C04FC964F1"],
                    "people": [{"groupID": "6F9619FF-8B86-D011-B42D-00C04FC964F1", "userID": "6F9619FF-8B86-D011-B42D-00C04FC964F2"}],
                    "houseIDs": []},
         "open": {"groupID": null, "person": null, "houseIDs": ["6F9619FF-8B86-D011-B42D-00C04FC964F3"]}}
        """
        let answer = try PlanAnswer.decode(Data(json.utf8))
        #expect(answer.graceUntil == Date(timeIntervalSince1970: 1_798_218_000))
        #expect(answer.lastPlan?.reason == .refunded && answer.lastPlan?.tier == .starter)
        #expect(answer.locked?.people.first?.userID == UUID(uuidString: "6F9619FF-8B86-D011-B42D-00C04FC964F2"))
        #expect(answer.open?.groupID == nil && answer.open?.houseIDs.count == 1)

        #expect(answer.tier == .growth)
        #expect(answer.period == .yearly)
        #expect(answer.state == .billingProblem)
        #expect(answer.source == .apple)
        #expect(answer.paidUntil == Date(timeIntervalSince1970: 1_796_835_600))
        #expect(answer.nextTier == .starter)
        #expect(answer.limits == .init(properties: 5, groups: nil, invitedPerGroup: nil))
        #expect(answer.used.invitedPerGroup == 4)
        #expect(answer.extensionsOpen == ["wellspent.properties", "wellspent.tax"])
        #expect(answer.canSyncPriceLabs)
        #expect(answer.appleAccountToken == UUID(uuidString: "6F9619FF-8B86-D011-B42D-00C04FC964FF"))
    }

    @Test func aFreeAnswerReads() throws {
        let json = """
        {"tier": "free", "period": "none", "state": "free", "source": "none", "paidUntil": null,
         "renews": false, "nextTier": null, "limits": {"properties": 1, "groups": 1, "invitedPerGroup": 1},
         "used": {"properties": 0, "groups": 1, "invitedPerGroup": 0}, "extensionsOpen": [],
         "canSyncPriceLabs": false, "refreshMinutes": 60, "appleAccountToken": null}
        """
        let answer = try PlanAnswer.decode(Data(json.utf8))

        #expect(answer.tier == .free)
        #expect(answer.paidUntil == nil)
        #expect(answer.appleAccountToken == nil)
        #expect(answer.limits.groups == 1)
        // Before the server sends them, the newer fields read as nil.
        #expect(answer.graceUntil == nil && answer.lastPlan == nil && answer.locked == nil && answer.open == nil)
    }

    @Test func theCacheKeepsAnAnswerAcrossLaunches() throws {
        let defaults = try #require(UserDefaults(suiteName: "plans-test-\(UUID())"))
        let cache = DefaultsPlanCache(defaults: defaults)
        #expect(cache.load() == nil)

        let answer = PlanAnswer(tier: .starter, period: .monthly, state: .canceled, source: .apple,
                                paidUntil: Date(timeIntervalSince1970: 1_796_835_600), renews: false, nextTier: nil,
                                limits: .init(properties: 2, groups: nil, invitedPerGroup: nil),
                                used: .init(properties: 2, groups: 3, invitedPerGroup: 2),
                                extensionsOpen: ["wellspent.properties"], canSyncPriceLabs: true,
                                refreshMinutes: 60, appleAccountToken: UUID())
        cache.save(answer)

        #expect(DefaultsPlanCache(defaults: defaults).load() == answer)
    }
}
