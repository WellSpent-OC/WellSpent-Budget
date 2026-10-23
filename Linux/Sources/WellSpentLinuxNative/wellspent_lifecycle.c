#include "wellspent_native.h"
#include <gtk/gtk.h>

#define LIFECYCLE_KEY "wellspent-lifecycle"

typedef struct {
    wellspent_lifecycle_receiver receive;
    guint clock_seconds;
    guint clock_source;
    guint focus_source;
    gboolean active;
    gboolean started;
    gboolean stopped;
} Lifecycle;

static Lifecycle *lifecycle(GApplication *app) {
    return g_object_get_data(G_OBJECT(app), LIFECYCLE_KEY);
}

// SwiftCrossUI's sheets are transient GtkWindows, not application windows.
// Following their parents includes them without counting another app's windows.
static gboolean belongs_to(GtkWindow *window, GtkApplication *app) {
    for (GtkWindow *parent = window; parent; parent = gtk_window_get_transient_for(parent)) {
        if (gtk_window_get_application(parent) == app) return TRUE;
    }
    return FALSE;
}

static gboolean check_focus(gpointer data) {
    GApplication *app = data;
    Lifecycle *watch = lifecycle(app);
    watch->focus_source = 0;
    gboolean active = FALSE;
    GListModel *windows = gtk_window_get_toplevels();
    for (guint i = 0; i < g_list_model_get_n_items(windows); i++) {
        GtkWindow *window = g_list_model_get_item(windows, i);
        active |= belongs_to(window, GTK_APPLICATION(app)) && gtk_window_is_active(window);
        g_object_unref(window);
    }
    gboolean came_to_front = active && !watch->active;
    watch->active = active;
    if (came_to_front && watch->receive) watch->receive(1);
    return G_SOURCE_REMOVE;
}

static void queue_focus_check(GApplication *app) {
    Lifecycle *watch = lifecycle(app);
    if (watch->stopped) return;
    if (watch->focus_source) g_source_remove(watch->focus_source);
    // A sheet taking focus sends a loss and a gain separately. Check after
    // they settle, so moving within the app does not start another sync.
    watch->focus_source = g_timeout_add(50, check_focus, app);
}

static void window_activity_changed(GObject *window, GParamSpec *property, gpointer app) {
    (void)window;
    (void)property;
    queue_focus_check(app);
}

static void windows_changed(GListModel *windows, guint position, guint removed, guint added, gpointer app) {
    (void)removed;
    for (guint i = position; i < position + added; i++) {
        GObject *window = g_list_model_get_item(windows, i);
        // Each list addition gets one handler. The application owns the
        // connection's lifetime, even for a sheet that outlives its parent.
        g_signal_connect_object(window, "notify::is-active", G_CALLBACK(window_activity_changed), app, 0);
        g_object_unref(window);
    }
    queue_focus_check(app);
}

static gboolean check_clock(gpointer app) {
    Lifecycle *watch = lifecycle(app);
    if (watch->receive) watch->receive(0);
    return G_SOURCE_CONTINUE;
}

static void start_watch(GApplication *app, gpointer unused) {
    (void)unused;
    Lifecycle *watch = lifecycle(app);
    if (watch->started) return;
    watch->started = TRUE;
    GListModel *windows = gtk_window_get_toplevels();
    g_signal_connect_object(windows, "items-changed", G_CALLBACK(windows_changed), app, 0);
    windows_changed(windows, 0, 0, g_list_model_get_n_items(windows), app);
    watch->clock_source = g_timeout_add_seconds(watch->clock_seconds, check_clock, app);
}

static void stop_watch(GApplication *app, gpointer unused) {
    (void)unused;
    Lifecycle *watch = lifecycle(app);
    if (watch->clock_source) g_source_remove(watch->clock_source);
    if (watch->focus_source) g_source_remove(watch->focus_source);
    watch->clock_source = watch->focus_source = 0;
    watch->receive = NULL;
    watch->stopped = TRUE;
}

static void free_watch(gpointer data) {
    Lifecycle *watch = data;
    if (watch->clock_source) g_source_remove(watch->clock_source);
    if (watch->focus_source) g_source_remove(watch->focus_source);
    g_free(watch);
}

void wellspent_watch_lifecycle(const char *app_id, unsigned int clock_seconds,
                              wellspent_lifecycle_receiver receive) {
    GApplication *app = g_application_get_default();
    if (!GTK_IS_APPLICATION(app) || g_strcmp0(g_application_get_application_id(app), app_id) != 0) return;
    Lifecycle *watch = lifecycle(app);
    if (watch) {
        watch->receive = receive;
        return;
    }
    watch = g_new0(Lifecycle, 1);
    watch->receive = receive;
    watch->clock_seconds = MAX(clock_seconds, 1);
    g_object_set_data_full(G_OBJECT(app), LIFECYCLE_KEY, watch, free_watch);
    // After GTK's startup, so its display and top-level window list exist.
    g_signal_connect_after(app, "startup", G_CALLBACK(start_watch), NULL);
    g_signal_connect(app, "shutdown", G_CALLBACK(stop_watch), NULL);
    if (g_application_get_is_registered(app) && !g_application_get_is_remote(app)) start_watch(app, NULL);
}
