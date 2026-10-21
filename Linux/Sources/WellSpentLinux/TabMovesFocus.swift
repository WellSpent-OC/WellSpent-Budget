import Gtk
import SwiftCrossUI
import WellSpentLinuxNative

extension View {
    /// Tab and Shift+Tab move between the controls of the window the view is
    /// in, as they do in the main window. For a sheet's content: in
    /// SwiftCrossUI 0.10.0 a sheet's window lets no Tab through, so a person
    /// can't reach Password from Email by the keyboard. Any view in the sheet
    /// will do, since it's the window that listens.
    func tabMovesFocus() -> some View {
        inspect([.onCreate, .afterUpdate]) { (widget: Gtk.Widget) in
            wellspent_tab_moves_focus(widget.widgetPointer)
        }
    }
}
