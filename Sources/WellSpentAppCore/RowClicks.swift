// The Mac screens. SwiftUI and AppKit exist only on Apple systems. The Linux
// app draws the same shared logic with its own screens.
#if canImport(SwiftUI) && canImport(AppKit)
import AppKit
import SwiftUI

/// Opens a row of the table it sits behind on a single click, anywhere in
/// the row.
///
/// SwiftUI's table opens a row on a double-click or on Return. A single click
/// only selects the row, and so do the arrow keys, so the selection can't
/// tell the two apart. A click on the row already selected changes nothing
/// at all. So the click is read from the mouse instead:
/// - While this view is in a window, it watches that window's mouse-downs.
///   Nothing is taken from them, and every one goes on to the window.
/// - One that lands on a row of a table inside this view's frame opens
///   that row, once the table has finished with the click.
/// - The arrow keys send no mouse-down, so they only select.
///
/// Placed as the table's background, so the table is always in front of it.
/// It never takes a click itself.
struct RowClicks: NSViewRepresentable {
    /// Called with the row's place in the table, counted from 0 at the top.
    let open: (Int) -> Void

    func makeNSView(context: Context) -> Watcher { Watcher() }

    func updateNSView(_ watcher: Watcher, context: Context) { watcher.open = open }

    static func dismantleNSView(_ watcher: Watcher, coordinator: ()) { watcher.stopWatching() }

    /// The row a plain single click opens, or nil. The click must land on a
    /// row, in a table inside `view`'s frame, in `view`'s window, with no
    /// sheet over the window. A click with Command, Shift, Option or Control
    /// held is the table's own: a change to the selection, or its menu.
    static func row(clickedBy event: NSEvent, behind view: NSView) -> Int? {
        guard let window = view.window, event.window === window, window.attachedSheet == nil,
              event.type == .leftMouseDown, event.clickCount == 1,
              event.modifierFlags.intersection([.command, .shift, .option, .control]).isEmpty,
              view.bounds.contains(view.convert(event.locationInWindow, from: nil)),
              let content = window.contentView,
              let hit = content.hitTest(content.superview?.convert(event.locationInWindow, from: nil)
                                        ?? event.locationInWindow),
              let table = sequence(first: hit, next: \.superview).lazy.compactMap({ $0 as? NSTableView }).first
        else { return nil }
        let row = table.row(at: table.convert(event.locationInWindow, from: nil))
        return row >= 0 ? row : nil
    }

    final class Watcher: NSView {
        var open: ((Int) -> Void)?
        private var monitor: Any?

        /// Never the view a click lands on.
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stopWatching()
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
                MainActor.assumeIsolated { self?.mouseWentDown(event) }
                return event
            }
        }

        func stopWatching() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }

        private func mouseWentDown(_ event: NSEvent) {
            guard let row = RowClicks.row(clickedBy: event, behind: self) else { return }
            // Once the table is done with the click. It selects the row,
            // then follows the mouse until the button is let go, and only
            // then is the app back in its default mode.
            RunLoop.main.perform(inModes: [.default]) { [weak self] in
                MainActor.assumeIsolated { self?.open?(row) }
            }
        }
    }
}

#endif
