#if canImport(AppKit)
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
    /// A link that came before the workspace was made. A click on an invite
    /// link that starts the app arrives before applicationDidFinishLaunching.
    private var waitingLink: URL?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let workspace: Workspace
        do {
            workspace = try Workspace.launch()
        } catch {
            let alert = NSAlert()
            alert.messageText = MainScreen.Words.couldNotOpen(AppEnvironment.current.appName)
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
        window.title = workspace.environment.appName
        window.center()
        // Each WellSpent account keeps its own budgets and its own keychain items,
        // so several can share this Mac login. See `AccountDirectory`.
        window.contentView = NSHostingView(rootView: wellSpentRootView(workspace: workspace))
        window.makeKeyAndOrderFront(nil)
        self.window = window
        self.workspace = workspace
        workspace.autoSync.start()
        // The banner says it inside the window. This says it in the Dock and the
        // app switcher, where two WellSpents side by side look otherwise alike.
        if workspace.environment == .staging {
            NSApp.dockTile.badgeLabel = "STAGING"
        }

        NSApp.activate(ignoringOtherApps: true)

        if let link = waitingLink {
            waitingLink = nil
            open(link, in: workspace)
        }
    }

    /// A click on one of this build's invite links. macOS hands it here,
    /// through the link type in the Info.plist, whether the click started
    /// the app or it was running already. What the link shows is the shared
    /// logic's (`Workspace.open`). Only the last of several links counts.
    func application(_ application: NSApplication, open urls: [URL]) {
        guard let link = urls.last else { return }
        guard let workspace else {
            waitingLink = link
            return
        }
        open(link, in: workspace)
    }

    /// Puts up the link's page, with the window to the front, so a click
    /// with the window in the Dock still shows it.
    @MainActor
    private func open(_ link: URL, in workspace: Workspace) {
        if let window {
            if window.isMiniaturized { window.deminiaturize(nil) }
            window.makeKeyAndOrderFront(nil)
        }
        Task { await workspace.open(link) }
    }

    /// Also runs once at launch, so this is the launch sync too.
    func applicationDidBecomeActive(_ notification: Notification) {
        guard let workspace else { return }
        Task { await workspace.autoSync.syncIfIdle() }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
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
application.mainMenu = MacMenu.make(appName: AppEnvironment.current.appName)
// Without this the process runs as a background accessory with no Dock icon and
// no way to focus the window.
application.setActivationPolicy(.regular)
// After the policy, so the process has a Dock tile for the icon to land on.
if let icon = appIcon() { application.applicationIconImage = icon }
application.run()

#else
// The Mac app. On Linux the WellSpent app is the separate Linux package.
print("This is the Mac app. On Linux, run the Linux app.")
#endif
