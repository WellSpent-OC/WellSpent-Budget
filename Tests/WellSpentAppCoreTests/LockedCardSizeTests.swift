// The Mac's lock card, measured. AppKit and SwiftUI exist only on the Mac.
#if canImport(SwiftUI) && os(macOS)
import AppKit
import SwiftUI
import Testing
@testable import WellSpentAppCore

/// Card #192: opening a locked group grew the window to 2159 points on a
/// 768 point screen, past its foot, so its buttons could not be clicked.
/// The window takes the smallest size its content allows, and the card had
/// no smallest width: squeezed to a word a line, its lines asked for that
/// height. A card that keeps a readable width keeps a height that fits.
@Suite("The lock card's size")
@MainActor
struct LockedCardSizeTests {
    @Test func squeezedNarrowTheCardStillFitsASmallScreen() {
        let card = LockedCardView(screen: LockedScreen(.ownGroup(open: "Home")), act: { _ in })
        let host = NSHostingController(rootView: card)
        let squeezed = host.sizeThatFits(in: CGSize(width: 1, height: 0))
        #expect(squeezed.height < 600, "the card asks for \(squeezed.height) points of height when squeezed")
    }
}
#endif
