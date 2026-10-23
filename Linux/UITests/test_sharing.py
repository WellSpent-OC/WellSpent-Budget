"""The Share sheet (Features/Sharing.md) in the real window, for one person:
what it asks, the link it makes and copies, and what it says signed out.

The tests signed in make Robin's account once per run and sign into it after
that, so they're skipped without the test mailbox's token. What happens once
someone joins is in test_sharing_shared.py."""

import subprocess
import unittest

from wellspent_ui import launch_fresh, needs_accounts, unique

VIEW = "Sees every budget and transaction. Changes nothing."
ADD = "Adds transactions, and edits or deletes their own."
MANAGE = "Edits budgets, edits or deletes anyone's transactions, and invites other people."


def clipboard():
    return subprocess.run(["xclip", "-o", "-selection", "clipboard"], capture_output=True, text=True).stdout


class Sharing(unittest.TestCase):

    def open_share(self, app, group):
        app.pick("Share…", app.group_menu(group))
        return app.wait_for_window(2, "the Share sheet")

    def lists(self, sheet):
        return [e for e in sheet.all("combo box") if e.showing]

    def test_signed_out_share_makes_no_link(self):
        app = launch_fresh(self)

        # Scenario SHARE-04
        # 1. Signed out, Share… says to sign in first, and Create Link stays
        # dimmed even with a name typed.
        sheet = self.open_share(app, "Household")
        app.wait_shows("Sign in first. Sharing goes through your account.", within=sheet)
        app.field("Your name", sheet).type("Robin")
        self.assertFalse(app.button("Create Link", within=sheet).enabled)
        app.button("Cancel", within=sheet).press()
        app.wait_for_window(1, "the Share sheet to close")

    def test_what_share_asks_and_the_link_it_makes(self):
        needs_accounts(self)
        app = launch_fresh(self)
        app.sign_in_as("Robin")
        flat = unique("Flat")
        app.new_group(flat)
        self.addCleanup(app.remove_group, flat)
        app.sync()

        # Scenario SHARE-01
        # 1. Share… opens "Share “Flat n”", asking for his name, with a hint
        # in the empty box, what they can do, Add chosen, and what they see,
        # Everything so far chosen.
        sheet = self.open_share(app, flat)
        texts = app.texts(sheet)
        self.assertIn(f"Share “{flat}”", texts)
        for words in ("Your name", "They can", "They see", "You get a link to send by text or email."):
            self.assertIn(words, texts)
        name = app.field("Your name", sheet)
        self.assertEqual("", name.text)
        self.assertEqual("How the group will see you", name.placeholder)
        role, history = self.lists(sheet)
        self.assertEqual("Add", role.words)
        self.assertEqual(["View", "Add", "Manage"], app.offered(role))
        self.assertEqual("Everything so far", history.words)
        self.assertEqual(["Everything so far", "Only from now on"], app.offered(history))
        app.button("Cancel", within=sheet)

        # Scenario SHARE-01
        # 2. A line says what the chosen level lets someone do.
        self.assertIn(ADD, app.texts(sheet))
        for level, words in (("View", VIEW), ("Manage", MANAGE), ("Add", ADD)):
            app.choose(level, role)
            app.wait_shows(words, within=sheet)

        # Scenario SHARE-01
        # 3. Create Link stays dimmed until he types a name.
        create = app.button("Create Link", within=sheet)
        self.assertFalse(create.enabled)
        name.type("Robin")
        app.until(lambda: create.enabled, "Create Link to light")

        # Scenario SHARE-02
        # 4. Create Link shows the link, with what to do with it, and Copy Link
        # and Done. (A staging build's links name staging: wellspent-staging.)
        create.press()
        link = app.until(lambda: next((t for t in app.texts(app.front) if "://join" in t), None), "the link")
        link = link.replace("\n", "").replace(" ", "")
        self.assertRegex(link, r"^wellspent(-staging)?://join")
        self.assertIn("Send this to the person you are inviting. It works once and expires in 7 days.",
                      app.texts(app.front))

        # Scenario SHARE-02
        # 5. Copy Link puts it on the clipboard, and Done closes the sheet.
        app.button("Copy Link", within=app.front).press()
        app.until(lambda: clipboard() == link, "the link on the clipboard")
        app.button("Done", within=app.front).press()
        app.wait_for_window(1, "the Share sheet to close")

        # Scenario SHARE-01
        # 6. The next time, "Your name" holds the name he used for it.
        sheet = self.open_share(app, flat)
        self.assertEqual("Robin", app.field("Your name", sheet).text)
        app.button("Cancel", within=sheet).press()
        app.wait_for_window(1, "the Share sheet to close")


if __name__ == "__main__":
    unittest.main()
