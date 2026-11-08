"""The sidebar's buttons fit on one line: Add Budget, Sign in, Account and
Sync don't wrap or break in the middle of a word."""

import unittest

from wellspent_ui import launch_fresh, needs_accounts, unique


class SidebarFooter(unittest.TestCase):
    def assertOneLine(self, app, words):
        # Compare with "More", a one-word native button in the same sidebar,
        # so the check follows the desktop theme.
        line = app.button("More", within=app.main).height
        self.assertGreater(line, 0)
        height = app.button(words, within=app.main).height
        self.assertGreater(height, 0)
        self.assertLessEqual(height, line + 2, f"{words} wraps in the sidebar")

    def test_the_sidebar_buttons_fit_on_one_line(self):
        needs_accounts(self)
        app = launch_fresh(self)

        # 1. Signed out: Add Budget and Sign in.
        self.assertOneLine(app, "Add Budget")
        self.assertOneLine(app, "Sign in")

        # 2. Signed in, with a budget open whose bill repeats: Account and
        # Sync. "· 1 repeat" under the wheel takes room from the sidebar,
        # which is where Sync broke into "Syn-" and "c".
        app.sign_in_as("Robin")
        home = unique("Home")
        app.new_group(home)
        self.addCleanup(app.remove_group, home)
        app.new_budget(f"{home} bills", "600", group=home)
        app.button("Add", within=app.main).press()
        sheet = app.wait_for_window(2, "the New transaction sheet")
        app.field("Merchant", sheet).type("Water")
        app.field("Amount", sheet).type("40.00")
        app.find("check box", "Repeats every month", within=sheet).press()
        app.button("Add", within=sheet).press()
        app.wait_for_window(1, "the New transaction sheet to close")
        app.entry("Water")
        self.assertOneLine(app, "Add Budget")
        self.assertOneLine(app, "Account")
        self.assertOneLine(app, "Sync")
        app.picture("sidebar-footer")


if __name__ == "__main__":
    unittest.main()
