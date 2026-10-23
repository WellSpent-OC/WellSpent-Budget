#include <gtk/gtk.h>

#include "wellspent_native.h"

// A single-line entry knows how to activate its window's default button.
// Leave text views and pickers alone: Return has its own meaning there.
static void enable_entry_defaults(GtkWidget *widget) {
    if (GTK_IS_ENTRY(widget)) {
        gtk_entry_set_activates_default(GTK_ENTRY(widget), TRUE);
    }
    for (GtkWidget *child = gtk_widget_get_first_child(widget); child;
         child = gtk_widget_get_next_sibling(child)) {
        enable_entry_defaults(child);
    }
}

// SwiftCrossUI 0.10.0's sheet Escape callback returns void where GTK expects
// a boolean. It consumes keys that reach the window. Entries handle Return
// themselves, but a focused button needs the window's activation. Preserve
// that behavior before the faulty callback, without redirecting Return from
// a focused Cancel button to Save.
static gboolean activate_focused_button(GtkEventControllerKey *controller,
                                        guint keyval, guint keycode,
                                        GdkModifierType state, gpointer data) {
    (void)keycode;
    (void)data;
    if (keyval != GDK_KEY_Return && keyval != GDK_KEY_KP_Enter) return FALSE;
    if (state & (GDK_SHIFT_MASK | GDK_CONTROL_MASK | GDK_ALT_MASK | GDK_SUPER_MASK)) return FALSE;

    GtkWidget *window = gtk_event_controller_get_widget(GTK_EVENT_CONTROLLER(controller));
    GtkWidget *focus = gtk_window_get_focus(GTK_WINDOW(window));
    for (GtkWidget *widget = focus; widget && widget != window;
         widget = gtk_widget_get_parent(widget)) {
        if (GTK_IS_BUTTON(widget)) {
            if (gtk_widget_is_sensitive(widget)) gtk_widget_activate(widget);
            return TRUE;
        }
    }
    return FALSE;
}

static void install_default(GtkWidget *button) {
    GtkRoot *root = gtk_widget_get_root(button);
    if (!GTK_IS_WINDOW(root)) return;
    gtk_window_set_default_widget(GTK_WINDOW(root), button);
    enable_entry_defaults(GTK_WIDGET(root));

    if (!g_object_get_data(G_OBJECT(root), "wellspent-default-keys")) {
        GtkEventController *keys = gtk_event_controller_key_new();
        gtk_event_controller_set_propagation_phase(keys, GTK_PHASE_CAPTURE);
        g_signal_connect(keys, "key-pressed", G_CALLBACK(activate_focused_button), NULL);
        gtk_widget_add_controller(GTK_WIDGET(root), keys);
        g_object_set_data(G_OBJECT(root), "wellspent-default-keys", GINT_TO_POINTER(1));
    }
}

static void default_on_realize(GtkWidget *button, gpointer data) {
    (void)data;
    install_default(button);
}

static void default_on_unrealize(GtkWidget *button, gpointer data) {
    (void)data;
    GtkRoot *root = gtk_widget_get_root(button);
    if (GTK_IS_WINDOW(root) && gtk_window_get_default_widget(GTK_WINDOW(root)) == button) {
        gtk_window_set_default_widget(GTK_WINDOW(root), NULL);
    }
}

void wellspent_default_action(void *widget) {
    if (!GTK_IS_BUTTON(widget)) return;
    GtkWidget *button = GTK_WIDGET(widget);
    // Connections live on the button. The window owns its key controller;
    // neither callback holds a pointer to another widget after it goes away.
    if (!g_object_get_data(G_OBJECT(button), "wellspent-default-action")) {
        g_signal_connect(button, "realize", G_CALLBACK(default_on_realize), NULL);
        g_signal_connect(button, "unrealize", G_CALLBACK(default_on_unrealize), NULL);
        g_object_set_data(G_OBJECT(button), "wellspent-default-action", GINT_TO_POINTER(1));
    }
    install_default(button);
}
