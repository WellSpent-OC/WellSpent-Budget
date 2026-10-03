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

    /// Unwrap whatever the server is holding for us in `group`.
    ///
    /// Group keys first, because budget keys are sealed under them. A wrap we
    /// cannot open is skipped rather than fatal: it may be for an epoch we have no
    /// business reading, which is exactly what `.fromNow` history access produces.
    ///
    /// A key this Mac takes in replaces what it reads and seals with, so not
    /// every wrap is taken:
    ///
    /// - A group key must be this group's, sealed to this person by someone
    ///   who may manage the group. Only a manager adds people or starts a new
    ///   epoch, and the seal proves who sent it.
    /// - A budget key is opened only with this group's key for the same epoch,
    ///   and never for a budget this Mac holds in another group. Opened with
    ///   any group key it held, a key published in one group replaced the key
    ///   for another group's budget.
    /// - A key this Mac already holds is never replaced. Whichever wrap came
    ///   last used to win, so any member could swap in a key of her own, and
    ///   every record sealed with the real one stopped opening.
    /// - Nothing is taken for an epoch beyond the log's, as the server refuses
    ///   to store one.
    ///
    /// `membership` must be the history this Mac has verified: the log it
    /// holds plus what extends it. A log the server hands over whole can be
    /// made up, and a key taken on its word would be kept for good.
    @discardableResult
    public func absorb(_ wrapped: [WrappedKey], in group: GroupID,
                       membership: MembershipState) throws -> Int {
        var opened = 0

        // Nothing for an epoch the log has not reached. Held early, a key
        // would win over the real one when that epoch starts. It is fetched
        // again once the log gets there.
        for wrap in wrapped where wrap.wrapKind == .hpkeToIdentity && wrap.epoch <= membership.epoch {
            guard wrap.scope == .group(group), wrap.recipientUserID == userID,
                  membership.allows(wrap.senderUserID, .manage),
                  let senderKeys = membership.keys[wrap.senderUserID],
                  !has(scope: wrap.scope, epoch: wrap.epoch),
                  let key = try? KeyWrap.unwrapToIdentity(wrap, recipient: identity, sender: senderKeys)
            else { continue }
            try remember(key)
            opened += 1
        }

        for wrap in wrapped where wrap.wrapKind == .aesUnderGroupKey && wrap.epoch <= membership.epoch {
            guard case .budget(let budget) = wrap.scope,
                  !has(scope: wrap.scope, epoch: wrap.epoch),
                  try mayBeIn(group, budget),
                  let groupKey = try? key(for: .group(group), epoch: wrap.epoch),
                  let key = try? KeyWrap.unwrapUnderGroupKey(wrap, groupKey: groupKey.material)
            else { continue }
            try remember(key)
            opened += 1
        }

        return opened
    }

    /// Whether `budget` can be in `group` as far as this Mac knows: it holds the
    /// budget there, or holds nothing under its ID yet.
    private func mayBeIn(_ group: GroupID, _ budget: BudgetID) throws -> Bool {
        guard let held = try store.holder(of: RecordID(budget.uuid)) else { return true }
        return held.type == .budget && held.group == group
    }

    /// A fresh group key and every budget key under it, sealed for each member.
    /// This is what a new epoch needs.
    ///
    /// The keys are returned, not kept. The caller keeps them once the server
    /// has taken the entry that starts the epoch, because a held key is never
    /// replaced: keys from an entry the server refused, say because another
    /// manager started the same epoch first, would stop the real ones arriving.
    public func rotate(group: GroupID, budgets: [BudgetID], to epoch: Epoch,
                       members: [(userID: UserID, keys: IdentityPublicKeys)]) throws
        -> (keys: [ScopedKey], wrapped: [WrappedKey]) {
        let groupKey = ScopedKey.generate(scope: .group(group), epoch: epoch)
        var keys = [groupKey]

        var wrapped: [WrappedKey] = []
        for member in members {
            wrapped.append(try KeyWrap.wrapToIdentity(
                groupKey, recipient: member.keys, recipientUserID: member.userID,
                sender: identity, senderUserID: userID))
        }

        for budget in budgets {
            let budgetKey = ScopedKey.generate(scope: .budget(budget), epoch: epoch)
            keys.append(budgetKey)
            wrapped.append(try KeyWrap.wrapUnderGroupKey(
                budgetKey, groupKey: groupKey.material, senderUserID: userID))
        }

        return (keys, wrapped)
    }
}
