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

    def test_a_node_a_redraw_replaced_has_no_role(self):
        # Finding by role reads each node's role, and a redraw can replace a
        # node between finding it and reading it.
        self.assertIsNone(wellspent_ui._role(Replaced()))
        with self.assertRaises(wellspent_ui.GLib.Error):
            wellspent_ui._role(TimedOut())


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

            def clear_cache(self):
                pass

        app = quit_app(0)
        app.process = None
        button = wellspent_ui.Element(app, Pressable())
        with unittest.mock.patch.object(wellspent_ui.Atspi.Action, "do_action", lambda node, index: False):
            with self.assertRaises(wellspent_ui.ScreenError):
                button.press()


class Node:
    """A node with a role and a name, and children. Once `gone`, it reads as
    a node a redraw replaced. With `slow` set, its first `slow` reads fail as
    an app that doesn't answer does."""

    def __init__(self, role, name, children=(), slow=0):
        self.role, self.name, self.children, self.slow, self.gone = role, name, list(children), slow, False

    def _answer(self):
        if self.gone:
            raise wellspent_ui.GLib.Error("The object /org/a11y/atspi/accessible/42 does not exist")
        if self.slow:
            self.slow -= 1
            raise wellspent_ui.GLib.Error("Did not receive a reply")

    def get_role_name(self):
        self._answer()
        return self.role

    def get_name(self):
        self._answer()
        return self.name

    def get_relation_set(self):
        return []

    def clear_cache(self):
        pass

    def get_child_count(self):
        self._answer()
        return len(self.children)

    def get_child_at_index(self, index):
        return self.children[index]


class Focus(unittest.TestCase):
    """focus() finds the element again by its role and words, then tabs to
    it. A redraw or a slow answer between finding it and focusing it must not
    send it looking for the wrong thing (ops#395)."""

    def focusing_app(self):
        app = quit_app(0)
        app.process = None
        app.bring_to_front = lambda: None
        app.sought = []

        def find(role, words, within=None, wait=None):
            app.sought.append((role, words))
            return unittest.mock.Mock(focused=True)
        app.find = find
        return app

    def test_a_redrawn_element_is_focused_by_the_words_it_was_found_by(self):
        app = self.focusing_app()
        box = Node("check box", "Sample Cottage")
        found = wellspent_ui.Element(app, Node("frame", "WellSpent", [box])).all("check box", "Sample Cottage")
        self.assertEqual(1, len(found))
        box.gone = True
        app.focus(found[0])
        self.assertEqual([("check box", "Sample Cottage")], app.sought)

    def test_an_app_slow_to_answer_is_asked_again(self):
        app = self.focusing_app()
        app.focus(wellspent_ui.Element(app, Node("push button", "Save", slow=2)))
        self.assertEqual([("push button", "Save")], app.sought)


class Cached(Node):
    """A node whose children are read from a cache, as libatspi keeps them:
    a child added after the first look stays unseen until the cache is
    cleared."""

    def __init__(self, role, name, children=()):
        super().__init__(role, name, children)
        self.cached = None

    def clear_cache(self):
        self.cached = None

    def get_child_count(self):
        if self.cached is None:
            self.cached = list(self.children)
        return len(self.cached)

    def get_child_at_index(self, index):
        return self.cached[index]


class Within(unittest.TestCase):
    """A step that looks inside a window it found earlier, such as a sheet,
    sees what is drawn there after it found it (ops#395: the House row came
    in after the sheet opened, and picker() waited 15s on the sheet's old
    children)."""

    def test_a_row_drawn_after_the_sheet_was_found_is_seen(self):
        app = quit_app(0)
        app.process = None
        sheet = Cached("dialog", "New transaction", [Node("combo box", "Lake bills")])
        found = wellspent_ui.Element(app, sheet)
        self.assertEqual([], found.all("combo box", "Lake House"))
        sheet.children.append(Node("combo box", "Lake House"))
        self.assertEqual(1, len(found.all("combo box", "Lake House")), "the row drawn later isn't seen")



class Shown(Node):
    """A node that reads as showing, with no description, as a window or a
    combo box on screen does."""

    def get_state_set(self):
        return unittest.mock.Mock(contains=lambda state: True)

    def get_description(self):
        return ""


class HeldSheet(unittest.TestCase):
    """A sheet found when it opens is found again at each step after. GTK
    can redraw a sheet after it first shows, and a step on the window as it
    was then reads nothing and acts on nothing: picker() waited 15s on a
    House picker the screen showed, and Save in the on-hand sheet did nothing
    (ops#416). A redraw while it's held is noted for the failure dump."""

    def setUp(self):
        self.app = quit_app(0)
        self.app.process = None
        self.app.home = os.path.dirname(os.path.abspath(__file__))
        self.main = Shown("frame", wellspent_ui.MAIN_WINDOW, [Shown("label", "Household")])
        self.sheet = Shown("dialog", "New transaction", [Shown("combo box", "Lake bills")])
        self.shown = [self.main, self.sheet]
        self.app.windows = lambda: [wellspent_ui.Element(self.app, node) for node in self.shown]

    def redraw(self):
        """The sheet drawn again: the old node goes, a new one with the House
        picker takes its place."""
        self.sheet.gone = True
        self.sheet = Shown("dialog", "New transaction",
                           [Shown("combo box", "Lake bills"), Shown("combo box", "House")])
        self.shown = [self.main, self.sheet]

    def test_a_sheet_redrawn_after_it_was_found_is_read_as_it_is_now(self):
        held = self.app.wait_for_window(2, "the sheet")
        self.redraw()
        self.assertEqual(1, len(held.all("combo box", "House")), "the redrawn sheet's House picker isn't seen")

    def test_a_redraw_while_held_is_noted_for_the_failure_dump(self):
        held = self.app.wait_for_window(2, "the sheet")
        held.all("combo box")
        self.redraw()
        held.all("combo box")
        self.assertEqual(1, held.redrawn, "the redraw wasn't counted")
        path = os.path.join(self.app.home, ".held-sheet-words.txt")
        self.addCleanup(lambda: os.path.exists(path) and os.remove(path))
        self.app._note_words(path)
        with open(path) as note:
            self.assertIn("New transaction: found again after 1 redraw while held", note.read())

    def test_a_held_sheet_never_becomes_another_window(self):
        # The sheet closes and another opens where it was: the held one
        # isn't read as the new one.
        held = self.app.wait_for_window(2, "the sheet")
        self.sheet.gone = True
        self.shown = [self.main, Shown("dialog", "Delete Lake bills?", [Shown("push button", "Delete")])]
        self.assertEqual([], held.all("push button", "Delete"), "the held sheet read another window's Delete")

    def test_a_held_window_is_found_by_its_name_when_the_order_shifts(self):
        # A question over the sheet is held, then the sheet under it closes:
        # the question moves down a place and is still the one read.
        question = Shown("dialog", "Discard changes?", [Shown("push button", "Discard")])
        self.shown = [self.main, self.sheet, question]
        held = self.app.wait_for_window(3, "the question")
        self.sheet.gone, question.gone = True, True
        self.shown = [self.main, Shown("dialog", "Discard changes?", [Shown("push button", "Discard")])]
        self.assertEqual(1, len(held.all("push button", "Discard")), "the held question was lost when the sheet closed")


class CrashBacktrace(unittest.TestCase):
    """The app is started so that a crash writes its backtrace, frame by
    frame, to its log, which a failure keeps beside the screenshot. The Linux
    app crashed once with exit status 139 and left nothing to read
    (wellspent-ops#421)."""

    def test_the_app_starts_with_a_backtrace_on_a_crash(self):
        app = wellspent_ui.App(path="/bin/true")
        self.addCleanup(lambda: __import__("shutil").rmtree(app.home, ignore_errors=True))
        started = {}

        class Started(Exception):
            pass

        def popen(command, env=None, **_):
            started.update(env)
            raise Started()
        with unittest.mock.patch.object(wellspent_ui.subprocess, "Popen", popen), \
                unittest.mock.patch.object(wellspent_ui, "_accessibility_bus", lambda: "unix:path=/nowhere"):
            with self.assertRaises(Started):
                app.launch()
        settings = dict(part.split("=", 1) for part in started.get("SWIFT_BACKTRACE", "").split(",") if "=" in part)
        self.assertEqual("yes", settings.get("enable"), f"no backtrace on a crash: {started.get('SWIFT_BACKTRACE')!r}")
        self.assertEqual("no", settings.get("interactive"), "a crash would wait for someone to answer")


class Linked(Shown):
    """A showing node that knows its parent, for steps that look near
    something by walking up from it."""

    def __init__(self, role, name, children=()):
        super().__init__(role, name, children)
        self.parent = None
        for child in self.children:
            child.parent = self

    def get_parent(self):
        return self.parent


class CheckBoxByLabel(unittest.TestCase):
    """A listing's check box is found by its label. GTK names a check box
    after its label only once the screen reader catches up, so for a while
    the box has no name and the label beside it does (wellspent-ops#395:
    "waited 15s for a check box saying 'Pool House'" with Pool House on the
    sheet). Then the box is the one nearest the label."""

    def sheet(self, pool_named):
        pool = Linked("check box", "Pool House" if pool_named else "")
        rows = [Linked("panel", "", [pool, Linked("label", "Pool House")]),
                Linked("panel", "", [Linked("check box", ""), Linked("label", "Mountain Cabin")])]
        return pool, wellspent_ui.Element(self.app, Linked("dialog", "", rows))

    def setUp(self):
        self.app = quit_app(0)
        self.app.process = None

    def test_a_named_box_is_found_by_its_name(self):
        pool, sheet = self.sheet(pool_named=True)
        self.assertIs(pool, self.app.check_box("Pool House", within=sheet).node)

    def test_a_box_not_named_yet_is_the_one_beside_its_label(self):
        pool, sheet = self.sheet(pool_named=False)
        self.assertIs(pool, self.app.check_box("Pool House", within=sheet).node,
                      "the box beside Pool House's label wasn't the one found")


class Recording:
    """A button or a field that writes down what was done to it."""

    def __init__(self, app, name):
        self.app, self.name = app, name

    def press(self):
        self.app.done.append(("press", self.name))

    def type(self, text):
        self.app.done.append(("type", self.name, text))


def signing_in_app():
    """An App whose buttons and fields only record, for checking which
    account a sign-in step reaches. Signing up through the window fails."""
    class Signing(wellspent_ui.App):
        main = "main"

    app = Signing.__new__(Signing)
    app.process = None
    app.failure = lambda what: wellspent_ui.ScreenError(what)
    app.done = []
    app.button = lambda name, within=None: Recording(app, name)
    app.field = lambda name, within=None: Recording(app, name)
    app.wait_for_window = lambda count, what: "sheet"
    app.sync = lambda: None

    def sign_up(*arguments):
        raise AssertionError("it made a new, empty account through the window")
    app.sign_up = app.sign_up_on_sheet = sign_up
    return app


class SignIn(unittest.TestCase):
    """A sign-in reaches the person's account for this run whichever test
    asks first, never a new, empty account made on the spot."""

    def setUp(self):
        patcher = unittest.mock.patch.object(wellspent_ui, "account", lambda name: ("robin@example.com", "a password"))
        patcher.start()
        self.addCleanup(patcher.stop)
        patcher = unittest.mock.patch.dict(wellspent_ui._ACCOUNTS, clear=True)
        patcher.start()
        self.addCleanup(patcher.stop)

    def test_signing_in_first_reaches_the_persons_account(self):
        app = signing_in_app()
        self.assertEqual("robin@example.com", app.sign_in_as("Robin"))
        self.assertIn(("type", "Email", "robin@example.com"), app.done)

    def test_signing_in_on_a_sheet_first_reaches_the_persons_account(self):
        app = signing_in_app()
        self.assertEqual("robin@example.com", app.sign_in_on_sheet("Robin"))
        self.assertIn(("type", "Email", "robin@example.com"), app.done)


class SyncButton:
    """Sync as one find of it sees it: greyed when a sync runs, and then
    pressing it does nothing."""

    def __init__(self, app, enabled):
        self.app, self.enabled = app, enabled

    def press(self, does_nothing=False):
        if does_nothing is None:
            if self.enabled:
                self.app.done.append(("press", "Sync"))
            return self.enabled
        if not self.enabled:
            raise wellspent_ui.ScreenError("pressing <push button 'Sync'> did nothing")
        self.app.done.append(("press", "Sync"))


class Sync(unittest.TestCase):

    def check_sync(self, states):
        """Runs sync() where each find of Sync sees the next of `states`."""
        app = signing_in_app()
        app.until = wellspent_ui.App.until.__get__(app)
        app.sync = wellspent_ui.App.sync.__get__(app)
        app.settle = lambda: None
        states = list(states)
        app.button = lambda name, within=None: SyncButton(app, states.pop(0) if states else True)
        app.main = type("Main", (), {"all": lambda self, role: [type("B", (), {"showing": True, "words": "Sync", "enabled": True})()]})()
        with unittest.mock.patch.object(wellspent_ui.time, "sleep", lambda seconds: None):
            app.sync()
        self.assertEqual([("press", "Sync")], app.done)

    def test_a_sync_already_running_is_waited_out_before_pressing(self):
        # The sync a sign-in starts by itself is still running for a moment.
        self.check_sync([False, False, False])

    def test_a_sync_that_starts_just_before_the_press_is_waited_out_too(self):
        # Sync is ready, then a change starts a sync of its own before the
        # press lands, so that press does nothing.
        self.check_sync([True, False])


class SpilledCleanup(unittest.TestCase):
    """A test's clean-up that fails leaves what it made on the server. The
    next test that signs in as that person must not inherit it (ops#392: one
    slow menu, then a failed Delete…, then five later tests saw a stray Food
    budget)."""

    def setUp(self):
        made = iter(range(1, 100))
        patcher = unittest.mock.patch.object(
            wellspent_ui, "_confirmed_account", lambda name: (f"{name.lower()}{next(made)}@example.com", "a password"))
        patcher.start()
        self.addCleanup(patcher.stop)
        patcher = unittest.mock.patch.dict(wellspent_ui._ACCOUNTS, clear=True)
        patcher.start()
        self.addCleanup(patcher.stop)
        patcher = unittest.mock.patch.object(wellspent_ui, "_OPEN_MENUS", [])
        patcher.start()
        self.addCleanup(patcher.stop)

    def removing_app(self, email, menu_fails):
        """An App signed in as `email`, on the Budget tab with the group
        showing, whose group menu fails to open when `menu_fails`."""
        app = signing_in_app()
        app.email = email
        app.until = lambda check, what, wait=None: check()
        app.shows = lambda *arguments, **settings: True
        app.settle = lambda: None

        def group_menu(name):
            if menu_fails:
                raise wellspent_ui.ScreenError("2 menu items say 'Delete…'")
            return "menu"
        app.group_menu = group_menu
        app.menu_items = lambda menu: ["Delete…"]
        app.pick = lambda words, menu: app.done.append(("pick", words))
        app.answer = lambda words: None
        return app

    def test_a_failed_removal_gives_everyone_a_fresh_account_next(self):
        # Leslie made Home 3 and Robin joined it, so it's on both accounts.
        leslie, robin = wellspent_ui.account("Leslie"), wellspent_ui.account("Robin")
        app = self.removing_app(leslie[0], menu_fails=True)
        with self.assertRaises(wellspent_ui.ScreenError):
            app.remove_group("Home 3")
        self.assertNotEqual(leslie, wellspent_ui.account("Leslie"), "the next test gets the account the group was left on")
        self.assertNotEqual(robin, wellspent_ui.account("Robin"), "the next test gets a member's account the group is on")

    def test_a_removal_that_works_keeps_the_account(self):
        first = wellspent_ui.account("Leslie")
        app = self.removing_app(first[0], menu_fails=False)
        present = iter([True, True])
        app.shows = lambda *arguments, **settings: next(present, False)
        app.remove_group("Home 3")
        self.assertIn(("pick", "Delete…"), app.done)
        self.assertEqual(first, wellspent_ui.account("Leslie"), "a clean removal made a new account")

    def test_a_menu_that_opens_too_late_is_still_closed_after(self):
        # The step gives up, then the menu opens. It must be on the list
        # close_open_menus works from, or the next menu opened makes two.
        app = signing_in_app()
        app.button_presses = []
        button = Recording(app, "More")

        def never(check, what, wait=None):
            raise wellspent_ui.ScreenError(f"waited for {what}")
        app.until = never
        with unittest.mock.patch.object(wellspent_ui, "close_open_menus", lambda: None), \
                unittest.mock.patch.object(wellspent_ui, "_menu_open", lambda button: False):
            with self.assertRaises(wellspent_ui.ScreenError):
                app.open_menu(button)
        self.assertIn((app, button), wellspent_ui._OPEN_MENUS, "a menu that opens late is never closed")


if __name__ == "__main__":
    unittest.main()
