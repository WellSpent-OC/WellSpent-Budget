import WellSpentLinuxNative

/// WellSpent's own pages, such as checkout, opened in the person's browser.
/// Any other link is refused (wellspent_open_link).
enum WebLink {
    @discardableResult
    static func open(_ url: String) -> Bool { wellspent_open_link(url) != 0 }
}
