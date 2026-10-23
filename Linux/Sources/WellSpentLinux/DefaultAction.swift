import Gtk
import SwiftCrossUI
import WellSpentLinuxNative

extension SwiftCrossUI.Button {
    /// Return in a single-line field performs this button's action. Apply
    /// directly to the button, before modifiers such as disabled or padding.
    /// GTK keeps a disabled action disabled and respects other focused controls.
    func defaultAction() -> some View {
        inspect([.onCreate, .afterUpdate]) { (button: Gtk.Button) in
            wellspent_default_action(button.widgetPointer)
        }
    }
}
