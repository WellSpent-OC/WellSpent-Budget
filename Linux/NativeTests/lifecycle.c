#include "wellspent_native.h"
#include <gtk/gtk.h>

static guint foreground_calls;
static guint clock_calls;
static guint replaced_calls;
static gint64 last_clock_at;
static gint64 least_clock_gap = G_MAXINT64;

static void receive(int foreground) {
    if (foreground) foreground_calls++;
    else {
        gint64 now = g_get_monotonic_time();
        if (last_clock_at) least_clock_gap = MIN(least_clock_gap, now - last_clock_at);
        last_clock_at = now;
        clock_calls++;
    }
}

static void replaced(int foreground) {
    (void)foreground;
    replaced_calls++;
}

static void settle(guint milliseconds) {
    gint64 end = g_get_monotonic_time() + milliseconds * 1000;
    do {
        while (g_main_context_iteration(NULL, FALSE)) {}
        g_usleep(1000);
    } while (g_get_monotonic_time() < end);
}

static void focus(GtkWindow *window) {
    gtk_window_present(window);
    settle(100);
    GdkSurface *surface = gtk_native_get_surface(GTK_NATIVE(window));
    g_assert_nonnull(surface);
    gdk_toplevel_focus(GDK_TOPLEVEL(surface), GDK_CURRENT_TIME);
    settle(200);
    g_assert_true(gtk_window_is_active(window));
}

static gboolean check_windows(gpointer data) {
    GtkApplication *app = data;
    GtkWindow *main = GTK_WINDOW(gtk_application_window_new(app));
    gtk_window_set_title(main, "Lifecycle test");
    gtk_window_set_default_size(main, 300, 200);
    focus(main);
    g_assert_cmpuint(foreground_calls, ==, 1);

    // A toolkit sheet is a plain transient GtkWindow, with no application.
    // Opening it and returning to the parent must not cause another sync.
    GtkWindow *sheet = GTK_WINDOW(gtk_window_new());
    gtk_window_set_transient_for(sheet, main);
    gtk_window_set_default_size(sheet, 150, 100);
    focus(sheet);
    g_assert_cmpuint(foreground_calls, ==, 1);
    gtk_window_destroy(sheet);
    focus(main);
    g_assert_cmpuint(foreground_calls, ==, 1);

    // A top-level window unrelated to this application does not count as
    // its foreground. Returning from it does count, exactly once.
    GtkWindow *other = GTK_WINDOW(gtk_window_new());
    gtk_window_set_default_size(other, 200, 100);
    focus(other);
    g_assert_cmpuint(foreground_calls, ==, 1);
    focus(main);
    g_assert_cmpuint(foreground_calls, ==, 2);

    // Installing the bridge twice replaced the callback, not the timer.
    // The seconds timer is aligned by GLib, so allow its first tick to land.
    settle(1800);
    guint before = clock_calls;
    settle(1100);
    g_assert_cmpuint(clock_calls, >, before);
    // Seconds timers may cross either one or two boundaries in 1.1 seconds.
    // Duplicate sources would instead call back together on one boundary.
    g_assert_cmpint(least_clock_gap, >, 500000);
    g_assert_cmpuint(foreground_calls, ==, 2);
    g_assert_cmpuint(replaced_calls, ==, 0);

    gtk_window_destroy(other);
    gtk_window_destroy(main);
    g_application_release(G_APPLICATION(app));
    g_application_quit(G_APPLICATION(app));
    return G_SOURCE_REMOVE;
}

static void activate(GtkApplication *app, gpointer unused) {
    (void)unused;
    g_application_hold(G_APPLICATION(app));
    g_idle_add(check_windows, app);
}

static void test_lifecycle(void) {
    GtkApplication *app = gtk_application_new("space.wellspent.lifecycle-test", G_APPLICATION_NON_UNIQUE);
    wellspent_watch_lifecycle("space.wellspent.another-app", 1, replaced);
    wellspent_watch_lifecycle("space.wellspent.lifecycle-test", 1, replaced);
    wellspent_watch_lifecycle("space.wellspent.lifecycle-test", 1, receive);
    g_signal_connect(app, "activate", G_CALLBACK(activate), NULL);
    char *arguments[] = { "lifecycle-test", NULL };
    g_assert_cmpint(g_application_run(G_APPLICATION(app), 1, arguments), ==, 0);

    // Shutdown must remove both timers even while the object is still alive.
    guint clocks_at_shutdown = clock_calls;
    guint foreground_at_shutdown = foreground_calls;
    settle(1500);
    g_assert_cmpuint(clock_calls, ==, clocks_at_shutdown);
    g_assert_cmpuint(foreground_calls, ==, foreground_at_shutdown);
    g_object_unref(app);
}

int main(int argc, char **argv) {
    g_test_init(&argc, &argv, NULL);
    g_test_add_func("/linux/lifecycle", test_lifecycle);
    return g_test_run();
}
