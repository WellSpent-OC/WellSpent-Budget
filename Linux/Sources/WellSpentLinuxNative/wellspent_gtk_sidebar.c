// The native sidebar: invitations, each group's name with its menu, its
// budgets as filled bars, the notes, then Add Budget, More and the footer.
// Drawn from the shared MainScreen by NativeShellController.render(); this
// file only knows widgets and words it is handed. Every control carries the
// name the SwiftCrossUI sidebar gives it, so the Linux UI tests and a screen
// reader find the same things.
#include "wellspent_gtk_shell_private.h"
#include <string.h>

static void clear_box(GtkWidget *box) {
    if (!box) return;
    GtkWidget *child = gtk_widget_get_first_child(box);
    while (child) {
        GtkWidget *next = gtk_widget_get_next_sibling(child);
        gtk_box_remove(GTK_BOX(box), child);
        child = next;
    }
}

void wellspent_gtk_sidebar_clear(void *shell_ptr) {
    WellSpentGtkShell *shell = (WellSpentGtkShell *)shell_ptr;
    if (!shell) return;
    clear_box(shell->sidebar_content);
    clear_box(shell->sidebar_bottom);
    shell->sidebar_footer_lbl = NULL;
}

/// A menu from its spec: items one per line, a line of "-" a divider. Each
/// item fires shell.pick with "<prefix>:<index>", the index counting items only.
static GMenu *menu_from_spec(const char *prefix, const char *spec) {
    GMenu *menu = g_menu_new();
    GMenu *section = g_menu_new();
    if (!spec) spec = "";
    gchar **lines = g_strsplit(spec, "\n", -1);
    int index = 0;
    for (int i = 0; lines[i]; i++) {
        const char *line = lines[i];
        if (strcmp(line, "-") == 0) {
            g_menu_append_section(menu, NULL, G_MENU_MODEL(section));
            g_object_unref(section);
            section = g_menu_new();
            continue;
        }
        if (*line == '\0') continue;
        char *target = g_strdup_printf("%s:%d", prefix ? prefix : "", index++);
        GMenuItem *item = g_menu_item_new(line, NULL);
        g_menu_item_set_action_and_target_value(item, "shell.pick", g_variant_new_string(target));
        g_menu_append_item(section, item);
        g_object_unref(item);
        g_free(target);
    }
    g_strfreev(lines);
    g_menu_append_section(menu, NULL, G_MENU_MODEL(section));
    g_object_unref(section);
    return menu;
}

/// A button that opens a menu, named by its label ("⋯", "More").
static GtkWidget *menu_button(const char *label, const char *css_class, const char *prefix, const char *spec) {
    GtkWidget *btn = gtk_menu_button_new();
    gtk_menu_button_set_label(GTK_MENU_BUTTON(btn), label);
    gtk_menu_button_set_always_show_arrow(GTK_MENU_BUTTON(btn), FALSE);
    GMenu *menu = menu_from_spec(prefix, spec);
    gtk_menu_button_set_menu_model(GTK_MENU_BUTTON(btn), G_MENU_MODEL(menu));
    g_object_unref(menu);
    if (css_class) gtk_widget_add_css_class(btn, css_class);
    wellspent_gtk_set_accessible_name(btn, label);
    return btn;
}

/// A plain button that fires an action id.
static GtkWidget *action_button(WellSpentGtkShell *shell, const char *label, const char *css_class, const char *action_id) {
    GtkWidget *btn = gtk_button_new_with_label(label);
    if (css_class) gtk_widget_add_css_class(btn, css_class);
    g_object_set_data_full(G_OBJECT(btn), "action_id", g_strdup(action_id), g_free);
    g_signal_connect(btn, "clicked", G_CALLBACK(wellspent_gtk_on_btn_clicked), shell);
    return btn;
}

void wellspent_gtk_sidebar_add_invitation(void *shell_ptr, const char *invitation_id,
                                          const char *group_name, const char *invited,
                                          const char *from, const char *terms,
                                          const char *accept_title, const char *reject_title,
                                          int is_responding, const char *failure) {
    WellSpentGtkShell *shell = (WellSpentGtkShell *)shell_ptr;
    if (!shell || !shell->sidebar_content) return;

    GtkWidget *row = gtk_box_new(GTK_ORIENTATION_VERTICAL, 4);
    gtk_widget_add_css_class(row, "ws-invite-row");

    GtkWidget *head = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 8);
    GtkWidget *dot = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 0);
    gtk_widget_add_css_class(dot, "ws-invite-dot");
    gtk_widget_set_valign(dot, GTK_ALIGN_CENTER);
    gtk_box_append(GTK_BOX(head), dot);
    GtkWidget *name = gtk_label_new(group_name ? group_name : "");
    gtk_widget_add_css_class(name, "ws-group-name");
    gtk_label_set_xalign(GTK_LABEL(name), 0);
    gtk_box_append(GTK_BOX(head), name);
    gtk_box_append(GTK_BOX(row), head);

    const char *lines[3] = { invited, from, terms };
    for (int i = 0; i < 3; i++) {
        if (!lines[i]) continue;
        GtkWidget *lbl = gtk_label_new(lines[i]);
        gtk_widget_add_css_class(lbl, "ws-invite-text");
        gtk_label_set_xalign(GTK_LABEL(lbl), 0);
        gtk_label_set_wrap(GTK_LABEL(lbl), TRUE);
        gtk_box_append(GTK_BOX(row), lbl);
    }

    GtkWidget *buttons = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 8);
    char *reject_id = g_strdup_printf("invite:reject:%s", invitation_id ? invitation_id : "");
    char *accept_id = g_strdup_printf("invite:accept:%s", invitation_id ? invitation_id : "");
    GtkWidget *reject = action_button(shell, reject_title, "ws-button", reject_id);
    GtkWidget *accept = action_button(shell, accept_title, "ws-button", accept_id);
    gtk_widget_add_css_class(accept, "primary");
    gtk_widget_set_sensitive(reject, !is_responding);
    gtk_widget_set_sensitive(accept, !is_responding);
    gtk_box_append(GTK_BOX(buttons), reject);
    GtkWidget *spacer = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 0);
    gtk_widget_set_hexpand(spacer, TRUE);
    gtk_box_append(GTK_BOX(buttons), spacer);
    gtk_box_append(GTK_BOX(buttons), accept);
    gtk_box_append(GTK_BOX(row), buttons);
    g_free(reject_id);
    g_free(accept_id);

    if (failure && *failure) {
        GtkWidget *lbl = gtk_label_new(failure);
        gtk_widget_add_css_class(lbl, "ws-sidebar-failure");
        gtk_label_set_xalign(GTK_LABEL(lbl), 0);
        gtk_label_set_wrap(GTK_LABEL(lbl), TRUE);
        gtk_box_append(GTK_BOX(row), lbl);
    }
    gtk_box_append(GTK_BOX(shell->sidebar_content), row);
}

void wellspent_gtk_sidebar_add_group(void *shell_ptr, const char *group_id, const char *title,
                                     const char *toggle_help, int is_page_open, int is_first,
                                     const char *menu_spec) {
    WellSpentGtkShell *shell = (WellSpentGtkShell *)shell_ptr;
    if (!shell || !shell->sidebar_content) return;

    if (!is_first) {
        GtkWidget *div = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 0);
        gtk_widget_add_css_class(div, "ws-sidebar-divider");
        gtk_box_append(GTK_BOX(shell->sidebar_content), div);
    }

    GtkWidget *line = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 6);

    // The name, in capitals, is the button that shows or hides the budgets.
    // The UI tests find a group by its name in capitals; what the button does
    // is its description, as the SwiftCrossUI sidebar says it.
    GtkWidget *btn = gtk_button_new();
    gtk_widget_add_css_class(btn, "ws-group-head");
    if (is_page_open) gtk_widget_add_css_class(btn, "selected");
    gtk_widget_set_hexpand(btn, TRUE);
    GtkWidget *name = gtk_label_new(title ? title : "");
    gtk_widget_add_css_class(name, "ws-group-name");
    gtk_label_set_xalign(GTK_LABEL(name), 0);
    gtk_label_set_ellipsize(GTK_LABEL(name), PANGO_ELLIPSIZE_END);
    gtk_button_set_child(GTK_BUTTON(btn), name);
    wellspent_gtk_set_accessible_name(btn, title);
    if (toggle_help) {
        gtk_accessible_update_property(GTK_ACCESSIBLE(btn), GTK_ACCESSIBLE_PROPERTY_DESCRIPTION, toggle_help, -1);
        gtk_widget_set_tooltip_text(btn, toggle_help);
    }
    char *action_id = g_strdup_printf("group:%s", group_id ? group_id : "");
    g_object_set_data_full(G_OBJECT(btn), "action_id", action_id, g_free);
    g_signal_connect(btn, "clicked", G_CALLBACK(wellspent_gtk_on_btn_clicked), shell);
    gtk_box_append(GTK_BOX(line), btn);

    // GTK has no right-click menu here, so each group has the ⋯ button that
    // opens the menu the Mac shows on a right-click.
    char *prefix = g_strdup_printf("menu:group:%s", group_id ? group_id : "");
    GtkWidget *menu = menu_button("⋯", "ws-group-menu", prefix, menu_spec);
    gtk_widget_set_valign(menu, GTK_ALIGN_CENTER);
    gtk_box_append(GTK_BOX(line), menu);
    g_free(prefix);

    gtk_box_append(GTK_BOX(shell->sidebar_content), line);
}

void wellspent_gtk_sidebar_add_note(void *shell_ptr, const char *text) {
    WellSpentGtkShell *shell = (WellSpentGtkShell *)shell_ptr;
    if (!shell || !shell->sidebar_content || !text) return;
    GtkWidget *lbl = gtk_label_new(text);
    gtk_widget_add_css_class(lbl, "ws-note");
    gtk_label_set_xalign(GTK_LABEL(lbl), 0);
    gtk_label_set_wrap(GTK_LABEL(lbl), TRUE);
    gtk_box_append(GTK_BOX(shell->sidebar_content), lbl);
}

void wellspent_gtk_sidebar_add_budget(void *shell_ptr, const char *budget_id, const char *name,
                                      const char *amount_text, const char *spoken_value,
                                      double share, int is_over, int is_selected) {
    WellSpentGtkShell *shell = (WellSpentGtkShell *)shell_ptr;
    if (!shell || !shell->sidebar_content) return;

    GtkWidget *btn = gtk_button_new();
    gtk_widget_add_css_class(btn, "ws-budget-row");
    if (is_selected) gtk_widget_add_css_class(btn, "selected");

    // The row is the bar: filled from the left as far as the budget is used.
    // The fill is a gradient set on this row alone; the colours are the
    // makeover's (dark fills on the band, the icon's colours on the sticker).
    double pct = share * 100.0;
    if (pct < 0.0) pct = 0.0;
    if (pct > 100.0) pct = 100.0;
    if (pct > 0.0) {
        const char *fill = is_selected ? (is_over ? "#DB7E56" : "#76A24D") : (is_over ? "#8A3A1C" : "#3D5E2E");
        const char *track = is_selected ? "#F4EEDC" : "#242424";
        char css[512];
        snprintf(css, sizeof(css),
                 "button { background-image: linear-gradient(to right, %s 0%%, %s %.1f%%, %s %.1f%%, %s 100%%); }",
                 fill, fill, pct, track, pct, track);
#pragma GCC diagnostic push
#pragma GCC diagnostic ignored "-Wdeprecated-declarations"
        GtkCssProvider *provider = gtk_css_provider_new();
        gtk_css_provider_load_from_string(provider, css);
        gtk_style_context_add_provider(gtk_widget_get_style_context(btn), GTK_STYLE_PROVIDER(provider),
                                       GTK_STYLE_PROVIDER_PRIORITY_APPLICATION + 2);
        g_object_unref(provider);
#pragma GCC diagnostic pop
    }

    GtkWidget *row = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 6);
    GtkWidget *name_lbl = gtk_label_new(name ? name : "");
    gtk_label_set_xalign(GTK_LABEL(name_lbl), 0);
    gtk_label_set_ellipsize(GTK_LABEL(name_lbl), PANGO_ELLIPSIZE_END);
    gtk_widget_set_hexpand(name_lbl, TRUE);
    gtk_box_append(GTK_BOX(row), name_lbl);
    GtkWidget *amt_lbl = gtk_label_new(amount_text ? amount_text : "");
    gtk_widget_add_css_class(amt_lbl, "ws-amount");
    if (is_over) gtk_widget_add_css_class(amt_lbl, "over");
    gtk_label_set_xalign(GTK_LABEL(amt_lbl), 1);
    gtk_box_append(GTK_BOX(row), amt_lbl);
    gtk_button_set_child(GTK_BUTTON(btn), row);

    // Named as the SwiftCrossUI row reads: its name, then what is left. How
    // much is used is its description, and the open one is SELECTED.
    char *spoken_name = g_strdup_printf("%s %s", name ? name : "", amount_text ? amount_text : "");
    wellspent_gtk_set_accessible_name(btn, spoken_name);
    g_free(spoken_name);
    if (spoken_value) {
        gtk_accessible_update_property(GTK_ACCESSIBLE(btn), GTK_ACCESSIBLE_PROPERTY_DESCRIPTION, spoken_value, -1);
    }
    gtk_accessible_update_state(GTK_ACCESSIBLE(btn), GTK_ACCESSIBLE_STATE_SELECTED, is_selected ? TRUE : FALSE, -1);

    char *action_id = g_strdup_printf("budget:%s", budget_id ? budget_id : "");
    g_object_set_data_full(G_OBJECT(btn), "action_id", action_id, g_free);
    g_signal_connect(btn, "clicked", G_CALLBACK(wellspent_gtk_on_btn_clicked), shell);
    gtk_box_append(GTK_BOX(shell->sidebar_content), btn);
}

void wellspent_gtk_sidebar_add_footer(void *shell_ptr, const char *add_title, const char *more_spec,
                                      const char *status_text, const char *failure_text) {
    WellSpentGtkShell *shell = (WellSpentGtkShell *)shell_ptr;
    if (!shell || !shell->sidebar_bottom) return;

    // Like Add List in Reminders: the common action is the button, the rarer
    // ones (New Group…, Join a Group…) are in More.
    GtkWidget *div = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 0);
    gtk_widget_add_css_class(div, "ws-sidebar-divider");
    gtk_box_append(GTK_BOX(shell->sidebar_bottom), div);

    GtkWidget *line = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 8);
    gtk_widget_set_margin_top(line, 4);
    gtk_widget_set_margin_bottom(line, 8);
    GtkWidget *add = action_button(shell, add_title ? add_title : "Add Budget", "ws-button", "action:add_budget");
    gtk_widget_add_css_class(add, "primary");
    gtk_box_append(GTK_BOX(line), add);
    GtkWidget *more = menu_button("More", "ws-button", "menu:add", more_spec);
    gtk_box_append(GTK_BOX(line), more);
    gtk_box_append(GTK_BOX(shell->sidebar_bottom), line);

    GtkWidget *foot = gtk_box_new(GTK_ORIENTATION_VERTICAL, 6);
    gtk_widget_add_css_class(foot, "ws-sidebar-foot");
    GtkWidget *status = gtk_label_new(status_text ? status_text : "");
    shell->sidebar_footer_lbl = status;
    gtk_widget_add_css_class(status, "ws-sidebar-status");
    gtk_label_set_xalign(GTK_LABEL(status), 0);
    gtk_label_set_wrap(GTK_LABEL(status), TRUE);
    gtk_box_append(GTK_BOX(foot), status);
    if (failure_text && *failure_text) {
        GtkWidget *failure = gtk_label_new(failure_text);
        gtk_widget_add_css_class(failure, "ws-sidebar-failure");
        gtk_label_set_xalign(GTK_LABEL(failure), 0);
        gtk_label_set_wrap(GTK_LABEL(failure), TRUE);
        gtk_box_append(GTK_BOX(foot), failure);
    }
    gtk_box_append(GTK_BOX(shell->sidebar_bottom), foot);
}

// A question before a delete, in the shared words: the title, what it says,
// the confirming button and Cancel. The answer goes back as 1 or 0.
typedef struct {
    wellspent_gtk_ask_cb cb;
    void *context;
} AskData;

static void on_ask_answered(GObject *source, GAsyncResult *result, gpointer user_data) {
    AskData *data = (AskData *)user_data;
    int button = gtk_alert_dialog_choose_finish(GTK_ALERT_DIALOG(source), result, NULL);
    // Buttons: 0 Cancel, 1 the confirming one. A closed dialog answers -1.
    if (data && data->cb) data->cb(data->context, button == 1 ? 1 : 0);
    g_free(data);
}

void wellspent_gtk_ask(void *shell_ptr, const char *title, const char *message,
                       const char *confirm_title, const char *cancel_title,
                       wellspent_gtk_ask_cb cb, void *context) {
    WellSpentGtkShell *shell = (WellSpentGtkShell *)shell_ptr;
    if (!shell || !shell->window) return;
    GtkAlertDialog *dialog = gtk_alert_dialog_new("%s", title ? title : "");
    gtk_alert_dialog_set_detail(dialog, message ? message : "");
    const char *buttons[] = { cancel_title ? cancel_title : "Cancel", confirm_title ? confirm_title : "Delete", NULL };
    gtk_alert_dialog_set_buttons(dialog, buttons);
    gtk_alert_dialog_set_cancel_button(dialog, 0);
    gtk_alert_dialog_set_default_button(dialog, 0);
    AskData *data = g_new0(AskData, 1);
    data->cb = cb;
    data->context = context;
    gtk_alert_dialog_choose(dialog, GTK_WINDOW(shell->window), NULL, on_ask_answered, data);
    g_object_unref(dialog);
}
