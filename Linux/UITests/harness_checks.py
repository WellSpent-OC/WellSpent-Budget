"""Checks of the UI tests' own tools (wellspent_ui), with no app and no
screen. run.sh runs them before the UI tests, so a broken tool fails in
seconds rather than partway through the suite.

    python3 -I Linux/UITests/harness_checks.py
"""

import os
import subprocess
import sys
import time
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import wellspent_ui  # noqa: E402


def quit_app(status):
    """An App whose app has already quit with `status`. A failed step just
    says what failed, with no picture, as there is no screen here."""
    app = wellspent_ui.App.__new__(wellspent_ui.App)
    app.process = subprocess.Popen(["sh", "-c", f"exit {status}"])
    app.process.wait()
    app.failure = lambda what: wellspent_ui.ScreenError(what)
    return app


class Until(unittest.TestCase):

    def test_a_wait_stops_as_soon_as_the_app_has_quit(self):
        app = quit_app(139)
        started = time.monotonic()
        with self.assertRaises(wellspent_ui.ScreenError) as raised:
            app.until(lambda: None, "the window", wait=30)
        self.assertLess(time.monotonic() - started, 2, "it waited out the whole wait for an app that had quit")
        self.assertIn("exit status 139", str(raised.exception))

    def test_a_wait_inside_a_wait_stops_too(self):
        # Steps wait on steps that wait: windows() waits for the main window
        # inside a test's own wait. Each must stop, not only the inner one.
        app = quit_app(139)
        started = time.monotonic()
        with self.assertRaises(wellspent_ui.ScreenError):
            app.until(lambda: app.until(lambda: None, "the main window", wait=30), "the review to close", wait=90)
        self.assertLess(time.monotonic() - started, 2, "the outer wait carried on after the app had quit")


if __name__ == "__main__":
    unittest.main()
