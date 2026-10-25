#include "wellspent_native.h"
#include <gtk/gtk.h>

static guint sent;
static void clicked(GtkButton *button, gpointer unused) { (void)button; (void)unused; sent++; }
static void settle(guint milliseconds) {
    gint64 end = g_get_monotonic_time() + milliseconds * 1000;
    do {
        while (g_main_context_iteration(NULL, FALSE)) {}
        g_usleep(1000);
    } while (g_get_monotonic_time() < end);
}
static gboolean key(GtkWidget *window, guint symbol, GdkModifierType modifiers) {
    GListModel *controllers = gtk_widget_observe_controllers(window);
    gboolean handled = FALSE;
    guint matching = 0;
    for (guint i = 0; i < g_list_model_get_n_items(controllers); i++) {
        GtkEventController *controller = g_list_model_get_item(controllers, i);
        if (g_strcmp0(gtk_event_controller_get_name(controller), "WellSpent WarTable send") == 0) {
            matching++;
            g_signal_emit_by_name(controller, "key-pressed", symbol, 0, modifiers, &handled);
        }
        g_object_unref(controller);
    }
    g_object_unref(controllers);
    g_assert_cmpuint(matching, ==, 1);
    settle(300); // GtkButton activation animates before emitting clicked.
    return handled;
}
static void focus(GtkWindow *window) {
    gtk_window_present(window);
    settle(100);
    gdk_toplevel_focus(GDK_TOPLEVEL(gtk_native_get_surface(GTK_NATIVE(window))), GDK_CURRENT_TIME);
    settle(100);
}
static void activate(GtkApplication *app, gpointer unused) {
    (void)unused;
    GtkWidget *window = gtk_application_window_new(app);
    GtkWidget *box = gtk_box_new(GTK_ORIENTATION_VERTICAL, 8);
    GtkWidget *editor = gtk_text_view_new();
    GtkWidget *button = gtk_button_new_with_label("Send");
    GtkWidget *other_editor = gtk_text_view_new();
    gtk_box_append(GTK_BOX(box), editor);
    gtk_box_append(GTK_BOX(box), button);
    gtk_box_append(GTK_BOX(box), other_editor);
    gtk_window_set_child(GTK_WINDOW(window), box);
    wellspent_wartable_composer(editor);
    wellspent_wartable_send(button);
    wellspent_wartable_send(button); // Repeated view updates remain idempotent.
    g_signal_connect(button, "clicked", G_CALLBACK(clicked), NULL);
    focus(GTK_WINDOW(window));
    gtk_widget_grab_focus(editor);
    g_assert_true(gtk_window_is_active(GTK_WINDOW(window)));
    g_assert_false(key(window, GDK_KEY_Return, 0));
    g_assert_cmpuint(sent, ==, 0);
    g_assert_true(key(window, GDK_KEY_Return, GDK_CONTROL_MASK));
    g_assert_cmpuint(sent, ==, 1);
    gtk_widget_set_sensitive(button, FALSE);
    g_assert_false(key(window, GDK_KEY_Return, GDK_CONTROL_MASK));
    g_assert_cmpuint(sent, ==, 1);
    gtk_widget_set_sensitive(button, TRUE);
    gtk_widget_grab_focus(other_editor);
    g_assert_false(key(window, GDK_KEY_Return, GDK_CONTROL_MASK));
    gtk_widget_grab_focus(editor);
    GtkWindow *sheet = GTK_WINDOW(gtk_window_new());
    gtk_window_set_transient_for(sheet, GTK_WINDOW(window));
    gtk_window_set_modal(sheet, TRUE);
    focus(sheet);
    g_assert_false(key(window, GDK_KEY_Return, GDK_CONTROL_MASK));
    g_assert_cmpuint(sent, ==, 1);
    gtk_window_destroy(sheet);
    focus(GTK_WINDOW(window));
    gtk_widget_grab_focus(editor);
    gtk_widget_set_visible(button, FALSE);
    g_assert_false(key(window, GDK_KEY_Return, GDK_CONTROL_MASK));
    g_assert_cmpuint(sent, ==, 1);
    gtk_window_destroy(GTK_WINDOW(window));
    g_application_quit(G_APPLICATION(app));
}
static void test_send(void) {
    GtkApplication *app = gtk_application_new("space.wellspent.wartable-native-test", G_APPLICATION_NON_UNIQUE);
    g_signal_connect(app, "activate", G_CALLBACK(activate), NULL);
    char *arguments[] = { "wartable-test", NULL };
    g_assert_cmpint(g_application_run(G_APPLICATION(app), 1, arguments), ==, 0);
    g_object_unref(app);
}
static void test_transcript(void) {
    GtkWidget *scroll = gtk_scrolled_window_new();
    g_object_ref_sink(scroll);
    GtkAdjustment *adjustment = gtk_scrolled_window_get_vadjustment(GTK_SCROLLED_WINDOW(scroll));
    wellspent_wartable_transcript(scroll, "one", "first", "first", 0);
    gtk_adjustment_configure(adjustment, 0, 0, 1000, 10, 100, 200);
    settle(10);
    g_assert_cmpfloat(gtk_adjustment_get_value(adjustment), ==, 800);
    gtk_adjustment_set_upper(adjustment, 1200);
    wellspent_wartable_transcript(scroll, "one", "first", "second", 0);
    settle(10);
    g_assert_cmpfloat(gtk_adjustment_get_value(adjustment), ==, 1000);
    gtk_adjustment_set_value(adjustment, 100); // Person reads earlier messages.
    gtk_adjustment_set_upper(adjustment, 1400);
    wellspent_wartable_transcript(scroll, "one", "first", "third", 0);
    settle(10);
    g_assert_cmpfloat(gtk_adjustment_get_value(adjustment), ==, 100);
    wellspent_wartable_transcript(scroll, "one", "older", "third", 0);
    gtk_adjustment_set_upper(adjustment, 1700); // Older history adds 300 pixels.
    settle(10);
    g_assert_cmpfloat(gtk_adjustment_get_value(adjustment), ==, 400);
    wellspent_wartable_transcript(scroll, "one", "older", "third", 1); // Latest messages.
    settle(10);
    g_assert_cmpfloat(gtk_adjustment_get_value(adjustment), ==, 1500);
    wellspent_wartable_transcript(scroll, "two", "other", "other", 1);
    g_object_unref(scroll); // Pending follow callback is cancelled safely.
    settle(10);
}
static void test_links(void) {
    g_assert_cmpint(wellspent_wartable_open_url("file:///etc/passwd"), ==, 0);
    g_assert_cmpint(wellspent_wartable_open_url("javascript:alert(1)"), ==, 0);
    g_assert_cmpint(wellspent_wartable_open_url("https://user:secret@example.com/"), ==, 0);
}
int main(int argc, char **argv) {
    g_test_init(&argc, &argv, NULL);
    gtk_init();
    g_test_add_func("/linux/wartable/send", test_send);
    g_test_add_func("/linux/wartable/transcript", test_transcript);
    g_test_add_func("/linux/wartable/links", test_links);
    return g_test_run();
}
