#if canImport(AppKit)
import Testing
import AppKit
@testable import WellSpentAppCore

/// The menu bar is where macOS sends Command-C, Command-V and Command-A. Without
/// an Edit menu, every text field beeps at them, which is what the go/no-go test
/// found on 2026-10-15: no way to paste an invite link with the keyboard.
@Suite("The Mac menu bar")
@MainActor
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

    @Test func theFileMenuHasCreationCommandsAndShortcuts() throws {
        let menu = MacMenu.make(appName: "WellSpent")
        let titles = menu.items.compactMap { $0.submenu?.title }
        #expect(titles.contains("File"))
        let file = try #require(menu.items.first { $0.submenu?.title == "File" }?.submenu)
        let byTitle = Dictionary(uniqueKeysWithValues: file.items.filter { !$0.isSeparatorItem }.map { ($0.title, $0) })
        #expect(byTitle["New Budget…"]?.keyEquivalent == "n")
        #expect(byTitle["New Group…"]?.keyEquivalent == "n")
        #expect(byTitle["New Group…"]?.keyEquivalentModifierMask == [.command, .shift])
        #expect(byTitle["Join a Group…"]?.keyEquivalent == "j")
        #expect(byTitle["Join a Group…"]?.keyEquivalentModifierMask == [.command, .option])
        #expect(byTitle["Add Transaction…"]?.keyEquivalent == "t")
        #expect(byTitle["Close Window"]?.keyEquivalent == "w")
    }

    @Test func menuActionsPostNotifications() throws {
        final class Box: @unchecked Sendable {
            var received = Set<Notification.Name>()
            let lock = NSLock()
            func add(_ name: Notification.Name) {
                lock.lock()
                defer { lock.unlock() }
                received.insert(name)
            }
            func has(_ name: Notification.Name) -> Bool {
                lock.lock()
                defer { lock.unlock() }
                return received.contains(name)
            }
        }
        let box = Box()
        let center = NotificationCenter.default
        let tokens = [
            center.addObserver(forName: .wellSpentNewBudget, object: nil, queue: nil) { _ in box.add(.wellSpentNewBudget) },
            center.addObserver(forName: .wellSpentNewGroup, object: nil, queue: nil) { _ in box.add(.wellSpentNewGroup) },
            center.addObserver(forName: .wellSpentJoinGroup, object: nil, queue: nil) { _ in box.add(.wellSpentJoinGroup) },
            center.addObserver(forName: .wellSpentAddTransaction, object: nil, queue: nil) { _ in box.add(.wellSpentAddTransaction) }
        ]
        defer { tokens.forEach { center.removeObserver($0) } }

        MacMenuActions.shared.newBudget(nil)
        MacMenuActions.shared.newGroup(nil)
        MacMenuActions.shared.joinGroup(nil)
        MacMenuActions.shared.addTransaction(nil)

        #expect(box.has(.wellSpentNewBudget))
        #expect(box.has(.wellSpentNewGroup))
        #expect(box.has(.wellSpentJoinGroup))
        #expect(box.has(.wellSpentAddTransaction))
    }
}
#endif
