import Foundation
import WellSpentAppCore
import WellSpentLinuxNative

/// How a clicked invite link reaches the Linux app. The menu entry the
/// package installs claims this build's link type, so the desktop starts the
/// app with the link as its argument. Started that way, the app opens the
/// link's page as its window comes up. GTK keeps one copy of an app open: when
/// one is open already, the new launch hands it the link and stops, and the
/// open copy shows the page and comes to the front. Either way the link goes
/// to `Workspace.open(_:)`, the one way in on every desktop.
///
/// The link is handed over as plain text, never as a file, so it arrives
/// exactly as it was clicked (`wellspent_link_handoff`).
@MainActor
enum OpenedLinks {
    /// The link this launch was started with, if any.
    static let launchLink = Workspace.openedLink(in: CommandLine.arguments)

    /// What opens a link another launch handed over.
    private static var open: (URL) -> Void = { _ in }

    /// Call once GTK's application is made, and before it runs. When a copy
    /// of this build is open already, it gets this launch's link, and this
    /// launch then stops without a window. Otherwise this copy takes the
    /// links later launches hand over, and `open` gets each one.
    static func handOver(appIdentifier: String, open: @escaping (URL) -> Void) {
        self.open = open
        wellspent_link_handoff(appIdentifier, launchLink?.absoluteString) { text in
            guard let text, let link = URL(string: String(cString: text)) else { return }
            Task { @MainActor in OpenedLinks.open(link) }
        }
    }
}
