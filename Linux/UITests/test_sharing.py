"""The email invitation form: required fields, levels and history, sending,
then a visible Pending invitation. Legacy links are covered separately."""

import unittest

from wellspent_ui import RUN, launch_fresh, needs_accounts, unique

VIEW = "Sees every budget and transaction. Changes nothing."
ADD = "Adds transactions, and edits or deletes their own."
MANAGE = "Edits budgets, edits or deletes anyone's transactions, and invites other people."


class Sharing(unittest.TestCase):

    def open_share(self, app, group):
        app.pick("Share…", app.group_menu(group))
        return app.wait_for_window(2, "the invitation sheet")

    def test_signed_out_cannot_send_an_invitation(self):
        app = launch_fresh(self)

        # Scenario SHARE-04, EMAIL-06
        sheet = self.open_share(app, "Household")
        app.wait_shows("Sign in first. Sharing goes through your account.", within=sheet)
        app.field("Their email", sheet).type("person@example.com")
        app.field("Their name", sheet).type("Leslie")
        app.field("Your name", sheet).type("Robin")
        self.assertFalse(app.button("Send Invite", within=sheet).enabled)
        self.assertFalse(app.shows("Create Link", within=sheet))
        self.assertFalse(app.shows("Copy Link", within=sheet))
        app.button("Cancel", within=sheet).press()
        app.wait_for_window(1, "the invitation sheet to close")

    def test_the_form_sends_an_email_and_shows_pending(self):
        needs_accounts(self)
        app = launch_fresh(self)
        app.sign_in_as("Robin")
        flat = unique("Flat")
        app.new_group(flat)
        self.addCleanup(app.remove_group, flat)
        app.sync()
        recipient = f"linux-invite-{RUN}@example.com"

        # Scenario SHARE-01, EMAIL-01
        sheet = self.open_share(app, flat)
        self.assertIn(f"Invite someone to “{flat}”", app.texts(sheet))
        for words in ("Their email", "Their name", "Your name", "They can", "They see"):
            self.assertIn(words, app.texts(sheet))
        email = app.field("Their email", sheet)
        their_name = app.field("Their name", sheet)
        my_name = app.field("Your name", sheet)
        app.until(lambda: email.focused, "Their email to have the keyboard")
        self.assertEqual("name@example.com", email.placeholder)
        self.assertEqual("How the group will see them", their_name.placeholder)
        self.assertEqual("How the group will see you", my_name.placeholder)
        role, history = [e for e in sheet.all("combo box") if e.showing]
        self.assertEqual("Add", role.words)
        self.assertEqual(["View", "Add", "Manage"], app.offered(role))
        self.assertEqual("Everything so far", history.words)
        self.assertEqual(["Everything so far", "Only from now on"], app.offered(history))
        for level, explanation in (("View", VIEW), ("Manage", MANAGE), ("Add", ADD)):
            app.choose(level, role)
            app.wait_shows(explanation, within=sheet)

        send = app.button("Send Invite", within=sheet)
        self.assertFalse(send.enabled)
        my_name.type("Robin")
        their_name.type("Leslie")
        for invalid in ("", "not-an-email", "person@", "@example.com", "two words@example.com"):
            email.type(invalid)
            self.assertFalse(send.enabled, invalid)
        email.type(recipient)
        their_name.type("   ")
        self.assertFalse(send.enabled, "an empty recipient name")
        their_name.type("Leslie")
        my_name.type(" ")
        self.assertFalse(send.enabled, "an empty sender name")
        my_name.type("Robin")
        self.assertTrue(send.enabled)
        send.press()
        app.wait_shows(f"Invitation sent to {recipient}. It stays Pending until they accept or reject it.")
        self.assertFalse(app.shows("Copy Link", within=app.front))
        self.assertFalse(any("://join" in text for text in app.texts(app.front)))
        app.button("Done", within=app.front).press()
        app.wait_for_window(1, "the invitation sheet to close")
        app.group(flat).press()
        app.wait_shows(recipient, within=app.main)
        app.near("label", "Pending", to=app.find("label", recipient, within=app.main))
        app.near("push button", "Cancel Invite", to=app.find("label", recipient, within=app.main))
        self.assertFalse(app.shows("Shared · 2 people · Made by you", within=app.main))

        sheet = self.open_share(app, flat)
        self.assertEqual("Robin", app.field("Your name", sheet).text)
        self.assertEqual("", app.field("Their email", sheet).text)
        app.button("Cancel", within=sheet).press()
        app.wait_for_window(1, "the invitation sheet to close")


if __name__ == "__main__":
    unittest.main()
