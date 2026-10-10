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
    }

    var body: some Scene {
        WindowGroup(LinuxSetup.environment.appName) {
            RootView(workspace: workspace)
        }
        .defaultSize(width: 1100, height: 720)
    }
}
