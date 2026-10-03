import Foundation
import WellSpentCrypto
import WellSpentStore

extension Sharing {
    /// A group's access history as this Mac has verified it: the log it holds,
    /// plus whatever the server adds to the end of it, replayed together. What
    /// the server adds is kept. Empty when this Mac holds nothing and the
    /// server has nothing either.
    ///
    /// The whole log, fetched and replayed on its own, can be made up: a chain
    /// founded with keys the server made checks out by itself. The engine asks
    /// only for what comes after the entries it holds, so a server could answer
    /// the engine honestly and this step with a made-up chain, and keys taken
    /// on its word were kept for good. Extending what this Mac holds is the
    /// same check the engine makes (`SyncEngine.membership(of:)`).
    func verifiedLog(of group: GroupID) async throws -> [MembershipLogEntry] {
        let known = try store.membershipLog(for: group)
        let since = UInt64(known.count)
        let incoming = try await transport.membershipLog(group: group, since: since)
            .filter { $0.sequence >= since }
        let combined = known + incoming
        guard !combined.isEmpty else { return [] }
        do {
            _ = try MembershipLog.replay(combined, scope: .group(group))
        } catch {
            throw SyncError.membershipRefused(String(describing: error))
        }
        for entry in incoming { try store.append(entry, in: group) }
        return combined
    }
}
