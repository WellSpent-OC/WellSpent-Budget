import Foundation
import WellSpentCrypto
import WellSpentStore

/// What the sealed app's access history says about a group, for a group the
/// readable server has not listed members for yet: one from before the
/// switch, not moved. Goes when the sealed code does.
enum SealedHistory {
    static func deleteReach(of group: GroupID, in store: Store, me: UserID?) -> GroupDeleteReach {
        guard let state = replayed(group, in: store), state.members.count > 1 else { return .justYou }
        guard let me, state.mayDeleteGroup(me) else { return .thisMacOnly }
        return .everyone
    }

    /// A group with no history at all has never synced, so it is this
    /// person's own.
    static func mayManageBudgets(in group: GroupID, store: Store, me: UserID?) -> Bool {
        guard let log = try? store.membershipLog(for: group), !log.isEmpty else { return true }
        guard let me, let state = replayed(group, in: store) else { return false }
        return state.allows(me, .manage)
    }

    static func mayAddEntries(in group: GroupID, store: Store, me: UserID?) -> Bool {
        guard let log = try? store.membershipLog(for: group), !log.isEmpty else { return true }
        guard let me, let state = replayed(group, in: store) else { return false }
        return state.allows(me, .write)
    }

    static func memberCount(in group: GroupID, store: Store) -> Int {
        max(1, replayed(group, in: store)?.members.count ?? 1)
    }

    private static func replayed(_ group: GroupID, in store: Store) -> MembershipState? {
        guard let log = try? store.membershipLog(for: group), !log.isEmpty else { return nil }
        return try? MembershipLog.replay(log, scope: .group(group))
    }
}
