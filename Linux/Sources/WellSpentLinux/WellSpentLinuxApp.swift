import CGtk4
import Foundation
import GtkBackend
import Observation
import SwiftCrossUI
import WellSpentAppCore
import WellSpentLinuxNative

/// The Linux desktop app launcher. The SwiftCrossUI app is what runs, the
/// one the Linux UI tests pass on. The straight native GTK 4 shell (Phase 1
/// of the native move) is opt-in with WELLSPENT_NATIVE=1 until the same
/// suite passes on it, screen by screen; then the default flips.
@main
struct WellSpentLinuxApp {
    /// The launch variable that picks the native shell.
    static let nativeVariable = "WELLSPENT_NATIVE"

    @MainActor
    static func main() {
        if ProcessInfo.processInfo.environment[nativeVariable] == "1" {
            runNative()
        } else {
            WellSpentLinuxSxiApp.main()
        }
    }

    @MainActor
    private static func runNative() {
        let workspace: Workspace
        do {
            workspace = try LinuxSetup.launch()
        } catch {
            FileHandle.standardError.write(Data(
                "\(LinuxSetup.environment.appName) could not open its database: \(error)\n".utf8))
            exit(1)
        }

        workspace.autoSync.start()
        Task { @MainActor in await workspace.autoSync.syncIfIdle() }

        let appId = LinuxSetup.environment.linuxAppIdentifier
        guard let app = gtk_application_new(appId, G_APPLICATION_DEFAULT_FLAGS) else {
            FileHandle.standardError.write(Data("Could not create GtkApplication\n".utf8))
            exit(1)
        }

        OpenedLinks.handOver(appIdentifier: appId) { link in
            Task { await workspace.open(link) }
        }
        wellspent_quit_on_terminate()
        LinuxLifecycle.watch(workspace)

        let controller = NativeShellController(workspace: workspace)
        let retainedController = Unmanaged.passRetained(controller)

        g_signal_connect_data(
            app,
            "activate",
            unsafeBitCast({ (app: UnsafeMutableRawPointer?, data: UnsafeMutableRawPointer?) in
                guard let app, let data else { return }
                let ctrl = Unmanaged<NativeShellController>.fromOpaque(data).takeUnretainedValue()
                MainActor.assumeIsolated {
                    ctrl.attach(to: app)
                }
            } as @convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?) -> Void, to: GCallback.self),
            retainedController.toOpaque(),
            nil,
            GConnectFlags(0)
        )

        let gApp = UnsafeMutableRawPointer(app).bindMemory(to: GApplication.self, capacity: 1)
        let status = g_application_run(gApp, Int32(CommandLine.argc), CommandLine.unsafeArgv)
        retainedController.release()
        g_object_unref(app)
        exit(status)
    }
}

/// The SwiftCrossUI application, the default.
struct WellSpentLinuxSxiApp: App {
    typealias Backend = GtkBackend

    @State var workspace: Workspace

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
            FileHandle.standardError.write(Data(
                "\(LinuxSetup.environment.appName) could not open its database: \(error)\n".utf8))
            exit(1)
        }
        _workspace = State(wrappedValue: workspace)
        workspace.autoSync.start()
        Task { @MainActor in await workspace.autoSync.syncIfIdle() }
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
