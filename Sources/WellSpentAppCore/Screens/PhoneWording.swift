import Foundation

/// The iPhone's form of the desktop's words, kept in one place so every
/// iPhone screen follows the same rule. The Mac and Linux keep the words as
/// they are.
public enum PhoneWording {
    /// A button or a menu item on the iPhone has no "…" at its end, as in
    /// Apple's own iPhone apps: the desktop's "Delete…" is "Delete". A title
    /// with no "…" at its end stays as it is.
    public static func button(_ title: String) -> String {
        title.hasSuffix(ellipsis) ? String(title.dropLast()) : title
    }

    private static let ellipsis = "\u{2026}"
}
