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

/// For a launch given a link on its command line. GTK keeps one copy of an app
/// per app ID: when a copy of `app_id` is running already, this launch hands it
/// `link` as GApplication's "open", which the app reads with onOpenURL, and then
/// stops without a window. When none is running, the launch goes on as before.
/// Call it after the app's GtkApplication is made, and before it runs.
void wellspent_hand_link_to_running_copy(const char *app_id, const char *link);
