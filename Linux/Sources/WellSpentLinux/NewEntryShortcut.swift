import Gtk
import GtkBackend
import SwiftCrossUI
import WellSpentLinuxNative

extension View {
    /// Ctrl+N activates this budget's Add button from its main window.
    /// Apply directly to the button, before wrappers, so the native helper
    /// sees its actual visibility and enabled state. Sheets keep their keys.
    func newEntryShortcut() -> some View {
        inspect([.onCreate, .afterUpdate]) { (widget: Gtk.Widget) in
            wellspent_new_entry_shortcut(widget.widgetPointer)
        }
    }
}
