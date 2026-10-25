import Gtk
import GtkBackend
import SwiftCrossUI
import WellSpentLinuxNative

enum WarTableBrowser {
    static func open(_ url: String) -> Bool { wellspent_wartable_open_url(url) != 0 }
}

extension View {
    func warTableControlLabel(_ label: String) -> some View {
        inspect([.onCreate, .afterUpdate]) { (widget: Gtk.Widget) in
            wellspent_wartable_control_label(widget.widgetPointer, label)
        }
    }
    /// Apply directly to TextEditor, before wrappers. Return remains a newline.
    func warTableComposer() -> some View {
        inspect([.onCreate, .afterUpdate]) { (widget: Gtk.Widget) in
            wellspent_wartable_composer(widget.widgetPointer)
        }
    }

    /// Apply directly to Send. The native shortcut activates the same button
    /// and therefore shares its enabled state and the screen's send checks.
    func warTableSendShortcut() -> some View {
        inspect([.onCreate, .afterUpdate]) { (widget: Gtk.Widget) in
            wellspent_wartable_send(widget.widgetPointer)
        }
    }

    func warTableTranscript(conversation: String, firstMessage: String, lastMessage: String, latest: Int) -> some View {
        inspect([.onCreate, .beforeUpdate]) { (widget: Gtk.Widget) in
            wellspent_wartable_transcript(widget.widgetPointer, conversation, firstMessage, lastMessage, Int32(clamping: latest))
        }
    }
}
