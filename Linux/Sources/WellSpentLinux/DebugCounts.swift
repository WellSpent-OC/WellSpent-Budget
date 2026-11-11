#if DEBUG
import Foundation
import WellSpentAppCore

/// What a UI test counts that a person can't see: how many times the window's
/// root has drawn, and how many screens wait on a reload. Written, whole, to
/// the file `variable` names, after each draw. A staging test build only: a
/// release build is compiled without it, and the release check fails the
/// build if this name is in the app.
@MainActor
enum DebugCounts {
    nonisolated static let variable = "WELLSPENT_DEBUG_COUNTS_FILE"

    private static let path: String? = {
        guard let path = ProcessInfo.processInfo.environment[variable], !path.isEmpty else { return nil }
        return path
    }()
    private static var draws = 0

    static func drew(_ workspace: Workspace) {
        guard let path, workspace.environment == .staging else { return }
        draws += 1
        try? "draws \(draws)\nwatchers \(workspace.reloadWatchers)\n"
            .write(toFile: path, atomically: true, encoding: .utf8)
    }
}
#endif
