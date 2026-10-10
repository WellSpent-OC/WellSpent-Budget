import Foundation
import WellSpentCrypto
import WellSpentStore

extension Store {
    /// The key for a scope on this device, minting and caching one the first time.
    ///
    /// This is what the statement importer keys its fingerprints with. It used to
    /// use a key generated at launch, which meant the same statement imported
    /// after a restart produced different fingerprints and duplicated every row.
    ///
    /// Always epoch zero, deliberately. Every epoch is kept forever, so asking for
    /// the first one means a key rotation does not change any fingerprint either.
    func localKey(for scope: KeyScope, epoch: Epoch = .initial) throws -> ScopedKey {
        if let existing = try cachedKey(scope: scope, epoch: epoch) { return existing }
        let fresh = ScopedKey.generate(scope: scope, epoch: epoch)
        try cache(fresh)
        return fresh
    }
}
