#if canImport(StoreKit)
import Foundation
import StoreKit

/// Apple's App Store, through StoreKit 2, on the Mac and iPhone.
///
/// It sends the server every purchase Apple reports, checked or not: the
/// server checks Apple's signature itself, so the app never decides whether a
/// purchase is genuine.
public actor AppleStore: PlanStore {
    /// Purchases handed out and not yet finished, so `finish` can find them.
    private var unfinished: [UInt64: Transaction] = [:]

    public init() {}

    public func offers() async throws -> [StoreOffer] {
        let products = try await Product.products(for: PlanProduct.all.map(\.id))
        return PlanProduct.all.compactMap { plan in
            products.first { $0.id == plan.id }.map { StoreOffer(product: plan, displayPrice: $0.displayPrice) }
        }
    }

    public func purchase(_ product: PlanProduct, accountToken: UUID) async throws -> PurchaseResult {
        guard let found = try await Product.products(for: [product.id]).first else { return .cancelled }
        switch try await found.purchase(options: [.appAccountToken(accountToken)]) {
        case .success(let result): return .purchased(keep(result))
        case .pending: return .pending
        case .userCancelled: return .cancelled
        @unknown default: return .cancelled
        }
    }

    public func current() async -> [StoreTransaction] {
        var held: [StoreTransaction] = []
        for await result in Transaction.currentEntitlements where PlanProduct(id: result.unsafePayloadValue.productID) != nil {
            held.append(keep(result))
        }
        return held
    }

    public func sync() async throws {
        try await AppStore.sync()
    }

    public func finish(_ transactionID: UInt64) async {
        await unfinished.removeValue(forKey: transactionID)?.finish()
    }

    public nonisolated func updates() -> AsyncStream<StoreTransaction> {
        AsyncStream { continuation in
            let task = Task {
                for await result in Transaction.updates where PlanProduct(id: result.unsafePayloadValue.productID) != nil {
                    continuation.yield(await self.keep(result))
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    public func storefrontCountry() async -> String? {
        await Storefront.current?.countryCode
    }

    private func keep(_ result: VerificationResult<Transaction>) -> StoreTransaction {
        let transaction = result.unsafePayloadValue
        unfinished[transaction.id] = transaction
        return StoreTransaction(id: transaction.id, productID: transaction.productID, signed: result.jwsRepresentation)
    }
}
#endif
