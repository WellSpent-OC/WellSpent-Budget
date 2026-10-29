import Testing
@testable import WellSpentLinux

/// The spec the C side draws and the index it reports back come from one
/// list, so a divider never shifts a press onto another item.
struct NativeMenuTests {
    struct Item { let title: String }

    @Test func aDividerDrawsALineButCountsNoItem() {
        let menu = NativeMenu([[Item(title: "Share"), Item(title: "People")], [Item(title: "Delete…")]],
                              title: \.title)
        #expect(menu.spec == "Share\nPeople\n-\nDelete…")
        #expect(menu.item(at: 0)?.title == "Share")
        #expect(menu.item(at: 1)?.title == "People")
        #expect(menu.item(at: 2)?.title == "Delete…")
        #expect(menu.item(at: 3) == nil)
    }

    @Test func everyDrawnLineIsTheItemAtItsIndex() {
        let menu = NativeMenu([[Item(title: "New Budget"), Item(title: "Rename")], [Item(title: "Leave")],
                               [Item(title: "Share")]], title: \.title)
        let drawn = menu.spec.split(separator: "\n").filter { $0 != "-" }
        #expect(drawn.count == menu.items.count)
        for (index, line) in drawn.enumerated() {
            #expect(menu.item(at: index)?.title == String(line))
        }
    }

    @Test func anEmptyMenuDrawsNothing() {
        let menu = NativeMenu([[Item]](), title: \.title)
        #expect(menu.spec == "")
        #expect(menu.item(at: 0) == nil)
    }
}
