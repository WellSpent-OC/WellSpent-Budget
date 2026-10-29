// What the Linux app needs from C: the desktop keyring (Secret Service, through
// libsecret, whose calls are variadic and so not callable from Swift), the GTK
// clipboard, handing a clicked link to the copy of the app already running,
// what a screen reader says about a widget (GTK's accessibility calls are
// variadic too), and quitting cleanly when the system asks.
#pragma once

/// Stores `value` under (service, item) in the default keyring. 1 on success.
int wellspent_keyring_store(const char *service, const char *item, const char *value);

/// The value under (service, item), or NULL when there is none or on error
/// (then *failed is 1). Free it with wellspent_keyring_free.
char *wellspent_keyring_lookup(const char *service, const char *item, int *failed);

/// Removes (service, item). 1 when removed or absent, 0 on error.
int wellspent_keyring_clear(const char *service, const char *item);

void wellspent_keyring_free(char *value);

/// Puts `text` on the clipboard of the default display. Call on GTK's thread.
void wellspent_clipboard_set_text(const char *text);

/// Gets a link another launch handed over, on GTK's thread.
typedef void (*wellspent_link_receiver)(const char *link);

/// How a clicked link reaches the copy of the app that is open already. GTK
/// keeps one copy of an app per app ID. Call it on every launch, after the
/// app's GtkApplication is made and before it runs. The app gets an action,
/// "open-link", that takes a link as plain text: each link it is given goes to
/// `receive`, and the app's window comes to the front. When this launch was
/// given `link` (NULL for none) and a copy of `app_id` is running already, the
/// link goes to that copy's action, and this launch stops without a window.
/// When none is running, the launch goes on as before.
void wellspent_link_handoff(const char *app_id, const char *link, wellspent_link_receiver receive);

/// Called on GTK's thread when the app comes to the front (1), or when its
/// clock should be checked (0). The timer never asks for a sync.
typedef void (*wellspent_lifecycle_receiver)(int came_to_front);

/// Watches this application's windows, including transient sheets. Install
/// after making GtkApplication and before running it. Installing again only
/// replaces the callback. The clock interval is in seconds, at least one.
/// The watch and its timers end with the application.
void wellspent_watch_lifecycle(const char *app_id, unsigned int clock_seconds,
                              wellspent_lifecycle_receiver receive);

/// What a screen reader names `widget` (a GtkWidget), in place of what it
/// shows: for a widget whose look carries its meaning, such as an arrow.
void wellspent_accessible_set_label(void *widget, const char *label);

/// What a screen reader says after the widget's name, such as how much of a
/// budget is used.
void wellspent_accessible_set_description(void *widget, const char *description);

/// Whether a screen reader hears the widget as the one picked, such as the
/// open budget's row. 1 for picked, 0 for not.
void wellspent_accessible_set_selected(void *widget, int selected);

/// The four arrows of the GTK calendar inside `widget` (a GtkWidget): names
/// them, since GTK leaves them unnamed and a screen reader hears four plain
/// buttons, in the order GTK shows them (the month back and on, then the
/// year back and on). A move by them chooses the day the calendar then shows
/// chosen, as a click on a day does. And the arrow keys move the chosen day
/// by a day or a week, as on the Mac. Call after every update.
void wellspent_calendar_arrows(void *widget, const char *previous_month, const char *next_month,
                               const char *previous_year, const char *next_year);

/// Quits the way the app's own last window would when the system asks it to
/// stop (SIGTERM), as a desktop does at log out, instead of the process just
/// ending. Call once, after the app's GtkApplication is made.
void wellspent_quit_on_terminate(void);

/// Tab and Shift+Tab move the keyboard between the controls of the window that
/// holds `widget` (a GtkWidget), once it is in one. For a sheet, whose window
/// lets no Tab through in SwiftCrossUI 0.10.0. Once per window is enough; more
/// calls change nothing.
void wellspent_tab_moves_focus(void *widget);

/// Makes `widget` (a GtkButton) the default action in its window. Return in
/// a single-line entry activates it only while it is enabled. The button
/// waits until it is in a window, and clears the default when unrealized.
void wellspent_default_action(void *widget);

/// Ctrl+N activates this main-window Add button when it is available.
void wellspent_new_entry_shortcut(void *widget);

/// Names a multiline chat editor and marks it as the Ctrl+Enter target.
void wellspent_wartable_composer(void *widget);
void wellspent_wartable_control_label(void *widget, const char *label);
/// Ctrl+Enter in that editor activates this visible, enabled Send button.
void wellspent_wartable_send(void *widget);
/// Follow appended messages only while reading the bottom. A new conversation
/// or changed latest request explicitly scrolls to the newest message.
void wellspent_wartable_transcript(void *widget, const char *conversation, const char *first_message,
                                  const char *last_message, int latest_request);
/// Opens a valid HTTPS URL with installed Google Chrome. Never substitutes Chromium.
int wellspent_wartable_open_url(const char *url);

// MARK: - Native GTK 4 Shell (Phase 1 & Phase 2)

typedef void (*wellspent_gtk_action_cb)(void *context, const char *action_id);
typedef void (*wellspent_gtk_new_budget_cb)(void *context, const char *name, const char *limit);
typedef void (*wellspent_gtk_new_tx_cb)(void *context, const char *merchant, const char *amount, const char *note);
typedef void (*wellspent_gtk_account_cb)(void *context, const char *action, const char *email, const char *password);

void wellspent_gtk_init_css(void);

void *wellspent_gtk_create_shell_window(void *gtk_app,
                                        const char *title,
                                        const char *team_name,
                                        wellspent_gtk_action_cb on_action,
                                        void *context);

void wellspent_gtk_sidebar_clear(void *shell_ptr);

// An invitation at the top of the sidebar, with Accept and Reject. Its
// buttons fire "invite:accept:<id>" and "invite:reject:<id>".
void wellspent_gtk_sidebar_add_invitation(void *shell_ptr, const char *invitation_id,
                                          const char *group_name, const char *invited,
                                          const char *from, const char *terms,
                                          const char *accept_title, const char *reject_title,
                                          int is_responding, const char *failure);

// A group's name (its button fires "group:<id>") and its ⋯ menu. The menu
// spec is one item per line, a line of "-" a divider; an item fires
// "menu:group:<id>:<index>", the index counting items only.
void wellspent_gtk_sidebar_add_group(void *shell_ptr, const char *group_id, const char *title,
                                     const char *toggle_help, int is_page_open, int is_first,
                                     const char *menu_spec);

// A quiet line under a group's name, such as "waiting on its founder".
void wellspent_gtk_sidebar_add_note(void *shell_ptr, const char *text);

// A budget's row, the bar filled to `share`. Fires "budget:<id>".
void wellspent_gtk_sidebar_add_budget(void *shell_ptr, const char *budget_id, const char *name,
                                      const char *amount_text, const char *spoken_value,
                                      double share, int is_over, int is_selected);

// Under the rows: the Add Budget button ("action:add_budget"), the More menu
// (its items fire "menu:add:<index>"), the footer and any sync failure.
void wellspent_gtk_sidebar_add_footer(void *shell_ptr, const char *add_title, const char *more_spec,
                                      const char *status_text, const char *failure_text);

// A question before a delete: the answer is 1 for the confirming button, 0 for
// Cancel or a closed dialog.
typedef void (*wellspent_gtk_ask_cb)(void *context, int confirmed);
void wellspent_gtk_ask(void *shell_ptr, const char *title, const char *message,
                       const char *confirm_title, const char *cancel_title,
                       wellspent_gtk_ask_cb cb, void *context);

// The look: the style sheet shipped with the app, and the fonts it names.
int wellspent_gtk_init_css_file(const char *path);
int wellspent_fonts_add_file(const char *path);

void wellspent_gtk_update_detail_wheel(void *shell_ptr,
                                       const char *budget_name,
                                       const char *day_line,
                                       const char *middle_key,
                                       const char *middle_amount,
                                       const char *middle_of,
                                       const char *pace_text,
                                       double arc,
                                       double tick,
                                       int is_over);

void wellspent_gtk_clear_transactions(void *shell_ptr);

void wellspent_gtk_add_transaction_row(void *shell_ptr,
                                       const char *date,
                                       const char *merchant,
                                       const char *source,
                                       const char *amount);

void wellspent_gtk_set_active_tab(void *shell_ptr, const char *tab_name);

void wellspent_gtk_set_sync_state(void *shell_ptr, int is_syncing);

void wellspent_gtk_show_new_budget_dialog(void *shell_ptr,
                                          wellspent_gtk_new_budget_cb cb,
                                          void *context);

void wellspent_gtk_show_new_tx_dialog(void *shell_ptr,
                                      wellspent_gtk_new_tx_cb cb,
                                      void *context);

void wellspent_gtk_show_account_dialog(void *shell_ptr,
                                       const char *email,
                                       int is_signed_in,
                                       wellspent_gtk_account_cb cb,
                                       void *context);

void wellspent_gtk_window_present(void *shell_ptr);

// Frees the shell struct. Call it once, after the action callback has said
// "window:destroyed"; every widget pointer inside is already NULL by then.
void wellspent_gtk_free_shell(void *shell_ptr);


