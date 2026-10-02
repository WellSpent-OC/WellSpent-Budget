import AppKit
import SwiftUI
import WellSpentAppCore
import WellSpentKeyStore
import WellSpentStore

/// Launched as a SwiftPM executable rather than an Xcode app target.
///
/// That is a deliberate constraint of this machine: `xcode-select` points at
/// CommandLineTools and the Xcode licence has not been accepted, so `xcodebuild`
/// cannot run. `swift build` can, and SwiftUI works fine from a plain executable
/// as long as the activation policy is set by hand. A process with no bundle
/// starts as a background accessory and its window never comes to the front.
///
/// Wrapping it in a real .app bundle is a packaging step, not a rewrite.
final class AppDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow?
    var workspace: Workspace?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let workspace: Workspace
        do {
            workspace = try Workspace.launch()
        } catch {
            let alert = NSAlert()
            alert.messageText = "WellSpent could not open its database"
            alert.informativeText = String(describing: error)
            alert.runModal()
            NSApp.terminate(nil)
            return
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1240, height: 800),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false
        )
        window.title = "WellSpent"
        window.center()
        // Each WellSpent account keeps its own budgets and its own keychain items,
        // so several can share this Mac login. See `AccountDirectory`.
        window.contentView = NSHostingView(rootView: wellSpentRootView(workspace: workspace))
        window.makeKeyAndOrderFront(nil)
        self.window = window
        self.workspace = workspace
        workspace.autoSync.start()

        NSApp.activate(ignoringOtherApps: true)
    }

    /// Also runs once at launch, so this is the launch sync too.
    func applicationDidBecomeActive(_ notification: Notification) {
        guard let workspace else { return }
        Task { await workspace.autoSync.syncIfIdle() }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

/// A process launched this way gets no menu bar, and the menu is where Cmd-Q
/// lives. This is the application menu a new Xcode project starts with.
func makeMainMenu() -> NSMenu {
    let appMenu = NSMenu()
    appMenu.addItem(withTitle: "Hide WellSpent", action: #selector(NSApplication.hide(_:)),
                    keyEquivalent: "h")
    let hideOthers = appMenu.addItem(withTitle: "Hide Others",
                                     action: #selector(NSApplication.hideOtherApplications(_:)),
                                     keyEquivalent: "h")
    hideOthers.keyEquivalentModifierMask = [.command, .option]
    appMenu.addItem(.separator())
    appMenu.addItem(withTitle: "Quit WellSpent", action: #selector(NSApplication.terminate(_:)),
                    keyEquivalent: "q")

    let appItem = NSMenuItem()
    appItem.submenu = appMenu
    let mainMenu = NSMenu()
    mainMenu.addItem(appItem)
    return mainMenu
}

/// The Dock icon. A process with no .app bundle has no Info.plist to name one, so
/// it is set here instead, from the icon SwiftPM copies next to the executable.
///
/// Looked up by hand rather than through `Bundle.module`, which stops the app
/// when the resource bundle is missing. A missing icon should cost the icon only.
func appIcon() -> NSImage? {
    let bundle = Bundle.main.url(forResource: "WellSpentBudget_WellSpentApp", withExtension: "bundle")
        .flatMap(Bundle.init(url:))
    return bundle?.url(forResource: "AppIcon", withExtension: "icns").flatMap(NSImage.init(contentsOf:))
}

let application = NSApplication.shared
let delegate = AppDelegate()
application.delegate = delegate
application.mainMenu = makeMainMenu()
// Without this the process runs as a background accessory with no Dock icon and
// no way to focus the window.
application.setActivationPolicy(.regular)
// After the policy, so the process has a Dock tile for the icon to land on.
if let icon = appIcon() { application.applicationIconImage = icon }
application.run()
