/// The words beside WELLSPENT at the top of the window (ops#408): the open
/// group's name alone, and nothing when no group's page is open. Both the
/// SwiftCrossUI shell and the native one show this.
enum Titlebar {
    static func subtitle(openGroup name: String?) -> String {
        name ?? ""
    }
}
