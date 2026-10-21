"""Accounts (Features/Accounts.md) in the real window: making an account and
confirming it with the emailed code, signing in and out, a wrong password, a
forgotten one, signing out everywhere, the name this computer goes by, and the
staging bar.

Every scenario but the first and the last makes an account on staging, read
through its test mailbox, so those are skipped without the mailbox's token. Each
makes an account of its own, since how an account starts is the point."""

import datetime
import json
import secrets
import socket
import time
import unittest
import urllib.error
import urllib.parse
import urllib.request

from wellspent_ui import (MAILBOX_TOKEN, RUN, STAGING, emailed_code, launch_fresh, needs_accounts, unique)

KEPT_HERE = "Kept on this computer only"
SYNCED = "Syncs through WellSpent's server"
PRIVACY = ("Your budgets sync through WellSpent's server. Connections and backups are encrypted. "
           "The server can read your budgets. That's how it checks who may change what, and why "
           "resetting a forgotten password doesn't lose your budgets.")
CONFIRM_REASON = ("Confirm your email so a forgotten password can be reset, and so you can join "
                  "shared budgets.")

_numbers = iter(range(1, 1000))


def fresh_address(name, cased=False):
    """An address no run has used, at example.com, where nobody gets mail."""
    address = f"linux-{RUN}a{next(_numbers)}-{name}@example.com"
    return address.replace("linux-", "Linux-").replace("@example.com", "@Example.com") if cased else address


def now():
    return datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(seconds=2)


def newest_mail_since(address, after):
    """The newest message staging kept for `address`, if it was sent after
    `after`, or None. Asks once, for a test that expects nothing to come."""
    url = f"{STAGING}/test/mailbox?address={urllib.parse.quote(address, safe='')}"
    request = urllib.request.Request(url, headers={"Authorization": f"Bearer {MAILBOX_TOKEN}",
                                                   "User-Agent": "WellSpent-Linux-UI-tests"})
    try:
        with urllib.request.urlopen(request, timeout=10) as answer:
            mail = json.load(answer)
    except urllib.error.HTTPError as error:
        if error.code == 404:
            return None
        raise
    sent = datetime.datetime.fromisoformat(mail["sentAt"].replace("Z", "+00:00"))
    return mail if sent >= after else None


def staging(method, path, body=None, token=None):
    """One request to staging's API, as the app makes it, for what the app has
    no screen for. Gives back the answer's JSON."""
    headers = {"Content-Type": "application/json", "User-Agent": "WellSpent-Linux-UI-tests"}
    if token:
        headers["Authorization"] = f"Bearer {token}"
    data = json.dumps(body).encode() if body is not None else None
    request = urllib.request.Request(STAGING + path, data=data, method=method, headers=headers)
    with urllib.request.urlopen(request, timeout=15) as answer:
        raw = answer.read()
        return json.loads(raw) if raw else None


class Accounts(unittest.TestCase):

    # MARK: - Steps

    def open_sheet(self, app):
        """Sign in, or Account when signed in: the account sheet."""
        button = "Account" if app.shows("Account", within=app.main, role="push button") else "Sign in"
        app.button(button, within=app.main).press()
        return app.wait_for_window(2, "the account sheet")

    def create(self, app, address, password, confirmation=None):
        """Sign in, Create an account, the three fields, Create account."""
        sheet = self.open_sheet(app)
        app.button("Create an account", within=sheet).press()
        app.wait_shows("Confirm password")
        sheet = app.front
        asked = now()
        app.field("Email", sheet).type(address)
        app.field("Password", sheet).type(password)
        app.field("Confirm password", sheet).type(confirmation or password)
        app.button("Create account", within=sheet).press()
        return asked

    def confirm(self, app, address, asked):
        """Types the emailed code and presses Confirm."""
        app.wait_shows("Confirm your email")
        app.field("Code", app.front).type(emailed_code(address.lower(), asked))
        app.button("Confirm", within=app.front).press()
        app.wait_shows("Your email is confirmed.")

    def done(self, app):
        app.button("Done", within=app.front).press()
        app.wait_for_window(1, "the account sheet to close")

    def sign_in(self, app, address, password):
        sheet = self.open_sheet(app)
        app.field("Email", sheet).type(address)
        app.field("Password", sheet).type(password)
        app.button("Sign in", within=sheet).press()

    def foot(self, app, words):
        app.wait_shows(words, within=app.main)

    # MARK: - Tests

    def test_signed_out_budgets_stay_here_and_signed_in_they_sync(self):
        needs_accounts(self)
        app = launch_fresh(self)

        # Scenario ACCT-01
        # 1. Signed out, the foot says the budgets are kept here, with Sign
        # in, and no Sync.
        self.foot(app, KEPT_HERE)
        app.button("Sign in", within=app.main)
        self.assertFalse(app.shows("Sync", within=app.main, role="push button"))

        # Scenario ACCT-01
        # 2. Signed in, it says they sync through the server.
        address, password = fresh_address("one"), secrets.token_urlsafe(18)
        self.confirm(app, address, self.create(app, address, password))
        self.done(app)
        self.foot(app, SYNCED)
        app.button("Sync", within=app.main)

    def test_create_an_account_and_confirm_it_with_the_code(self):
        needs_accounts(self)
        app = launch_fresh(self)
        address, password = fresh_address("robin", cased=True), secrets.token_urlsafe(18)

        # Scenario ACCT-02
        # 1. Create an account asks for an email, a password twice and the
        # server, says where the budgets go, and stays dimmed until all three
        # fields hold something.
        sheet = self.open_sheet(app)
        app.button("Create an account", within=sheet).press()
        app.wait_shows("Confirm password")
        sheet = app.front
        for words in ("Create an account", "Email", "Password", "Confirm password", "Server", PRIVACY):
            app.wait_shows(words, within=sheet)
        create = app.button("Create account", within=sheet)
        self.assertFalse(create.enabled, "nothing typed")
        app.field("Email", sheet).type(address)
        self.assertFalse(create.enabled, "only the email")
        app.field("Password", sheet).type(password)
        self.assertFalse(create.enabled, "no confirmation")
        app.field("Confirm password", sheet).type(password)
        app.until(lambda: create.enabled, "Create account to light")

        # Scenario ACCT-02
        # 2. Create account moves on to the code, sent to the address as
        # written in small letters, and the foot says the budgets now sync.
        asked = now()
        create.press()
        app.wait_shows("Confirm your email")
        app.wait_shows(f"Enter the code sent to {address.lower()}.", within=app.front)
        self.foot(app, SYNCED)

        # Scenario ACCT-05
        # 3. Confirm stays dimmed until the code holds all 8 letters and
        # numbers. Typed in small letters and without its dash, it's taken.
        code = emailed_code(address.lower(), asked)
        confirm = app.button("Confirm", within=app.front)
        app.field("Code", app.front).type(code.replace("-", "")[:7].lower())
        self.assertFalse(confirm.enabled, "seven of the eight")
        app.field("Code", app.front).type(code.replace("-", "").lower())
        app.until(lambda: confirm.enabled, "Confirm to light")
        confirm.press()

        # Scenario ACCT-05
        # 4. Your account: confirmed, signed in as the address, with its
        # buttons, and still confirmed after a restart.
        app.wait_shows("Your email is confirmed.")
        sheet = app.front
        app.wait_shows(f"Signed in as {address.lower()}.", within=sheet)
        for button in ("Change password…", "Sign out", "Sign out everywhere…", "Done"):
            app.button(button, within=sheet)
        self.done(app)
        app.restart()
        sheet = self.open_sheet(app)
        app.wait_shows(f"Signed in as {address.lower()}.", within=sheet)
        self.assertFalse(app.shows("Confirm your email…", within=sheet, role="push button"),
                         "asked again to confirm after a restart")
        self.assertFalse(app.shows(CONFIRM_REASON, within=sheet))

    def test_create_an_account_says_what_is_wrong_before_sending(self):
        needs_accounts(self)
        app = launch_fresh(self)

        # Scenario ACCT-03
        # Under each field it says what is wrong, nothing is sent, and the
        # computer is still signed out.
        self.create(app, "robin", "short", "something else")
        sheet = app.front
        for words in ("That does not look like an email address.", "A password needs at least 10 characters.",
                      "The two passwords are not the same."):
            app.wait_shows(words, within=sheet)
        app.wait_shows("Create an account", within=sheet)
        app.button("Cancel", within=sheet).press()
        app.wait_for_window(1, "the account sheet to close")
        self.foot(app, KEPT_HERE)
        app.button("Sign in", within=app.main)

    def test_an_email_that_already_has_an_account(self):
        needs_accounts(self)
        first = launch_fresh(self)
        address, password = fresh_address("taken"), secrets.token_urlsafe(18)
        self.confirm(first, address, self.create(first, address, password))
        self.done(first)

        # Scenario ACCT-04
        # Another computer tries the same address: the sheet stays on Create
        # an account and says so, still signed out, its budgets as they were.
        app = launch_fresh(self)
        before = app.sidebar()
        self.create(app, address, secrets.token_urlsafe(18))
        sheet = app.front
        app.wait_shows("That email already has an account. Sign in, or reset its password.", within=sheet)
        app.wait_shows("Create an account", within=sheet)
        app.button("Cancel", within=sheet).press()
        app.wait_for_window(1, "the account sheet to close")
        self.foot(app, KEPT_HERE)
        self.assertEqual(before, app.sidebar())

    def test_a_wrong_code_and_another_code(self):
        needs_accounts(self)
        app = launch_fresh(self)
        address = fresh_address("wrongcode")
        self.create(app, address, secrets.token_urlsafe(18))

        # Scenario ACCT-06
        # A wrong code is refused and the sheet stays. Send another code says
        # only the newest works.
        app.wait_shows("Confirm your email")
        app.field("Code", app.front).type("AAAA-AAAA")
        app.button("Confirm", within=app.front).press()
        app.wait_shows("That code is wrong or has expired.", within=app.front)
        app.wait_shows("Confirm your email", within=app.front)
        app.button("Send another code", within=app.front).press()
        app.wait_shows("If a code was sent in the last minute, use that one. Otherwise a new code is on its way. "
                       "Only the newest code works.", within=app.front)

    def test_an_email_not_confirmed_yet_is_asked_for_again(self):
        needs_accounts(self)
        first = launch_fresh(self)
        address, password = fresh_address("later"), secrets.token_urlsafe(18)
        self.create(first, address, password)
        first.wait_shows("Confirm your email")
        first.button("Not now", within=first.front).press()
        first.wait_for_window(1, "the account sheet to close")

        # Scenario ACCT-07
        # 1. Signing in on another computer asks for the email to be
        # confirmed, and offers to send a code.
        app = launch_fresh(self)
        self.sign_in(app, address, password)
        app.wait_shows("Confirm your email")
        app.wait_shows(CONFIRM_REASON, within=app.front)
        app.button("Send a code", within=app.front)

        # Scenario ACCT-07
        # 2. Not now closes the sheet, still signed in.
        app.button("Not now", within=app.front).press()
        app.wait_for_window(1, "the account sheet to close")
        self.foot(app, SYNCED)

        # Scenario ACCT-07
        # 3. Account, with a budget open, says the same, with Confirm your
        # email… leading back to the code.
        group = unique("Later")
        app.new_group(group)
        app.new_budget("Books", "100", group=group)
        sheet = self.open_sheet(app)
        app.wait_shows(CONFIRM_REASON, within=sheet)
        app.button("Confirm your email…", within=sheet).press()
        app.wait_shows("Confirm your email")
        app.field("Code", app.front)
        app.button("Not now", within=app.front).press()
        app.wait_for_window(1, "the account sheet to close")
        app.remove_group(group)

    def test_sign_in_brings_the_accounts_budgets_and_keeps_them_signed_in(self):
        needs_accounts(self)
        first = launch_fresh(self)
        address, password = fresh_address("signin"), secrets.token_urlsafe(18)
        self.confirm(first, address, self.create(first, address, password))
        self.done(first)
        group = unique("Signin")
        first.new_group(group)
        first.new_budget("Books", "100", group=group)
        first.sync()

        # Scenario ACCT-08
        # 1. On another computer, Sign in brings the account's budgets by a
        # sync, and none of the ones kept here signed out.
        app = launch_fresh(self)
        self.assertTrue(app.has_budget("Groceries"), "the samples this computer keeps")
        self.sign_in(app, address, password)
        app.wait_for_window(1, "the account sheet to close")
        app.until(lambda: app.has_budget("Books"), "the account's budget")
        self.assertFalse(app.has_budget("Groceries"), "a budget kept here while signed out")
        self.foot(app, SYNCED)
        app.button("Account", within=app.main)
        app.button("Sync", within=app.main)

        # Scenario ACCT-08
        # 2. Still signed in after a restart.
        app.restart()
        self.foot(app, SYNCED)
        app.until(lambda: app.has_budget("Books"), "the account's budget after a restart")
        first.remove_group(group)

    def test_a_wrong_password(self):
        needs_accounts(self)
        first = launch_fresh(self)
        address, password = fresh_address("wrongpw"), secrets.token_urlsafe(18)
        self.confirm(first, address, self.create(first, address, password))
        self.done(first)

        # Scenario ACCT-09
        # A wrong password, and an address with no account, say the same,
        # nothing syncs, and the foot still says the budgets are kept here.
        app = launch_fresh(self)
        for who, typed in ((address, "not-the-password"), (fresh_address("nobody"), password)):
            self.sign_in(app, who, typed)
            app.wait_shows("That email or password is wrong.", within=app.front)
            app.button("Cancel", within=app.front).press()
            app.wait_for_window(1, "the account sheet to close")
            self.foot(app, KEPT_HERE)
            self.assertFalse(app.shows("Sync", within=app.main, role="push button"))

    def test_forgot_password(self):
        needs_accounts(self)
        app = launch_fresh(self)
        address, password = fresh_address("forgot"), secrets.token_urlsafe(18)
        self.confirm(app, address, self.create(app, address, password))
        sheet = app.front
        app.button("Sign out", within=sheet).press()
        app.wait_for_window(1, "the account sheet to close")
        self.foot(app, KEPT_HERE)

        # Scenario ACCT-10
        # 1. Forgot your password? opens Reset your password with the email
        # already in it, and Send code says what happens without saying
        # whether the address has an account.
        sheet = self.open_sheet(app)
        app.field("Email", sheet).type(address)
        app.button("Forgot your password?", within=sheet).press()
        app.wait_shows("Reset your password")
        sheet = app.front
        email = app.near("text", None, to=app.find("label", "Email", sheet))
        self.assertEqual(address, email.text)
        asked = now()
        app.button("Send code", within=sheet).press()
        app.wait_shows(f"If {address} has an account and has been confirmed, a code is on its way. "
                       "It lasts 30 minutes.", within=app.front)
        for words in ("Code", "New password", "Confirm password"):
            app.wait_shows(words, within=app.front)
        app.button("Start over", within=app.front)

        # Scenario ACCT-10
        # 2. The code and a new password twice sign in, and every other
        # device is signed out.
        sheet = app.front
        new_password = secrets.token_urlsafe(18)
        app.field("Code", sheet).type(emailed_code(address, asked))
        app.field("New password", sheet).type(new_password)
        app.field("Confirm password", sheet).type(new_password)
        app.button("Set password", within=sheet).press()
        app.wait_shows("Your password is changed, and you are signed in. Every other device was signed out.")
        self.done(app)
        self.foot(app, SYNCED)

        # Scenario ACCT-10
        # 3. An address never confirmed gets no code, though the sheet says
        # the same words.
        other = launch_fresh(self)
        unconfirmed = fresh_address("unconfirmed")
        self.create(other, unconfirmed, secrets.token_urlsafe(18))
        other.wait_shows("Confirm your email")
        other.button("Not now", within=other.front).press()
        other.wait_for_window(1, "the account sheet to close")
        sheet = self.open_sheet(other)
        other.button("Sign out", within=sheet).press()
        other.wait_for_window(1, "the account sheet to close")
        sheet = self.open_sheet(other)
        other.field("Email", sheet).type(unconfirmed)
        other.button("Forgot your password?", within=sheet).press()
        other.wait_shows("Reset your password")
        asked = now()
        other.button("Send code", within=other.front).press()
        other.wait_shows(f"If {unconfirmed} has an account and has been confirmed, a code is on its way. "
                         "It lasts 30 minutes.", within=other.front)
        time.sleep(5)
        self.assertIsNone(newest_mail_since(unconfirmed, asked), "an unconfirmed address was sent a code")

    def test_sign_out(self):
        needs_accounts(self)
        app = launch_fresh(self)
        address, password = fresh_address("signout"), secrets.token_urlsafe(18)
        self.confirm(app, address, self.create(app, address, password))
        self.done(app)
        group = unique("Signout")
        app.new_group(group)
        app.new_budget("Books", "100", group=group)
        app.sync()

        # Scenario ACCT-11
        # 1. Sign out closes the sheet, and the list is what this computer
        # keeps signed out, without the account's budgets.
        sheet = self.open_sheet(app)
        app.button("Sign out", within=sheet).press()
        app.wait_for_window(1, "the account sheet to close")
        self.foot(app, KEPT_HERE)
        app.until(lambda: not app.has_budget("Books"), "the account's budget to go")

        # Scenario ACCT-11
        # 2. Still signed out after a restart, and signing in again brings
        # the account's budgets back.
        app.restart()
        self.foot(app, KEPT_HERE)
        self.assertFalse(app.has_budget("Books"))
        self.sign_in(app, address, password)
        app.wait_for_window(1, "the account sheet to close")
        app.until(lambda: app.has_budget("Books"), "the account's budget to come back")
        app.remove_group(group)

    def test_sign_out_everywhere_asks_first(self):
        needs_accounts(self)
        app = launch_fresh(self)
        address, password = fresh_address("everywhere"), secrets.token_urlsafe(18)
        self.confirm(app, address, self.create(app, address, password))
        self.done(app)

        # Scenario ACCT-12
        # 1. Sign out everywhere… asks first, and Cancel changes nothing.
        sheet = self.open_sheet(app)
        app.button("Sign out everywhere…", within=sheet).press()
        app.wait_for_window(3, "the question")
        self.assertEqual("Sign out everywhere? Every device signed in to this account is signed out, this one too. "
                         "Each device keeps its budgets.", app.question())
        app.button("Sign Out Everywhere", within=app.front)
        app.answer("Cancel")
        app.wait_shows(f"Signed in as {address}.", within=app.front)
        self.foot(app, SYNCED)

        # Scenario ACCT-12
        # 2. Sign Out Everywhere closes the sheet, and this computer is signed
        # out.
        app.button("Sign out everywhere…", within=app.front).press()
        app.wait_for_window(3, "the question")
        app.answer("Sign Out Everywhere")
        app.wait_for_window(1, "the account sheet to close")
        self.foot(app, KEPT_HERE)

    def test_this_computer_is_listed_by_its_own_name(self):
        needs_accounts(self)
        app = launch_fresh(self)
        address, password = fresh_address("named"), secrets.token_urlsafe(18)
        self.confirm(app, address, self.create(app, address, password))
        self.done(app)

        # Scenario ACCT-14
        # The account's list of signed-in devices, which the app has no
        # screen for yet, names this computer by its host name, without
        # ".local". Read from the server, signed in as the account.
        session = staging("POST", "/api/v2/signin",
                          {"email": address, "password": password, "deviceLabel": "UI test check"})
        try:
            names = [s.get("deviceLabel") for s in staging("GET", "/api/v2/sessions", token=session["token"])]
        finally:
            staging("POST", "/api/v2/signout", {}, token=session["token"])
        host = socket.gethostname().removesuffix(".local")
        self.assertIn(host, names)
        self.assertFalse(any(name and name.endswith(".local") for name in names), f"{names}")

    def test_a_staging_build_says_so_across_the_top(self):
        app = launch_fresh(self)

        # Scenario ACCT-15
        # The staging build, the only one these tests run, says STAGING
        # across the top.
        app.wait_shows("STAGING", within=app.main)


if __name__ == "__main__":
    unittest.main()
