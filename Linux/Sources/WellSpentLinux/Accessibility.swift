import Gtk
import GtkBackend
import SwiftCrossUI
import WellSpentLinuxNative

// What a screen reader says about a view beyond the words it shows: GTK's
// accessibility properties, set on the view's own widget. The Mac's views say
// the same through SwiftUI's accessibility modifiers, which SwiftCrossUI
// doesn't have yet. They're set again after every update, so they follow the
// screen's state.

extension View {
    /// What a screen reader hears about the view: `label` in place of what it
    /// shows, `value` after its name, and whether it's the one `selected`, as
    /// the Mac's `.accessibilityLabel`, `.accessibilityValue` and
    /// `.accessibilityAddTraits(.isSelected)` say. Nil leaves that part alone.
    ///
    /// Once per view, and before `.buttonStyle(_:)`, `.help(_:)` or anything
    /// else that wraps it: in SwiftCrossUI 0.10.0, a wrapper or a second
    /// `.inspect` is handed another widget, not the view's own. GTK gives no
    /// name to a plain container, so a label goes on a button or a text, not a
    /// stack.
    func accessibility(label: String? = nil, value: String? = nil, selected: Bool? = nil) -> some View {
        inspect([.onCreate, .afterUpdate]) { (widget: Gtk.Widget) in
            if let label {
                wellspent_accessible_set_label(widget.widgetPointer, label)
            }
            if let value {
                wellspent_accessible_set_description(widget.widgetPointer, value)
            }
            if let selected {
                wellspent_accessible_set_selected(widget.widgetPointer, selected ? 1 : 0)
            }
        }
    }
}
