import Foundation
import Crypto
import WellSpentCrypto
import WellSpentStore

/// Every key this device can currently use, and how it got them.
///
/// Group keys arrive sealed to the identity key. Budget keys arrive sealed under
/// their group key. Unwrapping is done once and cached in the local database,
/// because doing HPKE for every budget on every launch is a visible pause.
///
/// Every epoch is kept forever. Records written before a rotation stay readable
/// only because the old key is still here, so a cleanup job that prunes old epochs
/// is a data-loss bug with a six month fuse.
public final class KeyRing: @unchecked Sendable {
    private let store: Store
    private let identity: IdentityKeyPair
    private let userID: UserID
    private let lock = NSLock()
    private var cache: [CacheKey: ScopedKey] = [:]

    private struct CacheKey: Hashable {
        let scope: KeyScope
        let epoch: Epoch
    }

    public init(store: Store, identity: IdentityKeyPair, userID: UserID) {
        self.store = store
        self.identity = identity
        self.userID = userID
    }

    public func key(for scope: KeyScope, epoch: Epoch) throws -> ScopedKey {
        let cacheKey = CacheKey(scope: scope, epoch: epoch)
        lock.lock()
        let hit = cache[cacheKey]
        lock.unlock()
        if let hit { return hit }
        if let stored = try store.cachedKey(scope: scope, epoch: epoch) {
            lock.lock()
            cache[cacheKey] = stored
            lock.unlock()
            return stored
        }
        throw SyncError.noKeyForEpoch(epoch)
    }

    public func has(scope: KeyScope, epoch: Epoch) -> Bool {
        lock.lock()
        let cached = cache[CacheKey(scope: scope, epoch: epoch)] != nil
        lock.unlock()
        return cached || ((try? store.cachedKey(scope: scope, epoch: epoch)) ?? nil) != nil
    }

    public func remember(_ key: ScopedKey) throws {
        lock.lock()
        cache[CacheKey(scope: key.scope, epoch: key.epoch)] = key
        lock.unlock()
        try store.cache(key)
    }

    /// Unwrap whatever the server is holding for us.
    ///
    /// Group keys first, because budget keys are sealed under them. A wrap we
    /// cannot open is skipped rather than fatal: it may be for an epoch we have no
    /// business reading, which is exactly what `.fromNow` history access produces.
    @discardableResult
    public func absorb(_ wrapped: [WrappedKey], senders: [UserID: IdentityPublicKeys]) throws -> Int {
        var opened = 0

        let groupWraps = wrapped.filter { $0.wrapKind == .hpkeToIdentity }
        for wrap in groupWraps {
            guard wrap.recipientUserID == userID else { continue }
            guard let senderKeys = senders[wrap.senderUserID] else { continue }
            guard let key = try? KeyWrap.unwrapToIdentity(wrap, recipient: identity, sender: senderKeys) else {
                continue
            }
            try remember(key)
            opened += 1
        }

        let budgetWraps = wrapped.filter { $0.wrapKind == .aesUnderGroupKey }
        for wrap in budgetWraps {
            // Try every group key we hold. There are at most a handful.
            lock.lock()
            let groupKeys = cache.values.filter { $0.scope.isGroup }
            lock.unlock()
            for candidate in groupKeys {
                if let key = try? KeyWrap.unwrapUnderGroupKey(wrap, groupKey: candidate.material) {
                    try remember(key)
                    opened += 1
                    break
                }
            }
        }

        return opened
    }

    /// Generate a fresh group key and every budget key under it, then seal them for
    /// each member. This is what removal triggers.
    public func rotate(group: GroupID, budgets: [BudgetID], to epoch: Epoch,
                       members: [(userID: UserID, keys: IdentityPublicKeys)]) throws -> [WrappedKey] {
        let groupKey = ScopedKey.generate(scope: .group(group), epoch: epoch)
        try remember(groupKey)

        var wrapped: [WrappedKey] = []
        for member in members {
            wrapped.append(try KeyWrap.wrapToIdentity(
                groupKey, recipient: member.keys, recipientUserID: member.userID,
                sender: identity, senderUserID: userID))
        }

        for budget in budgets {
            let budgetKey = ScopedKey.generate(scope: .budget(budget), epoch: epoch)
            try remember(budgetKey)
            wrapped.append(try KeyWrap.wrapUnderGroupKey(
                budgetKey, groupKey: groupKey.material, senderUserID: userID))
        }

        return wrapped
    }
}

extension KeyScope {
    var isGroup: Bool {
        if case .group = self { return true }
        return false
    }
}
