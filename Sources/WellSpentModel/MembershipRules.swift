import Foundation
import WellSpentCrypto

/// Who may change whom in a group. One copy, used by the server, which enforces
/// it, and by the apps, which offer only what the server would allow, so the
/// two cannot drift.
///
/// The rungs of the old signed membership log (`MembershipLog.requiredLevel`
/// and `Sharing.levelNeededToAdd`), stricter in two ways the log was not:
/// nobody gives more than they hold, and nobody is given superadmin.
public enum MembershipRules {
    /// The levels a member can be given. Superadmin belongs to the founder
    /// alone, and nobody is given "none": removing them does that.
    public static let grantable: Set<AccessLevel> = [.read, .write, .manage, .admin]

    /// Giving someone a level, as a new member or a change: anything at or
    /// above Manage, on either side of the change, needs Admin.
    public static func neededToSet(from old: AccessLevel?, to new: AccessLevel) -> AccessLevel {
        max(new, old ?? .none) >= .manage ? .admin : .manage
    }

    /// Removing someone at Manage or above needs Admin.
    public static func neededToRemove(_ level: AccessLevel) -> AccessLevel {
        level >= .manage ? .admin : .manage
    }

    /// Nobody gives more than they hold. The founder's superadmin ranks above
    /// admin here, so the founder can make admins.
    public static func mayGrant(_ level: AccessLevel, holding mine: AccessLevel) -> Bool {
        grantable.contains(level) && level <= mine
    }

    // MARK: - Whole decisions

    /// Why a change would be refused. Each decision below makes its checks in
    /// the order the server's route does, and the server answers with the
    /// first one that fails.
    public enum Refusal: Equatable, Sendable {
        /// A level nobody can be given.
        case notGrantable
        /// The founder's level never changes, and the founder can neither
        /// leave nor be removed: their group is deleted instead.
        case founder
        /// The person is not in the group.
        case notAMember
        /// The asker's level is too low; this is the level it takes.
        case needs(AccessLevel)
    }

    /// Inviting someone at `level`.
    public static func invite(at level: AccessLevel, holding mine: AccessLevel) -> Refusal? {
        guard grantable.contains(level) else { return .notGrantable }
        guard mine.allows(.manage) else { return .needs(.manage) }
        let needed = neededToSet(from: nil, to: level)
        guard mine.allows(needed), mayGrant(level, holding: mine) else { return .needs(max(needed, level)) }
        return nil
    }

    /// Changing a member's level from `old` to `new`.
    public static func changeLevel(from old: AccessLevel, to new: AccessLevel, ofFounder: Bool,
                                   holding mine: AccessLevel) -> Refusal? {
        guard grantable.contains(new) else { return .notGrantable }
        guard mine.allows(.manage) else { return .needs(.manage) }
        guard !ofFounder else { return .founder }
        guard old != .none else { return .notAMember }
        let needed = neededToSet(from: old, to: new)
        guard mine.allows(needed) else { return .needs(needed) }
        guard mayGrant(new, holding: mine) else { return .needs(new) }
        return nil
    }

    /// Removing a member, or, when it is the asker's own membership, leaving.
    public static func remove(_ theirs: AccessLevel, ofFounder: Bool, isSelf: Bool,
                              holding mine: AccessLevel) -> Refusal? {
        guard mine != .none else { return .notAMember }
        guard !ofFounder else { return .founder }
        if isSelf { return nil }
        guard theirs != .none else { return .notAMember }
        let needed = neededToRemove(theirs)
        guard mine.allows(needed) else { return .needs(needed) }
        return nil
    }
}
