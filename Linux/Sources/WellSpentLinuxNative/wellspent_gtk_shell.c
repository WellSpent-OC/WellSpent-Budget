#include "wellspent_native.h"
#include <gtk/gtk.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static const char *WELLSPENT_SHELL_CSS =
"window.wellspent-native-window {\n"
"    background-color: #171717;\n"
"    color: #ffffff;\n"
"    font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, Helvetica, Arial, sans-serif;\n"
"}\n"
"\n"
".titlebar-box {\n"
"    background-color: #171717;\n"
"    padding: 6px 14px;\n"
"    border-bottom: 1px solid #292929;\n"
"    min-height: 34px;\n"
"}\n"
"\n"
".brand-label {\n"
"    font-weight: 800;\n"
"    font-size: 15px;\n"
"    color: #F5B731;\n"
"    letter-spacing: 0.5px;\n"
"}\n"
"\n"
".header-subtitle {\n"
"    font-size: 11px;\n"
"    color: #8A8A8A;\n"
"}\n"
"\n"
".activity-rail {\n"
"    background-color: #121212;\n"
"    border-right: 1px solid #292929;\n"
"    padding: 10px 4px;\n"
"    min-width: 52px;\n"
"    max-width: 52px;\n"
"}\n"
"\n"
".rail-btn {\n"
"    background: transparent;\n"
"    border: none;\n"
"    box-shadow: none;\n"
"    border-radius: 6px;\n"
"    padding: 8px;\n"
"    color: #8A8A8A;\n"
"    font-size: 17px;\n"
"    min-width: 40px;\n"
"    min-height: 40px;\n"
"    margin-bottom: 8px;\n"
"    transition: background-color 60ms ease, transform 30ms ease;\n"
"}\n"
"\n"
".rail-btn:hover {\n"
"    background-color: rgba(255, 255, 255, 0.08);\n"
"    color: #ffffff;\n"
"}\n"
"\n"
".rail-btn:active {\n"
"    background-color: rgba(255, 255, 255, 0.20);\n"
"    transform: scale(0.92);\n"
"}\n"
"\n"
".rail-btn.active {\n"
"    background-color: #262626;\n"
"    color: #F5B731;\n"
"    border-left: 3px solid #F5B731;\n"
"    border-radius: 2px 6px 6px 2px;\n"
"}\n"
"\n"
".sidebar-box {\n"
"    background-color: #202020;\n"
"    border-right: 1px solid #292929;\n"
"    padding: 8px;\n"
"    min-width: 210px;\n"
"    max-width: 230px;\n"
"}\n"
"\n"
".group-header-btn {\n"
"    background: transparent;\n"
"    border: none;\n"
"    box-shadow: none;\n"
"    padding: 4px 6px;\n"
"    font-weight: 700;\n"
"    font-size: 9.5px;\n"
"    color: #8A8A8A;\n"
"    border-radius: 4px;\n"
"    margin-top: 6px;\n"
"    margin-bottom: 2px;\n"
"    transition: background-color 40ms ease, transform 20ms ease;\n"
"}\n"
"\n"
".group-header-btn:hover {\n"
"    color: #CCCCCC;\n"
"    background-color: rgba(255, 255, 255, 0.05);\n"
"}\n"
"\n"
".group-header-btn:active {\n"
"    color: #FFFFFF;\n"
"    background-color: rgba(255, 255, 255, 0.15);\n"
"    transform: scale(0.96);\n"
"}\n"
"\n"
".sidebar-divider {\n"
"    background-color: #3D3D3D;\n"
"    min-height: 1px;\n"
"    margin: 8px 4px;\n"
"}\n"
"\n"
".budget-row-btn {\n"
"    border: none;\n"
"    box-shadow: none;\n"
"    border-radius: 8px;\n"
"    padding: 7px 12px;\n"
"    margin: 2px 0;\n"
"    min-height: 32px;\n"
"    transition: transform 30ms ease, filter 40ms ease;\n"
"}\n"
"\n"
".budget-row-btn:hover {\n"
"    filter: brightness(1.1);\n"
"}\n"
"\n"
".budget-row-btn:active {\n"
"    transform: scale(0.96);\n"
"    filter: brightness(1.25);\n"
"}\n"
"\n"
".budget-name {\n"
"    font-size: 13px;\n"
"    font-weight: 500;\n"
"    color: #CCCCCC;\n"
"}\n"
"\n"
".budget-name-selected {\n"
"    font-size: 13px;\n"
"    font-weight: 700;\n"
"    color: #171717;\n"
"}\n"
"\n"
".budget-amount {\n"
"    font-size: 11px;\n"
"    font-family: monospace;\n"
"    color: #8A8A8A;\n"
"}\n"
"\n"
".budget-amount-selected {\n"
"    font-size: 11px;\n"
"    font-family: monospace;\n"
"    font-weight: 700;\n"
"    color: #171717;\n"
"}\n"
"\n"
".budget-amount-over {\n"
"    font-size: 11px;\n"
"    font-family: monospace;\n"
"    font-weight: 600;\n"
"    color: #DB7E56;\n"
"}\n"
"\n"
".detail-pane {\n"
"    background-color: #1F1F1F;\n"
"    padding: 32px;\n"
"}\n"
"\n"
".detail-title {\n"
"    font-size: 24px;\n"
"    font-weight: 700;\n"
"    color: #FFFFFF;\n"
"    margin-bottom: 12px;\n"
"}\n"
"\n"
".detail-subtitle {\n"
"    font-size: 14px;\n"
"    color: #8A8A8A;\n"
"    margin-bottom: 24px;\n"
"}\n"
"\n"
".card-box {\n"
"    background-color: #262626;\n"
"    border-radius: 12px;\n"
"    padding: 24px;\n"
"    border: 1px solid #333333;\n"
"}\n"
"\n"
".footer-text {\n"
"    font-size: 11px;\n"
"    color: #777777;\n"
"    padding: 8px 4px;\n"
"}\n";

typedef struct {
    GtkWidget *window;
    GtkWidget *title_box;
    GtkWidget *title_label;
    GtkWidget *subtitle_label;
    GtkWidget *rail_box;
    GtkWidget *sidebar_scroll;
    GtkWidget *sidebar_content;
    GtkWidget *detail_pane;
    GtkWidget *detail_title;
    GtkWidget *detail_subtitle;
    GtkWidget *detail_stat_left;
    GtkWidget *detail_stat_spent;
    GtkWidget *btn_budgets;
    GtkWidget *btn_runway;
    GtkWidget *btn_sync;
    GtkWidget *btn_account;
    wellspent_gtk_action_cb action_cb;
    void *context;
} WellSpentGtkShell;

static void on_btn_clicked(GtkButton *btn, gpointer user_data) {
    const char *action = g_object_get_data(G_OBJECT(btn), "action_id");
    WellSpentGtkShell *shell = (WellSpentGtkShell *)user_data;
    if (shell && shell->action_cb && action) {
        shell->action_cb(shell->context, action);
    }
}

void wellspent_gtk_init_css(void) {
    static gboolean initialized = FALSE;
    if (initialized) return;
    initialized = TRUE;

    GtkCssProvider *provider = gtk_css_provider_new();
    gtk_css_provider_load_from_string(provider, WELLSPENT_SHELL_CSS);
    GdkDisplay *display = gdk_display_get_default();
    if (display) {
        gtk_style_context_add_provider_for_display(
            display,
            GTK_STYLE_PROVIDER(provider),
            GTK_STYLE_PROVIDER_PRIORITY_APPLICATION
        );
    }
    g_object_unref(provider);
}

void *wellspent_gtk_create_shell_window(void *gtk_app,
                                        const char *title,
                                        const char *team_name,
                                        wellspent_gtk_action_cb on_action,
                                        void *context) {
    wellspent_gtk_init_css();

    WellSpentGtkShell *shell = g_new0(WellSpentGtkShell, 1);
    shell->action_cb = on_action;
    shell->context = context;

    GtkApplication *app = GTK_APPLICATION(gtk_app);
    GtkWidget *win = gtk_application_window_new(app);
    shell->window = win;

    gtk_window_set_title(GTK_WINDOW(win), title ? title : "WellSpent");
    gtk_window_set_default_size(GTK_WINDOW(win), 1100, 720);
    gtk_widget_add_css_class(win, "wellspent-native-window");

    // Root vertical layout: top bar + main content
    GtkWidget *root_vbox = gtk_box_new(GTK_ORIENTATION_VERTICAL, 0);
    gtk_window_set_child(GTK_WINDOW(win), root_vbox);

    // Titlebar
    GtkWidget *titlebar = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 8);
    shell->title_box = titlebar;
    gtk_widget_add_css_class(titlebar, "titlebar-box");

    GtkWidget *brand = gtk_label_new("WELLSPENT");
    gtk_widget_add_css_class(brand, "brand-label");
    gtk_box_append(GTK_BOX(titlebar), brand);

    GtkWidget *title_spacer = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 0);
    gtk_widget_set_hexpand(title_spacer, TRUE);
    gtk_box_append(GTK_BOX(titlebar), title_spacer);

    char sub_buf[256];
    snprintf(sub_buf, sizeof(sub_buf), "%s · Linux desktop (Native GTK 4)", team_name ? team_name : "Demo Team");
    GtkWidget *sub = gtk_label_new(sub_buf);
    shell->subtitle_label = sub;
    gtk_widget_add_css_class(sub, "header-subtitle");
    gtk_box_append(GTK_BOX(titlebar), sub);

    gtk_box_append(GTK_BOX(root_vbox), titlebar);

    // Main horizontal split: Rail + Sidebar + Detail
    GtkWidget *main_hbox = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 0);
    gtk_widget_set_vexpand(main_hbox, TRUE);
    gtk_box_append(GTK_BOX(root_vbox), main_hbox);

    // 1. Activity Rail
    GtkWidget *rail = gtk_box_new(GTK_ORIENTATION_VERTICAL, 0);
    shell->rail_box = rail;
    gtk_widget_add_css_class(rail, "activity-rail");

    GtkWidget *btn_bud = gtk_button_new_with_label("👝");
    shell->btn_budgets = btn_bud;
    gtk_widget_add_css_class(btn_bud, "rail-btn");
    gtk_widget_add_css_class(btn_bud, "active");
    g_object_set_data_full(G_OBJECT(btn_bud), "action_id", g_strdup("tab:budgets"), g_free);
    g_signal_connect(btn_bud, "clicked", G_CALLBACK(on_btn_clicked), shell);
    gtk_box_append(GTK_BOX(rail), btn_bud);

    GtkWidget *btn_run = gtk_button_new_with_label("🎁");
    shell->btn_runway = btn_run;
    gtk_widget_add_css_class(btn_run, "rail-btn");
    g_object_set_data_full(G_OBJECT(btn_run), "action_id", g_strdup("tab:runway"), g_free);
    g_signal_connect(btn_run, "clicked", G_CALLBACK(on_btn_clicked), shell);
    gtk_box_append(GTK_BOX(rail), btn_run);

    GtkWidget *rail_spacer = gtk_box_new(GTK_ORIENTATION_VERTICAL, 0);
    gtk_widget_set_vexpand(rail_spacer, TRUE);
    gtk_box_append(GTK_BOX(rail), rail_spacer);

    GtkWidget *btn_sync = gtk_button_new_with_label("🔄");
    shell->btn_sync = btn_sync;
    gtk_widget_add_css_class(btn_sync, "rail-btn");
    g_object_set_data_full(G_OBJECT(btn_sync), "action_id", g_strdup("action:sync"), g_free);
    g_signal_connect(btn_sync, "clicked", G_CALLBACK(on_btn_clicked), shell);
    gtk_box_append(GTK_BOX(rail), btn_sync);

    GtkWidget *btn_acct = gtk_button_new_with_label("👤");
    shell->btn_account = btn_acct;
    gtk_widget_add_css_class(btn_acct, "rail-btn");
    g_object_set_data_full(G_OBJECT(btn_acct), "action_id", g_strdup("action:account"), g_free);
    g_signal_connect(btn_acct, "clicked", G_CALLBACK(on_btn_clicked), shell);
    gtk_box_append(GTK_BOX(rail), btn_acct);

    gtk_box_append(GTK_BOX(main_hbox), rail);

    // 2. Sidebar (scrolled)
    GtkWidget *scroll = gtk_scrolled_window_new();
    shell->sidebar_scroll = scroll;
    gtk_widget_add_css_class(scroll, "sidebar-box");
    gtk_scrolled_window_set_policy(GTK_SCROLLED_WINDOW(scroll), GTK_POLICY_NEVER, GTK_POLICY_AUTOMATIC);

    GtkWidget *side_content = gtk_box_new(GTK_ORIENTATION_VERTICAL, 2);
    shell->sidebar_content = side_content;
    gtk_scrolled_window_set_child(GTK_SCROLLED_WINDOW(scroll), side_content);
    gtk_box_append(GTK_BOX(main_hbox), scroll);

    // 3. Detail Pane
    GtkWidget *detail = gtk_box_new(GTK_ORIENTATION_VERTICAL, 16);
    shell->detail_pane = detail;
    gtk_widget_add_css_class(detail, "detail-pane");
    gtk_widget_set_hexpand(detail, TRUE);
    gtk_widget_set_vexpand(detail, TRUE);

    GtkWidget *d_title = gtk_label_new("Groceries Budget");
    shell->detail_title = d_title;
    gtk_widget_add_css_class(d_title, "detail-title");
    gtk_widget_set_halign(d_title, GTK_ALIGN_START);
    gtk_box_append(GTK_BOX(detail), d_title);

    GtkWidget *d_sub = gtk_label_new("October · Current month");
    shell->detail_subtitle = d_sub;
    gtk_widget_add_css_class(d_sub, "detail-subtitle");
    gtk_widget_set_halign(d_sub, GTK_ALIGN_START);
    gtk_box_append(GTK_BOX(detail), d_sub);

    GtkWidget *card = gtk_box_new(GTK_ORIENTATION_VERTICAL, 12);
    gtk_widget_add_css_class(card, "card-box");

    GtkWidget *stat_left = gtk_label_new("Left this month: $420.00 of $600.00");
    shell->detail_stat_left = stat_left;
    gtk_widget_set_halign(stat_left, GTK_ALIGN_START);
    gtk_box_append(GTK_BOX(card), stat_left);

    GtkWidget *stat_spent = gtk_label_new("Transactions: 14 recorded this month. Native GTK 4 render active.");
    shell->detail_stat_spent = stat_spent;
    gtk_widget_set_halign(stat_spent, GTK_ALIGN_START);
    gtk_box_append(GTK_BOX(card), stat_spent);

    gtk_box_append(GTK_BOX(detail), card);
    gtk_box_append(GTK_BOX(main_hbox), detail);

    g_object_set_data_full(G_OBJECT(win), "shell_data", shell, g_free);
    return shell;
}

void wellspent_gtk_sidebar_clear(void *shell_ptr) {
    WellSpentGtkShell *shell = (WellSpentGtkShell *)shell_ptr;
    if (!shell || !shell->sidebar_content) return;
    GtkWidget *child = gtk_widget_get_first_child(shell->sidebar_content);
    while (child) {
        GtkWidget *next = gtk_widget_get_next_sibling(child);
        gtk_box_remove(GTK_BOX(shell->sidebar_content), child);
        child = next;
    }
}

void wellspent_gtk_sidebar_add_group(void *shell_ptr,
                                     const char *group_id,
                                     const char *title,
                                     int is_collapsed,
                                     int is_first) {
    WellSpentGtkShell *shell = (WellSpentGtkShell *)shell_ptr;
    if (!shell || !shell->sidebar_content) return;

    if (!is_first) {
        GtkWidget *div = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 0);
        gtk_widget_add_css_class(div, "sidebar-divider");
        gtk_box_append(GTK_BOX(shell->sidebar_content), div);
    }

    char label_buf[256];
    snprintf(label_buf, sizeof(label_buf), "%s", title ? title : "");

    GtkWidget *btn = gtk_button_new_with_label(label_buf);
    gtk_widget_add_css_class(btn, "group-header-btn");
    gtk_widget_set_halign(btn, GTK_ALIGN_START);

    char act_buf[256];
    snprintf(act_buf, sizeof(act_buf), "group:%s", group_id ? group_id : "");
    g_object_set_data_full(G_OBJECT(btn), "action_id", g_strdup(act_buf), g_free);
    g_signal_connect(btn, "clicked", G_CALLBACK(on_btn_clicked), shell);

    gtk_box_append(GTK_BOX(shell->sidebar_content), btn);
}

void wellspent_gtk_sidebar_add_budget(void *shell_ptr,
                                      const char *budget_id,
                                      const char *name,
                                      const char *amount_text,
                                      double share,
                                      int is_over,
                                      int is_selected) {
    WellSpentGtkShell *shell = (WellSpentGtkShell *)shell_ptr;
    if (!shell || !shell->sidebar_content) return;

    GtkWidget *btn = gtk_button_new();
    gtk_widget_add_css_class(btn, "budget-row-btn");

    if (is_selected) {
        gtk_widget_add_css_class(btn, "selected");
    }

    // Dynamic gradient background based on fill.share:
    // Capped 0.0 to 1.0
    double pct = share * 100.0;
    if (pct < 0.0) pct = 0.0;
    if (pct > 100.0) pct = 100.0;

    char css_buf[512];
    if (is_selected) {
        if (pct > 0.0) {
            const char *col = is_over ? "#DB7E56" : "#76A24D";
            snprintf(css_buf, sizeof(css_buf),
                     "button.budget-row-btn { background: linear-gradient(to right, %s 0%%, %s %.1f%%, #F4EEDC %.1f%%, #F4EEDC 100%%); }",
                     col, col, pct, pct);
        } else {
            snprintf(css_buf, sizeof(css_buf), "button.budget-row-btn { background: #F4EEDC; }");
        }
    } else {
        if (pct > 0.0) {
            const char *col = is_over ? "#8A3A1C" : "#3D5E2E";
            snprintf(css_buf, sizeof(css_buf),
                     "button.budget-row-btn { background: linear-gradient(to right, %s 0%%, %s %.1f%%, #242424 %.1f%%, #242424 100%%); }",
                     col, col, pct, pct);
        } else {
            snprintf(css_buf, sizeof(css_buf), "button.budget-row-btn { background: #242424; }");
        }
    }

    GtkCssProvider *btn_provider = gtk_css_provider_new();
    gtk_css_provider_load_from_string(btn_provider, css_buf);
    gtk_style_context_add_provider(
        gtk_widget_get_style_context(btn),
        GTK_STYLE_PROVIDER(btn_provider),
        GTK_STYLE_PROVIDER_PRIORITY_APPLICATION + 1
    );
    g_object_unref(btn_provider);

    // Inner horizontal row layout: name on left, amount on right
    GtkWidget *row_box = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 6);

    GtkWidget *name_lbl = gtk_label_new(name ? name : "");
    gtk_widget_add_css_class(name_lbl, is_selected ? "budget-name-selected" : "budget-name");
    gtk_widget_set_halign(name_lbl, GTK_ALIGN_START);
    gtk_box_append(GTK_BOX(row_box), name_lbl);

    GtkWidget *spacer = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 0);
    gtk_widget_set_hexpand(spacer, TRUE);
    gtk_box_append(GTK_BOX(row_box), spacer);

    GtkWidget *amt_lbl = gtk_label_new(amount_text ? amount_text : "");
    if (is_selected) {
        gtk_widget_add_css_class(amt_lbl, "budget-amount-selected");
    } else if (is_over) {
        gtk_widget_add_css_class(amt_lbl, "budget-amount-over");
    } else {
        gtk_widget_add_css_class(amt_lbl, "budget-amount");
    }
    gtk_widget_set_halign(amt_lbl, GTK_ALIGN_END);
    gtk_box_append(GTK_BOX(row_box), amt_lbl);

    gtk_button_set_child(GTK_BUTTON(btn), row_box);

    char act_buf[256];
    snprintf(act_buf, sizeof(act_buf), "budget:%s", budget_id ? budget_id : "");
    g_object_set_data_full(G_OBJECT(btn), "action_id", g_strdup(act_buf), g_free);
    g_signal_connect(btn, "clicked", G_CALLBACK(on_btn_clicked), shell);

    gtk_box_append(GTK_BOX(shell->sidebar_content), btn);
}

void wellspent_gtk_sidebar_add_footer(void *shell_ptr, const char *status_text) {
    WellSpentGtkShell *shell = (WellSpentGtkShell *)shell_ptr;
    if (!shell || !shell->sidebar_content) return;

    GtkWidget *spacer = gtk_box_new(GTK_ORIENTATION_VERTICAL, 0);
    gtk_widget_set_vexpand(spacer, TRUE);
    gtk_box_append(GTK_BOX(shell->sidebar_content), spacer);

    GtkWidget *lbl = gtk_label_new(status_text ? status_text : "Syncs through WellSpent's server");
    gtk_widget_add_css_class(lbl, "footer-text");
    gtk_widget_set_halign(lbl, GTK_ALIGN_START);
    gtk_box_append(GTK_BOX(shell->sidebar_content), lbl);
}

void wellspent_gtk_update_detail(void *shell_ptr,
                                 const char *budget_name,
                                 const char *spent_text,
                                 const char *left_text,
                                 const char *pace_text,
                                 double share,
                                 int is_over) {
    WellSpentGtkShell *shell = (WellSpentGtkShell *)shell_ptr;
    if (!shell) return;

    if (shell->detail_title && budget_name) {
        char buf[256];
        snprintf(buf, sizeof(buf), "%s Budget", budget_name);
        gtk_label_set_text(GTK_LABEL(shell->detail_title), buf);
    }
    if (shell->detail_stat_left && left_text) {
        gtk_label_set_text(GTK_LABEL(shell->detail_stat_left), left_text);
    }
    if (shell->detail_stat_spent && spent_text) {
        gtk_label_set_text(GTK_LABEL(shell->detail_stat_spent), spent_text);
    }
}

void wellspent_gtk_window_present(void *shell_ptr) {
    WellSpentGtkShell *shell = (WellSpentGtkShell *)shell_ptr;
    if (shell && shell->window) {
        gtk_window_present(GTK_WINDOW(shell->window));
    }
}
