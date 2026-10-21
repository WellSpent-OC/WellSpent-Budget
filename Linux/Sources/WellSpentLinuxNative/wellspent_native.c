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

// GLib calls this as GTK starts, before it decides on a window. Registering is
// what tells this launch whether a copy is running already. GLib registers
// next anyway, and a second call does nothing. When a copy is running, it gets
// the link, and 0 stops this launch, as its exit status. Otherwise -1 lets the
// start go on as before.
static gint hand_link_over(GApplication *app, GVariantDict *options, gpointer link) {
    (void)options;
    if (!g_application_register(app, NULL, NULL) || !g_application_get_is_remote(app)) return -1;
    GFile *file = g_file_new_for_uri(link);
    g_application_open(app, &file, 1, "");
    g_object_unref(file);
    // Sent before this launch stops.
    GDBusConnection *bus = g_application_get_dbus_connection(app);
    if (bus) g_dbus_connection_flush_sync(bus, NULL, NULL);
    return 0;
}

static void free_link(gpointer link, GClosure *closure) {
    (void)closure;
    g_free(link);
}

void wellspent_hand_link_to_running_copy(const char *app_id, const char *link) {
    // The application SwiftCrossUI made, which became the default as it was made.
    GApplication *app = g_application_get_default();
    if (!app || !link || g_strcmp0(g_application_get_application_id(app), app_id) != 0) return;
    g_signal_connect_data(app, "handle-local-options", G_CALLBACK(hand_link_over), g_strdup(link),
                          free_link, 0);
}
