#if canImport(AppKit)
import Testing
import AppKit
@testable import WellSpentAppCore

/// The menu bar is where macOS sends Command-C, Command-V and Command-A. Without
/// an Edit menu, every text field beeps at them, which is what the go/no-go test
/// found on 2026-10-15: no way to paste an invite link with the keyboard.
@Suite("The Mac menu bar")
struct MacMenuTests {
    @Test func theEditMenuHasTheStandardShortcuts() throws {
        let menu = MacMenu.make(appName: "WellSpent")
        let titles = menu.items.compactMap { $0.submenu?.title }
        #expect(titles.contains("Edit"))
        let edit = try #require(menu.items.first { $0.submenu?.title == "Edit" }?.submenu)
        let byTitle = Dictionary(uniqueKeysWithValues: edit.items.filter { !$0.isSeparatorItem }.map { ($0.title, $0) })
        #expect(byTitle["Paste"]?.keyEquivalent == "v")
        #expect(byTitle["Copy"]?.keyEquivalent == "c")
        #expect(byTitle["Cut"]?.keyEquivalent == "x")
        #expect(byTitle["Select All"]?.keyEquivalent == "a")
        #expect(byTitle["Undo"]?.keyEquivalent == "z")
        #expect(byTitle["Redo"]?.keyEquivalentModifierMask == [.command, .shift])
        #expect(byTitle["Paste"]?.action == #selector(NSText.paste(_:)))
    }

    @Test func theAppMenuStillQuits() throws {
        let menu = MacMenu.make(appName: "WellSpent")
        let app = try #require(menu.items.first?.submenu)
        #expect(app.items.contains { $0.title == "Quit WellSpent" && $0.keyEquivalent == "q" })
    }
}
#endif
