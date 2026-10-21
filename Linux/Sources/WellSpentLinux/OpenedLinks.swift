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
enum OpenedLinks {
    /// The link this launch was started with, if any.
    static let launchLink = Workspace.openedLink(in: CommandLine.arguments)

    /// Call once GTK's application is made, and before it runs. When a copy
    /// of this build is open already, it gets this launch's link, and this
    /// launch then stops without a window. With no link, nothing changes.
    static func handToOpenCopy(appIdentifier: String) {
        guard let launchLink else { return }
        wellspent_hand_link_to_running_copy(appIdentifier, launchLink.absoluteString)
    }
}
