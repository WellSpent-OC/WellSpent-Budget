import Foundation
import GtkBackend
import Observation
import SwiftCrossUI
import WellSpentAppCore

/// The Linux app. It starts up exactly as the Mac app does, through
/// `Workspace.launch`, with Linux's own folder, settings and keyring
/// (`LinuxSetup`). The screens are drawn by SwiftCrossUI on GTK 4; what they
/// hold, check and say is the shared code.
@main
struct WellSpentLinuxApp: App {
    typealias Backend = GtkBackend

    @State var workspace: Workspace

    /// GTK under this build's own app ID. Without one, every SwiftCrossUI app
    /// shares a placeholder ID, and opening live while staging was open only
    /// brought staging to the front. SwiftCrossUI asks for it once, just
    /// before GTK starts: a launch given a link while a copy is open hands it
    /// over there (`OpenedLinks`).
    var backend: GtkBackend {
        let backend = GtkBackend(appIdentifier: LinuxSetup.environment.linuxAppIdentifier)
        OpenedLinks.handToOpenCopy(appIdentifier: LinuxSetup.environment.linuxAppIdentifier)
        return backend
    }

    init() {
        let workspace: Workspace
        do {
            workspace = try LinuxSetup.launch()
        } catch {
            // No window can show it yet: the database is what the window draws.
            FileHandle.standardError.write(Data(
                "\(LinuxSetup.environment.appName) could not open its database: \(error)\n".utf8))
            exit(1)
        }
        _workspace = State(wrappedValue: workspace)
        workspace.autoSync.start()
        // The launch sync. The Mac also syncs whenever its window comes to the
        // front; here the timer and every edit cover that.
        Task { @MainActor in await workspace.autoSync.syncIfIdle() }
        // A click on an invite link that started the app: its page is up as
        // the window opens.
        if let link = OpenedLinks.launchLink {
            Task { @MainActor in await workspace.open(link) }
        }
    }

    var body: some Scene {
        WindowGroup(LinuxSetup.environment.appName) {
            RootView(workspace: workspace)
                // A click while the app is open: the launch it started handed
                // the link over. Its page opens, and SwiftCrossUI then brings
                // the window to the front.
                .onOpenURL { [workspace] link in
                    Task { @MainActor in await workspace.open(link) }
                }
        }
        .defaultSize(width: 1100, height: 720)
    }
}
