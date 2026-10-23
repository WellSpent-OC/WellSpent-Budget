#include "wellspent_native.h"
#include <gtk/gtk.h>

#define SHORTCUT_KEY "wellspent-new-entry-shortcut"

typedef struct {
    GWeakRef button;
} NewEntryShortcut;

static void free_shortcut(gpointer data) {
    NewEntryShortcut *shortcut = data;
    g_weak_ref_clear(&shortcut->button);
    g_free(shortcut);
}

// Normally GTK sends a sheet's keys only to the sheet. Also check for a
// visible modal child, so a focus transition cannot activate the main Add.
static gboolean has_modal_child(GtkWindow *window) {
    GListModel *windows = gtk_window_get_toplevels();
    for (guint i = 0; i < g_list_model_get_n_items(windows); i++) {
        GtkWindow *other = g_list_model_get_item(windows, i);
        gboolean blocks = FALSE;
        if (gtk_window_get_modal(other) && gtk_widget_get_visible(GTK_WIDGET(other))) {
            for (GtkWindow *parent = gtk_window_get_transient_for(other); parent;
                 parent = gtk_window_get_transient_for(parent)) {
                if (parent == window) {
                    blocks = TRUE;
                    break;
                }
            }
        }
        g_object_unref(other);
        if (blocks) return TRUE;
    }
    return FALSE;
}

static gboolean new_entry_key(GtkEventControllerKey *controller, guint keyval, guint keycode,
                              GdkModifierType state, gpointer data) {
    (void)keycode;
    if (gdk_keyval_to_lower(keyval) != GDK_KEY_n ||
        (state & gtk_accelerator_get_default_mod_mask()) != GDK_CONTROL_MASK) return FALSE;

    GtkWidget *window = gtk_event_controller_get_widget(GTK_EVENT_CONTROLLER(controller));
    if (!gtk_window_is_active(GTK_WINDOW(window)) || has_modal_child(GTK_WINDOW(window))) return FALSE;

    NewEntryShortcut *shortcut = data;
    GtkWidget *button = g_weak_ref_get(&shortcut->button);
    if (!button) return FALSE;
    gboolean allowed = gtk_widget_get_root(button) == GTK_ROOT(window) &&
        gtk_widget_get_mapped(button) && gtk_widget_get_visible(button) && gtk_widget_is_sensitive(button);
    gboolean handled = allowed && gtk_widget_activate(button);
    g_object_unref(button);
    return handled;
}

static void install_shortcut(GtkWidget *button) {
    GtkRoot *root = gtk_widget_get_root(button);
    // A sheet must never claim this shortcut. Only the main app window owns
    // it, and it has one controller even when switching budgets makes new
    // Add buttons. The weak reference never keeps an old button alive.
    if (!GTK_IS_APPLICATION_WINDOW(root)) return;
    NewEntryShortcut *shortcut = g_object_get_data(G_OBJECT(root), SHORTCUT_KEY);
    if (!shortcut) {
        shortcut = g_new0(NewEntryShortcut, 1);
        g_weak_ref_init(&shortcut->button, button);
        g_object_set_data_full(G_OBJECT(root), SHORTCUT_KEY, shortcut, free_shortcut);
        GtkEventController *keys = gtk_event_controller_key_new();
        gtk_event_controller_set_propagation_phase(keys, GTK_PHASE_CAPTURE);
        g_signal_connect(keys, "key-pressed", G_CALLBACK(new_entry_key), shortcut);
        gtk_widget_add_controller(GTK_WIDGET(root), keys);
    } else {
        g_weak_ref_set(&shortcut->button, button);
    }
}

static void install_on_realize(GtkWidget *button, gpointer data) {
    (void)data;
    install_shortcut(button);
}

void wellspent_new_entry_shortcut(void *widget) {
    if (!GTK_IS_BUTTON(widget)) return;
    GtkWidget *button = GTK_WIDGET(widget);
    if (!g_object_get_data(G_OBJECT(button), SHORTCUT_KEY)) {
        g_signal_connect(button, "realize", G_CALLBACK(install_on_realize), NULL);
        g_object_set_data(G_OBJECT(button), SHORTCUT_KEY, GINT_TO_POINTER(1));
    }
    install_shortcut(button);
}
