// The native budget page, read the way a screen reader and the UI tests read
// it: the budget's buttons by name, the wheel by what it says, a figure's
// amount with its description, and each entry a button whose labels read
// date, merchant, note, who added it, source, amount. No accounts, no database.
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
    g_printerr("budget page: %s\n", what);
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

/// The first label showing `text`, or NULL.
static GtkWidget *showing(GtkWidget *root, const char *text) {
    if (!root) return NULL;
    if (GTK_IS_LABEL(root) && strcmp(gtk_label_get_text(GTK_LABEL(root)), text) == 0) return root;
    for (GtkWidget *child = gtk_widget_get_first_child(root); child; child = gtk_widget_get_next_sibling(child)) {
        GtkWidget *found = showing(child, text);
        if (found) return found;
    }
    return NULL;
}

/// The nearest button holding `widget`, or NULL.
static GtkWidget *button_of(GtkWidget *widget) {
    for (GtkWidget *w = widget; w; w = gtk_widget_get_parent(w))
        if (GTK_IS_BUTTON(w)) return w;
    return NULL;
}

static gboolean described(GtkWidget *widget, const char *description) {
    char *mismatch = gtk_test_accessible_check_property(GTK_ACCESSIBLE(widget), GTK_ACCESSIBLE_PROPERTY_DESCRIPTION, description);
    gboolean ok = mismatch == NULL;
    g_free(mismatch);
    return ok;
}

/// A button's labels in order, joined by "|", as the UI tests read a row.
static void labels_in(GtkWidget *root, GString *out) {
    if (GTK_IS_LABEL(root)) {
        if (out->len) g_string_append_c(out, '|');
        g_string_append(out, gtk_label_get_text(GTK_LABEL(root)));
    }
    for (GtkWidget *child = gtk_widget_get_first_child(root); child; child = gtk_widget_get_next_sibling(child))
        labels_in(child, out);
}

static void on_action(void *context, const char *action_id) {
    const char **last = context;
    *last = g_intern_string(action_id);
}

static const char *press(GtkWidget *button, const char **last_action) {
    *last_action = NULL;
    if (button) { g_signal_emit_by_name(button, "clicked"); settle(50); }
    return *last_action ? *last_action : "";
}

static void activate(GtkApplication *app, gpointer user_data) {
    (void)user_data;
    const char *last_action = NULL;
    void *shell_ptr = wellspent_gtk_create_shell_window(app, "WellSpent", "Budgets", on_action, &last_action);
    WellSpentGtkShell *shell = shell_ptr;
    wellspent_gtk_wheel wheel = {
        .size = 210, .radius = 89, .band = 26, .outer_edge = 102, .inner_edge = 76,
        .edge_width = 3, .tick_width = 5, .arc = 0.6, .has_tick = 1,
        .tick_from_x = 105, .tick_from_y = 35, .tick_to_x = 105, .tick_to_y = 0,
        .track = { 0.9, 0.9, 0.9 }, .edge = { 0.07, 0.07, 0.07 }, .arc_color = { 0.46, 0.64, 0.3 },
    };

    wellspent_gtk_page_clear(shell_ptr);
    wellspent_gtk_page_add_head(shell_ptr, "Groceries", 1, "Import statement", "Add", "Edit…\n-\nDelete…");
    wellspent_gtk_page_add_undo(shell_ptr, "Deleted “Costco”, $286.31.", "Undo");
    wellspent_gtk_page_add_wheel(shell_ptr, "October · day 9 of 31", &wheel, "Left", "$588", "of $1,000",
                                 (wellspent_rgb){ 0.07, 0.07, 0.07 }, "Left $588 of $1,000",
                                 "On pace to spend $1,040.", "Edit Budget…");
    wellspent_gtk_page_add_figure(shell_ptr, "Spent", "$412.00", NULL, 0);
    wellspent_gtk_page_add_figure(shell_ptr, "Coming by Oct 20", "$650.00", "More than what's left", 1);
    wellspent_gtk_page_add_count(shell_ptr, "3 transactions since Oct 1", "2 repeats");
    wellspent_gtk_page_add_columns(shell_ptr, "Date", "Description", "Added by", "Source", "Amount");
    wellspent_gtk_page_add_entry(shell_ptr, "e1", "Oct 5", "Hilltop Grocery", "weekly shop", NULL, "Robin",
                                 "Manual", "$142.08", "Opens the transaction.");
    wellspent_gtk_page_add_entry(shell_ptr, "e2", "Oct 2", "Trader Joes", "", NULL, "You",
                                 "Statement", "$54.20", "Opens the transaction.");
    gtk_window_present(GTK_WINDOW(shell->window));
    settle(300);

    GtkWidget *page = shell->detail_pane;
    expect(showing(page, "Groceries") != NULL, "the budget's name is the title");
    GtkWidget *add = button_of(showing(page, "Add"));
    expect(add != NULL, "Add is a button");
    expect(strcmp(press(add, &last_action), "page:add") == 0, "Add's press is page:add");
    expect(strcmp(press(button_of(showing(page, "Import statement")), &last_action), "page:import") == 0,
           "Import statement's press is page:import");
    // The menu's divider is not an item, so Delete… is item 1.
    expect(strcmp(press(button_of(showing(page, "Delete…")), &last_action), "menu:budget:1") == 0,
           "the budget's menu items are buttons, counted as NativeMenu counts them");
    expect(strcmp(press(button_of(showing(page, "Undo")), &last_action), "page:undo") == 0, "Undo's press is page:undo");
    expect(strcmp(press(button_of(showing(page, "Edit Budget…")), &last_action), "page:edit_budget") == 0,
           "Edit Budget… beside the pace words is page:edit_budget");
    expect(strcmp(press(button_of(showing(page, "2 repeats")), &last_action), "page:repeats") == 0,
           "the count line's repeats open their list");

    GtkWidget *drawing = named(page, "Left $588 of $1,000");
    expect(drawing && GTK_IS_DRAWING_AREA(drawing), "the wheel is named by what it says");
    expect(showing(page, "$588") && showing(page, "of $1,000") && showing(page, "October · day 9 of 31"),
           "the wheel's middle words and the day line show");
    GtkWidget *coming = showing(page, "$650.00");
    expect(coming && described(coming, "More than what's left"), "a figure's amount carries its description");
    expect(coming && gtk_widget_has_css_class(coming, "over"), "a warning figure is marked over");

    GtkWidget *hilltop = button_of(showing(page, "Hilltop Grocery"));
    expect(hilltop != NULL, "an entry's row is a button");
    if (hilltop) {
        GString *read = g_string_new(NULL);
        labels_in(hilltop, read);
        expect(strcmp(read->str, "Oct 5|Hilltop Grocery|weekly shop|Robin|Manual|$142.08") == 0,
               "a row's labels read date, merchant, note, who added it, source, amount");
        g_string_free(read, TRUE);
        expect(described(hilltop, "Opens the transaction."), "a row says what a click does");
    }
    expect(strcmp(press(hilltop, &last_action), "entry:e1") == 0, "a row's press is entry:<id>");
    GtkWidget *joes = button_of(showing(page, "Trader Joes"));
    if (joes) {
        GString *read = g_string_new(NULL);
        labels_in(joes, read);
        expect(strcmp(read->str, "Oct 2|Trader Joes|You|Statement|$54.20") == 0, "a row with no note has no note label");
        g_string_free(read, TRUE);
    }

    // A budget no one else shares: no Added by, and no Add for a reader.
    wellspent_gtk_page_clear(shell_ptr);
    settle(50);
    expect(gtk_widget_get_first_child(page) == NULL, "clear empties the page");
    wellspent_gtk_page_add_head(shell_ptr, "Fuel", 0, "Import statement", "Add", NULL);
    wellspent_gtk_page_add_columns(shell_ptr, "Date", "Description", NULL, "Source", "Amount");
    wellspent_gtk_page_add_empty(shell_ptr, "Nothing spent in this budget this period.");
    settle(50);
    expect(showing(page, "Add") == NULL && showing(page, "Import statement") == NULL,
           "someone who may not add sees no Add or Import statement");
    expect(showing(page, "Added by") == NULL, "Added by shows only on a shared budget");
    expect(showing(page, "Nothing spent in this budget this period.") != NULL, "an empty budget says so");

    // No budgets yet: the words and Add Budget.
    wellspent_gtk_page_clear(shell_ptr);
    wellspent_gtk_page_show_message(shell_ptr, "No budgets yet", "A budget is an amount to spend each month.",
                                    "Add Budget");
    settle(50);
    expect(showing(page, "No budgets yet") != NULL, "no budgets says so");
    expect(strcmp(press(button_of(showing(page, "Add Budget")), &last_action), "action:add_budget") == 0,
           "Add Budget on the empty page is action:add_budget");

    gtk_window_destroy(GTK_WINDOW(shell->window));
    settle(100);
    wellspent_gtk_free_shell(shell_ptr);
    if (failures) g_printerr("budget page: %d check(s) failed\n", failures);
    else g_print("budget page: ok\n");
}

int main(int argc, char **argv) {
    GtkApplication *app = gtk_application_new("space.wellspent.budgetpage.test", G_APPLICATION_NON_UNIQUE);
    g_signal_connect(app, "activate", G_CALLBACK(activate), NULL);
    int status = g_application_run(G_APPLICATION(app), argc, argv);
    g_object_unref(app);
    return failures ? 1 : status;
}
