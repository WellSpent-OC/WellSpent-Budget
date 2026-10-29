// The native shell's sidebar, read the way a screen reader and the UI tests
// read it: a group's name is a button whose description says what it does, a
// budget's row is named by its name and what is left, says how much is used,
// and the open one alone is SELECTED. No accounts, no database.
#include "wellspent_gtk_shell_private.h"
#include "wellspent_native.h"
#include <gtk/gtk.h>
#include <string.h>

static int failures;

static void settle(guint milliseconds) {
    gint64 end = g_get_monotonic_time() + milliseconds * 1000;
    do {
        while (g_main_context_iteration(NULL, FALSE)) {}
        g_usleep(1000);
    } while (g_get_monotonic_time() < end);
}

static void expect(gboolean ok, const char *what) {
    if (ok) return;
    failures++;
    g_printerr("sidebar: %s\n", what);
}

/// The first descendant whose accessible label is `label`, or NULL.
static GtkWidget *named(GtkWidget *root, const char *label) {
    if (!root) return NULL;
    char *mismatch = gtk_test_accessible_check_property(GTK_ACCESSIBLE(root), GTK_ACCESSIBLE_PROPERTY_LABEL, label);
    if (!mismatch && gtk_test_accessible_has_property(GTK_ACCESSIBLE(root), GTK_ACCESSIBLE_PROPERTY_LABEL)) return root;
    g_free(mismatch);
    for (GtkWidget *child = gtk_widget_get_first_child(root); child; child = gtk_widget_get_next_sibling(child)) {
        GtkWidget *found = named(child, label);
        if (found) return found;
    }
    return NULL;
}

static gboolean described(GtkWidget *widget, const char *description) {
    char *mismatch = gtk_test_accessible_check_property(GTK_ACCESSIBLE(widget), GTK_ACCESSIBLE_PROPERTY_DESCRIPTION, description);
    gboolean ok = mismatch == NULL;
    g_free(mismatch);
    return ok;
}

static gboolean selected(GtkWidget *widget, gboolean value) {
    char *mismatch = gtk_test_accessible_check_state(GTK_ACCESSIBLE(widget), GTK_ACCESSIBLE_STATE_SELECTED, value);
    gboolean ok = mismatch == NULL;
    g_free(mismatch);
    return ok;
}

static void on_action(void *context, const char *action_id) {
    const char **last = context;
    *last = g_intern_string(action_id);
}

static void activate(GtkApplication *app, gpointer user_data) {
    (void)user_data;
    const char *last_action = NULL;
    void *shell_ptr = wellspent_gtk_create_shell_window(app, "WellSpent", "Budgets", on_action, &last_action);
    WellSpentGtkShell *shell = shell_ptr;

    wellspent_gtk_sidebar_clear(shell_ptr);
    wellspent_gtk_sidebar_add_group(shell_ptr, "g1", "HOUSEHOLD", "Hide budgets", 0, 1, "Rename…\nShare…\n-\nDelete…");
    wellspent_gtk_sidebar_add_budget(shell_ptr, "b1", "Groceries", "$588.00 left", "27 percent used", 0.27, 0, 1);
    wellspent_gtk_sidebar_add_budget(shell_ptr, "b2", "Fuel", "$3.75 over", "Over budget", 1.0, 1, 0);
    wellspent_gtk_sidebar_add_group(shell_ptr, "g2", "SIDE BUSINESS", "Show budgets", 1, 0, "Rename…");
    wellspent_gtk_sidebar_add_note(shell_ptr, "waiting on its founder");
    wellspent_gtk_sidebar_add_footer(shell_ptr, "Add Budget", "New Group…\nJoin a Group…",
                                     "Your budgets are kept on this computer.", NULL);
    gtk_window_present(GTK_WINDOW(shell->window));
    settle(300);

    GtkWidget *side = shell->sidebar_content;
    GtkWidget *household = named(side, "HOUSEHOLD");
    expect(household && GTK_IS_BUTTON(household), "the group's name is a button named HOUSEHOLD");
    expect(household && described(household, "Hide budgets"), "the group's button says it hides the budgets");
    expect(household && gtk_widget_has_css_class(household, "selected") == FALSE, "a group whose page is closed is not marked");

    GtkWidget *side_business = named(side, "SIDE BUSINESS");
    expect(side_business && gtk_widget_has_css_class(side_business, "selected"), "the group whose page is open is marked");

    GtkWidget *groceries = named(side, "Groceries $588.00 left");
    expect(groceries != NULL, "a budget's row is named by its name and what is left");
    expect(groceries && described(groceries, "27 percent used"), "a budget's row says how much is used");
    expect(groceries && selected(groceries, TRUE), "the open budget's row is SELECTED");

    GtkWidget *fuel = named(side, "Fuel $3.75 over");
    expect(fuel != NULL, "an over budget's row is named by how far over");
    expect(fuel && selected(fuel, FALSE), "a closed budget's row is not SELECTED");

    int menus = 0;
    for (GtkWidget *line = gtk_widget_get_first_child(side); line; line = gtk_widget_get_next_sibling(line))
        if (named(line, "⋯")) menus++;
    expect(menus == 2, "each group has its ⋯ menu button");

    GtkWidget *note = named(side, "waiting on its founder");
    expect(note && GTK_IS_LABEL(note) && !GTK_IS_BUTTON(note), "a note is a label, not a control");

    GtkWidget *bottom = shell->sidebar_bottom;
    expect(named(bottom, "Add Budget") != NULL, "Add Budget is under the rows");
    expect(named(bottom, "More") != NULL, "the More menu is under the rows");

    // Pressing a row and a group's name reach Swift as their action ids.
    if (groceries) { g_signal_emit_by_name(groceries, "clicked"); settle(50); }
    expect(last_action && strcmp(last_action, "budget:b1") == 0, "a row's press is budget:<id>");
    if (household) { g_signal_emit_by_name(household, "clicked"); settle(50); }
    expect(last_action && strcmp(last_action, "group:g1") == 0, "a group's press is group:<id>");

    // Cleared, the sidebar holds nothing, and building it again works.
    wellspent_gtk_sidebar_clear(shell_ptr);
    settle(50);
    expect(gtk_widget_get_first_child(side) == NULL, "clear empties the rows");
    wellspent_gtk_sidebar_add_group(shell_ptr, "g1", "HOUSEHOLD", "Hide budgets", 0, 1, NULL);
    settle(50);
    expect(named(side, "HOUSEHOLD") != NULL, "the sidebar can be rebuilt after a clear");

    gtk_window_destroy(GTK_WINDOW(shell->window));
    settle(100);
    wellspent_gtk_free_shell(shell_ptr);
    if (failures) g_printerr("sidebar: %d check(s) failed\n", failures);
    else g_print("sidebar: ok\n");
}

int main(int argc, char **argv) {
    GtkApplication *app = gtk_application_new("space.wellspent.sidebar.test", G_APPLICATION_NON_UNIQUE);
    g_signal_connect(app, "activate", G_CALLBACK(activate), NULL);
    int status = g_application_run(G_APPLICATION(app), argc, argv);
    g_object_unref(app);
    return failures ? 1 : status;
}
