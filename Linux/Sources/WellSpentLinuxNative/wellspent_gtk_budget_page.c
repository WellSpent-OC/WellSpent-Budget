// The native budget page: the budget's name and its buttons, the undo strip,
// the day of the period, the money wheel with the pace words and figures
// beside it, the count line, then the entries on a card. Drawn from the
// shared BudgetScreen by NativeShellController.render(); this file only knows
// widgets and words it is handed. Every control carries the name the
// SwiftCrossUI page gives it, so the Linux UI tests and a screen reader find
// the same things.
#include "wellspent_gtk_shell_private.h"
#include <math.h>
#include <string.h>

void wellspent_gtk_page_clear(void *shell_ptr) {
    WellSpentGtkShell *shell = (WellSpentGtkShell *)shell_ptr;
    if (!shell || !shell->detail_pane) return;
    GtkWidget *child = gtk_widget_get_first_child(shell->detail_pane);
    while (child) {
        GtkWidget *next = gtk_widget_get_next_sibling(child);
        gtk_box_remove(GTK_BOX(shell->detail_pane), child);
        child = next;
    }
    shell->page_figures = NULL;
    shell->page_list = NULL;
}

static GtkWidget *label(const char *text, const char *css_class, float xalign) {
    GtkWidget *lbl = gtk_label_new(text ? text : "");
    if (css_class) gtk_widget_add_css_class(lbl, css_class);
    gtk_label_set_xalign(GTK_LABEL(lbl), xalign);
    return lbl;
}

/// A button that fires an action id.
static GtkWidget *action_button(WellSpentGtkShell *shell, const char *title, const char *css_class,
                                const char *action_id) {
    GtkWidget *btn = gtk_button_new_with_label(title ? title : "");
    if (css_class) gtk_widget_add_css_class(btn, css_class);
    g_object_set_data_full(G_OBJECT(btn), "action_id", g_strdup(action_id), g_free);
    g_signal_connect(btn, "clicked", G_CALLBACK(wellspent_gtk_on_btn_clicked), shell);
    return btn;
}

void wellspent_gtk_page_add_head(void *shell_ptr, const char *title, int may_add,
                                 const char *import_title, const char *add_title, const char *menu_spec) {
    WellSpentGtkShell *shell = (WellSpentGtkShell *)shell_ptr;
    if (!shell || !shell->detail_pane) return;

    GtkWidget *row = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 8);
    gtk_widget_add_css_class(row, "ws-budget-top");
    GtkWidget *name = label(title, "ws-title", 0);
    gtk_label_set_ellipsize(GTK_LABEL(name), PANGO_ELLIPSIZE_END);
    gtk_widget_set_hexpand(name, TRUE);
    gtk_box_append(GTK_BOX(row), name);

    if (may_add) {
        gtk_box_append(GTK_BOX(row), action_button(shell, import_title, "ws-button", "page:import"));
        GtkWidget *add = action_button(shell, add_title, "ws-button", "page:add");
        gtk_widget_add_css_class(add, "primary");
        gtk_box_append(GTK_BOX(row), add);
    }

    // The Mac's right-click menu on the budget, as buttons, as the
    // SwiftCrossUI page draws it. Index counts items only, as NativeMenu does.
    gchar **lines = g_strsplit(menu_spec ? menu_spec : "", "\n", -1);
    int index = 0;
    for (int i = 0; lines[i]; i++) {
        if (*lines[i] == '\0' || strcmp(lines[i], "-") == 0) continue;
        char *action_id = g_strdup_printf("menu:budget:%d", index++);
        gtk_box_append(GTK_BOX(row), action_button(shell, lines[i], "ws-button", action_id));
        g_free(action_id);
    }
    g_strfreev(lines);

    gtk_box_append(GTK_BOX(shell->detail_pane), row);
}

void wellspent_gtk_page_add_undo(void *shell_ptr, const char *message, const char *button_title) {
    WellSpentGtkShell *shell = (WellSpentGtkShell *)shell_ptr;
    if (!shell || !shell->detail_pane) return;
    GtkWidget *row = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 10);
    gtk_widget_add_css_class(row, "ws-undo");
    GtkWidget *words = label(message, "ws-undo-text", 0);
    gtk_label_set_wrap(GTK_LABEL(words), TRUE);
    gtk_widget_set_hexpand(words, TRUE);
    gtk_box_append(GTK_BOX(row), words);
    gtk_box_append(GTK_BOX(row), action_button(shell, button_title, "ws-button", "page:undo"));
    gtk_box_append(GTK_BOX(shell->detail_pane), row);
}

static void set_source(cairo_t *cr, wellspent_rgb colour) {
    cairo_set_source_rgb(cr, colour.red, colour.green, colour.blue);
}

static void circle(cairo_t *cr, const wellspent_gtk_wheel *w, double radius, double width, wellspent_rgb colour) {
    cairo_new_path(cr);
    cairo_arc(cr, w->size / 2, w->size / 2, radius, 0, 2 * M_PI);
    cairo_set_line_width(cr, width);
    set_source(cr, colour);
    cairo_stroke(cr);
}

/// The wheel as WheelGeometry places it: the track, what is left clockwise
/// from the top, the band's two edges, then the tick. Cairo's angles run
/// clockwise from 3 o'clock with y down, as WheelGeometry's spans do.
static void draw_wheel(GtkDrawingArea *area, cairo_t *cr, int width, int height, gpointer data) {
    (void)area;
    const wellspent_gtk_wheel *w = data;
    if (!w) return;
    cairo_translate(cr, (width - w->size) / 2, (height - w->size) / 2);
    circle(cr, w, w->radius, w->band, w->track);
    if (w->arc > 0) {
        double top = 3 * M_PI / 2;
        double share = w->arc < 1 ? w->arc : 1;
        cairo_new_path(cr);
        if (share >= 1) {
            cairo_arc(cr, w->size / 2, w->size / 2, w->radius, 0, 2 * M_PI);
        } else {
            cairo_arc(cr, w->size / 2, w->size / 2, w->radius, top, top + 2 * M_PI * share);
        }
        cairo_set_line_width(cr, w->band);
        cairo_set_line_cap(cr, CAIRO_LINE_CAP_BUTT);
        set_source(cr, w->arc_color);
        cairo_stroke(cr);
    }
    circle(cr, w, w->outer_edge, w->edge_width, w->edge);
    circle(cr, w, w->inner_edge, w->edge_width, w->edge);
    if (w->has_tick) {
        cairo_new_path(cr);
        cairo_move_to(cr, w->tick_from_x, w->tick_from_y);
        cairo_line_to(cr, w->tick_to_x, w->tick_to_y);
        cairo_set_line_width(cr, w->tick_width);
        cairo_set_line_cap(cr, CAIRO_LINE_CAP_BUTT);
        set_source(cr, w->edge);
        cairo_stroke(cr);
    }
}

void wellspent_gtk_page_add_wheel(void *shell_ptr, const char *day_line, const wellspent_gtk_wheel *wheel,
                                  const char *middle_key, const char *middle_amount, const char *middle_of,
                                  wellspent_rgb amount_color, const char *spoken,
                                  const char *pace_text, const char *edit_title) {
    WellSpentGtkShell *shell = (WellSpentGtkShell *)shell_ptr;
    if (!shell || !shell->detail_pane || !wheel) return;

    if (day_line) {
        gtk_box_append(GTK_BOX(shell->detail_pane), label(day_line, "ws-day", 0));
    }

    GtkWidget *panel = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 24);
    gtk_widget_add_css_class(panel, "ws-wheel-panel");

    // The drawing keeps its own copy of the numbers, freed with it.
    GtkWidget *overlay = gtk_overlay_new();
    gtk_widget_set_valign(overlay, GTK_ALIGN_START);
    GtkWidget *area = gtk_drawing_area_new();
    int size = (int)ceil(wheel->size);
    gtk_drawing_area_set_content_width(GTK_DRAWING_AREA(area), size);
    gtk_drawing_area_set_content_height(GTK_DRAWING_AREA(area), size);
    gtk_drawing_area_set_draw_func(GTK_DRAWING_AREA(area), draw_wheel, g_memdup2(wheel, sizeof *wheel), g_free);
    wellspent_gtk_set_accessible_name(area, spoken);
    gtk_overlay_set_child(GTK_OVERLAY(overlay), area);

    // The words in the middle, inside the tick's inner end. Pango shrinks
    // nothing on its own, so a long amount is cut short with an ellipsis
    // rather than crossing the tick.
    GtkWidget *middle = gtk_box_new(GTK_ORIENTATION_VERTICAL, 2);
    gtk_widget_set_halign(middle, GTK_ALIGN_CENTER);
    gtk_widget_set_valign(middle, GTK_ALIGN_CENTER);
    gtk_widget_set_size_request(middle, (int)((wheel->inner_edge - 6) * 2), -1);
    GtkWidget *key = label(middle_key, "ws-wheel-key", 0.5);
    GtkWidget *amount = label(middle_amount, "ws-wheel-amount", 0.5);
    GtkWidget *of = label(middle_of, "ws-wheel-of", 0.5);
    GtkWidget *words[] = { key, amount, of };
    for (int i = 0; i < 3; i++) {
        gtk_label_set_ellipsize(GTK_LABEL(words[i]), PANGO_ELLIPSIZE_END);
        gtk_box_append(GTK_BOX(middle), words[i]);
    }
    PangoAttrList *attrs = pango_attr_list_new();
    pango_attr_list_insert(attrs, pango_attr_foreground_new((guint16)(amount_color.red * 65535),
                                                            (guint16)(amount_color.green * 65535),
                                                            (guint16)(amount_color.blue * 65535)));
    gtk_label_set_attributes(GTK_LABEL(amount), attrs);
    pango_attr_list_unref(attrs);
    gtk_overlay_add_overlay(GTK_OVERLAY(overlay), middle);
    gtk_box_append(GTK_BOX(panel), overlay);

    // Beside the wheel: the pace words with Edit Budget…, then the figures.
    GtkWidget *column = gtk_box_new(GTK_ORIENTATION_VERTICAL, 8);
    gtk_widget_set_size_request(column, 260, -1);
    gtk_widget_set_valign(column, GTK_ALIGN_CENTER);
    if (pace_text) {
        GtkWidget *pace = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 10);
        GtkWidget *pace_words = label(pace_text, "ws-pace", 0);
        gtk_label_set_wrap(GTK_LABEL(pace_words), TRUE);
        gtk_widget_set_hexpand(pace_words, TRUE);
        gtk_box_append(GTK_BOX(pace), pace_words);
        if (edit_title) {
            GtkWidget *edit = action_button(shell, edit_title, "ws-button", "page:edit_budget");
            gtk_widget_set_valign(edit, GTK_ALIGN_CENTER);
            gtk_box_append(GTK_BOX(pace), edit);
        }
        gtk_box_append(GTK_BOX(column), pace);
    }
    GtkWidget *figures = gtk_box_new(GTK_ORIENTATION_VERTICAL, 0);
    gtk_widget_add_css_class(figures, "ws-figures");
    gtk_box_append(GTK_BOX(column), figures);
    shell->page_figures = figures;
    gtk_box_append(GTK_BOX(panel), column);

    gtk_box_append(GTK_BOX(shell->detail_pane), panel);
}

void wellspent_gtk_page_add_figure(void *shell_ptr, const char *label_text, const char *amount_text,
                                   const char *description, int is_warning) {
    WellSpentGtkShell *shell = (WellSpentGtkShell *)shell_ptr;
    if (!shell || !shell->page_figures) return;
    GtkWidget *row = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 12);
    gtk_widget_add_css_class(row, "ws-figure");
    // A rule between figures, none above the first.
    if (gtk_widget_get_first_child(shell->page_figures)) gtk_widget_add_css_class(row, "ruled");
    GtkWidget *name = label(label_text, "ws-figure-label", 0);
    gtk_widget_set_hexpand(name, TRUE);
    gtk_box_append(GTK_BOX(row), name);
    GtkWidget *amount = label(amount_text, "ws-money", 1);
    if (is_warning) gtk_widget_add_css_class(amount, "over");
    // Coming by says why in its description, so the colour is never the
    // only sign.
    if (description) {
        gtk_accessible_update_property(GTK_ACCESSIBLE(amount), GTK_ACCESSIBLE_PROPERTY_DESCRIPTION, description, -1);
    }
    gtk_box_append(GTK_BOX(row), amount);
    gtk_box_append(GTK_BOX(shell->page_figures), row);
}

void wellspent_gtk_page_add_count(void *shell_ptr, const char *count_line, const char *repeats_title) {
    WellSpentGtkShell *shell = (WellSpentGtkShell *)shell_ptr;
    if (!shell || !shell->detail_pane) return;
    GtkWidget *row = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 4);
    gtk_widget_add_css_class(row, "ws-count");
    gtk_box_append(GTK_BOX(row), label(count_line, NULL, 0));
    if (repeats_title) {
        gtk_box_append(GTK_BOX(row), label("·", NULL, 0));
        GtkWidget *repeats = action_button(shell, repeats_title, "ws-link", "page:repeats");
        gtk_box_append(GTK_BOX(row), repeats);
    }
    gtk_box_append(GTK_BOX(shell->detail_pane), row);
}

/// The fixed columns every row and the heading share; the description takes
/// what is left.
enum { DATE_WIDTH = 70, WHO_WIDTH = 90, SOURCE_WIDTH = 80, AMOUNT_WIDTH = 100 };

static void fixed(GtkWidget *widget, int width) {
    gtk_widget_set_size_request(widget, width, -1);
}

void wellspent_gtk_page_add_columns(void *shell_ptr, const char *date, const char *description,
                                    const char *added_by, const char *source, const char *amount) {
    WellSpentGtkShell *shell = (WellSpentGtkShell *)shell_ptr;
    if (!shell || !shell->detail_pane) return;

    GtkWidget *card = gtk_box_new(GTK_ORIENTATION_VERTICAL, 0);
    gtk_widget_add_css_class(card, "ws-entries");
    gtk_widget_set_vexpand(card, TRUE);

    GtkWidget *head = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 12);
    gtk_widget_add_css_class(head, "ws-entries-head");
    GtkWidget *d = label(date, "ws-section", 0);
    fixed(d, DATE_WIDTH);
    gtk_box_append(GTK_BOX(head), d);
    GtkWidget *what = label(description, "ws-section", 0);
    gtk_widget_set_hexpand(what, TRUE);
    gtk_box_append(GTK_BOX(head), what);
    if (added_by) {
        GtkWidget *who = label(added_by, "ws-section", 0);
        fixed(who, WHO_WIDTH);
        gtk_box_append(GTK_BOX(head), who);
    }
    GtkWidget *src = label(source, "ws-section", 0);
    fixed(src, SOURCE_WIDTH);
    gtk_box_append(GTK_BOX(head), src);
    GtkWidget *amt = label(amount, "ws-section", 1);
    fixed(amt, AMOUNT_WIDTH);
    gtk_box_append(GTK_BOX(head), amt);
    gtk_box_append(GTK_BOX(card), head);

    GtkWidget *scroll = gtk_scrolled_window_new();
    gtk_scrolled_window_set_policy(GTK_SCROLLED_WINDOW(scroll), GTK_POLICY_NEVER, GTK_POLICY_AUTOMATIC);
    gtk_widget_set_vexpand(scroll, TRUE);
    GtkWidget *list = gtk_box_new(GTK_ORIENTATION_VERTICAL, 0);
    gtk_scrolled_window_set_child(GTK_SCROLLED_WINDOW(scroll), list);
    gtk_box_append(GTK_BOX(card), scroll);
    shell->page_list = list;

    gtk_box_append(GTK_BOX(shell->detail_pane), card);
}

void wellspent_gtk_page_add_entry(void *shell_ptr, const char *entry_id, const char *date,
                                  const char *merchant, const char *note, const char *notice,
                                  const char *added_by, const char *source,
                                  const char *amount, const char *help) {
    WellSpentGtkShell *shell = (WellSpentGtkShell *)shell_ptr;
    if (!shell || !shell->page_list) return;

    GtkWidget *btn = gtk_button_new();
    gtk_widget_add_css_class(btn, "ws-entry");
    GtkWidget *row = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 12);

    GtkWidget *d = label(date, "ws-date", 0);
    fixed(d, DATE_WIDTH);
    gtk_widget_set_valign(d, GTK_ALIGN_CENTER);
    gtk_box_append(GTK_BOX(row), d);

    GtkWidget *what = gtk_box_new(GTK_ORIENTATION_VERTICAL, 2);
    gtk_widget_set_hexpand(what, TRUE);
    gtk_widget_set_valign(what, GTK_ALIGN_CENTER);
    GtkWidget *name = label(merchant, "ws-name", 0);
    gtk_label_set_ellipsize(GTK_LABEL(name), PANGO_ELLIPSIZE_END);
    gtk_box_append(GTK_BOX(what), name);
    if (note && *note) {
        GtkWidget *memo = label(note, "ws-memo", 0);
        gtk_label_set_ellipsize(GTK_LABEL(memo), PANGO_ELLIPSIZE_END);
        gtk_box_append(GTK_BOX(what), memo);
    }
    // This computer's last change to it didn't go through, until it is opened.
    if (notice && *notice) {
        gtk_box_append(GTK_BOX(what), label(notice, "ws-notice", 0));
    }
    gtk_box_append(GTK_BOX(row), what);

    if (added_by) {
        // Who added it: a small sticker in its column.
        GtkWidget *cell = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 0);
        fixed(cell, WHO_WIDTH);
        gtk_widget_set_valign(cell, GTK_ALIGN_CENTER);
        GtkWidget *who = label(added_by, "ws-who", 0.5);
        gtk_label_set_ellipsize(GTK_LABEL(who), PANGO_ELLIPSIZE_END);
        gtk_box_append(GTK_BOX(cell), who);
        gtk_box_append(GTK_BOX(row), cell);
    }

    GtkWidget *src = label(source, "ws-source", 0);
    fixed(src, SOURCE_WIDTH);
    gtk_widget_set_valign(src, GTK_ALIGN_CENTER);
    gtk_box_append(GTK_BOX(row), src);

    GtkWidget *amt = label(amount, "ws-money", 1);
    fixed(amt, AMOUNT_WIDTH);
    gtk_widget_set_valign(amt, GTK_ALIGN_CENTER);
    gtk_box_append(GTK_BOX(row), amt);

    gtk_button_set_child(GTK_BUTTON(btn), row);
    if (help) {
        gtk_widget_set_tooltip_text(btn, help);
        gtk_accessible_update_property(GTK_ACCESSIBLE(btn), GTK_ACCESSIBLE_PROPERTY_DESCRIPTION, help, -1);
    }
    char *action_id = g_strdup_printf("entry:%s", entry_id ? entry_id : "");
    g_object_set_data_full(G_OBJECT(btn), "action_id", action_id, g_free);
    g_signal_connect(btn, "clicked", G_CALLBACK(wellspent_gtk_on_btn_clicked), shell);
    gtk_box_append(GTK_BOX(shell->page_list), btn);
}

void wellspent_gtk_page_add_empty(void *shell_ptr, const char *text) {
    WellSpentGtkShell *shell = (WellSpentGtkShell *)shell_ptr;
    if (!shell || !shell->page_list) return;
    gtk_box_append(GTK_BOX(shell->page_list), label(text, "ws-empty-text", 0));
}

void wellspent_gtk_page_show_message(void *shell_ptr, const char *title, const char *text,
                                     const char *button_title) {
    WellSpentGtkShell *shell = (WellSpentGtkShell *)shell_ptr;
    if (!shell || !shell->detail_pane) return;
    GtkWidget *box = gtk_box_new(GTK_ORIENTATION_VERTICAL, 10);
    gtk_widget_set_halign(box, GTK_ALIGN_CENTER);
    gtk_widget_set_valign(box, GTK_ALIGN_CENTER);
    gtk_widget_set_vexpand(box, TRUE);
    gtk_box_append(GTK_BOX(box), label(title, "ws-empty-title", 0.5));
    gtk_box_append(GTK_BOX(box), label(text, "ws-empty-text", 0.5));
    if (button_title) {
        GtkWidget *add = action_button(shell, button_title, "ws-button", "action:add_budget");
        gtk_widget_add_css_class(add, "primary");
        gtk_widget_set_halign(add, GTK_ALIGN_CENTER);
        gtk_box_append(GTK_BOX(box), add);
    }
    gtk_box_append(GTK_BOX(shell->detail_pane), box);
}
