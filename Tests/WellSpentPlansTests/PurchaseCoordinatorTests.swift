import Foundation
import Testing
import WellSpentPlans

/// What the fakes saw, in order, so a test can check the server heard about a
/// purchase before the store was told it was done.
private final class Log: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []
    func add(_ line: String) { lock.withLock { lines.append(line) } }
    var all: [String] { lock.withLock { lines } }
}

private final class FakeStore: PlanStore, @unchecked Sendable {
    let log: Log
    var result: PurchaseResult = .cancelled
    var held: [StoreTransaction] = []
    var syncFails = false
    var purchaseFails = false
    var tokens: [UUID] = []
    private var continuation: AsyncStream<StoreTransaction>.Continuation?
    private let stream: AsyncStream<StoreTransaction>

    init(log: Log) {
        self.log = log
        var made: AsyncStream<StoreTransaction>.Continuation?
        stream = AsyncStream { made = $0 }
        continuation = made
    }

    func offers() async throws -> [StoreOffer] {
        PlanProduct.all.map { StoreOffer(product: $0, displayPrice: "$\($0.tier.rawValue)") }
    }

    func purchase(_ product: PlanProduct, accountToken: UUID) async throws -> PurchaseResult {
        log.add("purchase \(product.id)")
        tokens.append(accountToken)
        if purchaseFails { throw CocoaError(.featureUnsupported) }
        return result
    }

    func current() async -> [StoreTransaction] { held }

    func sync() async throws {
        log.add("sync")
        if syncFails { throw CocoaError(.featureUnsupported) }
    }

    func finish(_ transactionID: UInt64) async { log.add("finish \(transactionID)") }

    func updates() -> AsyncStream<StoreTransaction> { stream }

    func send(_ transaction: StoreTransaction) { continuation?.yield(transaction) }
    func end() { continuation?.finish() }

    var country: String? = "USA"
    func storefrontCountry() async -> String? { country }
}

private final class FakeService: PlanService, @unchecked Sendable {
    let log: Log
    var answer: PlanAnswer
    var submitError: PlanServiceError?
    var planError: PlanServiceError?

    init(log: Log, answer: PlanAnswer) {
        self.log = log
        self.answer = answer
    }

    func plan() async throws -> PlanAnswer {
        log.add("plan")
        if let planError { throw planError }
        return answer
    }

    func submitApple(signedTransaction: String) async throws -> PlanAnswer {
        log.add("submit \(signedTransaction)")
        if let submitError { throw submitError }
        return answer
    }
}

private final class FakeLockService: PlanService, PlanLockService, @unchecked Sendable {
    var answer: PlanAnswer
    var refusal: PlanLockError?
    var picks: [PlanPick] = []
    var paid: [UUID] = []

    init(answer: PlanAnswer) { self.answer = answer }

    func plan() async throws -> PlanAnswer { answer }
    func submitApple(signedTransaction: String) async throws -> PlanAnswer { answer }
    func savePick(_ pick: PlanPick) async throws -> PlanAnswer {
        if let refusal { throw refusal }
        picks.append(pick)
        return answer
    }
    func payForGroup(_ groupID: UUID) async throws -> PlanAnswer {
        if let refusal { throw refusal }
        paid.append(groupID)
        return answer
    }
}

private final class MemoryCache: PlanCache, @unchecked Sendable {
    var stored: PlanAnswer?
    var pending: UUID?
    init(_ stored: PlanAnswer? = nil, pending: UUID? = nil) {
        self.stored = stored
        self.pending = pending
    }
    func load() -> PlanAnswer? { stored }
    func save(_ answer: PlanAnswer) { stored = answer }
    func loadPendingGroup() -> UUID? { pending }
    func savePendingGroup(_ id: UUID?) { pending = id }
    func clear() {
        stored = nil
        pending = nil
    }
}

private let token = UUID(uuidString: "6F9619FF-8B86-D011-B42D-00C04FC964FF")!

private func answer(_ tier: PlanTier, token: UUID? = token, source: PlanAnswer.Source? = nil) -> PlanAnswer {
    PlanAnswer(tier: tier, period: tier == .free ? .none : .monthly, state: tier == .free ? .free : .active,
               source: source ?? (tier == .free ? .none : .apple), paidUntil: nil, renews: tier != .free, nextTier: nil,
               limits: .init(properties: tier == .free ? 1 : 5, groups: tier == .free ? 1 : nil,
                             invitedPerGroup: tier == .free ? 1 : nil),
               used: .init(properties: 1, groups: 1, invitedPerGroup: 0),
               extensionsOpen: tier == .free ? [] : ["wellspent.properties", "wellspent.tax"],
               canSyncPriceLabs: tier != .free, refreshMinutes: 60, appleAccountToken: token)
}

/// A paid answer in which `group` is still locked to this person.
private func paid(locking group: UUID) -> PlanAnswer {
    let paid = answer(.starter)
    return PlanAnswer(tier: paid.tier, period: paid.period, state: paid.state, source: .paddle,
                      paidUntil: nil, renews: true, nextTier: nil, limits: paid.limits, used: paid.used,
                      extensionsOpen: paid.extensionsOpen, canSyncPriceLabs: true, refreshMinutes: 60,
                      appleAccountToken: token, locked: .init(groupIDs: [group], people: [], houseIDs: []))
}

private let growthMonthly = StoreTransaction(id: 7, productID: "app.wellspent.pro.growth.monthly", signed: "jws-7")

@MainActor
struct PurchaseCoordinatorTests {
    @Test func aPurchaseReachesTheServerBeforeTheStoreIsToldItIsDone() async {
        let log = Log()
        let store = FakeStore(log: log)
        store.result = .purchased(growthMonthly)
        let service = FakeService(log: log, answer: answer(.growth))
        let coordinator = PurchaseCoordinator(store: store, service: service, cache: MemoryCache(answer(.free)))

        await coordinator.buy(PlanProduct(.growth, .monthly))

        #expect(log.all == ["purchase app.wellspent.pro.growth.monthly", "submit jws-7", "finish 7"])
        #expect(store.tokens == [token])
        #expect(coordinator.answer?.tier == .growth)
        #expect(coordinator.status == .idle)
    }

    @Test func aPurchaseTheServerCannotHearStaysUnfinished() async {
        let log = Log()
        let store = FakeStore(log: log)
        store.result = .purchased(growthMonthly)
        let service = FakeService(log: log, answer: answer(.growth))
        service.submitError = .unreachable
        let coordinator = PurchaseCoordinator(store: store, service: service, cache: MemoryCache(answer(.free)))

        await coordinator.buy(PlanProduct(.growth, .monthly))

        #expect(!log.all.contains("finish 7"))
        #expect(coordinator.answer?.tier == .free)
        #expect(coordinator.status == .failed(.unreachable))
    }

    @Test(arguments: [(PlanServiceError.paddlePlanLive, PurchaseCoordinator.Failure.paddlePlanLive),
                      (.notGenuine, .notGenuine)])
    func theServerSaysWhyItRefused(_ error: PlanServiceError, _ failure: PurchaseCoordinator.Failure) async {
        let log = Log()
        let store = FakeStore(log: log)
        store.result = .purchased(growthMonthly)
        let service = FakeService(log: log, answer: answer(.growth))
        service.submitError = error
        let coordinator = PurchaseCoordinator(store: store, service: service, cache: MemoryCache(answer(.free)))

        await coordinator.buy(PlanProduct(.growth, .monthly))

        #expect(coordinator.status == .failed(failure))
        #expect(!log.all.contains("finish 7"))
    }

    @Test func someonePayingOnTheWebsiteIsNeverShownApplesSheet() async {
        let log = Log()
        let store = FakeStore(log: log)
        store.result = .purchased(growthMonthly)
        let coordinator = PurchaseCoordinator(store: store, service: FakeService(log: log, answer: answer(.growth)),
                                              cache: MemoryCache(answer(.starter, source: .paddle)))

        await coordinator.buy(PlanProduct(.growth, .monthly))

        #expect(log.all.isEmpty)
        #expect(coordinator.status == .failed(.paddlePlanLive))
    }

    @Test func closingTheSheetSendsNothing() async {
        let log = Log()
        let store = FakeStore(log: log)
        let coordinator = PurchaseCoordinator(store: store, service: FakeService(log: log, answer: answer(.growth)),
                                              cache: MemoryCache(answer(.free)))

        await coordinator.buy(PlanProduct(.starter, .yearly))

        #expect(log.all == ["purchase app.wellspent.pro.starter.yearly"])
        #expect(coordinator.status == .idle)
    }

    @Test func aPurchaseWaitingForApprovalSaysSo() async {
        let log = Log()
        let store = FakeStore(log: log)
        store.result = .pending
        let coordinator = PurchaseCoordinator(store: store, service: FakeService(log: log, answer: answer(.growth)),
                                              cache: MemoryCache(answer(.free)))

        await coordinator.buy(PlanProduct(.starter, .monthly))

        #expect(coordinator.status == .waitingForApproval)
        #expect(coordinator.answer?.tier == .free)
    }

    @Test func aStoreErrorSaysTheStoreFailed() async {
        let log = Log()
        let store = FakeStore(log: log)
        store.purchaseFails = true
        let coordinator = PurchaseCoordinator(store: store, service: FakeService(log: log, answer: answer(.growth)),
                                              cache: MemoryCache(answer(.free)))

        await coordinator.buy(PlanProduct(.starter, .monthly))

        #expect(coordinator.status == .failed(.storeFailed))
    }

    @Test func withNoPlanAnswerYetNothingIsBought() async {
        let log = Log()
        let store = FakeStore(log: log)
        let coordinator = PurchaseCoordinator(store: store, service: FakeService(log: log, answer: answer(.growth)),
                                              cache: MemoryCache())

        await coordinator.buy(PlanProduct(.starter, .monthly))

        #expect(log.all.isEmpty)
        #expect(coordinator.status == .failed(.notReady))
    }

    @Test func withNoStoreBuyingAndRestoringPointToTheWebsite() async {
        let log = Log()
        let coordinator = PurchaseCoordinator(store: nil, service: FakeService(log: log, answer: answer(.free)),
                                              cache: MemoryCache(answer(.free)))

        #expect(!coordinator.canBuyInApp)
        #expect(await coordinator.offers().isEmpty)
        await coordinator.buy(PlanProduct(.starter, .monthly))
        #expect(coordinator.status == .failed(.noStore))
        await coordinator.restore()
        #expect(coordinator.status == .failed(.noStore))
        await coordinator.listen()
        #expect(log.all.isEmpty)
    }

    @Test func restoreHandsTheServerEverySubscriptionHeld() async {
        let log = Log()
        let store = FakeStore(log: log)
        store.held = [growthMonthly]
        let coordinator = PurchaseCoordinator(store: store, service: FakeService(log: log, answer: answer(.growth)),
                                              cache: MemoryCache(answer(.free)))

        await coordinator.restore()

        #expect(log.all == ["sync", "submit jws-7", "finish 7"])
        #expect(coordinator.answer?.tier == .growth)
        #expect(coordinator.status == .idle)
    }

    @Test func restoreWithNothingHeldAsksTheServerAgain() async {
        let log = Log()
        let store = FakeStore(log: log)
        let coordinator = PurchaseCoordinator(store: store, service: FakeService(log: log, answer: answer(.starter)),
                                              cache: MemoryCache(answer(.free)))

        await coordinator.restore()

        #expect(log.all == ["sync", "plan"])
        #expect(coordinator.answer?.tier == .starter)
    }

    @Test func restoreStopsAtTheFirstRefusal() async {
        let log = Log()
        let store = FakeStore(log: log)
        store.held = [growthMonthly, StoreTransaction(id: 8, productID: "app.wellspent.pro.starter.yearly", signed: "jws-8")]
        let service = FakeService(log: log, answer: answer(.growth))
        service.submitError = .notGenuine
        let coordinator = PurchaseCoordinator(store: store, service: service, cache: MemoryCache(answer(.free)))

        await coordinator.restore()

        #expect(log.all == ["sync", "submit jws-7"])
        #expect(coordinator.status == .failed(.notGenuine))
    }

    @Test func aStoreThatCannotSyncSaysTheStoreFailed() async {
        let log = Log()
        let store = FakeStore(log: log)
        store.syncFails = true
        let coordinator = PurchaseCoordinator(store: store, service: FakeService(log: log, answer: answer(.growth)),
                                              cache: MemoryCache(answer(.free)))

        await coordinator.restore()

        #expect(coordinator.status == .failed(.storeFailed))
    }

    @Test func aPurchaseFromAnotherDeviceIsHandedOnWhileTheAppRuns() async {
        let log = Log()
        let store = FakeStore(log: log)
        let coordinator = PurchaseCoordinator(store: store, service: FakeService(log: log, answer: answer(.growth)),
                                              cache: MemoryCache(answer(.free)))

        store.send(growthMonthly)
        store.end()
        await coordinator.listen()

        #expect(log.all == ["submit jws-7", "finish 7"])
        #expect(coordinator.answer?.tier == .growth)
    }

    @Test func offlineTheLastAnswerStays() async {
        let log = Log()
        let service = FakeService(log: log, answer: answer(.growth))
        service.planError = .unreachable
        let cache = MemoryCache(answer(.starter))
        let coordinator = PurchaseCoordinator(store: FakeStore(log: log), service: service, cache: cache)

        await coordinator.refresh()

        #expect(coordinator.answer?.tier == .starter)
    }

    @Test func aNewAnswerIsKeptForNextTime() async {
        let log = Log()
        let cache = MemoryCache()
        let coordinator = PurchaseCoordinator(store: FakeStore(log: log),
                                              service: FakeService(log: log, answer: answer(.portfolio)), cache: cache)

        await coordinator.refresh()

        #expect(cache.stored?.tier == .portfolio)
        #expect(await coordinator.offers().count == 6)
    }

    @Test func signingOutForgetsThePlan() async {
        let log = Log()
        let cache = MemoryCache(answer(.growth))
        let coordinator = PurchaseCoordinator(store: FakeStore(log: log),
                                              service: FakeService(log: log, answer: answer(.growth)), cache: cache)
        #expect(coordinator.answer?.tier == .growth)

        coordinator.forget()

        #expect(coordinator.answer == nil)
        #expect(cache.stored == nil)
        #expect(coordinator.status == .idle)
    }
}

@MainActor
struct PlanLockCallTests {
    @Test func aSavedPickTakesTheServersAnswer() async throws {
        let cache = MemoryCache(answer(.free))
        let service = FakeLockService(answer: answer(.growth))
        let plans = PurchaseCoordinator(store: nil, service: service, cache: cache)
        let pick = PlanPick(groupID: UUID(), person: nil, houseIDs: [UUID()])
        try await plans.save(pick)
        #expect(service.picks == [pick])
        #expect(plans.answer?.tier == .growth)
        #expect(cache.stored?.tier == .growth)
    }

    @Test func aRefusedPickKeepsTheLastAnswerAndSaysWhy() async {
        let service = FakeLockService(answer: answer(.growth))
        service.refusal = .pickTooSoon
        let plans = PurchaseCoordinator(store: nil, service: service, cache: MemoryCache(answer(.free)))
        await #expect(throws: PlanLockError.pickTooSoon) {
            try await plans.save(PlanPick(groupID: UUID(), person: nil, houseIDs: []))
        }
        #expect(plans.answer?.tier == .free)
    }

    @Test func payingForAGroupTakesTheServersAnswer() async throws {
        let service = FakeLockService(answer: answer(.starter))
        let plans = PurchaseCoordinator(store: nil, service: service, cache: MemoryCache())
        let group = UUID()
        try await plans.payFor(group: group)
        #expect(service.paid == [group])
        #expect(plans.answer?.tier == .starter)
    }

    @Test func aServerWithoutLockCallsCantBeReached() async {
        let plans = PurchaseCoordinator(store: nil, service: FakeService(log: Log(), answer: answer(.free)),
                                        cache: MemoryCache())
        await #expect(throws: PlanLockError.unreachable) { try await plans.payFor(group: UUID()) }
    }
}

@MainActor
struct StorefrontTests {
    /// "Email us" past 15 properties shows in the app only on the US store.
    @Test func onlyTheUSStoreCountsAsUS() async {
        let store = FakeStore(log: Log())
        let plans = PurchaseCoordinator(store: store, service: FakeService(log: Log(), answer: answer(.free)),
                                        cache: MemoryCache())
        #expect(await plans.storefrontIsUS())
        store.country = "CAN"
        #expect(await !plans.storefrontIsUS())
        store.country = nil
        #expect(await !plans.storefrontIsUS())
        let none = PurchaseCoordinator(store: nil, service: FakeService(log: Log(), answer: answer(.free)),
                                       cache: MemoryCache())
        #expect(await !none.storefrontIsUS())
    }
}

private func locking(_ tier: PlanTier = .free, groups: [UUID] = [], people: [PlanAnswer.Person] = [],
                     houses: [UUID] = []) -> PlanAnswer {
    let base = answer(tier)
    let locked = groups.isEmpty && people.isEmpty && houses.isEmpty
        ? nil : PlanAnswer.Locked(groupIDs: groups, people: people, houseIDs: houses)
    return PlanAnswer(tier: base.tier, period: base.period, state: base.state, source: base.source,
                      paidUntil: nil, renews: base.renews, nextTier: nil, limits: base.limits, used: base.used,
                      extensionsOpen: [], canSyncPriceLabs: false, refreshMinutes: 60, appleAccountToken: token,
                      locked: locked)
}

/// Pulls leave out what's locked, behind the device's cursor. So when a new
/// answer opens any of it, the app reads its groups again from the start.
struct LocksLessTests {
    @Test func openingAnythingLockedCounts() {
        let group = UUID(), house = UUID(), person = PlanAnswer.Person(groupID: UUID(), userID: UUID())
        let before = locking(groups: [group], people: [person], houses: [house])
        #expect(locking().locksLess(than: before), "nothing locked now")
        #expect(locking(people: [person], houses: [house]).locksLess(than: before), "the group opened")
        #expect(locking(groups: [group], houses: [house]).locksLess(than: before), "the person opened")
        #expect(locking(groups: [group], people: [person]).locksLess(than: before), "the house opened")
        #expect(locking(.growth).locksLess(than: locking(.free)), "a bigger plan")
    }

    @Test func lockingTheSameOrMoreDoesNot() {
        let group = UUID(), house = UUID()
        let before = locking(groups: [group])
        #expect(!locking(groups: [group]).locksLess(than: before))
        #expect(!locking(groups: [group], houses: [house]).locksLess(than: before))
        #expect(!locking().locksLess(than: locking()), "nothing was locked")
        #expect(!locking(.free).locksLess(than: locking(.growth)), "a smaller plan opens nothing")
        #expect(!locking().locksLess(than: nil), "a first answer has nothing to compare")
    }

    @MainActor
    @Test func theCoordinatorSaysWhenAnAnswerOpensSomething() async {
        let service = FakeService(log: Log(), answer: locking(groups: [UUID()]))
        let plans = PurchaseCoordinator(store: nil, service: service, cache: MemoryCache())
        var opened = 0
        plans.didOpen = { opened += 1 }
        await plans.refresh()
        #expect(opened == 0, "the first answer opens nothing")
        await plans.refresh()
        #expect(opened == 0, "the same answer opens nothing")
        service.answer = locking()
        await plans.refresh()
        #expect(opened == 1)
    }
}

/// Pay for This Group when the purchase happens outside the app, as on the
/// website: the group waits, and the next answer with a paid plan takes it over.
@MainActor
struct PendingGroupPayTests {
    @Test func aGroupToPayForIsRememberedForThisAccount() {
        let cache = MemoryCache(answer(.free))
        let plans = PurchaseCoordinator(store: nil, service: FakeLockService(answer: answer(.free)), cache: cache)
        let group = UUID()
        plans.payForGroupLater(group)
        #expect(plans.pendingGroup == group)
        #expect(cache.pending == group)
        #expect(PurchaseCoordinator(store: nil, service: FakeLockService(answer: answer(.free)),
                                    cache: cache).pendingGroup == group)
    }

    @Test func theNextPaidAnswerTakesOverTheGroup() async {
        let group = UUID()
        let cache = MemoryCache(answer(.free), pending: group)
        let service = FakeLockService(answer: paid(locking: group))
        let plans = PurchaseCoordinator(store: nil, service: service, cache: cache)
        await plans.refresh()
        #expect(service.paid == [group])
        #expect(plans.pendingGroup == nil)
        #expect(cache.pending == nil)
    }

    @Test func onTheFreePlanItWaitsWithoutAsking() async {
        let group = UUID()
        let free = answer(.free)
        let lockedOnFree = PlanAnswer(tier: free.tier, period: free.period, state: free.state, source: free.source,
                                      paidUntil: nil, renews: false, nextTier: nil, limits: free.limits,
                                      used: free.used, extensionsOpen: [], canSyncPriceLabs: false,
                                      refreshMinutes: 60, appleAccountToken: token,
                                      locked: .init(groupIDs: [group], people: [], houseIDs: []))
        let service = FakeLockService(answer: lockedOnFree)
        let plans = PurchaseCoordinator(store: nil, service: service, cache: MemoryCache(pending: group))
        await plans.refresh()
        #expect(service.paid.isEmpty)
        #expect(plans.pendingGroup == group)
    }

    @Test func aPlanThatDoesNotCoverItYetKeepsItForNextTime() async {
        let group = UUID()
        let service = FakeLockService(answer: paid(locking: group))
        service.refusal = .planDoesNotCover
        let plans = PurchaseCoordinator(store: nil, service: service, cache: MemoryCache(pending: group))
        await plans.refresh()
        #expect(plans.pendingGroup == group)
    }

    @Test(arguments: [PlanLockError.groupGone, .notYours])
    func aGroupThatIsGoneOrNotTheirsIsForgotten(_ refusal: PlanLockError) async {
        let group = UUID()
        let service = FakeLockService(answer: paid(locking: group))
        service.refusal = refusal
        let plans = PurchaseCoordinator(store: nil, service: service, cache: MemoryCache(pending: group))
        await plans.refresh()
        #expect(plans.pendingGroup == nil)
    }

    @Test func offlineItWaits() async {
        let group = UUID()
        let service = FakeLockService(answer: paid(locking: group))
        service.refusal = .unreachable
        let plans = PurchaseCoordinator(store: nil, service: service, cache: MemoryCache(pending: group))
        await plans.refresh()
        #expect(plans.pendingGroup == group)
    }

    @Test func aGroupNoLongerLockedIsForgottenWithoutPaying() async {
        let group = UUID()
        let service = FakeLockService(answer: answer(.starter))
        let plans = PurchaseCoordinator(store: nil, service: service, cache: MemoryCache(pending: group))
        await plans.refresh()
        #expect(service.paid.isEmpty)
        #expect(plans.pendingGroup == nil)
    }

    @Test func signingOutForgetsIt() {
        let cache = MemoryCache(answer(.free), pending: UUID())
        let plans = PurchaseCoordinator(store: nil, service: FakeLockService(answer: answer(.free)), cache: cache)
        plans.forget()
        #expect(plans.pendingGroup == nil)
        #expect(cache.pending == nil)
    }

    @Test func theDefaultsCacheKeepsItUntilCleared() throws {
        let defaults = try #require(UserDefaults(suiteName: "pending-\(UUID())"))
        let group = UUID()
        DefaultsPlanCache(defaults: defaults).savePendingGroup(group)
        #expect(DefaultsPlanCache(defaults: defaults).loadPendingGroup() == group)
        DefaultsPlanCache(defaults: defaults).clear()
        #expect(DefaultsPlanCache(defaults: defaults).loadPendingGroup() == nil)
    }
}
