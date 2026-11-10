import Foundation
import Observation

/// Buying, restoring and showing a plan, the same on every platform. The store
/// sells, the server decides, and this only passes one to the other.
///
/// The rule that matters: a purchase is finished with the store only after the
/// server has accepted it. Until then the store keeps it and offers it again
/// through `updates()`, so a purchase made while the server can't be reached
/// is never lost.
@MainActor
@Observable
public final class PurchaseCoordinator {
    public enum Status: Equatable, Sendable {
        case idle
        case working
        /// The purchase waits for someone else's approval.
        case waitingForApproval
        case failed(Failure)
    }

    public enum Failure: Equatable, Sendable {
        /// This platform has no store. Buying is on the website.
        case noStore
        /// No plan answer yet, so no account token to buy with.
        case notReady
        case paddlePlanLive
        case notGenuine
        case unreachable
        case storeFailed
    }

    /// Told when a new answer opens something the last one locked, so the
    /// app reads its groups again from the start.
    @ObservationIgnored public var didOpen: (@MainActor () -> Void)?

    /// The server's last answer, from this run or a cached one.
    public private(set) var answer: PlanAnswer?
    public private(set) var status: Status = .idle
    /// A locked group this person chose to pay for, while their plan makes
    /// its way to the server.
    public private(set) var pendingGroup: UUID?

    private let store: (any PlanStore)?
    private let service: any PlanService
    private let cache: any PlanCache

    public init(store: (any PlanStore)?, service: any PlanService, cache: any PlanCache) {
        self.store = store
        self.service = service
        self.cache = cache
        answer = cache.load()
        pendingGroup = cache.loadPendingGroup()
    }

    /// Whether this platform can buy in the app.
    public var canBuyInApp: Bool { store != nil }

    /// Asks the server again. With no answer, the last one stays.
    public func refresh() async {
        do {
            accept(try await service.plan())
        } catch {
            // Offline or refused: keep showing the last answer.
            return
        }
        await payForPendingGroup()
    }

    /// Keep These Open, or Skip: saves what stays open on the free plan. The
    /// server's answer, with its new open and locked, replaces the last one.
    /// Throws `PlanLockError` when the server refuses.
    public func save(_ pick: PlanPick) async throws {
        accept(try await lockService().savePick(pick))
    }

    /// Pay for This Group: once this person's own plan is live, they take
    /// over paying for a locked group.
    public func payFor(group id: UUID) async throws {
        accept(try await lockService().payForGroup(id))
    }

    /// Pay for This Group when the purchase happens outside the app, as on
    /// the website: the group waits, and the next answer with a paid plan
    /// takes it over (`payForPendingGroup`). Kept for this account only.
    public func payForGroupLater(_ id: UUID) {
        pendingGroup = id
        cache.savePendingGroup(id)
    }

    /// Takes over the waiting group once the plan is paid. Forgets it when it
    /// opened, is gone, or isn't theirs. A plan that doesn't cover it yet,
    /// or no answer, keeps it for the next refresh.
    private func payForPendingGroup() async {
        guard let group = pendingGroup, let answer else { return }
        guard answer.locked?.groupIDs.contains(group) == true else { return forgetPendingGroup() }
        guard answer.tier != .free else { return }
        do {
            try await payFor(group: group)
            forgetPendingGroup()
        } catch PlanLockError.groupGone, PlanLockError.notYours {
            forgetPendingGroup()
        } catch {
            // Not paid yet, or unreachable: ask again next time.
        }
    }

    private func forgetPendingGroup() {
        pendingGroup = nil
        cache.savePendingGroup(nil)
    }

    private func lockService() throws -> any PlanLockService {
        guard let locks = service as? any PlanLockService else { throw PlanLockError.unreachable }
        return locks
    }

    /// Signed out: the last account's plan is no one's now.
    public func forget() {
        answer = nil
        pendingGroup = nil
        status = .idle
        cache.clear()
    }

    /// The store's offers, empty when there is no store or it can't answer.
    public func offers() async -> [StoreOffer] {
        guard let store else { return [] }
        return (try? await store.offers()) ?? []
    }

    /// Buys a product, then hands the purchase to the server.
    public func buy(_ product: PlanProduct) async {
        guard let store else { return status = .failed(.noStore) }
        guard let token = answer?.appleAccountToken else { return status = .failed(.notReady) }
        // A plan bought on the website changes on the website. Apple would
        // charge first and the server refuse after, so the person paid twice.
        guard answer?.source != .paddle else { return status = .failed(.paddlePlanLive) }
        status = .working
        do {
            switch try await store.purchase(product, accountToken: token) {
            case .purchased(let transaction): await hand(transaction)
            case .pending: status = .waitingForApproval
            case .cancelled: status = .idle
            }
        } catch {
            status = .failed(.storeFailed)
        }
    }

    /// Restore Purchases: brings the store up to date, then hands the server
    /// every subscription this store account holds.
    public func restore() async {
        guard let store else { return status = .failed(.noStore) }
        status = .working
        do {
            try await store.sync()
        } catch {
            return status = .failed(.storeFailed)
        }
        let held = await store.current()
        for transaction in held {
            await hand(transaction)
            if case .failed = status { return }
        }
        if held.isEmpty { await refresh() }
        status = .idle
    }

    /// Hands each purchase the store reports while the app runs to the server.
    /// Start once at launch; it runs until the task is cancelled.
    public func listen() async {
        guard let store else { return }
        for await transaction in store.updates() {
            await hand(transaction)
        }
    }

    private func hand(_ transaction: StoreTransaction) async {
        do {
            accept(try await service.submitApple(signedTransaction: transaction.signed))
            await store?.finish(transaction.id)
            status = .idle
            await payForPendingGroup()
        } catch let error as PlanServiceError {
            status = .failed(Self.failure(for: error))
        } catch {
            status = .failed(.unreachable)
        }
    }

    private func accept(_ new: PlanAnswer) {
        let opened = new.locksLess(than: answer)
        answer = new
        cache.save(new)
        if opened { didOpen?() }
    }

    private static func failure(for error: PlanServiceError) -> Failure {
        switch error {
        case .paddlePlanLive: .paddlePlanLive
        case .notGenuine: .notGenuine
        case .unreachable: .unreachable
        }
    }
}
