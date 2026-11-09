// Opens one of WellSpent's own web pages, such as checkout, in the person's
// browser, or an email to WellSpent in their mail program, the way the
// desktop opens any link. Only https links to wellspent.space or a part of
// it, and mail to an address at wellspent.space, are opened: anything else is
// refused, so a link that came from the server can never send someone
// elsewhere.
#include "wellspent_native.h"
#include <gtk/gtk.h>
#include <string.h>

static gboolean ends_with(const char *text, const char *tail) {
    size_t a = strlen(text), b = strlen(tail);
    return a >= b && g_ascii_strcasecmp(text + a - b, tail) == 0;
}

/// "mailto:someone@wellspent.space", with nothing after the address but a
/// subject or a body.
static gboolean mail_to_us(const char *url) {
    if (g_ascii_strncasecmp(url, "mailto:", 7) != 0) return FALSE;
    const char *address = url + 7;
    size_t length = strcspn(address, "?");
    char *to = g_uri_unescape_segment(address, address + length, NULL);
    gboolean ours = to && strchr(to, '@') == strrchr(to, '@') && !strpbrk(to, ",; \t\r\n") &&
        strchr(to, '@') != to && ends_with(to, "@wellspent.space");
    g_free(to);
    if (!ours) return FALSE;
    const char *query = address[length] == '?' ? address + length + 1 : NULL;
    if (!query) return TRUE;
    // Only a subject and a body: no cc, bcc or second recipient.
    gchar **parts = g_strsplit(query, "&", -1);
    for (int i = 0; parts[i]; i++) {
        if (g_ascii_strncasecmp(parts[i], "subject=", 8) != 0 && g_ascii_strncasecmp(parts[i], "body=", 5) != 0) {
            ours = FALSE;
            break;
        }
    }
    g_strfreev(parts);
    return ours;
}

int wellspent_link_is_ours(const char *url) {
    if (!url) return 0;
    if (mail_to_us(url)) return 1;
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
