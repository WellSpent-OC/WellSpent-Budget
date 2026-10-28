#include "wellspent_native.h"
#include <gtk/gtk.h>
#include <math.h>
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
"    min-width: 220px;\n"
"    max-width: 240px;\n"
"}\n"
"\n"
".group-header-btn {\n"
"    background: transparent;\n"
"    border: none;\n"
"    box-shadow: none;\n"
"    padding: 6px 8px;\n"
"    font-weight: 700;\n"
"    font-size: 10px;\n"
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
".sidebar-add-btn {\n"
"    background: rgba(255, 255, 255, 0.05);\n"
"    color: #F5B731;\n"
"    font-size: 12px;\n"
"    font-weight: 600;\n"
"    border-radius: 6px;\n"
"    padding: 8px 10px;\n"
"    margin: 8px 0 4px 0;\n"
"    border: 1px dashed rgba(245, 183, 49, 0.35);\n"
"    transition: background-color 40ms ease, transform 20ms ease;\n"
"}\n"
"\n"
".sidebar-add-btn:hover {\n"
"    background: rgba(245, 183, 49, 0.12);\n"
"    color: #FFC94D;\n"
"}\n"
"\n"
".sidebar-add-btn:active {\n"
"    transform: scale(0.96);\n"
"}\n"
"\n"
".footer-text {\n"
"    font-size: 11px;\n"
"    color: #777777;\n"
"    padding: 8px 4px;\n"
"}\n"
"\n"
".detail-pane {\n"
"    background-color: #1A1A1A;\n"
"    padding: 24px 32px;\n"
"}\n"
"\n"
".detail-title {\n"
"    font-size: 24px;\n"
"    font-weight: 700;\n"
"    color: #FFFFFF;\n"
"}\n"
"\n"
".detail-subtitle {\n"
"    font-size: 13px;\n"
"    color: #8A8A8A;\n"
"    margin-top: 2px;\n"
"}\n"
"\n"
".add-trans-btn {\n"
"    background: #F5B731;\n"
"    color: #171717;\n"
"    font-weight: 700;\n"
"    font-size: 12px;\n"
"    border-radius: 6px;\n"
"    padding: 7px 16px;\n"
"    border: none;\n"
"    transition: background-color 40ms ease, transform 20ms ease;\n"
"}\n"
"\n"
".add-trans-btn:hover {\n"
"    background: #FFC94D;\n"
"}\n"
"\n"
".add-trans-btn:active {\n"
"    background: #D99B1A;\n"
"    transform: scale(0.96);\n"
"}\n"
"\n"
".card-box {\n"
"    background-color: #242424;\n"
"    border-radius: 12px;\n"
"    padding: 16px 20px;\n"
"    border: 1px solid #333333;\n"
"}\n"
"\n"
".wheel-mid-key {\n"
"    font-size: 11px;\n"
"    font-weight: 600;\n"
"    color: #8A8A8A;\n"
"    text-transform: uppercase;\n"
"    letter-spacing: 0.5px;\n"
"}\n"
"\n"
".wheel-mid-amount {\n"
"    font-size: 24px;\n"
"    font-weight: 700;\n"
"    font-family: monospace;\n"
"    color: #FFFFFF;\n"
"}\n"
"\n"
".wheel-mid-of {\n"
"    font-size: 11px;\n"
"    color: #8A8A8A;\n"
"}\n"
"\n"
".wheel-pace {\n"
"    font-size: 13px;\n"
"    color: #CCCCCC;\n"
"    margin-top: 6px;\n"
"}\n"
"\n"
".table-header {\n"
"    font-size: 10px;\n"
"    font-weight: 700;\n"
"    color: #777777;\n"
"    padding: 6px 10px;\n"
"    border-bottom: 1px solid #333333;\n"
"}\n"
"\n"
".transaction-row {\n"
"    padding: 8px 10px;\n"
"    border-bottom: 1px solid #282828;\n"
"    border-radius: 4px;\n"
"    transition: background-color 30ms ease;\n"
"}\n"
"\n"
".transaction-row:hover {\n"
"    background-color: rgba(255, 255, 255, 0.04);\n"
"}\n"
"\n"
".tx-date {\n"
"    font-size: 12px;\n"
"    color: #8A8A8A;\n"
"    min-width: 80px;\n"
"}\n"
"\n"
".tx-merchant {\n"
"    font-size: 13px;\n"
"    color: #EEEEEE;\n"
"}\n"
"\n"
".tx-source {\n"
"    font-size: 11px;\n"
"    color: #666666;\n"
"    min-width: 80px;\n"
"}\n"
"\n"
".tx-amount {\n"
"    font-size: 13px;\n"
"    font-family: monospace;\n"
"    font-weight: 600;\n"
"    color: #FFFFFF;\n"
"    min-width: 80px;\n"
"}\n"
"\n"
".catalog-pane {\n"
"    background-color: #1A1A1A;\n"
"    padding: 28px 36px;\n"
"}\n"
"\n"
".catalog-title {\n"
"    font-size: 26px;\n"
"    font-weight: 700;\n"
"    color: #FFFFFF;\n"
"}\n"
"\n"
".catalog-desc {\n"
"    font-size: 13px;\n"
"    color: #8A8A8A;\n"
"    margin-top: 4px;\n"
"    margin-bottom: 24px;\n"
"}\n"
"\n"
".ext-card {\n"
"    background-color: #242424;\n"
"    border-radius: 12px;\n"
"    padding: 18px;\n"
"    margin-bottom: 14px;\n"
"    border: 1px solid #333333;\n"
"}\n"
"\n"
".ext-card-title {\n"
"    font-size: 16px;\n"
"    font-weight: 700;\n"
"    color: #FFFFFF;\n"
"}\n"
"\n"
".ext-tag-free {\n"
"    font-size: 11px;\n"
"    font-weight: 700;\n"
"    color: #F5B731;\n"
"    background: rgba(245, 183, 49, 0.15);\n"
"    padding: 3px 8px;\n"
"    border-radius: 4px;\n"
"}\n"
"\n"
".ext-tag-avail {\n"
"    font-size: 11px;\n"
"    font-weight: 700;\n"
"    color: #5E9CE6;\n"
"    background: rgba(94, 156, 230, 0.15);\n"
"    padding: 3px 8px;\n"
"    border-radius: 4px;\n"
"}\n"
"\n"
".ext-desc {\n"
"    font-size: 13px;\n"
"    color: #AAAAAA;\n"
"    margin: 8px 0 12px 0;\n"
"}\n"
"\n"
".ext-btn {\n"
"    background: rgba(255, 255, 255, 0.08);\n"
"    color: #FFFFFF;\n"
"    font-size: 12px;\n"
"    font-weight: 600;\n"
"    border-radius: 6px;\n"
"    padding: 6px 14px;\n"
"    border: none;\n"
"}\n"
"\n"
".ext-btn:hover {\n"
"    background: rgba(255, 255, 255, 0.15);\n"
"}\n"
"\n"
".wellspent-modal-dialog {\n"
"    background-color: #202020;\n"
"    color: #FFFFFF;\n"
"}\n"
"\n"
".modal-title {\n"
"    font-size: 17px;\n"
"    font-weight: 700;\n"
"    color: #FFFFFF;\n"
"    margin-bottom: 14px;\n"
"}\n"
"\n"
".modal-label {\n"
"    font-size: 12px;\n"
"    font-weight: 600;\n"
"    color: #AAAAAA;\n"
"    margin-bottom: 4px;\n"
"}\n"
"\n"
".modal-entry {\n"
"    background-color: #171717;\n"
"    color: #FFFFFF;\n"
"    border: 1px solid #383838;\n"
"    border-radius: 6px;\n"
"    padding: 8px 10px;\n"
"    font-size: 13px;\n"
"    margin-bottom: 12px;\n"
"}\n"
"\n"
".modal-entry:focus {\n"
"    border-color: #F5B731;\n"
"}\n"
"\n"
".accent-action-btn {\n"
"    background: #F5B731;\n"
"    color: #171717;\n"
"    font-weight: 700;\n"
"    font-size: 13px;\n"
"    border-radius: 6px;\n"
"    padding: 7px 18px;\n"
"    border: none;\n"
"}\n"
"\n"
".accent-action-btn:hover {\n"
"    background: #FFC94D;\n"
"}\n"
"\n"
".modal-cancel-btn {\n"
"    background: transparent;\n"
"    color: #CCCCCC;\n"
"    font-size: 13px;\n"
"    border-radius: 6px;\n"
"    padding: 7px 14px;\n"
"    border: 1px solid #444444;\n"
"    margin-right: 8px;\n"
"}\n"
"\n"
".modal-cancel-btn:hover {\n"
"    background: rgba(255, 255, 255, 0.08);\n"
"    color: #FFFFFF;\n"
"}\n";

typedef struct {
    GtkWidget *window;
    GtkWidget *title_box;
    GtkWidget *title_label;
    GtkWidget *subtitle_label;
    
    // Rail
    GtkWidget *rail_box;
    GtkWidget *btn_budgets;
    GtkWidget *btn_runway;
    GtkWidget *btn_wartable;
    GtkWidget *btn_catalog;
    GtkWidget *btn_sync;
    GtkWidget *btn_account;
    
    // Sidebar
    GtkWidget *sidebar_scroll;
    GtkWidget *sidebar_content;
    GtkWidget *sidebar_footer_lbl;
    
    // Content Stack
    GtkWidget *content_stack;
    
    // Budget Detail View
    GtkWidget *detail_pane;
    GtkWidget *detail_title;
    GtkWidget *detail_subtitle;
    GtkWidget *btn_add_tx;
    
    // Money Wheel
    GtkWidget *wheel_drawing_area;
    GtkWidget *wheel_mid_key;
    GtkWidget *wheel_mid_amount;
    GtkWidget *wheel_mid_of;
    GtkWidget *wheel_pace_lbl;
    double wheel_arc;
    double wheel_tick;
    int wheel_is_over;
    
    // Transactions
    GtkWidget *tx_scroll;
    GtkWidget *tx_box;
    GtkWidget *tx_count_lbl;
    
    // Extensions Catalog View
    GtkWidget *catalog_pane;
    
    wellspent_gtk_action_cb action_cb;
    void *context;
} WellSpentGtkShell;

static void on_window_destroy(GtkWidget *win, gpointer user_data) {
    WellSpentGtkShell *shell = (WellSpentGtkShell *)user_data;
    if (!shell) return;
    wellspent_gtk_action_cb cb = shell->action_cb;
    void *context = shell->context;
    // Every widget belonged to the window, so none of these may be touched again.
    WellSpentGtkShell cleared = {0};
    cleared.wheel_arc = shell->wheel_arc;
    *shell = cleared;
    if (cb) cb(context, "window:destroyed");
}

/// Screen readers and the UI tests find a control by its name and role. A
/// rail button shows a glyph, so its name is set here, in the same words the
/// SwiftCrossUI rail uses.
static void set_accessible_name(GtkWidget *widget, const char *name) {
    if (!widget || !name) return;
    gtk_accessible_update_property(GTK_ACCESSIBLE(widget), GTK_ACCESSIBLE_PROPERTY_LABEL, name, -1);
}

static void on_btn_clicked(GtkButton *btn, gpointer user_data) {
    const char *action = g_object_get_data(G_OBJECT(btn), "action_id");
    WellSpentGtkShell *shell = (WellSpentGtkShell *)user_data;
    if (shell && shell->action_cb && action) {
        shell->action_cb(shell->context, action);
    }
}

static void on_draw_wheel(GtkDrawingArea *area, cairo_t *cr, int width, int height, gpointer user_data) {
    WellSpentGtkShell *shell = (WellSpentGtkShell *)user_data;
    if (!shell) return;

    double cx = width / 2.0;
    double cy = height / 2.0;
    double radius = (width < height ? width : height) / 2.0 - 18.0;
    if (radius < 15.0) return;

    // Background track ring
    cairo_set_line_width(cr, 14.0);
    cairo_set_source_rgba(cr, 0.22, 0.22, 0.22, 1.0);
    cairo_arc(cr, cx, cy, radius, 0, 2.0 * M_PI);
    cairo_stroke(cr);

    // Inner and outer border rings
    cairo_set_line_width(cr, 1.0);
    cairo_set_source_rgba(cr, 0.30, 0.30, 0.30, 1.0);
    cairo_arc(cr, cx, cy, radius - 7.0, 0, 2.0 * M_PI);
    cairo_stroke(cr);
    cairo_arc(cr, cx, cy, radius + 7.0, 0, 2.0 * M_PI);
    cairo_stroke(cr);

    // Arc fill
    if (shell->wheel_arc > 0.0) {
        if (shell->wheel_is_over) {
            cairo_set_source_rgba(cr, 0.859, 0.494, 0.337, 1.0);
        } else {
            cairo_set_source_rgba(cr, 0.463, 0.635, 0.302, 1.0);
        }
        cairo_set_line_width(cr, 14.0);
        double start_angle = -M_PI / 2.0;
        double end_angle = start_angle + (shell->wheel_arc * 2.0 * M_PI);
        cairo_arc(cr, cx, cy, radius, start_angle, end_angle);
        cairo_stroke(cr);
    }

    // Pace tick line
    if (shell->wheel_tick >= 0.0) {
        double angle = -M_PI / 2.0 + (shell->wheel_tick * 2.0 * M_PI);
        double r_in = radius - 10.0;
        double r_out = radius + 10.0;
        cairo_set_line_width(cr, 2.5);
        cairo_set_source_rgba(cr, 0.95, 0.95, 0.95, 0.95);
        cairo_move_to(cr, cx + r_in * cos(angle), cy + r_in * sin(angle));
        cairo_line_to(cr, cx + r_out * cos(angle), cy + r_out * sin(angle));
        cairo_stroke(cr);
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
    gtk_window_set_default_size(GTK_WINDOW(win), 1140, 740);
    gtk_widget_add_css_class(win, "wellspent-native-window");

    // Root vbox
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
    snprintf(sub_buf, sizeof(sub_buf), "%s · Linux desktop", team_name ? team_name : "Demo Team");
    GtkWidget *sub = gtk_label_new(sub_buf);
    shell->subtitle_label = sub;
    gtk_widget_add_css_class(sub, "header-subtitle");
    gtk_box_append(GTK_BOX(titlebar), sub);

    gtk_box_append(GTK_BOX(root_vbox), titlebar);

    // Main horizontal layout: Rail + Sidebar + Content Stack
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
    gtk_widget_set_tooltip_text(btn_bud, "Budgets");
    g_object_set_data_full(G_OBJECT(btn_bud), "action_id", g_strdup("tab:budgets"), g_free);
    set_accessible_name(btn_bud, "Budget");
    g_signal_connect(btn_bud, "clicked", G_CALLBACK(on_btn_clicked), shell);
    gtk_box_append(GTK_BOX(rail), btn_bud);

    GtkWidget *btn_run = gtk_button_new_with_label("🏡");
    shell->btn_runway = btn_run;
    gtk_widget_add_css_class(btn_run, "rail-btn");
    gtk_widget_set_tooltip_text(btn_run, "Runway & Properties");
    g_object_set_data_full(G_OBJECT(btn_run), "action_id", g_strdup("tab:runway"), g_free);
    set_accessible_name(btn_run, "Properties");
    g_signal_connect(btn_run, "clicked", G_CALLBACK(on_btn_clicked), shell);
    gtk_box_append(GTK_BOX(rail), btn_run);

    GtkWidget *btn_wt = gtk_button_new_with_label("⚔");
    shell->btn_wartable = btn_wt;
    gtk_widget_add_css_class(btn_wt, "rail-btn");
    gtk_widget_set_tooltip_text(btn_wt, "WarTable");
    g_object_set_data_full(G_OBJECT(btn_wt), "action_id", g_strdup("tab:wartable"), g_free);
    set_accessible_name(btn_wt, "WarTable");
    g_signal_connect(btn_wt, "clicked", G_CALLBACK(on_btn_clicked), shell);
    gtk_box_append(GTK_BOX(rail), btn_wt);

    GtkWidget *btn_cat = gtk_button_new_with_label("⬚");
    shell->btn_catalog = btn_cat;
    gtk_widget_add_css_class(btn_cat, "rail-btn");
    gtk_widget_set_tooltip_text(btn_cat, "Extensions Catalog");
    g_object_set_data_full(G_OBJECT(btn_cat), "action_id", g_strdup("tab:catalog"), g_free);
    set_accessible_name(btn_cat, "Extensions");
    g_signal_connect(btn_cat, "clicked", G_CALLBACK(on_btn_clicked), shell);
    gtk_box_append(GTK_BOX(rail), btn_cat);

    GtkWidget *rail_spacer = gtk_box_new(GTK_ORIENTATION_VERTICAL, 0);
    gtk_widget_set_vexpand(rail_spacer, TRUE);
    gtk_box_append(GTK_BOX(rail), rail_spacer);

    GtkWidget *btn_sync = gtk_button_new_with_label("🔄");
    shell->btn_sync = btn_sync;
    gtk_widget_add_css_class(btn_sync, "rail-btn");
    gtk_widget_set_tooltip_text(btn_sync, "Sync now");
    g_object_set_data_full(G_OBJECT(btn_sync), "action_id", g_strdup("action:sync"), g_free);
    set_accessible_name(btn_sync, "Sync");
    g_signal_connect(btn_sync, "clicked", G_CALLBACK(on_btn_clicked), shell);
    gtk_box_append(GTK_BOX(rail), btn_sync);

    GtkWidget *btn_acct = gtk_button_new_with_label("👤");
    shell->btn_account = btn_acct;
    gtk_widget_add_css_class(btn_acct, "rail-btn");
    gtk_widget_set_tooltip_text(btn_acct, "Account");
    g_object_set_data_full(G_OBJECT(btn_acct), "action_id", g_strdup("action:account"), g_free);
    set_accessible_name(btn_acct, "Account");
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

    // 3. Content Stack (switches between Budgets detail and Extensions catalog)
    GtkWidget *stack = gtk_stack_new();
    shell->content_stack = stack;
    gtk_widget_set_hexpand(stack, TRUE);
    gtk_widget_set_vexpand(stack, TRUE);
    gtk_stack_set_transition_type(GTK_STACK(stack), GTK_STACK_TRANSITION_TYPE_CROSSFADE);

    // Page 0: Budgets Detail Pane
    GtkWidget *detail = gtk_box_new(GTK_ORIENTATION_VERTICAL, 16);
    shell->detail_pane = detail;
    gtk_widget_add_css_class(detail, "detail-pane");

    // Header row: Title + Subtitle on left, + Add Transaction on right
    GtkWidget *head_row = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 12);
    
    GtkWidget *title_vbox = gtk_box_new(GTK_ORIENTATION_VERTICAL, 2);
    GtkWidget *d_title = gtk_label_new("Groceries");
    shell->detail_title = d_title;
    gtk_widget_add_css_class(d_title, "detail-title");
    gtk_widget_set_halign(d_title, GTK_ALIGN_START);
    gtk_box_append(GTK_BOX(title_vbox), d_title);

    GtkWidget *d_sub = gtk_label_new("October · Current month");
    shell->detail_subtitle = d_sub;
    gtk_widget_add_css_class(d_sub, "detail-subtitle");
    gtk_widget_set_halign(d_sub, GTK_ALIGN_START);
    gtk_box_append(GTK_BOX(title_vbox), d_sub);
    gtk_box_append(GTK_BOX(head_row), title_vbox);

    GtkWidget *head_spacer = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 0);
    gtk_widget_set_hexpand(head_spacer, TRUE);
    gtk_box_append(GTK_BOX(head_row), head_spacer);

    GtkWidget *btn_add_tx = gtk_button_new_with_label("+ Add Transaction");
    shell->btn_add_tx = btn_add_tx;
    gtk_widget_add_css_class(btn_add_tx, "add-trans-btn");
    gtk_widget_set_valign(btn_add_tx, GTK_ALIGN_CENTER);
    g_object_set_data_full(G_OBJECT(btn_add_tx), "action_id", g_strdup("action:new_transaction"), g_free);
    g_signal_connect(btn_add_tx, "clicked", G_CALLBACK(on_btn_clicked), shell);
    gtk_box_append(GTK_BOX(head_row), btn_add_tx);

    gtk_box_append(GTK_BOX(detail), head_row);

    // Money Wheel Card Box
    GtkWidget *wheel_card = gtk_box_new(GTK_ORIENTATION_VERTICAL, 8);
    gtk_widget_add_css_class(wheel_card, "card-box");

    GtkWidget *wheel_overlay = gtk_overlay_new();
    gtk_widget_set_halign(wheel_overlay, GTK_ALIGN_CENTER);

    GtkWidget *draw_area = gtk_drawing_area_new();
    shell->wheel_drawing_area = draw_area;
    gtk_widget_set_size_request(draw_area, 200, 200);
    gtk_drawing_area_set_draw_func(GTK_DRAWING_AREA(draw_area), on_draw_wheel, shell, NULL);
    gtk_overlay_set_child(GTK_OVERLAY(wheel_overlay), draw_area);

    // Center overlay inside money wheel
    GtkWidget *center_vbox = gtk_box_new(GTK_ORIENTATION_VERTICAL, 2);
    gtk_widget_set_halign(center_vbox, GTK_ALIGN_CENTER);
    gtk_widget_set_valign(center_vbox, GTK_ALIGN_CENTER);

    GtkWidget *lbl_key = gtk_label_new("Remaining");
    shell->wheel_mid_key = lbl_key;
    gtk_widget_add_css_class(lbl_key, "wheel-mid-key");
    gtk_box_append(GTK_BOX(center_vbox), lbl_key);

    GtkWidget *lbl_amt = gtk_label_new("$420.00");
    shell->wheel_mid_amount = lbl_amt;
    gtk_widget_add_css_class(lbl_amt, "wheel-mid-amount");
    gtk_box_append(GTK_BOX(center_vbox), lbl_amt);

    GtkWidget *lbl_of = gtk_label_new("of $600.00");
    shell->wheel_mid_of = lbl_of;
    gtk_widget_add_css_class(lbl_of, "wheel-mid-of");
    gtk_box_append(GTK_BOX(center_vbox), lbl_of);

    gtk_overlay_add_overlay(GTK_OVERLAY(wheel_overlay), center_vbox);
    gtk_box_append(GTK_BOX(wheel_card), wheel_overlay);

    GtkWidget *lbl_pace = gtk_label_new("On track to stay within budget");
    shell->wheel_pace_lbl = lbl_pace;
    gtk_widget_add_css_class(lbl_pace, "wheel-pace");
    gtk_widget_set_halign(lbl_pace, GTK_ALIGN_CENTER);
    gtk_box_append(GTK_BOX(wheel_card), lbl_pace);

    gtk_box_append(GTK_BOX(detail), wheel_card);

    // Transactions Card Box
    GtkWidget *tx_card = gtk_box_new(GTK_ORIENTATION_VERTICAL, 6);
    gtk_widget_add_css_class(tx_card, "card-box");
    gtk_widget_set_vexpand(tx_card, TRUE);

    GtkWidget *tx_head_row = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 8);
    GtkWidget *tx_title = gtk_label_new("Transactions");
    gtk_widget_add_css_class(tx_title, "ext-card-title");
    gtk_box_append(GTK_BOX(tx_head_row), tx_title);

    GtkWidget *tx_head_sp = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 0);
    gtk_widget_set_hexpand(tx_head_sp, TRUE);
    gtk_box_append(GTK_BOX(tx_head_row), tx_head_sp);

    GtkWidget *tx_count = gtk_label_new("0 entries");
    shell->tx_count_lbl = tx_count;
    gtk_widget_add_css_class(tx_count, "detail-subtitle");
    gtk_box_append(GTK_BOX(tx_head_row), tx_count);

    gtk_box_append(GTK_BOX(tx_card), tx_head_row);

    // Table Column Headers
    GtkWidget *th_row = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 8);
    gtk_widget_add_css_class(th_row, "table-header");

    GtkWidget *th_date = gtk_label_new("DATE");
    gtk_widget_set_halign(th_date, GTK_ALIGN_START);
    gtk_widget_add_css_class(th_date, "tx-date");
    gtk_box_append(GTK_BOX(th_row), th_date);

    GtkWidget *th_merch = gtk_label_new("MERCHANT");
    gtk_widget_set_halign(th_merch, GTK_ALIGN_START);
    gtk_widget_set_hexpand(th_merch, TRUE);
    gtk_box_append(GTK_BOX(th_row), th_merch);

    GtkWidget *th_src = gtk_label_new("SOURCE");
    gtk_widget_set_halign(th_src, GTK_ALIGN_START);
    gtk_widget_add_css_class(th_src, "tx-source");
    gtk_box_append(GTK_BOX(th_row), th_src);

    GtkWidget *th_amt = gtk_label_new("AMOUNT");
    gtk_widget_set_halign(th_amt, GTK_ALIGN_END);
    gtk_widget_add_css_class(th_amt, "tx-amount");
    gtk_box_append(GTK_BOX(th_row), th_amt);

    gtk_box_append(GTK_BOX(tx_card), th_row);

    // Scrolled list of transactions
    GtkWidget *tx_scroll = gtk_scrolled_window_new();
    shell->tx_scroll = tx_scroll;
    gtk_widget_set_vexpand(tx_scroll, TRUE);
    gtk_scrolled_window_set_policy(GTK_SCROLLED_WINDOW(tx_scroll), GTK_POLICY_NEVER, GTK_POLICY_AUTOMATIC);

    GtkWidget *tx_box = gtk_box_new(GTK_ORIENTATION_VERTICAL, 2);
    shell->tx_box = tx_box;
    gtk_scrolled_window_set_child(GTK_SCROLLED_WINDOW(tx_scroll), tx_box);
    gtk_box_append(GTK_BOX(tx_card), tx_scroll);

    gtk_box_append(GTK_BOX(detail), tx_card);

    gtk_stack_add_named(GTK_STACK(stack), detail, "budgets");

    // Page 1: Extensions Catalog Pane
    GtkWidget *catalog = gtk_box_new(GTK_ORIENTATION_VERTICAL, 0);
    shell->catalog_pane = catalog;
    gtk_widget_add_css_class(catalog, "catalog-pane");

    GtkWidget *c_title = gtk_label_new("Extensions");
    gtk_widget_add_css_class(c_title, "catalog-title");
    gtk_widget_set_halign(c_title, GTK_ALIGN_START);
    gtk_box_append(GTK_BOX(catalog), c_title);

    GtkWidget *c_desc = gtk_label_new("Add what your life needs. Turn any extension off again, whenever you like.");
    gtk_widget_add_css_class(c_desc, "catalog-desc");
    gtk_widget_set_halign(c_desc, GTK_ALIGN_START);
    gtk_box_append(GTK_BOX(catalog), c_desc);

    GtkWidget *c_scroll = gtk_scrolled_window_new();
    gtk_widget_set_vexpand(c_scroll, TRUE);
    gtk_scrolled_window_set_policy(GTK_SCROLLED_WINDOW(c_scroll), GTK_POLICY_NEVER, GTK_POLICY_AUTOMATIC);

    GtkWidget *c_list = gtk_box_new(GTK_ORIENTATION_VERTICAL, 14);
    gtk_scrolled_window_set_child(GTK_SCROLLED_WINDOW(c_scroll), c_list);

    // Card 1: Budgets
    GtkWidget *card1 = gtk_box_new(GTK_ORIENTATION_VERTICAL, 8);
    gtk_widget_add_css_class(card1, "ext-card");

    GtkWidget *c1_head = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 8);
    GtkWidget *c1_t = gtk_label_new("Budgets");
    gtk_widget_add_css_class(c1_t, "ext-card-title");
    gtk_box_append(GTK_BOX(c1_head), c1_t);

    GtkWidget *c1_sp = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 0);
    gtk_widget_set_hexpand(c1_sp, TRUE);
    gtk_box_append(GTK_BOX(c1_head), c1_sp);

    GtkWidget *c1_tag = gtk_label_new("Included Free");
    gtk_widget_add_css_class(c1_tag, "ext-tag-free");
    gtk_box_append(GTK_BOX(c1_head), c1_tag);
    gtk_box_append(GTK_BOX(card1), c1_head);

    GtkWidget *c1_desc = gtk_label_new("Core envelope budgeting with real-time balance tracking, money wheel, and fast keyboard entry.");
    gtk_label_set_wrap(GTK_LABEL(c1_desc), TRUE);
    gtk_widget_add_css_class(c1_desc, "ext-desc");
    gtk_widget_set_halign(c1_desc, GTK_ALIGN_START);
    gtk_box_append(GTK_BOX(card1), c1_desc);

    gtk_box_append(GTK_BOX(c_list), card1);

    // Card 2: WarTable
    GtkWidget *card2 = gtk_box_new(GTK_ORIENTATION_VERTICAL, 8);
    gtk_widget_add_css_class(card2, "ext-card");

    GtkWidget *c2_head = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 8);
    GtkWidget *c2_t = gtk_label_new("WarTable AI Financial Council");
    gtk_widget_add_css_class(c2_t, "ext-card-title");
    gtk_box_append(GTK_BOX(c2_head), c2_t);

    GtkWidget *c2_sp = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 0);
    gtk_widget_set_hexpand(c2_sp, TRUE);
    gtk_box_append(GTK_BOX(c2_head), c2_sp);

    GtkWidget *c2_tag = gtk_label_new("Available");
    gtk_widget_add_css_class(c2_tag, "ext-tag-avail");
    gtk_box_append(GTK_BOX(c2_head), c2_tag);
    gtk_box_append(GTK_BOX(card2), c2_head);

    GtkWidget *c2_desc = gtk_label_new("Multi-agent AI council. Deliberate on investments, run scenarios, and model financial decisions with full local transcript privacy.");
    gtk_label_set_wrap(GTK_LABEL(c2_desc), TRUE);
    gtk_widget_add_css_class(c2_desc, "ext-desc");
    gtk_widget_set_halign(c2_desc, GTK_ALIGN_START);
    gtk_box_append(GTK_BOX(card2), c2_desc);

    GtkWidget *c2_btn = gtk_button_new_with_label("Open WarTable");
    gtk_widget_add_css_class(c2_btn, "ext-btn");
    gtk_widget_set_halign(c2_btn, GTK_ALIGN_START);
    g_object_set_data_full(G_OBJECT(c2_btn), "action_id", g_strdup("tab:wartable"), g_free);
    g_signal_connect(c2_btn, "clicked", G_CALLBACK(on_btn_clicked), shell);
    gtk_box_append(GTK_BOX(card2), c2_btn);

    gtk_box_append(GTK_BOX(c_list), card2);

    // Card 3: Runway & Properties
    GtkWidget *card3 = gtk_box_new(GTK_ORIENTATION_VERTICAL, 8);
    gtk_widget_add_css_class(card3, "ext-card");

    GtkWidget *c3_head = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 8);
    GtkWidget *c3_t = gtk_label_new("Runway & Properties");
    gtk_widget_add_css_class(c3_t, "ext-card-title");
    gtk_box_append(GTK_BOX(c3_head), c3_t);

    GtkWidget *c3_sp = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 0);
    gtk_widget_set_hexpand(c3_sp, TRUE);
    gtk_box_append(GTK_BOX(c3_head), c3_sp);

    GtkWidget *c3_tag = gtk_label_new("Available");
    gtk_widget_add_css_class(c3_tag, "ext-tag-avail");
    gtk_box_append(GTK_BOX(c3_head), c3_tag);
    gtk_box_append(GTK_BOX(card3), c3_head);

    GtkWidget *c3_desc = gtk_label_new("Real estate cash flow, booking revenue horizons, and dynamic proforma scenarios connecting properties directly to household burn.");
    gtk_label_set_wrap(GTK_LABEL(c3_desc), TRUE);
    gtk_widget_add_css_class(c3_desc, "ext-desc");
    gtk_widget_set_halign(c3_desc, GTK_ALIGN_START);
    gtk_box_append(GTK_BOX(card3), c3_desc);

    GtkWidget *c3_btn = gtk_button_new_with_label("Open Runway");
    gtk_widget_add_css_class(c3_btn, "ext-btn");
    gtk_widget_set_halign(c3_btn, GTK_ALIGN_START);
    g_object_set_data_full(G_OBJECT(c3_btn), "action_id", g_strdup("tab:runway"), g_free);
    g_signal_connect(c3_btn, "clicked", G_CALLBACK(on_btn_clicked), shell);
    gtk_box_append(GTK_BOX(card3), c3_btn);

    gtk_box_append(GTK_BOX(c_list), card3);

    gtk_box_append(GTK_BOX(catalog), c_scroll);
    gtk_stack_add_named(GTK_STACK(stack), catalog, "catalog");

    gtk_box_append(GTK_BOX(main_hbox), stack);

    // When the window goes (the person closed it, or the app quit), every
    // widget in it goes too. The struct outlives them so a call that is
    // already in flight finds NULL pointers, not freed ones; each entry point
    // checks. Swift hears "window:destroyed", drops its pointer, and frees the
    // struct with wellspent_gtk_free_shell.
    g_signal_connect(win, "destroy", G_CALLBACK(on_window_destroy), shell);
    return shell;
}

void wellspent_gtk_free_shell(void *shell_ptr) {
    g_free(shell_ptr);
}

void wellspent_gtk_set_active_tab(void *shell_ptr, const char *tab_name) {
    WellSpentGtkShell *shell = (WellSpentGtkShell *)shell_ptr;
    if (!shell || !shell->content_stack || !tab_name) return;

    gtk_stack_set_visible_child_name(GTK_STACK(shell->content_stack), tab_name);

    gtk_widget_remove_css_class(shell->btn_budgets, "active");
    gtk_widget_remove_css_class(shell->btn_runway, "active");
    gtk_widget_remove_css_class(shell->btn_wartable, "active");
    gtk_widget_remove_css_class(shell->btn_catalog, "active");

    if (strcmp(tab_name, "budgets") == 0) {
        gtk_widget_add_css_class(shell->btn_budgets, "active");
    } else if (strcmp(tab_name, "runway") == 0) {
        gtk_widget_add_css_class(shell->btn_runway, "active");
    } else if (strcmp(tab_name, "wartable") == 0) {
        gtk_widget_add_css_class(shell->btn_wartable, "active");
    } else if (strcmp(tab_name, "catalog") == 0) {
        gtk_widget_add_css_class(shell->btn_catalog, "active");
    }
}

void wellspent_gtk_set_sync_state(void *shell_ptr, int is_syncing) {
    WellSpentGtkShell *shell = (WellSpentGtkShell *)shell_ptr;
    if (!shell || !shell->btn_sync) return;

    if (is_syncing) {
        gtk_button_set_label(GTK_BUTTON(shell->btn_sync), "⏳");
        gtk_widget_set_tooltip_text(shell->btn_sync, "Syncing with server...");
    } else {
        gtk_button_set_label(GTK_BUTTON(shell->btn_sync), "🔄");
        gtk_widget_set_tooltip_text(shell->btn_sync, "Sync now");
    }
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

#pragma GCC diagnostic push
#pragma GCC diagnostic ignored "-Wdeprecated-declarations"
    GtkCssProvider *btn_provider = gtk_css_provider_new();
    gtk_css_provider_load_from_string(btn_provider, css_buf);
    gtk_style_context_add_provider(
        gtk_widget_get_style_context(btn),
        GTK_STYLE_PROVIDER(btn_provider),
        GTK_STYLE_PROVIDER_PRIORITY_APPLICATION + 1
    );
    g_object_unref(btn_provider);
#pragma GCC diagnostic pop

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
    set_accessible_name(btn, name);
    gtk_accessible_update_state(GTK_ACCESSIBLE(btn), GTK_ACCESSIBLE_STATE_SELECTED, is_selected ? TRUE : FALSE, -1);

    char act_buf[256];
    snprintf(act_buf, sizeof(act_buf), "budget:%s", budget_id ? budget_id : "");
    g_object_set_data_full(G_OBJECT(btn), "action_id", g_strdup(act_buf), g_free);
    g_signal_connect(btn, "clicked", G_CALLBACK(on_btn_clicked), shell);

    gtk_box_append(GTK_BOX(shell->sidebar_content), btn);
}

void wellspent_gtk_sidebar_add_footer(void *shell_ptr, const char *status_text) {
    WellSpentGtkShell *shell = (WellSpentGtkShell *)shell_ptr;
    if (!shell || !shell->sidebar_content) return;

    // + Add Budget button above footer
    GtkWidget *btn_add_b = gtk_button_new_with_label("+ Add Budget");
    gtk_widget_add_css_class(btn_add_b, "sidebar-add-btn");
    g_object_set_data_full(G_OBJECT(btn_add_b), "action_id", g_strdup("action:add_budget"), g_free);
    g_signal_connect(btn_add_b, "clicked", G_CALLBACK(on_btn_clicked), shell);
    gtk_box_append(GTK_BOX(shell->sidebar_content), btn_add_b);

    GtkWidget *spacer = gtk_box_new(GTK_ORIENTATION_VERTICAL, 0);
    gtk_widget_set_vexpand(spacer, TRUE);
    gtk_box_append(GTK_BOX(shell->sidebar_content), spacer);

    GtkWidget *lbl = gtk_label_new(status_text ? status_text : "Syncs through WellSpent's server");
    shell->sidebar_footer_lbl = lbl;
    gtk_widget_add_css_class(lbl, "footer-text");
    gtk_widget_set_halign(lbl, GTK_ALIGN_START);
    gtk_box_append(GTK_BOX(shell->sidebar_content), lbl);
}

void wellspent_gtk_update_detail_wheel(void *shell_ptr,
                                       const char *budget_name,
                                       const char *day_line,
                                       const char *middle_key,
                                       const char *middle_amount,
                                       const char *middle_of,
                                       const char *pace_text,
                                       double arc,
                                       double tick,
                                       int is_over) {
    WellSpentGtkShell *shell = (WellSpentGtkShell *)shell_ptr;
    if (!shell) return;

    if (shell->detail_title && budget_name) {
        gtk_label_set_text(GTK_LABEL(shell->detail_title), budget_name);
    }
    if (shell->detail_subtitle && day_line) {
        gtk_label_set_text(GTK_LABEL(shell->detail_subtitle), day_line);
    }
    if (shell->wheel_mid_key && middle_key) {
        gtk_label_set_text(GTK_LABEL(shell->wheel_mid_key), middle_key);
    }
    if (shell->wheel_mid_amount && middle_amount) {
        gtk_label_set_text(GTK_LABEL(shell->wheel_mid_amount), middle_amount);
    }
    if (shell->wheel_mid_of && middle_of) {
        gtk_label_set_text(GTK_LABEL(shell->wheel_mid_of), middle_of);
    }
    if (shell->wheel_pace_lbl && pace_text) {
        gtk_label_set_text(GTK_LABEL(shell->wheel_pace_lbl), pace_text);
    }

    shell->wheel_arc = arc;
    shell->wheel_tick = tick;
    shell->wheel_is_over = is_over;

    if (shell->wheel_drawing_area) {
        gtk_widget_queue_draw(shell->wheel_drawing_area);
    }
}

void wellspent_gtk_clear_transactions(void *shell_ptr) {
    WellSpentGtkShell *shell = (WellSpentGtkShell *)shell_ptr;
    if (!shell || !shell->tx_box) return;
    GtkWidget *child = gtk_widget_get_first_child(shell->tx_box);
    while (child) {
        GtkWidget *next = gtk_widget_get_next_sibling(child);
        gtk_box_remove(GTK_BOX(shell->tx_box), child);
        child = next;
    }
}

void wellspent_gtk_add_transaction_row(void *shell_ptr,
                                       const char *date,
                                       const char *merchant,
                                       const char *source,
                                       const char *amount) {
    WellSpentGtkShell *shell = (WellSpentGtkShell *)shell_ptr;
    if (!shell || !shell->tx_box) return;

    GtkWidget *row = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 8);
    gtk_widget_add_css_class(row, "transaction-row");

    GtkWidget *d_lbl = gtk_label_new(date ? date : "");
    gtk_widget_add_css_class(d_lbl, "tx-date");
    gtk_widget_set_halign(d_lbl, GTK_ALIGN_START);
    gtk_box_append(GTK_BOX(row), d_lbl);

    GtkWidget *m_lbl = gtk_label_new(merchant ? merchant : "");
    gtk_widget_add_css_class(m_lbl, "tx-merchant");
    gtk_widget_set_halign(m_lbl, GTK_ALIGN_START);
    gtk_widget_set_hexpand(m_lbl, TRUE);
    gtk_box_append(GTK_BOX(row), m_lbl);

    GtkWidget *s_lbl = gtk_label_new(source ? source : "");
    gtk_widget_add_css_class(s_lbl, "tx-source");
    gtk_widget_set_halign(s_lbl, GTK_ALIGN_START);
    gtk_box_append(GTK_BOX(row), s_lbl);

    GtkWidget *a_lbl = gtk_label_new(amount ? amount : "");
    gtk_widget_add_css_class(a_lbl, "tx-amount");
    gtk_widget_set_halign(a_lbl, GTK_ALIGN_END);
    gtk_box_append(GTK_BOX(row), a_lbl);

    gtk_box_append(GTK_BOX(shell->tx_box), row);
}

// Dialog: New Budget
typedef struct {
    GtkWidget *dialog;
    GtkWidget *name_entry;
    GtkWidget *limit_entry;
    wellspent_gtk_new_budget_cb cb;
    void *context;
} NewBudgetDialogData;

static void on_create_budget_submit(GtkButton *btn, gpointer user_data) {
    NewBudgetDialogData *data = (NewBudgetDialogData *)user_data;
    const char *name = gtk_editable_get_text(GTK_EDITABLE(data->name_entry));
    const char *limit = gtk_editable_get_text(GTK_EDITABLE(data->limit_entry));
    if (data->cb && name && strlen(name) > 0) {
        data->cb(data->context, name, limit);
    }
    gtk_window_destroy(GTK_WINDOW(data->dialog));
}

static void on_dialog_cancel(GtkButton *btn, gpointer user_data) {
    GtkWidget *dlg = GTK_WIDGET(user_data);
    gtk_window_destroy(GTK_WINDOW(dlg));
}

void wellspent_gtk_show_new_budget_dialog(void *shell_ptr,
                                          wellspent_gtk_new_budget_cb cb,
                                          void *context) {
    WellSpentGtkShell *shell = (WellSpentGtkShell *)shell_ptr;
    if (!shell || !shell->window) return;

    NewBudgetDialogData *data = g_new0(NewBudgetDialogData, 1);
    data->cb = cb;
    data->context = context;

    GtkWidget *dlg = gtk_window_new();
    data->dialog = dlg;
    // The dialog owns its data: destroying it, by any path, frees this.
    g_object_set_data_full(G_OBJECT(dlg), "dialog_data", data, g_free);
    gtk_window_set_title(GTK_WINDOW(dlg), "New Budget");
    gtk_window_set_transient_for(GTK_WINDOW(dlg), GTK_WINDOW(shell->window));
    gtk_window_set_modal(GTK_WINDOW(dlg), TRUE);
    gtk_window_set_default_size(GTK_WINDOW(dlg), 380, 260);
    gtk_widget_add_css_class(dlg, "wellspent-modal-dialog");

    GtkWidget *vbox = gtk_box_new(GTK_ORIENTATION_VERTICAL, 10);
    gtk_widget_set_margin_start(vbox, 24);
    gtk_widget_set_margin_end(vbox, 24);
    gtk_widget_set_margin_top(vbox, 20);
    gtk_widget_set_margin_bottom(vbox, 20);
    gtk_window_set_child(GTK_WINDOW(dlg), vbox);

    GtkWidget *title = gtk_label_new("Create New Budget");
    gtk_widget_add_css_class(title, "modal-title");
    gtk_widget_set_halign(title, GTK_ALIGN_START);
    gtk_box_append(GTK_BOX(vbox), title);

    GtkWidget *l1 = gtk_label_new("Budget Name");
    gtk_widget_add_css_class(l1, "modal-label");
    gtk_widget_set_halign(l1, GTK_ALIGN_START);
    gtk_box_append(GTK_BOX(vbox), l1);

    GtkWidget *name_entry = gtk_entry_new();
    data->name_entry = name_entry;
    gtk_entry_set_placeholder_text(GTK_ENTRY(name_entry), "e.g. Dining Out");
    gtk_widget_add_css_class(name_entry, "modal-entry");
    gtk_box_append(GTK_BOX(vbox), name_entry);

    GtkWidget *l2 = gtk_label_new("Monthly Limit ($)");
    gtk_widget_add_css_class(l2, "modal-label");
    gtk_widget_set_halign(l2, GTK_ALIGN_START);
    gtk_box_append(GTK_BOX(vbox), l2);

    GtkWidget *limit_entry = gtk_entry_new();
    data->limit_entry = limit_entry;
    gtk_entry_set_placeholder_text(GTK_ENTRY(limit_entry), "e.g. 350.00");
    gtk_widget_add_css_class(limit_entry, "modal-entry");
    gtk_box_append(GTK_BOX(vbox), limit_entry);

    GtkWidget *btn_row = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 8);
    gtk_widget_set_halign(btn_row, GTK_ALIGN_END);

    GtkWidget *cancel = gtk_button_new_with_label("Cancel");
    gtk_widget_add_css_class(cancel, "modal-cancel-btn");
    g_signal_connect(cancel, "clicked", G_CALLBACK(on_dialog_cancel), dlg);
    gtk_box_append(GTK_BOX(btn_row), cancel);

    GtkWidget *create = gtk_button_new_with_label("Create Budget");
    gtk_widget_add_css_class(create, "accent-action-btn");
    g_signal_connect(create, "clicked", G_CALLBACK(on_create_budget_submit), data);
    gtk_box_append(GTK_BOX(btn_row), create);

    gtk_box_append(GTK_BOX(vbox), btn_row);

    gtk_window_present(GTK_WINDOW(dlg));
}

// Dialog: New Transaction
typedef struct {
    GtkWidget *dialog;
    GtkWidget *merch_entry;
    GtkWidget *amount_entry;
    GtkWidget *note_entry;
    wellspent_gtk_new_tx_cb cb;
    void *context;
} NewTxDialogData;

static void on_create_tx_submit(GtkButton *btn, gpointer user_data) {
    NewTxDialogData *data = (NewTxDialogData *)user_data;
    const char *merch = gtk_editable_get_text(GTK_EDITABLE(data->merch_entry));
    const char *amt = gtk_editable_get_text(GTK_EDITABLE(data->amount_entry));
    const char *note = gtk_editable_get_text(GTK_EDITABLE(data->note_entry));
    if (data->cb && amt && strlen(amt) > 0) {
        data->cb(data->context, merch, amt, note);
    }
    gtk_window_destroy(GTK_WINDOW(data->dialog));
}

void wellspent_gtk_show_new_tx_dialog(void *shell_ptr,
                                      wellspent_gtk_new_tx_cb cb,
                                      void *context) {
    WellSpentGtkShell *shell = (WellSpentGtkShell *)shell_ptr;
    if (!shell || !shell->window) return;

    NewTxDialogData *data = g_new0(NewTxDialogData, 1);
    data->cb = cb;
    data->context = context;

    GtkWidget *dlg = gtk_window_new();
    data->dialog = dlg;
    // The dialog owns its data: destroying it, by any path, frees this.
    g_object_set_data_full(G_OBJECT(dlg), "dialog_data", data, g_free);
    gtk_window_set_title(GTK_WINDOW(dlg), "New Transaction");
    gtk_window_set_transient_for(GTK_WINDOW(dlg), GTK_WINDOW(shell->window));
    gtk_window_set_modal(GTK_WINDOW(dlg), TRUE);
    gtk_window_set_default_size(GTK_WINDOW(dlg), 400, 320);
    gtk_widget_add_css_class(dlg, "wellspent-modal-dialog");

    GtkWidget *vbox = gtk_box_new(GTK_ORIENTATION_VERTICAL, 10);
    gtk_widget_set_margin_start(vbox, 24);
    gtk_widget_set_margin_end(vbox, 24);
    gtk_widget_set_margin_top(vbox, 20);
    gtk_widget_set_margin_bottom(vbox, 20);
    gtk_window_set_child(GTK_WINDOW(dlg), vbox);

    GtkWidget *title = gtk_label_new("Record Transaction");
    gtk_widget_add_css_class(title, "modal-title");
    gtk_widget_set_halign(title, GTK_ALIGN_START);
    gtk_box_append(GTK_BOX(vbox), title);

    GtkWidget *l1 = gtk_label_new("Amount ($)");
    gtk_widget_add_css_class(l1, "modal-label");
    gtk_widget_set_halign(l1, GTK_ALIGN_START);
    gtk_box_append(GTK_BOX(vbox), l1);

    GtkWidget *amount_entry = gtk_entry_new();
    data->amount_entry = amount_entry;
    gtk_entry_set_placeholder_text(GTK_ENTRY(amount_entry), "e.g. 42.50");
    gtk_widget_add_css_class(amount_entry, "modal-entry");
    gtk_box_append(GTK_BOX(vbox), amount_entry);

    GtkWidget *l2 = gtk_label_new("Merchant / Description");
    gtk_widget_add_css_class(l2, "modal-label");
    gtk_widget_set_halign(l2, GTK_ALIGN_START);
    gtk_box_append(GTK_BOX(vbox), l2);

    GtkWidget *merch_entry = gtk_entry_new();
    data->merch_entry = merch_entry;
    gtk_entry_set_placeholder_text(GTK_ENTRY(merch_entry), "e.g. Trader Joe's");
    gtk_widget_add_css_class(merch_entry, "modal-entry");
    gtk_box_append(GTK_BOX(vbox), merch_entry);

    GtkWidget *l3 = gtk_label_new("Note (optional)");
    gtk_widget_add_css_class(l3, "modal-label");
    gtk_widget_set_halign(l3, GTK_ALIGN_START);
    gtk_box_append(GTK_BOX(vbox), l3);

    GtkWidget *note_entry = gtk_entry_new();
    data->note_entry = note_entry;
    gtk_entry_set_placeholder_text(GTK_ENTRY(note_entry), "e.g. Weekly staples");
    gtk_widget_add_css_class(note_entry, "modal-entry");
    gtk_box_append(GTK_BOX(vbox), note_entry);

    GtkWidget *btn_row = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 8);
    gtk_widget_set_halign(btn_row, GTK_ALIGN_END);

    GtkWidget *cancel = gtk_button_new_with_label("Cancel");
    gtk_widget_add_css_class(cancel, "modal-cancel-btn");
    g_signal_connect(cancel, "clicked", G_CALLBACK(on_dialog_cancel), dlg);
    gtk_box_append(GTK_BOX(btn_row), cancel);

    GtkWidget *add_btn = gtk_button_new_with_label("Add Transaction");
    gtk_widget_add_css_class(add_btn, "accent-action-btn");
    g_signal_connect(add_btn, "clicked", G_CALLBACK(on_create_tx_submit), data);
    gtk_box_append(GTK_BOX(btn_row), add_btn);

    gtk_box_append(GTK_BOX(vbox), btn_row);

    gtk_window_present(GTK_WINDOW(dlg));
}

// Dialog: Account
typedef struct {
    GtkWidget *dialog;
    GtkWidget *email_entry;
    GtkWidget *pass_entry;
    wellspent_gtk_account_cb cb;
    void *context;
} AccountDialogData;

static void on_sign_in_submit(GtkButton *btn, gpointer user_data) {
    AccountDialogData *data = (AccountDialogData *)user_data;
    const char *email = gtk_editable_get_text(GTK_EDITABLE(data->email_entry));
    const char *pass = gtk_editable_get_text(GTK_EDITABLE(data->pass_entry));
    if (data->cb && email && strlen(email) > 0) {
        data->cb(data->context, "sign_in", email, pass);
    }
    gtk_window_destroy(GTK_WINDOW(data->dialog));
}

static void on_sign_out_submit(GtkButton *btn, gpointer user_data) {
    AccountDialogData *data = (AccountDialogData *)user_data;
    if (data->cb) {
        data->cb(data->context, "sign_out", NULL, NULL);
    }
    gtk_window_destroy(GTK_WINDOW(data->dialog));
}

void wellspent_gtk_show_account_dialog(void *shell_ptr,
                                       const char *email,
                                       int is_signed_in,
                                       wellspent_gtk_account_cb cb,
                                       void *context) {
    WellSpentGtkShell *shell = (WellSpentGtkShell *)shell_ptr;
    if (!shell || !shell->window) return;

    AccountDialogData *data = g_new0(AccountDialogData, 1);
    data->cb = cb;
    data->context = context;

    GtkWidget *dlg = gtk_window_new();
    data->dialog = dlg;
    // The dialog owns its data: destroying it, by any path, frees this.
    g_object_set_data_full(G_OBJECT(dlg), "dialog_data", data, g_free);
    gtk_window_set_title(GTK_WINDOW(dlg), "Account");
    gtk_window_set_transient_for(GTK_WINDOW(dlg), GTK_WINDOW(shell->window));
    gtk_window_set_modal(GTK_WINDOW(dlg), TRUE);
    gtk_window_set_default_size(GTK_WINDOW(dlg), 380, is_signed_in ? 200 : 280);
    gtk_widget_add_css_class(dlg, "wellspent-modal-dialog");

    GtkWidget *vbox = gtk_box_new(GTK_ORIENTATION_VERTICAL, 12);
    gtk_widget_set_margin_start(vbox, 24);
    gtk_widget_set_margin_end(vbox, 24);
    gtk_widget_set_margin_top(vbox, 20);
    gtk_widget_set_margin_bottom(vbox, 20);
    gtk_window_set_child(GTK_WINDOW(dlg), vbox);

    if (is_signed_in) {
        GtkWidget *title = gtk_label_new("WellSpent Account");
        gtk_widget_add_css_class(title, "modal-title");
        gtk_widget_set_halign(title, GTK_ALIGN_START);
        gtk_box_append(GTK_BOX(vbox), title);

        char signed_buf[256];
        snprintf(signed_buf, sizeof(signed_buf), "Signed in as:\n%s", email ? email : "Member");
        GtkWidget *lbl_info = gtk_label_new(signed_buf);
        gtk_widget_add_css_class(lbl_info, "detail-subtitle");
        gtk_widget_set_halign(lbl_info, GTK_ALIGN_START);
        gtk_box_append(GTK_BOX(vbox), lbl_info);

        GtkWidget *btn_row = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 8);
        gtk_widget_set_halign(btn_row, GTK_ALIGN_END);

        GtkWidget *close_btn = gtk_button_new_with_label("Close");
        gtk_widget_add_css_class(close_btn, "modal-cancel-btn");
        g_signal_connect(close_btn, "clicked", G_CALLBACK(on_dialog_cancel), dlg);
        gtk_box_append(GTK_BOX(btn_row), close_btn);

        GtkWidget *sign_out = gtk_button_new_with_label("Sign Out");
        gtk_widget_add_css_class(sign_out, "accent-action-btn");
        g_signal_connect(sign_out, "clicked", G_CALLBACK(on_sign_out_submit), data);
        gtk_box_append(GTK_BOX(btn_row), sign_out);

        gtk_box_append(GTK_BOX(vbox), btn_row);
    } else {
        GtkWidget *title = gtk_label_new("Sign In to WellSpent");
        gtk_widget_add_css_class(title, "modal-title");
        gtk_widget_set_halign(title, GTK_ALIGN_START);
        gtk_box_append(GTK_BOX(vbox), title);

        GtkWidget *l1 = gtk_label_new("Email");
        gtk_widget_add_css_class(l1, "modal-label");
        gtk_widget_set_halign(l1, GTK_ALIGN_START);
        gtk_box_append(GTK_BOX(vbox), l1);

        GtkWidget *email_entry = gtk_entry_new();
        data->email_entry = email_entry;
        gtk_entry_set_placeholder_text(GTK_ENTRY(email_entry), "you@example.com");
        gtk_widget_add_css_class(email_entry, "modal-entry");
        gtk_box_append(GTK_BOX(vbox), email_entry);

        GtkWidget *l2 = gtk_label_new("Password");
        gtk_widget_add_css_class(l2, "modal-label");
        gtk_widget_set_halign(l2, GTK_ALIGN_START);
        gtk_box_append(GTK_BOX(vbox), l2);

        GtkWidget *pass_entry = gtk_entry_new();
        data->pass_entry = pass_entry;
        gtk_entry_set_visibility(GTK_ENTRY(pass_entry), FALSE);
        gtk_widget_add_css_class(pass_entry, "modal-entry");
        gtk_box_append(GTK_BOX(vbox), pass_entry);

        GtkWidget *btn_row = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 8);
        gtk_widget_set_halign(btn_row, GTK_ALIGN_END);

        GtkWidget *cancel = gtk_button_new_with_label("Cancel");
        gtk_widget_add_css_class(cancel, "modal-cancel-btn");
        g_signal_connect(cancel, "clicked", G_CALLBACK(on_dialog_cancel), dlg);
        gtk_box_append(GTK_BOX(btn_row), cancel);

        GtkWidget *sign_in = gtk_button_new_with_label("Sign In");
        gtk_widget_add_css_class(sign_in, "accent-action-btn");
        g_signal_connect(sign_in, "clicked", G_CALLBACK(on_sign_in_submit), data);
        gtk_box_append(GTK_BOX(btn_row), sign_in);

        gtk_box_append(GTK_BOX(vbox), btn_row);
    }

    gtk_window_present(GTK_WINDOW(dlg));
}

void wellspent_gtk_window_present(void *shell_ptr) {
    WellSpentGtkShell *shell = (WellSpentGtkShell *)shell_ptr;
    if (shell && shell->window) {
        gtk_window_present(GTK_WINDOW(shell->window));
    }
}
