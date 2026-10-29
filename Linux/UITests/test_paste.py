"""Pasting into the Linux app's fields (Features/Paste.md), with the real
keyboard: Ctrl+V with words on the clipboard, select all, copy and cut, in
the account sheet, a transaction's sheet, and the sheets for making a group
or a budget and for joining. Nothing is saved except one sign-in."""

import base64
import secrets
import unittest
import urllib.parse

from wellspent_ui import SERVER_OVERRIDE, STAGING, account, launch_fresh, needs_accounts

SYNCED = "Syncs through WellSpent's server"


def made_up_link(group, inviter):
    """A link of this build's type with a secret nobody made, enough for the
    sheet to say who sent it and to what. Joining is not tried."""
    secret = base64.urlsafe_b64encode(secrets.token_bytes(32)).decode().rstrip("=")
    return "wellspent-staging://join#" + urllib.parse.urlencode(
        {"s": secret, "g": group, "f": inviter}, quote_via=urllib.parse.quote)


class Paste(unittest.TestCase):

    def pasted(self, app, text, into):
        app.paste(text, into)
        app.until(lambda: into.text == text, f"the paste to land in {into!r}")

    def test_pasting_into_every_field_of_the_account_sheet(self):
        app = launch_fresh(self)
        app.button("Sign in", within=app.main).press()
        sheet = app.wait_for_window(2, "the account sheet")

        # Scenario PASTE-01, PASTE-09
        # 1. Signing in: the address, the server's address and the password.
        # Sign in lights once the password is pasted.
        self.pasted(app, "pasted@example.com", app.field("Email", sheet))
        server = app.field("Server", sheet)
        address = server.text
        self.pasted(app, address + "/", server)
        self.pasted(app, address, server)
        self.assertFalse(app.button("Sign in", within=sheet).enabled, "Sign in lit before the password")
        app.paste("a-long-password", app.field("Password", sheet))
        app.until(lambda: app.button("Sign in", within=sheet).enabled, "Sign in to light")

        # Scenario PASTE-09
        # 2. Making an account: the address, and the password twice.
        app.button("Create an account", within=sheet).press()
        app.wait_shows("Create account", within=app.front, role="push button")
        sheet = app.front
        self.pasted(app, "new-person@example.com", app.field("Email", sheet))
        app.paste("a-long-password", app.field("Password", sheet))
        self.assertFalse(app.button("Create account", within=sheet).enabled, "Create account, with the password once")
        app.paste("a-long-password", app.field("Confirm password", sheet))
        app.until(lambda: app.button("Create account", within=sheet).enabled, "Create account to light")
        app.button("Cancel", within=sheet).press()
        app.wait_for_window(1, "the account sheet to close")

        # Scenario PASTE-09
        # 3. A forgotten password, for an address with no account: the code
        # goes in as the email shows it, with its dash, then the new
        # password twice.
        app.button("Sign in", within=app.main).press()
        sheet = app.wait_for_window(2, "the account sheet")
        nobody = f"nobody-{secrets.token_hex(4)}@example.com"
        self.pasted(app, nobody, app.field("Email", sheet))
        app.button("Forgot your password?", within=sheet).press()
        app.wait_shows("Reset your password")
        app.button("Send code", within=app.front).press()
        app.wait_shows("Code", within=app.front)
        sheet = app.front
        self.pasted(app, "K7QF-2M9X", app.field("Code", sheet))
        app.paste("a-new-long-password", app.field("New password", sheet))
        self.assertFalse(app.button("Set password", within=sheet).enabled, "Set password, with the new password once")
        app.paste("a-new-long-password", app.field("Confirm password", sheet))
        app.until(lambda: app.button("Set password", within=sheet).enabled, "Set password to light")
        app.button("Start over", within=sheet).press()

    def test_signing_in_by_pasting(self):
        needs_accounts(self)
        app = launch_fresh(self)
        email, password = account("Robin")

        # Scenario PASTE-02
        # 1. The email and the password pasted, then Sign in: signed in, and
        # the foot of the list says so.
        app.button("Sign in", within=app.main).press()
        sheet = app.wait_for_window(2, "the account sheet")
        if SERVER_OVERRIDE:
            app.field("Server", sheet).type(STAGING)
        self.pasted(app, email, app.field("Email", sheet))
        app.paste(password, app.field("Password", sheet))
        app.button("Sign in", within=sheet).press()
        app.wait_for_window(1, "the account sheet to close")
        app.wait_shows(SYNCED, within=app.main)

    def test_select_all_copy_cut_and_paste_in_a_transactions_fields(self):
        app = launch_fresh(self)
        app.new_group("Shop")
        app.new_budget("Food", "500", group="Shop")
        app.button("Add", within=app.main).press()
        sheet = app.wait_for_window(2, "the New transaction sheet")
        merchant, amount, note = (app.field(label, sheet) for label in ("Merchant", "Amount", "Note"))

        # Scenario PASTE-04
        # 1. Select all, then typing replaces the whole field, in each one.
        for box, before, after in ((merchant, "Hilltop", "Probe"), (amount, "12.50", "40"), (note, "a note", "b")):
            box.type(before)
            app.keyboard_to(box)
            app.key("ctrl+a")
            app.typing(after)
            app.until(lambda: box.text == after, f"{after!r} alone in {box!r}")

        # Scenario PASTE-05
        # 2. Copy, type over, then paste brings the copied words back.
        for box, words in ((merchant, "Probe"), (amount, "40"), (note, "b")):
            app.keyboard_to(box)
            app.key("ctrl+a")
            app.key("ctrl+c")
            app.typing("X")
            app.until(lambda: box.text == "X", f"X alone in {box!r}")
            app.key("ctrl+a")
            app.key("ctrl+v")
            app.until(lambda: box.text == words, f"{words!r} back in {box!r}")

        # Scenario PASTE-06
        # 3. Cut takes the words out, and paste puts them back.
        note.type("weekly shop")
        app.keyboard_to(note)
        app.key("ctrl+a")
        app.key("ctrl+x")
        app.until(lambda: note.text == "", "Note to empty")
        app.key("ctrl+v")
        app.until(lambda: note.text == "weekly shop", "Note to say weekly shop again")
        app.button("Cancel", within=sheet).press()
        app.wait_for_window(1, "the sheet to close")

    def test_pasting_into_the_fields_for_making_and_joining(self):
        app = launch_fresh(self)

        # Scenario PASTE-10
        # 1. A new budget's name and amount, the amount as a bank shows it.
        app.near("push button", "Add Budget", to=app.button("More", within=app.main)).press()
        sheet = app.wait_for_window(2, "the New Budget sheet")
        self.pasted(app, "Pasted Budget", app.field("Name", sheet))
        self.pasted(app, "$1,250.00", app.field("Each month", sheet))
        app.button("Cancel", within=sheet).press()
        app.wait_for_window(1, "the sheet to close")

        # Scenario PASTE-10
        # 2. A new group's name.
        app.pick("New Group…", app.open_menu(app.button("More", within=app.main)))
        sheet = app.wait_for_window(2, "the New Group sheet")
        self.pasted(app, "Pasted Group", app.field("Name", sheet))
        app.button("Cancel", within=sheet).press()
        app.wait_for_window(1, "the sheet to close")

        # Scenario PASTE-03, PASTE-10
        # 3. Join a Group: the pasted link says who sent it and to which
        # group, and the name takes a paste too.
        app.pick("Join a Group…", app.open_menu(app.button("More", within=app.main)))
        sheet = app.wait_for_window(2, "the Join a Group sheet")
        link = made_up_link("Household", "Leslie")
        self.pasted(app, link, app.field("Invite link", sheet))
        app.wait_shows("Leslie invited you to “Household”.", within=sheet)
        self.pasted(app, "Robin", app.field("Your name", sheet))
        app.button("Cancel", within=sheet).press()
        app.wait_for_window(1, "the sheet to close")


if __name__ == "__main__":
    unittest.main()
