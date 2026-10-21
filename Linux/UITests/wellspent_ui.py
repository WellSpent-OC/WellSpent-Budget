"""The tool the Linux UI tests drive WellSpent with.

It finds what's on screen by its role and its words, through the accessibility
tree GTK publishes (AT-SPI), and acts the way a person does: a press, typed
words, a key. It never clicks at a place on the screen.

Tests say what a person does and sees, in the scenario's words. How to reach a
thing on screen belongs here, never in a test. When something can't be found
by its role and words, the fix goes here or in the app's accessibility labels.
"""

import datetime
import itertools
import json
import os
import secrets
import shutil
import signal
import subprocess
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request

import gi

gi.require_version("Atspi", "2.0")
from gi.repository import Atspi  # noqa: E402

# How long a step waits for the screen to show what it expects. The test
# display is about three times slower than a desktop.
WAIT = float(os.environ.get("WELLSPENT_UI_WAIT", "15"))
OUT = os.environ.get("WELLSPENT_UI_OUT", "/tmp/wellspent-ui")


class ScreenError(AssertionError):
    """The screen didn't show what a step expected. A picture of it is kept."""


# MARK: - Elements


def _text(node):
    try:
        return Atspi.Text.get_text(node, 0, Atspi.Text.get_character_count(node)) or ""
    except Exception:
        return ""


def _words(node):
    """An element's words: its own name, else the text of whatever labels it
    (GTK 4.14 keeps a menu item's words there), else a label's own text."""
    try:
        name = node.get_name() or ""
    except Exception:
        return ""
    if name:
        return name
    try:
        for relation in node.get_relation_set() or []:
            if relation.get_relation_type() == Atspi.RelationType.LABELLED_BY:
                targets = [relation.get_target(i) for i in range(relation.get_n_targets())]
                words = " ".join(_text(t) for t in targets).strip()
                if words:
                    return words
    except Exception:
        pass
    return _text(node) if node.get_role_name() == "label" else ""


def _walk(node):
    found = []
    stack = [node]
    while stack:
        current = stack.pop()
        found.append(current)
        try:
            count = current.get_child_count()
            children = [current.get_child_at_index(i) for i in reversed(range(count))]
        except Exception:
            continue
        # A child can be gone already while GTK rebuilds that part.
        stack.extend(child for child in children if child is not None)
    return found


class Element:
    """One thing on screen: a button, a text, a text box, a menu item."""

    def __init__(self, app, node):
        self.app = app
        self.node = node

    def __repr__(self):
        return f"<{self.role} {self.words!r}>"

    @property
    def role(self):
        return self.node.get_role_name()

    @property
    def words(self):
        return _words(self.node)

    @property
    def value(self):
        """What a screen reader says after the name, such as "48 percent used"."""
        return self.node.get_description() or ""

    @property
    def text(self):
        """What a text box holds, or a label shows."""
        return _text(self.node)

    @property
    def placeholder(self):
        """The example an empty text box shows, such as "500.00"."""
        try:
            return self.node.get_attributes().get("placeholder-text", "")
        except Exception:
            return ""

    def _has(self, state):
        return self.node.get_state_set().contains(state)

    @property
    def enabled(self):
        return self._has(Atspi.StateType.SENSITIVE)

    @property
    def selected(self):
        """Whether it's the one picked, such as the open budget's row."""
        return self._has(Atspi.StateType.SELECTED)

    @property
    def showing(self):
        return self._has(Atspi.StateType.SHOWING)

    def all(self, role=None, words=None, starts=None):
        """Everything inside this element with that role and those words, or
        whose words start with `starts`."""
        return [
            Element(self.app, n)
            for n in _walk(self.node)[1:]
            if (role is None or n.get_role_name() == role)
            and (words is None or _words(n) == words)
            and (starts is None or _words(n).startswith(starts))
        ]

    def press(self):
        """A click, or Space on it: its first action."""
        actions = self.node.get_action_iface()
        if not actions or actions.get_n_actions() == 0:
            raise ScreenError(f"{self!r} can't be pressed")
        Atspi.Action.do_action(self.node, 0)
        self.app.settle()

    def type(self, words):
        """Replaces what a text box holds with `words`, as selecting all and
        typing does."""
        if not Atspi.EditableText.set_text_contents(self.node, words):
            raise ScreenError(f"{self!r} took no words")
        self.app.settle()


# MARK: - The app


class App:
    """One copy of WellSpent, with a home of its own, so it starts with fresh
    data and never touches anyone's budgets.

    Use `launch_fresh(test)` in a test's setUp: the app closes and its files go
    when the test ends."""

    def __init__(self, path=None):
        self.path = path or os.environ["WELLSPENT_APP"]
        self.home = tempfile.mkdtemp(prefix="wellspent-ui-")
        self.process = None
        self.launched_with = {}

    # Starting and stopping

    def launch(self, *arguments, day=None, undo_seconds=None, region="en_US.UTF-8"):
        """Starts the app, given `arguments` as a desktop would, such as an
        invite link. A staging build takes two test settings, as on the Mac:
        `day` pins the money wheel to that day of this month, and
        `undo_seconds` sets how long Undo stays. `region` is the computer's,
        as a desktop names it: the scenarios' United States unless a test
        says otherwise, such as "de_DE.UTF-8"."""
        if self.process is not None:
            raise RuntimeError("already running")
        env = dict(os.environ)
        env.update(HOME=self.home, XDG_DATA_HOME=os.path.join(self.home, ".local/share"),
                   XDG_CONFIG_HOME=os.path.join(self.home, ".config"), LC_ALL=region, LANG=region)
        env.pop("LC_NUMERIC", None)
        env.pop("WELLSPENT_DAY_OF_MONTH", None)
        env.pop("WELLSPENT_UNDO_SECONDS", None)
        if day is not None:
            env["WELLSPENT_DAY_OF_MONTH"] = str(day)
        if undo_seconds is not None:
            env["WELLSPENT_UNDO_SECONDS"] = str(undo_seconds)
        self.launched_with = dict(day=day, undo_seconds=undo_seconds, region=region)
        self.env = env
        self.log = open(os.path.join(self.home, "app.log"), "ab")
        # Each copy runs on a session bus and keyring of its own, as each
        # person's computer has, so several people can be on the screen at
        # once: GTK keeps one copy of an app per bus. All of them show on the
        # one accessibility tree the tests read.
        env["AT_SPI_BUS_ADDRESS"] = _accessibility_bus()
        bus_file = os.path.join(self.home, "session-bus")
        self.process = subprocess.Popen(
            ["dbus-run-session", "--", "sh", "-c",
             'printf "%s" "$DBUS_SESSION_BUS_ADDRESS" > "$WELLSPENT_UI_BUS_FILE"; '
             'eval "$(printf test-keyring | gnome-keyring-daemon --unlock --components=secrets --daemonize)"; '
             'export GNOME_KEYRING_CONTROL; exec "$0" "$@"',
             self.path, *arguments],
            env=dict(env, WELLSPENT_UI_BUS_FILE=bus_file), stdout=self.log, stderr=self.log)
        self.pid = self.until(lambda: _child_named(self.process.pid, "WellSpentLinux"), "the app to start")
        self.session_bus = self.until(lambda: _read(bus_file), "the app's session bus")
        self.until(lambda: self._root() is not None and self.windows(), "the window to open")
        self.settle()
        return self

    def launch_again(self, *arguments):
        """A second launch on this copy's computer, given `arguments`, as a
        click on an invite link while the app is open: GTK hands them to the
        copy that's open, and the second launch stops. Gives its exit status."""
        env = dict(self.env, DBUS_SESSION_BUS_ADDRESS=self.session_bus)
        done = subprocess.run([self.path, *arguments], env=env, stdout=self.log, stderr=self.log, timeout=WAIT)
        self.settle()
        return done.returncode

    def quit(self):
        """Quits as the desktop does when it closes a window: the app saves as
        it goes, so nothing is lost."""
        if self.process is None:
            return
        pid = self.pid
        try:
            os.kill(pid, signal.SIGTERM)
        except ProcessLookupError:
            pass
        try:
            self.process.wait(timeout=WAIT)
        except subprocess.TimeoutExpired:
            self.process.kill()
            self.process.wait()
        self.process = None
        self.log.close()
        self.until(lambda: not self._roots_with(pid), "the app to leave the screen")

    def restart(self):
        """Quits and opens again, with the same data and test settings."""
        self.quit()
        self.launch(**self.launched_with)

    def close(self):
        self.quit()
        shutil.rmtree(self.home, ignore_errors=True)

    # Waiting

    def settle(self):
        """A moment for GTK to draw what a step changed."""
        time.sleep(0.4)

    def until(self, check, what, wait=WAIT):
        """Waits until `check()` gives something truthy, and gives it back.
        Otherwise keeps a picture of the screen and fails, saying `what`."""
        deadline = time.monotonic() + wait
        last_error = None
        while True:
            try:
                result = check()
                if result:
                    return result
            except Exception as error:  # the tree changes under a step
                last_error = error
            if time.monotonic() > deadline:
                picture = self.picture("failed")
                # The app's own log goes beside the picture, since its home
                # goes when the test ends.
                shutil.copyfile(os.path.join(self.home, "app.log"), picture.replace(".png", "-app.log")) \
                    if os.path.exists(os.path.join(self.home, "app.log")) else None
                self._note_process(picture.replace(".png", "-process.txt"))
                cause = f" ({last_error})" if last_error else ""
                raise ScreenError(f"waited {wait:g}s for {what}{cause}. Screen: {picture}")
            time.sleep(0.2)

    def _note_process(self, path):
        """Whether the app was still running when a step failed, and what each
        of its threads was waiting on, to tell a hang from a crash or a quit."""
        lines = []
        pid = getattr(self, "pid", None)
        if pid is None:
            lines.append("no app process was started")
        elif self.process is not None and self.process.poll() is not None:
            lines.append(f"the app's session ended, exit status {self.process.returncode}")
        try:
            with open(f"/proc/{pid}/status") as status:
                lines += [l.strip() for l in status if l.startswith(("State:", "Threads:"))]
            for task in sorted(os.listdir(f"/proc/{pid}/task"), key=int):
                with open(f"/proc/{pid}/task/{task}/comm") as comm, open(f"/proc/{pid}/task/{task}/wchan") as wchan:
                    lines.append(f"thread {task} {comm.read().strip()}: waiting in {wchan.read().strip() or '-'}")
        except (OSError, TypeError):
            lines.append(f"process {pid} is gone")
        with open(path, "w") as note:
            note.write("\n".join(lines) + "\n")
        # Still running: every thread's stack, which names the lock or wait a
        # hang is stuck on. Swift's own debugger reads Swift's frames. It
        # needs the container's ptrace capability (run-in-docker.sh, CI).
        if pid is not None and os.path.exists(f"/proc/{pid}"):
            try:
                stacks = subprocess.run(["lldb", "--batch", "-p", str(pid), "-o", "thread backtrace all"],
                                        capture_output=True, text=True, timeout=120)
                with open(path.replace("-process.txt", "-stacks.txt"), "w") as out:
                    out.write(stacks.stdout + stacks.stderr)
            except (OSError, subprocess.TimeoutExpired) as error:
                with open(path, "a") as note:
                    note.write(f"no stacks: {error}\n")

    def picture(self, name):
        os.makedirs(OUT, exist_ok=True)
        path = os.path.join(OUT, f"{datetime.datetime.now():%H%M%S}-{name}.png")
        subprocess.run(["import", "-window", "root", path], check=False,
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        return path

    # Windows

    def _roots_with(self, pid):
        desktop = Atspi.get_desktop(0)
        roots = []
        for i in range(desktop.get_child_count()):
            node = desktop.get_child_at_index(i)
            try:
                if node is not None and node.get_process_id() == pid:
                    roots.append(node)
            except Exception:
                pass
        return roots

    def _root(self):
        roots = self._roots_with(self.pid) if self.process else []
        if not roots:
            return None
        roots[0].clear_cache()
        return roots[0]

    def windows(self):
        """The windows showing, oldest first: the main window, then any sheet
        or question over it."""
        root = self._root()
        if root is None:
            return []
        found = []
        for i in range(root.get_child_count()):
            node = root.get_child_at_index(i)
            if node is not None and node.get_state_set().contains(Atspi.StateType.SHOWING):
                found.append(Element(self, node))
        return found

    @property
    def main(self):
        return self.until(lambda: self.windows()[0], "the main window")

    @property
    def front(self):
        """The window in front, where a person acts: a question, else a sheet,
        else the main window."""
        return self.until(lambda: self.windows()[-1], "a window")

    def wait_for_window(self, count, what):
        """Waits until `count` windows show, such as 2 for a sheet over the
        main window, and gives back the one in front."""
        self.until(lambda: len(self.windows()) == count, what)
        return self.front

    # Finding

    def find(self, role, words, within=None, wait=WAIT):
        """The one element with that role and those words, in the window in
        front unless `within` says where. Waits for it to show."""
        def one():
            place = within or self.front
            hits = [e for e in place.all(role, words) if e.showing]
            if len(hits) > 1:
                raise ScreenError(f"{len(hits)} {role}s say {words!r}; say which one with within or near")
            return hits[0] if hits else None
        return self.until(one, f"a {role} saying {words!r}", wait)

    def shows(self, words, within=None, role=None):
        """Whether something says `words` right now, without waiting."""
        place = within or self.front
        return any(e.showing for e in place.all(role, words))

    def wait_shows(self, words, within=None, role=None):
        return self.until(lambda: self.shows(words, within, role), f"something saying {words!r}")

    def wait_gone(self, words, within=None, role=None):
        return self.until(lambda: not self.shows(words, within, role), f"{words!r} to go")

    def button(self, words, within=None):
        return self.find("push button", words, within)

    def near(self, role, words, to):
        """The element with that role and words nearest to `to`, for things
        every line has, like each group's ⋯ and arrow: the one in the smallest
        part of the window holding both."""
        def nearest():
            node = to.node
            while node is not None:
                hits = [e for e in Element(self, node).all(role, words) if e.showing]
                if len(hits) == 1:
                    return hits[0]
                if len(hits) > 1:
                    raise ScreenError(f"{len(hits)} {role}s say {words!r} equally near {to!r}")
                node = node.get_parent()
            return None
        return self.until(nearest, f"a {role} saying {words!r} near {to!r}")

    def texts(self, within=None):
        """Every text showing, in reading order."""
        place = within or self.front
        return [e.words for e in place.all("label") if e.showing and e.words]

    def reads(self, words, within=None):
        """Whether these texts show one after another, such as a wheel's middle
        ["Left", "$517", "of $1,000"], or a figure and its amount."""
        texts = self.texts(within)
        return any(texts[i:i + len(words)] == list(words) for i in range(len(texts)))

    def wait_reads(self, words, within=None):
        return self.until(lambda: self.reads(words, within), f"{list(words)} to show in that order")

    def field(self, label, within=None):
        """The text box under a label such as "Name"."""
        return self.near("text", "", to=self.find("label", label, within))

    # The sidebar

    def group(self, name):
        """A group's name in the sidebar, the button that opens its page. The
        sidebar shows names in capitals."""
        return self.find("push button", name.upper(), within=self.main)

    def budget(self, name):
        """A budget's row in the sidebar, a button that says its name, then
        what's left."""
        def row():
            hits = [e for e in self.main.all("push button", starts=name + " ") if e.showing]
            if len(hits) > 1:
                raise ScreenError(f"{len(hits)} budgets are named {name!r}")
            return hits[0] if hits else None
        return self.until(row, f"the budget {name!r} in the sidebar")

    def has_budget(self, name):
        return any(e.showing for e in self.main.all("push button", starts=name + " "))

    # A budget's transactions

    def entries(self):
        """The open budget's transactions, top to bottom, each as the texts
        its row shows: its date, merchant, any note, who added it, its
        source and its amount."""
        rows = []
        for button in self.main.all("push button"):
            parts = [label.words for label in button.all("label") if label.words]
            if button.showing and len(parts) >= 4 and _looks_like_a_date(parts[0]):
                rows.append(parts)
        return rows

    def entry(self, merchant):
        """A transaction's row, the button that opens it."""
        def row():
            hits = [b for b in self.main.all("push button")
                    if b.showing and any(label.words == merchant for label in b.all("label"))
                    and _looks_like_a_date(next((label.words for label in b.all("label")), ""))]
            if len(hits) > 1:
                raise ScreenError(f"{len(hits)} transactions are from {merchant!r}")
            return hits[0] if hits else None
        return self.until(row, f"the transaction from {merchant!r}")

    def sidebar(self):
        """The sidebar's lines, top to bottom: each group's name in capitals,
        and each budget's row, its name then what's left."""
        lines = []
        for button in self.main.all("push button"):
            words = button.words
            if not button.showing or words in ("⋯", "Add Budget", "More", "Sign in", "Account", "Sync") \
                    or words.endswith("budgets"):
                continue
            parts = [label.words for label in button.all("label") if label.words]
            if parts and len(parts) >= 4 and _looks_like_a_date(parts[0]):
                continue  # a transaction's row, on the open budget's page
            if words.isupper() or "$" in words:
                lines.append(words)
        return lines

    def budgets_in(self, group):
        """The budgets' rows under a group's name in the sidebar."""
        lines = self.sidebar()
        start = lines.index(group.upper()) + 1
        rows = []
        for line in lines[start:]:
            if line.isupper() and "$" not in line:
                break
            rows.append(line)
        return rows

    def menu_items(self, menu):
        """The words of an open menu's items, top to bottom."""
        return [e.words for e in menu.all("menu item") if e.showing]

    def question(self):
        """The words of the question in front, such as a delete's: its title
        and what it says, as GTK shows them, one under the other."""
        self.until(lambda: len(self.windows()) > 1, "a question")
        return self.until(lambda: self.texts(self.front)[0], "the question's words").replace("\n\n", " ")

    def open_menu(self, button):
        """Presses a button that opens a menu, such as More or a group's ⋯,
        until its items show, and gives it back for `pick`. A press as a
        window first draws can be lost, so a second one follows if needed."""
        for _ in range(2):
            button.press()
            try:
                self.until(lambda: any(e.showing for e in button.all("menu item")), "the menu to open", wait=4)
                return button
            except ScreenError:
                pass
        self.until(lambda: any(e.showing for e in button.all("menu item")), f"{button!r}'s menu to open")
        return button

    def group_menu(self, name):
        """Opens a group's ⋯ menu, and gives back its button for `pick`."""
        return self.open_menu(self.near("push button", "⋯", to=self.group(name)))

    def pick(self, words, menu):
        """Presses the item saying `words` in the open menu of `menu`."""
        self.find("menu item", words, within=menu).press()

    # Keys and lists

    def key(self, *keys):
        """Keys pressed in the window in front, as a person types them."""
        self._focus_front()
        subprocess.run(["xdotool", "key", "--clearmodifiers", *keys], check=True)
        self.settle()

    def _focus_front(self):
        # The test display has no window manager to give the window in front
        # the keyboard, so it's given here: the app's newest window showing.
        ids = subprocess.run(["xdotool", "search", "--onlyvisible", "--pid", str(self.pid)],
                             capture_output=True, text=True).stdout.split()
        # Windows, not a menu's or a list's popup, which has no name.
        named = [i for i in ids if subprocess.run(["xdotool", "getwindowname", i], capture_output=True,
                                                  text=True).stdout.strip()]
        if named:
            subprocess.run(["xdotool", "windowfocus", "--sync", max(named, key=int)], check=False)

    def choose(self, words, list_box):
        """Opens a drop-down list such as a level list, and chooses `words` by
        the keyboard: Home to the top, Down to it, Return. The list's words
        are read from the tree first, and the choice is checked in it after.
        (Where the keyboard starts in an opened list isn't what the tree
        reports, so no step leans on it.)"""
        toggle = list_box.all("toggle button")[0] if list_box.role == "combo box" else list_box
        # The keyboard goes to this copy's window first. Once the list is open
        # its keys go on there, never to the list's own popup window.
        self._focus_front()
        toggle.press()

        def open_items():
            lists = [e for e in Element(self, self._root()).all("list") if e.showing]
            if not lists:
                return None
            return [Element(self, lists[-1].node.get_child_at_index(i))
                    for i in range(lists[-1].node.get_child_count())]

        items = self.until(open_items, "the list to open")
        names = [" ".join(label.words for label in item.all("label")) for item in items]
        if words not in names:
            subprocess.run(["xdotool", "key", "Escape"], check=True)
            raise ScreenError(f"{words!r} isn't offered. The list says {names}")
        for key in ["Home"] + ["Down"] * names.index(words) + ["Return"]:
            subprocess.run(["xdotool", "key", key], check=True)
            time.sleep(0.3)
        self.settle()
        self.until(lambda: toggle.words == words or list_box.words == words, f"the list to say {words!r}")

    # Steps many tests take, done as a person does them

    def new_group(self, name):
        """More, New Group…, its name, Add."""
        more = self.open_menu(self.button("More", within=self.main))
        self.pick("New Group…", more)
        sheet = self.wait_for_window(2, "the New Group sheet")
        self.field("Name", sheet).type(name)
        self.button("Add", within=sheet).press()
        self.wait_for_window(1, "the New Group sheet to close")
        self.group(name)

    def new_budget(self, name, amount, group=None):
        """Add Budget, its name and monthly amount, its group when one is
        given, Add. Saving opens it."""
        # The sidebar's, beside More: with no budgets yet, the page has one too.
        self.near("push button", "Add Budget", to=self.button("More", within=self.main)).press()
        sheet = self.wait_for_window(2, "the New Budget sheet")
        self.field("Name", sheet).type(name)
        self.field("Each month", sheet).type(amount)
        if group is not None:
            groups = [e for e in sheet.all("combo box") if e.showing]
            if groups and groups[0].words != group:
                self.choose(group, groups[0])
        self.button("Add", within=sheet).press()
        self.wait_for_window(1, "the New Budget sheet to close")
        self.until(lambda: self.budget(name).selected, f"{name!r} to open")

    def add_entry(self, merchant, amount, note=None):
        """Add on the open budget, then the merchant and amount, Add. It's
        dated today."""
        self.button("Add", within=self.main).press()
        sheet = self.wait_for_window(2, "the New transaction sheet")
        self.field("Merchant", sheet).type(merchant)
        self.field("Amount", sheet).type(amount)
        if note is not None:
            self.field("Note", sheet).type(note)
        self.button("Add", within=sheet).press()
        self.wait_for_window(1, "the New transaction sheet to close")

    def delete_entry(self, merchant):
        """Opens a transaction, Delete…, then Delete in the question."""
        self.entry(merchant).press()
        editor = self.wait_for_window(2, f"{merchant} to open")
        self.button("Delete…", within=editor).press()
        self.answer("Delete")
        self.until(lambda: len(self.windows()) == 1, "the transaction to close")
        self.until(lambda: all(row[1] != merchant for row in self.entries()), f"{merchant} to go")

    def answer(self, button):
        """Presses `button` in the question in front, such as "Delete"."""
        count = self.until(lambda: len(self.windows()) if len(self.windows()) > 1 else None, "a question")
        self.button(button, within=self.front).press()
        self.until(lambda: len(self.windows()) < count, "the question to close")

    def sign_up(self, name):
        """Makes a fresh account on staging for this copy, as a person does:
        Sign in, Create an account, an email and a password, then the emailed
        code. Signed in afterwards. Gives back the email."""
        slug = "".join(ch for ch in name.lower() if ch.isalnum())
        self.email = f"linux-{RUN}{next(_ACCOUNT_NUMBERS)}-{slug}@example.com"
        self.password = secrets.token_urlsafe(18)
        self.button("Sign in", within=self.main).press()
        sheet = self.wait_for_window(2, "the account sheet")
        self.button("Create an account", within=sheet).press()
        self.wait_shows("Confirm password")
        sheet = self.front
        asked = datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(seconds=2)
        self.field("Email", sheet).type(self.email)
        self.field("Password", sheet).type(self.password)
        self.field("Confirm password", sheet).type(self.password)
        self.button("Create account", within=sheet).press()
        self.wait_shows("Confirm your email")
        self.field("Code", self.front).type(emailed_code(self.email, asked))
        self.button("Confirm", within=self.front).press()
        self.wait_shows("Your email is confirmed.")
        self.button("Done", within=self.front).press()
        self.wait_for_window(1, "the account sheet to close")
        self.button("Sync", within=self.main)
        _ACCOUNTS[name.lower()] = (self.email, self.password)
        return self.email

    def sign_in_as(self, name):
        """Signs this copy in to the person's account for this run, making it
        the first time it's needed. Signed in, with their groups synced."""
        if name.lower() not in _ACCOUNTS:
            return self.sign_up(name)
        self.email, self.password = _ACCOUNTS[name.lower()]
        self.button("Sign in", within=self.main).press()
        sheet = self.wait_for_window(2, "the account sheet")
        self.field("Email", sheet).type(self.email)
        self.field("Password", sheet).type(self.password)
        self.button("Sign in", within=sheet).press()
        # Signed in to a confirmed account, the sheet closes by itself.
        self.wait_for_window(1, "the account sheet to close")
        self.button("Sync", within=self.main)
        self.sync()
        return self.email

    def sign_out(self):
        """Account, then Sign out. Signed out afterwards, with the sheet
        closed."""
        self.button("Account", within=self.main).press()
        sheet = self.wait_for_window(2, "the account sheet")
        self.button("Sign out", within=sheet).press()
        self.until(lambda: len(self.windows()) == 1 or self.shows("Sign in", within=self.front, role="push button"),
                   "signing out")
        if len(self.windows()) > 1:
            self.button("Cancel", within=self.front).press()
            self.wait_for_window(1, "the account sheet to close")
        self.button("Sign in", within=self.main)

    def remove_group(self, name):
        """Takes a group a test made off this person's computer and, for its
        owner, off the server: Delete… where they may, else Leave…. For a
        test's clean-up."""
        if not self.shows(name.upper(), within=self.main):
            return
        menu = self.group_menu(name)
        items = self.menu_items(menu)
        if "Delete…" in items:
            self.pick("Delete…", menu)
            self.answer("Delete")
        else:
            self.pick("Leave…", menu)
            self.answer("Leave")
        self.until(lambda: not self.shows(name.upper(), within=self.main), f"{name!r} to go")
        self.sync()

    def sync(self):
        """The Sync button, then waits until it's done."""
        self.button("Sync", within=self.main).press()
        time.sleep(1)
        self.until(lambda: self.button("Sync", within=self.main).enabled, "the sync to finish")
        self.settle()

    def share(self, group, my_name, level=None):
        """Share… in the group's menu: this person's name, what they can do
        when it isn't the sheet's own choice, Create Link. Gives back the
        link, read off the sheet, and closes it."""
        menu = self.group_menu(group)
        self.pick("Share…", menu)
        sheet = self.wait_for_window(2, "the Share sheet")
        self.field("Your name", sheet).type(my_name)
        if level is not None:
            levels = [e for e in sheet.all("combo box") if e.showing][0]
            if levels.words != level:
                self.choose(level, levels)
        self.button("Create Link", within=sheet).press()
        link = self.until(lambda: next((t for t in self.texts(self.front) if "://join" in t), None),
                          "the link to show")
        self.button("Done", within=self.front).press()
        self.wait_for_window(1, "the Share sheet to close")
        return link.replace("\n", "").replace(" ", "")

    def set_level(self, group, person, level):
        """On the group's page, the level list on the person's row, then
        `level`, then a sync so it reaches the server."""
        self.group(group).press()
        self.sync()
        row_label = self.find("label", person, within=self.main)
        self.choose(level, self.near("combo box", None, to=row_label))
        self.sync()

    def join(self, link, my_name):
        """More, Join a Group…, the link and this person's name, Join."""
        more = self.open_menu(self.button("More", within=self.main))
        self.pick("Join a Group…", more)
        sheet = self.wait_for_window(2, "the Join a Group sheet")
        self.field("Invite link", sheet).type(link)
        self.field("Your name", sheet).type(my_name)
        self.until(lambda: self.button("Join", within=sheet).enabled, "Join to light")
        self.button("Join", within=sheet).press()
        self.wait_for_window(1, "the Join a Group sheet to close")

    def delete_group(self, name):
        """The group's ⋯, Delete…, then Delete in the question."""
        menu = self.group_menu(name)
        self.pick("Delete…", menu)
        self.answer("Delete")
        self.until(lambda: not self.shows(name.upper(), within=self.main), f"{name!r} to go")


def _read(path):
    try:
        with open(path) as f:
            return f.read().strip() or None
    except OSError:
        return None


def _child_named(parent, name):
    """The process called `name` started under `parent`, at any depth."""
    children = {}
    for entry in os.listdir("/proc"):
        if not entry.isdigit():
            continue
        try:
            with open(f"/proc/{entry}/stat") as f:
                fields = f.read().rsplit(")", 1)[1].split()
            with open(f"/proc/{entry}/comm") as f:
                comm = f.read().strip()
        except OSError:
            continue
        children.setdefault(int(fields[1]), []).append((int(entry), comm))
    stack = [parent]
    while stack:
        for pid, comm in children.get(stack.pop(), []):
            if comm == name[:15]:
                return pid
            stack.append(pid)
    return None


_bus = None


def _accessibility_bus():
    """The accessibility bus of the tests' own session, which every copy of
    the app is shown on."""
    global _bus
    if _bus is None:
        _bus = subprocess.run(["dbus-send", "--session", "--dest=org.a11y.Bus", "--print-reply=literal",
                               "/org/a11y/bus", "org.a11y.Bus.GetAddress"],
                              capture_output=True, text=True, check=True).stdout.strip()
    return _bus


# MARK: - Accounts on staging
#
# Each run makes fresh accounts, linux-<run>-<name>@example.com, and reads the
# code staging emails them from its test mailbox. The mailbox's token comes
# from the environment only, never a file in the repository or a command line.

STAGING = "https://staging.wellspent.space"
MAILBOX_TOKEN = os.environ.get("WELLSPENT_UI_TEST_MAILBOX_TOKEN") or None
RUN = f"{datetime.datetime.now():%m%d%H%M%S}{secrets.token_hex(2)}"
# Every account in a run has an address of its own.
_ACCOUNT_NUMBERS = itertools.count(1)
# Each person's account, made once per run and signed into after that, since
# staging limits how many accounts one computer may make in an hour.
_ACCOUNTS = {}
# Names no earlier test in the run has used.
_NAME_NUMBERS = itertools.count(1)


def unique(name):
    """A group's name no other test in this run uses: "Home 3"."""
    return f"{name} {next(_NAME_NUMBERS)}"


def needs_accounts(test):
    """Skips a test that makes accounts when there's no mailbox to read their
    codes from, as for a pull request from a fork."""
    if MAILBOX_TOKEN is None:
        test.skipTest("no WELLSPENT_UI_TEST_MAILBOX_TOKEN, so no account can be made")


def emailed_code(address, after):
    """The code staging emailed `address` after `after` (a UTC time), read from
    the test mailbox. Waits for it, since the email goes out just after the
    answer."""
    url = f"{STAGING}/test/mailbox?address={urllib.parse.quote(address, safe='')}"
    # Named, since the site's front door turns away Python's own unnamed requests.
    request = urllib.request.Request(url, headers={"Authorization": f"Bearer {MAILBOX_TOKEN}",
                                                   "User-Agent": "WellSpent-Linux-UI-tests"})

    def code():
        try:
            with urllib.request.urlopen(request, timeout=10) as answer:
                mail = json.load(answer)
        except urllib.error.HTTPError as error:
            if error.code == 404:
                return None
            raise
        sent = datetime.datetime.fromisoformat(mail["sentAt"].replace("Z", "+00:00"))
        return mail.get("code") if sent >= after else None

    deadline = time.monotonic() + WAIT
    while time.monotonic() < deadline:
        found = code()
        if found:
            return found
        time.sleep(0.5)
    raise ScreenError(f"no code reached {address}'s mailbox")


def launch_fresh(test, *arguments, **settings):
    """A fresh copy of the app for one test, closed and cleared when it ends.
    `settings` are `App.launch`'s: day, undo_seconds."""
    app = App()
    test.addCleanup(app.close)
    return app.launch(*arguments, **settings)


# MARK: - What the app should say
#
# The wheel's words for a day, so a test knows what to expect whatever day it
# runs. The arithmetic is the shared code's (MoneyWheel and BudgetPace in
# WellSpentAppCore): a copy, kept as small as the rules, and checked against
# the app on every run.


def days_in_month(day):
    following = (day.replace(day=28) + datetime.timedelta(days=4)).replace(day=1)
    return (following - datetime.timedelta(days=1)).day


def today(day=None):
    """The app's today: `day` of this month when the test pinned one, the
    month's last day for a day past its end, else the real today."""
    now = datetime.date.today()
    if day is None:
        return now
    return now.replace(day=min(day, days_in_month(now)))


def short_date(day):
    """A transaction's date as the app writes it in the United States: "Oct 21"."""
    return f"{day:%b} {day.day}"


def _looks_like_a_date(words):
    # "Oct 21" in the United States, "21. Okt." in Germany, "21 Oct" elsewhere.
    return any(ch.isdigit() for ch in words) and any(ch.isalpha() for ch in words) and len(words) <= 9


def dollars(cents):
    """$1060.21, as the app writes amounts."""
    sign = "-" if cents < 0 else ""
    return f"{sign}${abs(cents) // 100}.{abs(cents) % 100:02d}"


def whole_dollars(cents):
    """$1,060, as the wheel's middle writes amounts: rounded half up, with a
    comma every three digits."""
    units = (abs(cents) + 50) // 100
    sign = "-" if cents < 0 and units > 0 else ""
    return f"{sign}${units:,}"


def days_in_words(count):
    """"one day", "five days" or "12 days"."""
    words = ["one", "two", "three", "four", "five", "six", "seven", "eight", "nine"]
    if not 1 <= count <= 9:
        return f"{count} days"
    return "one day" if count == 1 else f"{words[count - 1]} days"


class Wheel:
    """A budget's wheel on a day, as the app should put it in words. For a
    group's, `group=True`, with every budget in it added up."""

    def __init__(self, name, limit_cents, spent_cents, day=None, may_edit=True, group=False):
        self.name, self.limit, self.spent, self.may_edit = name, limit_cents, spent_cents, may_edit
        self.group = group
        self.today = today(day)
        self.days = days_in_month(self.today)
        self.to_come = self.days - self.today.day

    @property
    def left(self):
        return self.limit - self.spent

    @property
    def is_over(self):
        return self.spent > self.limit

    @property
    def day_line(self):
        """"October · day 21 of 31"."""
        return f"{self.today:%B} · day {self.today.day} of {self.days}"

    @property
    def middle(self):
        """The wheel's middle, top to bottom: "Left", "$517", "of $1,000"."""
        of = f"of {whole_dollars(self.limit)}"
        month = " this month" if self.group else ""
        if self.is_over:
            return ["Over" + month, whole_dollars(max(self.spent - self.limit, 100)), of]
        return ["Left" + month, whole_dollars(self.left), of]

    @property
    def expected_left(self):
        if self.is_over or self.limit <= 0:
            return None
        return (self.limit * self.to_come * 2 + self.days) // (2 * self.days)

    @property
    def figures(self):
        """Beside the wheel, in order: ("Spent", "$483.16"), then Left or
        Over, then Expected left by today when there is one."""
        figures = [("Spent", dollars(self.spent))]
        if self.is_over:
            figures.append(("Over", dollars(self.spent - self.limit)))
        else:
            figures.append(("Left", dollars(self.left)))
        if self.expected_left is not None:
            figures.append(("Expected left by today", dollars(self.expected_left)))
        return figures

    @property
    def pace(self):
        """The words under the figures, or None. A group's wheel has none."""
        expected = self.expected_left
        if self.group or expected is None or self.left <= 0:
            return None
        if self.left < expected:
            runs_out = self.limit * self.today.day // self.spent
            date = self.today.replace(day=1) + datetime.timedelta(days=runs_out - 1)
            early = max(self.days - runs_out, 1)
            return (f"At this pace, {self.name} runs out around {date:%b} {date.day}, "
                    f"{days_in_words(early)} early.")
        more = self.left - expected
        if more > 0 and self.to_come < 7 and self.may_edit and (more + 50) // 100 >= 1:
            return (f"{whole_dollars(more)} more left than expected by today. "
                    "Keep this budget, or lower it for next month?")
        return None

    @property
    def note(self):
        """Under a group's figures: "Day 18 of 31. Every budget in Household, added up."."""
        return f"Day {self.today.day} of {self.days}. Every budget in {self.name}, added up."

    @property
    def row(self):
        """A budget's row in the sidebar: its words, and what it says to a
        screen reader."""
        if self.is_over:
            return f"{self.name} {dollars(self.spent - self.limit)} over", "Over budget"
        used = 0 if self.limit <= 0 else min(max(self.spent * 100 // self.limit, 0), 100)
        return f"{self.name} {dollars(self.left)}", f"{used} percent used"
