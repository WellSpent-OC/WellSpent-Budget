"""The keyboard in a sheet: Tab and Shift+Tab move between its fields, as in
the main window. Nothing here signs in, so it runs without the test
mailbox's token."""

import unittest

from wellspent_ui import launch_fresh


class SheetKeys(unittest.TestCase):

    def test_tab_moves_between_the_sign_in_fields(self):
        app = launch_fresh(self)
        app.button("Sign in", within=app.main).press()
        sheet = app.wait_for_window(2, "the account sheet")
        email, password = app.field("Email", sheet), app.field("Password", sheet)
        app.until(lambda: email.focused, "the keyboard on Email")

        app.key("Tab")
        app.until(lambda: password.focused, "Tab to move the keyboard to Password")
        self.assertFalse(email.focused)

        app.key("shift+Tab")
        app.until(lambda: email.focused, "Shift+Tab to move the keyboard back to Email")


if __name__ == "__main__":
    unittest.main()
