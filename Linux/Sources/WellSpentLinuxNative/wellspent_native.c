#include "wellspent_native.h"
#include <libsecret/secret.h>
#include <gtk/gtk.h>

// One schema for every WellSpent item. "service" is the per-build, per-account
// name the Mac app uses for its keychain (app.wellspent.keys.<account>), so the
// two apps name things alike and live never sees staging's items.
static const SecretSchema *wellspent_schema(void) {
    static const SecretSchema schema = {
        "app.wellspent.keys", SECRET_SCHEMA_NONE,
        {
            { "service", SECRET_SCHEMA_ATTRIBUTE_STRING },
            { "item", SECRET_SCHEMA_ATTRIBUTE_STRING },
            { NULL, 0 },
        }
    };
    return &schema;
}

int wellspent_keyring_store(const char *service, const char *item, const char *value) {
    GError *error = NULL;
    gchar *label = g_strdup_printf("WellSpent (%s, %s)", service, item);
    gboolean ok = secret_password_store_sync(wellspent_schema(), SECRET_COLLECTION_DEFAULT, label, value,
                                             NULL, &error, "service", service, "item", item, NULL);
    g_free(label);
    if (error) { g_error_free(error); return 0; }
    return ok ? 1 : 0;
}

char *wellspent_keyring_lookup(const char *service, const char *item, int *failed) {
    GError *error = NULL;
    gchar *value = secret_password_lookup_sync(wellspent_schema(), NULL, &error,
                                               "service", service, "item", item, NULL);
    *failed = error ? 1 : 0;
    if (error) g_error_free(error);
    return value;
}

int wellspent_keyring_clear(const char *service, const char *item) {
    GError *error = NULL;
    secret_password_clear_sync(wellspent_schema(), NULL, &error, "service", service, "item", item, NULL);
    if (error) { g_error_free(error); return 0; }
    return 1;
}

void wellspent_keyring_free(char *value) { secret_password_free(value); }

void wellspent_clipboard_set_text(const char *text) {
    GdkDisplay *display = gdk_display_get_default();
    if (!display) return;
    gdk_clipboard_set_text(gdk_display_get_clipboard(display), text);
}

// The link goes over as plain text, through an action of the app's own. GTK's
// usual way, GApplication's "open", sends it as a file, and both copies make a
// GFile of it. Where the desktop's file layer (gvfs) is installed, as it is on
// most desktops, that changes the link: "wellspent://join#s=..." arrives as
// "wellspent://join/#s=...", which no longer reads as an invite.
#define OPEN_LINK_ACTION "open-link"

// The Swift side, which opens the link's page.
static wellspent_link_receiver link_receiver;

// In the open copy, when another launch sends it a link.
static void open_link(GSimpleAction *action, GVariant *link, gpointer app) {
    (void)action;
    if (link_receiver) link_receiver(g_variant_get_string(link, NULL));
    GtkWindow *window = gtk_application_get_active_window(GTK_APPLICATION(app));
    if (window) gtk_window_present(window);
}

// GLib calls this as GTK starts, before it decides on a window. Registering is
// what tells this launch whether a copy is running already. GLib registers
// next anyway, and a second call does nothing. When a copy is running, it gets
// the link, and 0 stops this launch, as its exit status. Otherwise -1 lets the
// start go on as before.
static gint hand_link_over(GApplication *app, GVariantDict *options, gpointer link) {
    (void)options;
    if (!g_application_register(app, NULL, NULL) || !g_application_get_is_remote(app)) return -1;
    g_action_group_activate_action(G_ACTION_GROUP(app), OPEN_LINK_ACTION, g_variant_new_string(link));
    // Sent before this launch stops.
    GDBusConnection *bus = g_application_get_dbus_connection(app);
    if (bus) g_dbus_connection_flush_sync(bus, NULL, NULL);
    return 0;
}

static void free_link(gpointer link, GClosure *closure) {
    (void)closure;
    g_free(link);
}

void wellspent_link_handoff(const char *app_id, const char *link, wellspent_link_receiver receive) {
    // The application SwiftCrossUI made, which became the default as it was made.
    GApplication *app = g_application_get_default();
    if (!app || g_strcmp0(g_application_get_application_id(app), app_id) != 0) return;
    link_receiver = receive;
    GSimpleAction *action = g_simple_action_new(OPEN_LINK_ACTION, G_VARIANT_TYPE_STRING);
    g_signal_connect(action, "activate", G_CALLBACK(open_link), app);
    g_action_map_add_action(G_ACTION_MAP(app), G_ACTION(action));
    g_object_unref(action);
    if (link)
        g_signal_connect_data(app, "handle-local-options", G_CALLBACK(hand_link_over), g_strdup(link),
                              free_link, 0);
}

void wellspent_accessible_set_label(void *widget, const char *label) {
    if (!GTK_IS_ACCESSIBLE(widget) || !label) return;
    gtk_accessible_update_property(GTK_ACCESSIBLE(widget), GTK_ACCESSIBLE_PROPERTY_LABEL, label, -1);
}

void wellspent_accessible_set_description(void *widget, const char *description) {
    if (!GTK_IS_ACCESSIBLE(widget) || !description) return;
    gtk_accessible_update_property(GTK_ACCESSIBLE(widget), GTK_ACCESSIBLE_PROPERTY_DESCRIPTION, description, -1);
}

void wellspent_accessible_set_selected(void *widget, int selected) {
    if (!GTK_IS_ACCESSIBLE(widget)) return;
    gtk_accessible_update_state(GTK_ACCESSIBLE(widget), GTK_ACCESSIBLE_STATE_SELECTED, selected ? TRUE : FALSE, -1);
}
