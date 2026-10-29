/// A menu as the native shell hands it to C and reads a press back. The spec
/// is the items' titles one per line, with a line of "-" between sections.
/// C counts items only, never dividers, and reports a press as the item's
/// index, so the spec and the lookup come from the same flattened list: an
/// index can never reach a different item from the one whose title it drew.
struct NativeMenu<Item> {
    let items: [Item]
    let spec: String

    init(_ parts: [[Item]], title: KeyPath<Item, String>) {
        items = parts.flatMap { $0 }
        spec = parts.map { $0.map { $0[keyPath: title] }.joined(separator: "\n") }.joined(separator: "\n-\n")
    }

    func item(at index: Int) -> Item? {
        items.indices.contains(index) ? items[index] : nil
    }
}
