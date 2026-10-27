#if canImport(AppKit)
import AppKit

extension Notification.Name {
    public static let wellSpentNewBudget = Notification.Name("WellSpent.newBudget")
    public static let wellSpentNewGroup = Notification.Name("WellSpent.newGroup")
    public static let wellSpentJoinGroup = Notification.Name("WellSpent.joinGroup")
    public static let wellSpentAddTransaction = Notification.Name("WellSpent.addTransaction")
}

/// The receiver for menu bar commands on macOS.
@MainActor
@objc public final class MacMenuActions: NSObject {
    public static let shared = MacMenuActions()

    @objc public func newBudget(_ sender: Any? = nil) {
        NotificationCenter.default.post(name: .wellSpentNewBudget, object: nil)
    }

    @objc public func newGroup(_ sender: Any? = nil) {
        NotificationCenter.default.post(name: .wellSpentNewGroup, object: nil)
    }

    @objc public func joinGroup(_ sender: Any? = nil) {
        NotificationCenter.default.post(name: .wellSpentJoinGroup, object: nil)
    }

    @objc public func addTransaction(_ sender: Any? = nil) {
        NotificationCenter.default.post(name: .wellSpentAddTransaction, object: nil)
    }
}

/// The Mac app's menu bar. A process launched from a package gets none, and the
/// menu bar is where Command-Q lives, and where macOS sends Command-C, Command-V
/// and Command-A: without an Edit menu, every text field beeps at them.
@MainActor
public enum MacMenu {
    /// The application menu, File menu, and Edit menu.
    public static func make(appName: String) -> NSMenu {
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Hide \(appName)", action: #selector(NSApplication.hide(_:)),
                        keyEquivalent: "h")
        let hideOthers = appMenu.addItem(withTitle: "Hide Others",
                                         action: #selector(NSApplication.hideOtherApplications(_:)),
                                         keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit \(appName)", action: #selector(NSApplication.terminate(_:)),
                        keyEquivalent: "q")

        // The File menu: creation commands, indexed by macOS Quick Search (Help menu).
        let fileMenu = NSMenu(title: "File")
        let newBudget = fileMenu.addItem(withTitle: "New Budget…",
                                         action: #selector(MacMenuActions.newBudget(_:)),
                                         keyEquivalent: "n")
        newBudget.target = MacMenuActions.shared

        let newGroup = fileMenu.addItem(withTitle: "New Group…",
                                        action: #selector(MacMenuActions.newGroup(_:)),
                                        keyEquivalent: "n")
        newGroup.keyEquivalentModifierMask = [.command, .shift]
        newGroup.target = MacMenuActions.shared

        let joinGroup = fileMenu.addItem(withTitle: "Join a Group…",
                                         action: #selector(MacMenuActions.joinGroup(_:)),
                                         keyEquivalent: "j")
        joinGroup.keyEquivalentModifierMask = [.command, .option]
        joinGroup.target = MacMenuActions.shared

        fileMenu.addItem(.separator())
        let addTx = fileMenu.addItem(withTitle: "Add Transaction…",
                                     action: #selector(MacMenuActions.addTransaction(_:)),
                                     keyEquivalent: "t")
        addTx.target = MacMenuActions.shared

        fileMenu.addItem(.separator())
        fileMenu.addItem(withTitle: "Close Window",
                         action: #selector(NSWindow.performClose(_:)),
                         keyEquivalent: "w")

        // The standard editing actions. Each goes to the first responder, which
        // is the focused text field, so pasting an invite link works.
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")

        let mainMenu = NSMenu()
        for submenu in [appMenu, fileMenu, editMenu] {
            let item = NSMenuItem()
            item.submenu = submenu
            mainMenu.addItem(item)
        }
        return mainMenu
    }
}
#endif
