// What the Linux app needs from C: the desktop keyring (Secret Service, through
// libsecret, whose calls are variadic and so not callable from Swift), the GTK
// clipboard, and handing a clicked link to the copy of the app already running.
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
