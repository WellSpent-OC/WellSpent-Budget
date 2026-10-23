import Foundation
import GtkBackend
import Observation
import SwiftCrossUI
import WellSpentAppCore
import WellSpentLinuxNative

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
    /// over there (`OpenedLinks`). A click while the app is open starts such a
    /// launch, and the open copy opens the link's page.
    var backend: GtkBackend {
        let backend = GtkBackend(appIdentifier: LinuxSetup.environment.linuxAppIdentifier)
        OpenedLinks.handOver(appIdentifier: LinuxSetup.environment.linuxAppIdentifier) { [workspace] link in
            Task { await workspace.open(link) }
        }
        wellspent_quit_on_terminate()
        LinuxLifecycle.watch(workspace)
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
        // The launch sync also works when the desktop starts us in the
        // background. LinuxLifecycle handles later returns to the window.
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
        }
        .defaultSize(width: 1100, height: 720)
    }
}
