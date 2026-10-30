#include "wellspent_native.h"
#include <gtk/gtk.h>

#define COMPOSER "wellspent-wartable-composer"
#define SEND "wellspent-wartable-send"
#define TRANSCRIPT "wellspent-wartable-transcript"

static GtkWidget *named_control(GtkWidget *widget) {
    if (GTK_IS_DROP_DOWN(widget) || GTK_IS_CHECK_BUTTON(widget)) return widget;
    for (GtkWidget *child = gtk_widget_get_first_child(widget); child; child = gtk_widget_get_next_sibling(child)) {
        GtkWidget *found = named_control(child);
        if (found) return found;
    }
    return NULL;
}
static gboolean label_control_idle(gpointer widget) {
    g_object_set_data(G_OBJECT(widget), "wartable-label-pending", NULL);
    GtkWidget *control = named_control(GTK_WIDGET(widget));
    const char *label = g_object_get_data(G_OBJECT(widget), "wartable-control-label");
    const char *description = g_object_get_data(G_OBJECT(widget), "wartable-control-description");
    if (control && label) gtk_accessible_update_property(GTK_ACCESSIBLE(control),
        GTK_ACCESSIBLE_PROPERTY_LABEL, label, GTK_ACCESSIBLE_PROPERTY_DESCRIPTION, label, -1);
    // A description alone keeps GTK's own name for the control, such as a
    // list's chosen option, and says what the control is for after it.
    if (control && description && !label) gtk_accessible_update_property(GTK_ACCESSIBLE(control),
        GTK_ACCESSIBLE_PROPERTY_DESCRIPTION, description, -1);
    return G_SOURCE_REMOVE;
}
void wellspent_wartable_control_label(void *widget, const char *label) {
    if (!GTK_IS_WIDGET(widget)) return;
    // SwiftCrossUI's Picker and checkbox Toggle are composite views. Name the
    // actual control rather than the surrounding anonymous layout container.
    g_object_set_data_full(G_OBJECT(widget), "wartable-control-label", g_strdup(label), g_free);
    // Composite children can be attached after the inspection callback.
    if (!g_object_get_data(G_OBJECT(widget), "wartable-label-pending")) {
        g_object_set_data(G_OBJECT(widget), "wartable-label-pending", GINT_TO_POINTER(1));
        g_idle_add_full(G_PRIORITY_DEFAULT_IDLE, label_control_idle, g_object_ref(widget), g_object_unref);
    }
}

void wellspent_control_description(void *widget, const char *description) {
    if (!GTK_IS_WIDGET(widget)) return;
    g_object_set_data_full(G_OBJECT(widget), "wartable-control-description", g_strdup(description), g_free);
    if (!g_object_get_data(G_OBJECT(widget), "wartable-label-pending")) {
        g_object_set_data(G_OBJECT(widget), "wartable-label-pending", GINT_TO_POINTER(1));
        g_idle_add_full(G_PRIORITY_DEFAULT_IDLE, label_control_idle, g_object_ref(widget), g_object_unref);
    }
}

typedef struct { GWeakRef button; } SendAction;

static void free_send(gpointer data) {
    SendAction *action = data;
    g_weak_ref_clear(&action->button);
    g_free(action);
}

static gboolean send_key(GtkEventControllerKey *controller, guint key, guint code,
                         GdkModifierType modifiers, gpointer data) {
    (void)code;
    if ((key != GDK_KEY_Return && key != GDK_KEY_KP_Enter) ||
        (modifiers & gtk_accelerator_get_default_mod_mask()) != GDK_CONTROL_MASK) return FALSE;
    GtkWidget *window = gtk_event_controller_get_widget(GTK_EVENT_CONTROLLER(controller));
    if (!gtk_window_is_active(GTK_WINDOW(window))) return FALSE;
    GtkWidget *focus = gtk_window_get_focus(GTK_WINDOW(window));
    if (!GTK_IS_TEXT_VIEW(focus) || !g_object_get_data(G_OBJECT(focus), COMPOSER) ||
        !gtk_widget_is_sensitive(focus) || !gtk_widget_get_mapped(focus)) return FALSE;
    // During the brief focus transition to a modal sheet, the main window
    // may still report active. It must not submit the draft underneath it.
    GListModel *windows = gtk_window_get_toplevels();
    for (guint i = 0; i < g_list_model_get_n_items(windows); i++) {
        GtkWindow *other = g_list_model_get_item(windows, i);
        gboolean blocks = gtk_window_get_modal(other) && gtk_widget_get_visible(GTK_WIDGET(other)) &&
            gtk_window_get_transient_for(other) == GTK_WINDOW(window);
        g_object_unref(other);
        if (blocks) return FALSE;
    }
    SendAction *action = data;
    GtkWidget *button = g_weak_ref_get(&action->button);
    if (!button) return FALSE;
    gboolean allowed = gtk_widget_get_root(button) == GTK_ROOT(window) &&
        gtk_widget_get_mapped(button) && gtk_widget_is_sensitive(button);
    gboolean handled = allowed && gtk_widget_activate(button);
    g_object_unref(button);
    return handled;
}

static void install_send(GtkWidget *button, gpointer unused) {
    (void)unused;
    GtkRoot *root = gtk_widget_get_root(button);
    if (!GTK_IS_APPLICATION_WINDOW(root)) return;
    SendAction *action = g_object_get_data(G_OBJECT(root), SEND);
    if (!action) {
        action = g_new0(SendAction, 1);
        g_weak_ref_init(&action->button, button);
        g_object_set_data_full(G_OBJECT(root), SEND, action, free_send);
        GtkEventController *keys = gtk_event_controller_key_new();
        gtk_event_controller_set_name(keys, "WellSpent WarTable send");
        gtk_event_controller_set_propagation_phase(keys, GTK_PHASE_CAPTURE);
        g_signal_connect(keys, "key-pressed", G_CALLBACK(send_key), action);
        gtk_widget_add_controller(GTK_WIDGET(root), keys);
    } else {
        g_weak_ref_set(&action->button, button);
    }
}

void wellspent_wartable_composer(void *widget) {
    if (!GTK_IS_TEXT_VIEW(widget)) return;
    g_object_set_data(G_OBJECT(widget), COMPOSER, GINT_TO_POINTER(1));
    gtk_accessible_update_property(GTK_ACCESSIBLE(widget),
        GTK_ACCESSIBLE_PROPERTY_LABEL, "Message",
        GTK_ACCESSIBLE_PROPERTY_DESCRIPTION, "Enter inserts a newline. Control Enter sends.", -1);
}

void wellspent_wartable_send(void *widget) {
    if (!GTK_IS_BUTTON(widget)) return;
    if (!g_object_get_data(G_OBJECT(widget), SEND)) {
        g_signal_connect(widget, "realize", G_CALLBACK(install_send), NULL);
        g_object_set_data(G_OBJECT(widget), SEND, GINT_TO_POINTER(1));
    }
    install_send(GTK_WIDGET(widget), NULL);
}

typedef struct {
    GtkAdjustment *adjustment; // Retained while callbacks are installed.
    gboolean following;
    gboolean moving;
    guint pending;
    char *conversation;
    char *first_message;
    char *last_message;
    int latest_request;
    gboolean prepending;
    double anchor_value;
    double anchor_upper;
} Transcript;

static double bottom(GtkAdjustment *adjustment) {
    return MAX(gtk_adjustment_get_lower(adjustment),
               gtk_adjustment_get_upper(adjustment) - gtk_adjustment_get_page_size(adjustment));
}

static gboolean follow_bottom(gpointer data) {
    Transcript *state = data;
    state->pending = 0;
    if (state->prepending && gtk_adjustment_get_upper(state->adjustment) > state->anchor_upper) {
        state->moving = TRUE;
        gtk_adjustment_set_value(state->adjustment, state->anchor_value +
            gtk_adjustment_get_upper(state->adjustment) - state->anchor_upper);
        state->moving = FALSE;
        state->prepending = FALSE;
    } else if (state->following) {
        state->moving = TRUE;
        gtk_adjustment_set_value(state->adjustment, bottom(state->adjustment));
        state->moving = FALSE;
    }
    return G_SOURCE_REMOVE;
}

static void queue_follow(Transcript *state) {
    if (!state->pending) state->pending = g_idle_add(follow_bottom, state);
}

static void transcript_changed(GtkAdjustment *adjustment, gpointer data) {
    (void)adjustment;
    Transcript *state = data;
    if (state->following || state->prepending) queue_follow(state);
}

static void transcript_scrolled(GtkAdjustment *adjustment, gpointer data) {
    Transcript *state = data;
    if (!state->moving) {
        state->following = gtk_adjustment_get_value(adjustment) >= bottom(adjustment) - 2;
    }
}

static void free_transcript(gpointer data) {
    Transcript *state = data;
    if (state->pending) g_source_remove(state->pending);
    g_signal_handlers_disconnect_by_data(state->adjustment, state);
    g_object_unref(state->adjustment);
    g_free(state->conversation);
    g_free(state->first_message);
    g_free(state->last_message);
    g_free(state);
}

void wellspent_wartable_transcript(void *widget, const char *conversation, const char *first_message,
                                  const char *last_message, int latest_request) {
    if (!GTK_IS_SCROLLED_WINDOW(widget)) return;
    Transcript *state = g_object_get_data(G_OBJECT(widget), TRANSCRIPT);
    if (!state) {
        state = g_new0(Transcript, 1);
        state->adjustment = g_object_ref(gtk_scrolled_window_get_vadjustment(GTK_SCROLLED_WINDOW(widget)));
        state->following = TRUE;
        g_signal_connect(state->adjustment, "changed", G_CALLBACK(transcript_changed), state);
        g_signal_connect(state->adjustment, "value-changed", G_CALLBACK(transcript_scrolled), state);
        g_object_set_data_full(G_OBJECT(widget), TRANSCRIPT, state, free_transcript);
    }
    gboolean switched = g_strcmp0(state->conversation, conversation) != 0;
    gboolean appended = !switched && state->last_message &&
        g_strcmp0(state->last_message, last_message) != 0 && last_message && *last_message;
    if (switched || state->latest_request != latest_request) {
        state->prepending = FALSE;
        state->following = TRUE;
        queue_follow(state);
    } else if (!appended && state->first_message && *state->first_message &&
               g_strcmp0(state->first_message, first_message) != 0) {
        // Called before GTK lays out the newly prepended history. Keep the
        // same visible text by adding only the new content's height.
        state->prepending = TRUE;
        state->following = FALSE;
        state->anchor_upper = gtk_adjustment_get_upper(state->adjustment);
        state->anchor_value = gtk_adjustment_get_value(state->adjustment);
    }
    if (appended) {
#if GTK_CHECK_VERSION(4, 14, 0)
        gtk_accessible_announce(GTK_ACCESSIBLE(widget), "New messages", GTK_ACCESSIBLE_ANNOUNCEMENT_PRIORITY_LOW);
#endif
    }
    g_free(state->conversation);
    g_free(state->first_message);
    g_free(state->last_message);
    state->conversation = g_strdup(conversation);
    state->first_message = g_strdup(first_message);
    state->last_message = g_strdup(last_message);
    state->latest_request = latest_request;
}

int wellspent_wartable_open_url(const char *url) {
    GUri *uri = g_uri_parse(url, G_URI_FLAGS_NONE, NULL);
    if (!uri) return 0;
    gboolean safe = g_strcmp0(g_uri_get_scheme(uri), "https") == 0 &&
        g_uri_get_host(uri) && *g_uri_get_host(uri) && !g_uri_get_userinfo(uri);
    g_uri_unref(uri);
    if (!safe) return 0;
    char *program = g_find_program_in_path("google-chrome");
    if (!program) program = g_find_program_in_path("google-chrome-stable");
    if (!program) return 0;
    char *quoted = g_shell_quote(program);
    char *command = g_strconcat(quoted, " %u", NULL);
    GAppInfo *chrome = g_app_info_create_from_commandline(command, "Google Chrome", G_APP_INFO_CREATE_SUPPORTS_URIS, NULL);
    g_free(command); g_free(quoted); g_free(program);
    if (!chrome) return 0;
    GList *uris = g_list_append(NULL, (gpointer)url);
    gboolean opened = g_app_info_launch_uris(chrome, uris, NULL, NULL);
    g_list_free(uris); g_object_unref(chrome);
    return opened ? 1 : 0;
}
