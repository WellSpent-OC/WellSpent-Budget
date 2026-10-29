// The native shell's own struct and helpers, shared by its C files only.
// Swift sees the shell as an opaque pointer (wellspent_native.h).
#ifndef WELLSPENT_GTK_SHELL_PRIVATE_H
#define WELLSPENT_GTK_SHELL_PRIVATE_H

#include <gtk/gtk.h>
#include "wellspent_native.h"

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
    /// Under the scrolling rows: Add Budget, More, the footer.
    GtkWidget *sidebar_bottom;
    
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

/// A button's click goes to Swift as the "action_id" string set on it.
void wellspent_gtk_on_btn_clicked(GtkButton *btn, gpointer user_data);

/// What a screen reader and the UI tests call a control.
void wellspent_gtk_set_accessible_name(GtkWidget *widget, const char *name);

#endif
