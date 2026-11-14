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
import unittest.mock

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


class TimedOut:
    """A node of an app that has stopped answering: every call to it fails
    the way the tree fails when the app doesn't answer in time."""

    def __getattr__(self, name):
        def call(*arguments):
            raise wellspent_ui.GLib.Error("Timeout was reached")
        return call


class Replaced:
    """A node a redraw replaced: every call says it doesn't exist."""

    def __getattr__(self, name):
        def call(*arguments):
            raise wellspent_ui.GLib.Error("The object /org/a11y/atspi/accessible/42 does not exist")
        return call


class TreeErrors(unittest.TestCase):

    def test_an_app_that_doesnt_answer_is_not_read_as_nothing_there(self):
        with self.assertRaises(wellspent_ui.GLib.Error):
            wellspent_ui._words(TimedOut())
        with self.assertRaises(wellspent_ui.GLib.Error):
            wellspent_ui._walk(TimedOut())

    def test_a_node_a_redraw_replaced_is_still_read_as_gone(self):
        self.assertEqual("", wellspent_ui._words(Replaced()))
        self.assertEqual([], wellspent_ui._walk(Replaced())[1:])


class Quit(unittest.TestCase):

    def test_quitting_an_app_that_crashed_fails(self):
        app = quit_app(139)
        app.pid = None
        app.log = open(os.devnull, "w")
        with self.assertRaises(wellspent_ui.ScreenError) as raised:
            app.quit()
        self.assertIn("crashed, exit status 139", str(raised.exception))

    def test_quitting_an_app_that_quit_as_asked_passes(self):
        app = quit_app(143)
        app.pid = None
        app.log = open(os.devnull, "w")
        app.quit()


class Press(unittest.TestCase):

    def test_a_press_that_did_nothing_fails(self):
        class Pressable:
            def get_action_iface(self):
                return self

            def get_n_actions(self):
                return 1

            def get_child_count(self):
                return 0

        app = quit_app(0)
        app.process = None
        button = wellspent_ui.Element(app, Pressable())
        with unittest.mock.patch.object(wellspent_ui.Atspi.Action, "do_action", lambda node, index: False):
            with self.assertRaises(wellspent_ui.ScreenError):
                button.press()


if __name__ == "__main__":
    unittest.main()
