// Opens one of WellSpent's own web pages, such as checkout, in the person's
// browser, the way the desktop opens any link. Only https links to
// wellspent.space or a part of it are opened: anything else is refused, so a
// link that came from the server can never send someone elsewhere.
#include "wellspent_native.h"
#include <gtk/gtk.h>
#include <string.h>

static gboolean ends_with(const char *text, const char *tail) {
    size_t a = strlen(text), b = strlen(tail);
    return a >= b && g_ascii_strcasecmp(text + a - b, tail) == 0;
}

int wellspent_link_is_ours(const char *url) {
    if (!url) return 0;
    GUri *uri = g_uri_parse(url, G_URI_FLAGS_NONE, NULL);
    if (!uri) return 0;
    const char *host = g_uri_get_host(uri);
    gboolean ours = g_strcmp0(g_uri_get_scheme(uri), "https") == 0 && host && !g_uri_get_userinfo(uri) &&
        g_uri_get_port(uri) == -1 &&
        (g_ascii_strcasecmp(host, "wellspent.space") == 0 || ends_with(host, ".wellspent.space"));
    g_uri_unref(uri);
    return ours ? 1 : 0;
}

static void launched(GObject *source, GAsyncResult *result, gpointer data) {
    (void)data;
    GError *error = NULL;
    if (!gtk_uri_launcher_launch_finish(GTK_URI_LAUNCHER(source), result, &error)) {
        g_printerr("open link: %s\n", error ? error->message : "no browser answered");
        g_clear_error(&error);
    }
    g_object_unref(source);
}

int wellspent_open_link(const char *url) {
    if (!wellspent_link_is_ours(url)) return 0;
    GtkUriLauncher *launcher = gtk_uri_launcher_new(url);
    gtk_uri_launcher_launch(launcher, NULL, NULL, launched, NULL);
    return 1;
}
