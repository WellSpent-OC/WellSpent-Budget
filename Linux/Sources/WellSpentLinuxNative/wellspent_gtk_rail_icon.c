// The rail's icons, drawn as lines in the button's own color. A font glyph
// would need a font that has it, and many computers have no emoji font, so a
// missing one showed as a box with a number in it.
#include "wellspent_gtk_shell_private.h"
#include <math.h>
#include <string.h>

/// Each icon is drawn on a 20 by 20 grid, centered in its area.
#define ICON_SIZE 20

static void rounded_rect(cairo_t *cr, double x, double y, double w, double h, double r) {
    cairo_new_sub_path(cr);
    cairo_arc(cr, x + w - r, y + r, r, -M_PI / 2, 0);
    cairo_arc(cr, x + w - r, y + h - r, r, 0, M_PI / 2);
    cairo_arc(cr, x + r, y + h - r, r, M_PI / 2, M_PI);
    cairo_arc(cr, x + r, y + r, r, M_PI, 3 * M_PI / 2);
    cairo_close_path(cr);
}

static void line(cairo_t *cr, double x1, double y1, double x2, double y2) {
    cairo_move_to(cr, x1, y1);
    cairo_line_to(cr, x2, y2);
}

/// An arrowhead at the end of an arc, pointing along it.
static void arrowhead(cairo_t *cr, double cx, double cy, double r, double angle) {
    double x = cx + r * cos(angle), y = cy + r * sin(angle);
    // Along the arc, clockwise, at its end.
    double tx = -sin(angle), ty = cos(angle);
    double nx = cos(angle), ny = sin(angle);
    line(cr, x, y, x - 3 * tx + 2.5 * nx, y - 3 * ty + 2.5 * ny);
    line(cr, x, y, x - 3 * tx - 2.5 * nx, y - 3 * ty - 2.5 * ny);
}

static void draw_budget(cairo_t *cr) {
    // A wallet with its pocket and clasp.
    rounded_rect(cr, 2, 5, 16, 11, 2);
    rounded_rect(cr, 12, 8.5, 6, 4, 1);
    cairo_stroke(cr);
    cairo_arc(cr, 14.5, 10.5, 0.9, 0, 2 * M_PI);
    cairo_fill(cr);
}

static void draw_house(cairo_t *cr) {
    cairo_move_to(cr, 2, 10);
    cairo_line_to(cr, 10, 3);
    cairo_line_to(cr, 18, 10);
    cairo_move_to(cr, 4.5, 8.5);
    cairo_line_to(cr, 4.5, 17);
    cairo_line_to(cr, 15.5, 17);
    cairo_line_to(cr, 15.5, 8.5);
    cairo_move_to(cr, 8.5, 17);
    cairo_line_to(cr, 8.5, 12.5);
    cairo_line_to(cr, 11.5, 12.5);
    cairo_line_to(cr, 11.5, 17);
}

static void draw_swords(cairo_t *cr) {
    // Two blades crossed, each with a guard and a grip.
    line(cr, 3, 3, 13.5, 13.5);
    line(cr, 11, 16, 16, 11);
    line(cr, 14.5, 14.5, 17.5, 17.5);
    line(cr, 17, 3, 6.5, 13.5);
    line(cr, 4, 11, 9, 16);
    line(cr, 5.5, 14.5, 2.5, 17.5);
}

static void draw_extensions(cairo_t *cr) {
    rounded_rect(cr, 2.5, 2.5, 6.5, 6.5, 1.5);
    rounded_rect(cr, 11, 2.5, 6.5, 6.5, 1.5);
    rounded_rect(cr, 2.5, 11, 6.5, 6.5, 1.5);
    rounded_rect(cr, 11, 11, 6.5, 6.5, 1.5);
}

static void draw_sync(cairo_t *cr) {
    // Two arrows chasing each other round a circle.
    double r = 6.5;
    cairo_new_sub_path(cr);
    cairo_arc(cr, 10, 10, r, M_PI * 1.1, M_PI * 1.85);
    arrowhead(cr, 10, 10, r, M_PI * 1.85);
    cairo_new_sub_path(cr);
    cairo_arc(cr, 10, 10, r, M_PI * 0.1, M_PI * 0.85);
    arrowhead(cr, 10, 10, r, M_PI * 0.85);
}

static void draw_hourglass(cairo_t *cr) {
    line(cr, 4.5, 2.5, 15.5, 2.5);
    line(cr, 4.5, 17.5, 15.5, 17.5);
    cairo_move_to(cr, 6, 2.5);
    cairo_line_to(cr, 14, 17.5);
    cairo_move_to(cr, 14, 2.5);
    cairo_line_to(cr, 6, 17.5);
}

static void draw_account(cairo_t *cr) {
    cairo_new_sub_path(cr);
    cairo_arc(cr, 10, 6.5, 3.5, 0, 2 * M_PI);
    cairo_new_sub_path(cr);
    cairo_arc(cr, 10, 19, 7, M_PI, 2 * M_PI);
}

static void on_draw_icon(GtkDrawingArea *area, cairo_t *cr, int width, int height, gpointer data) {
    (void)data;
    const char *kind = g_object_get_data(G_OBJECT(area), "icon");
    if (!kind) return;
    GdkRGBA color;
    gtk_widget_get_color(GTK_WIDGET(area), &color);
    gdk_cairo_set_source_rgba(cr, &color);
    cairo_translate(cr, (width - ICON_SIZE) / 2.0, (height - ICON_SIZE) / 2.0);
    cairo_set_line_width(cr, 1.6);
    cairo_set_line_cap(cr, CAIRO_LINE_CAP_ROUND);
    cairo_set_line_join(cr, CAIRO_LINE_JOIN_ROUND);
    if (strcmp(kind, "budget") == 0) {
        draw_budget(cr);
        return;
    }
    if (strcmp(kind, "house") == 0) draw_house(cr);
    else if (strcmp(kind, "swords") == 0) draw_swords(cr);
    else if (strcmp(kind, "extensions") == 0) draw_extensions(cr);
    else if (strcmp(kind, "sync") == 0) draw_sync(cr);
    else if (strcmp(kind, "syncing") == 0) draw_hourglass(cr);
    else if (strcmp(kind, "account") == 0) draw_account(cr);
    cairo_stroke(cr);
}

GtkWidget *wellspent_gtk_rail_button(const char *icon) {
    GtkWidget *button = gtk_button_new();
    GtkWidget *area = gtk_drawing_area_new();
    gtk_drawing_area_set_content_width(GTK_DRAWING_AREA(area), ICON_SIZE);
    gtk_drawing_area_set_content_height(GTK_DRAWING_AREA(area), ICON_SIZE);
    gtk_drawing_area_set_draw_func(GTK_DRAWING_AREA(area), on_draw_icon, NULL, NULL);
    gtk_button_set_child(GTK_BUTTON(button), area);
    wellspent_gtk_rail_button_set_icon(button, icon);
    return button;
}

void wellspent_gtk_rail_button_set_icon(GtkWidget *button, const char *icon) {
    GtkWidget *area = gtk_button_get_child(GTK_BUTTON(button));
    if (!area || !GTK_IS_DRAWING_AREA(area)) return;
    g_object_set_data_full(G_OBJECT(area), "icon", g_strdup(icon), g_free);
    gtk_widget_queue_draw(area);
}

const char *wellspent_gtk_rail_button_icon(GtkWidget *button) {
    GtkWidget *area = gtk_button_get_child(GTK_BUTTON(button));
    return area ? g_object_get_data(G_OBJECT(area), "icon") : NULL;
}
