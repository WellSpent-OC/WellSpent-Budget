import Foundation

/// The sharing ladder, carried over unchanged from the 2014 `memberships` table.
///
/// The gaps in the numbering are original and deliberate: they leave room to add
/// a rung without renumbering rows that already exist.
public enum AccessLevel: Int, Codable, Comparable, Sendable, CaseIterable {
    case none       = 0
    case read       = 3
    case write      = 5
    case manage     = 7
    case admin      = 11
    case superadmin = 13

    public static func < (a: AccessLevel, b: AccessLevel) -> Bool { a.rawValue < b.rawValue }

    /// Whether this level satisfies a requirement.
    ///
    /// Note the asymmetry, which is inherited from `models/Membership.rb`: every
    /// rung is a floor except superadmin, which is an exact match. An admin is not
    /// a superadmin no matter how the numbers compare. Keep it that way. The old
    /// app relied on it, and "fixing" it would silently promote every admin.
    public func allows(_ required: AccessLevel) -> Bool {
        required == .superadmin ? self == .superadmin : self >= required
    }

    /// What encryption alone can enforce.
    ///
    /// Exactly one rung: read. Holding the key is reading. Everything above read is
    /// enforced by the server refusing the write and by honest clients rejecting a
    /// signed envelope whose author was below `write` at that point in the
    /// membership log. There is no cryptographic write permission, and pretending
    /// otherwise is how these systems get designed wrong.
    public var isCryptographicallyEnforced: Bool { self == .read }
}
