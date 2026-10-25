"""WarTable through the native window, real server and accessibility tree.

These tests do not start model providers or pretend a task ran. The server and
connector suites exercise scoped credentials, concurrent sends and work leases.
"""
import unittest
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile

from wellspent_ui import launch_fresh, needs_accounts, unique, STAGING


def open_board(app, group=None):
    if not app.shows("WarTable", role="push button"):
        app.button("Extensions", within=app.main).press()
        app.button("Install WarTable", within=app.main).press()
    else:
        app.button("WarTable", within=app.main).press()
    if group:
        picker = app.picker("WarTable group", within=app.main)
        app.choose(group, picker)


def enable_board(app, group, name="Robin"):
    open_board(app, group)
    app.field("Your WarTable name", app.main).type(name)
    app.button("Turn on WarTable", within=app.main).press()
    app.wait_shows("No messages yet. Start the conversation.", within=app.main)


def enroll_agent(app, name):
    app.button("People", within=app.main).press()
    app.button("Enroll agent…", within=app.main).press()
    sheet = app.wait_for_window(2, "agent enrollment")
    app.field("Agent name", sheet).type(name)
    app.field("Agent tool", sheet).type("Local test harness")
    app.field("Machine label", sheet).type("Disposable container")
    app.button("Create enrollment code", within=sheet).press()
    app.wait_shows(f"Connect {name}")
    app.button("Copy enrollment code", within=app.front).press()
    app.button("Done", within=app.front).press()
    app.wait_for_window(1, "enrollment to close")
    app.wait_shows(f"{name} · Disconnected", within=app.main)


class SignedOut(unittest.TestCase):
    # Scenario WARTABLE-01
    def test_extension_keeps_budgets_available(self):
        app = launch_fresh(self)
        group = unique("WarTable local")
        app.new_group(group)
        app.new_budget("Local food", "300", group=group)
        open_board(app)
        app.wait_shows("Sign in and choose a synced group to use WarTable.", within=app.main)
        app.budget("Local food").press()
        app.until(app.budget_open, "the budget to remain available")
        open_board(app)
        app.button("Open Account", within=app.main).press()
        sheet = app.wait_for_window(2, "Account from WarTable")
        app.field("Email", sheet)
        app.button("Cancel", within=sheet).press()


class Connected(unittest.TestCase):
    def setUp(self):
        needs_accounts(self)
        self.app = launch_fresh(self)
        self.app.sign_in_as("Robin")
        self.group = unique("WarTable")
        self.app.new_group(self.group)
        self.addCleanup(self.app.remove_group, self.group)
        self.app.new_budget(f"{self.group} food", "400", group=self.group)
        self.app.sync()

    # Scenario WARTABLE-01, WARTABLE-02, WARTABLE-05, WARTABLE-09
    def test_multiline_send_account_isolation_and_disable(self):
        app = self.app
        enable_board(app, self.group)
        app.wait_shows("Visible to: Robin", within=app.main)
        composer = app.find("text", "Message", within=app.main)
        composer.type("First line")
        app.focus(composer)
        app.key("End")
        app.key("Return")
        app.until(lambda: "\n" in app.find("text", "Message", within=app.main).text,
                  "Enter to insert a newline")
        self.assertTrue(app.shows("No messages yet. Start the conversation.", within=app.main))
        composer = app.find("text", "Message", within=app.main)
        composer.type("First line\nSecond line")
        app.focus(composer)
        app.key("ctrl+Return")
        app.wait_shows("First line\nSecond line", within=app.main)
        self.assertEqual("", app.find("text", "Message", within=app.main).text)
        app.picture("wartable-signed-in-chat")
        app.find("text", "Message", within=app.main).type("Unsent account draft")
        app.sign_out()
        open_board(app)
        app.wait_shows("Sign in and choose a synced group to use WarTable.", within=app.main)
        self.assertFalse(app.shows("First line\nSecond line", within=app.main))
        self.assertFalse(app.shows("Unsent account draft", within=app.main))
        app.sign_in_as("Robin")
        open_board(app, self.group)
        app.wait_shows("First line\nSecond line", within=app.main)
        self.assertEqual("", app.find("text", "Message", within=app.main).text)
        app.button("Turn off…", within=app.main).press()
        app.answer("Turn off")
        app.wait_shows("Turn on WarTable", role="push button", within=app.main)
        app.budget(f"{self.group} food").press()
        app.until(app.budget_open, "budget after disabling WarTable")

    # Scenario WARTABLE-03, WARTABLE-04, WARTABLE-10
    def test_direct_audience_and_real_agent_controls(self):
        app = self.app
        leslie = launch_fresh(self)
        leslie.sign_in_as("Leslie")
        leslie.join(app.share(self.group, "Robin", "Add"), "Leslie")
        app.sync()
        enable_board(app, self.group)
        app.button("People", within=app.main).press()
        app.button("Add group member…", within=app.main).press()
        sheet = app.wait_for_window(2, "add group member")
        app.choose("Leslie", app.picker("Group member", within=sheet))
        app.button("Add member", within=sheet).press()
        app.wait_for_window(1, "member added")
        app.button("Edit role…", within=app.main).press()
        sheet = app.wait_for_window(2, "member role")
        app.choose("Manager", app.picker("Extension role", within=sheet))
        app.button("Save role", within=sheet).press()
        app.wait_for_window(1, "manager role saved")
        app.wait_shows("Manager", within=app.main)
        app.button("Chat", within=app.main).press()
        app.button("New conversation…", within=app.main).press()
        sheet = app.wait_for_window(2, "direct conversation")
        app.field("Conversation name", sheet).type("Review planning")
        app.find("check box", "Leslie · Person", within=sheet).press()
        app.wait_shows("The owner and current extension admins and managers are always included.", within=sheet)
        app.button("Start conversation", within=sheet).press()
        app.wait_for_window(1, "new direct conversation")
        app.until(lambda: any(t.startswith("Visible to:") and "Robin" in t and "Leslie" in t
                              for t in app.texts(app.main)), "complete direct audience")
        app.find("text", "Message", within=app.main).type("Visible collaboration")
        app.button("Send", within=app.main).press()
        app.wait_shows("Visible collaboration", within=app.main)
        app.button("People", within=app.main).press()
        app.button("Enroll agent…", within=app.main).press()
        sheet = app.wait_for_window(2, "agent enrollment")
        app.field("Agent name", sheet).type("Test connector")
        app.field("Agent tool", sheet).type("Local test harness")
        app.field("Machine label", sheet).type("Disposable container")
        app.button("Create enrollment code", within=sheet).press()
        app.wait_shows("Connect Test connector")
        app.button("Done", within=app.front).press()
        app.wait_for_window(1, "enrollment to close")
        app.wait_shows("Test connector · Disconnected", within=app.main)
        app.button("Pause Test connector", within=app.main).press()
        app.wait_shows("Test connector · Paused", within=app.main)
        app.button("Resume Test connector", within=app.main).press()
        app.wait_shows("Test connector · Disconnected", within=app.main)
        app.button("Revoke Test connector…", within=app.main).press()
        app.answer("Revoke")
        app.wait_shows("Test connector · Revoked", within=app.main)
        app.picture("wartable-people")
        app.button("Transfer ownership…", within=app.main).press()
        sheet = app.wait_for_window(2, "ownership transfer")
        app.choose("Leslie", app.picker("New owner", within=sheet))
        app.button("Review transfer…", within=sheet).press()
        self.assertIn("retained history", app.question())
        app.answer("Keep ownership")
        app.button("Review transfer…", within=app.front).press()
        app.answer("Transfer ownership")
        app.wait_for_window(1, "ownership transferred")
        app.wait_gone("Turn off…", role="push button", within=app.main)
        app.wait_reads(["Robin", "Admin"], within=app.main)
        leslie.sync()
        open_board(leslie, self.group)
        leslie.button("Turn off…", within=leslie.main)
        leslie.button("Review planning", within=leslie.main).press()
        leslie.wait_shows("Visible collaboration", within=leslie.main)

    # Scenario WARTABLE-06, WARTABLE-07
    def test_context_and_task_require_explicit_authority(self):
        app = self.app
        enable_board(app, self.group)
        enroll_agent(app, "Fixture worker")
        app.button("Context", within=app.main).press()
        app.button("Add context source…", within=app.main).press()
        sheet = app.wait_for_window(2, "context source")
        app.field("Source name", sheet).type("Fixture repository")
        app.field("Source reference", sheet).type("https://example.com/fixture/repository")
        app.find("text", "Allowed paths", within=sheet).type("../Private")
        app.find("check box", "Fixture worker · Agent", within=sheet).press()
        app.button("Add source", within=sheet).press()
        app.wait_shows("Choose explicit relative paths without traversal.", within=sheet)
        self.assertEqual("Fixture repository", app.field("Source name", sheet).text)
        app.find("text", "Allowed paths", within=sheet).type("Sources\nTests")
        app.button("Add source", within=sheet).press()
        app.wait_for_window(1, "saved source")
        app.wait_shows("Fixture repository", within=app.main)
        app.button("Edit source…", within=app.main).press()
        sheet = app.wait_for_window(2, "source policy edit")
        app.find("text", "Allowed paths", within=sheet).type("Sources\nTests\nDocs")
        app.button("Save source", within=sheet).press()
        app.wait_for_window(1, "source policy saved")
        app.wait_shows("Source policy revision 2", within=app.main)
        app.button("Grant source access…", within=app.main).press()
        sheet = app.wait_for_window(2, "grant source access")
        app.choose("Fixture worker", app.picker("Person or agent", within=sheet))
        app.find("text", "Grant paths", within=sheet).type("Sources\nTests")
        app.button("Grant access", within=sheet).press()
        app.wait_for_window(1, "source grant saved")
        app.wait_shows("Read context", within=app.main)
        app.button("Work", within=app.main).press()
        app.button("Create task…", within=app.main).press()
        sheet = app.wait_for_window(2, "task proposal")
        app.field("Task title", sheet).type("Review fixture behavior")
        app.find("text", "Task details", within=sheet).type("Read the permitted source and report findings.")
        app.find("text", "Expected checks", within=sheet).type("Unit tests")
        app.button("Propose task", within=sheet).press()
        app.wait_for_window(1, "task proposal saved")
        app.wait_shows("Review fixture behavior", within=app.main)
        app.wait_shows("Proposed", within=app.main)
        self.assertFalse(app.shows("Running", within=app.main))
        app.picture("wartable-work-proposal")
        app.button("Authorize task…", within=app.main).press()
        sheet = app.wait_for_window(2, "authorize task")
        app.button("Authorize task", within=sheet).press()
        app.wait_for_window(1, "authorized task")
        app.wait_shows("Ready", within=app.main)
        self.assertFalse(app.shows("Running", within=app.main), "a disconnected worker did not run")
        app.button("Stop task…", within=app.main).press()
        app.answer("Stop task")
        app.wait_shows("Cancelled", within=app.main)
        app.button("Context", within=app.main).press()
        app.button("Revoke grant", within=app.main).press()
        app.wait_shows("Revoked", within=app.main)
        app.button("Chat", within=app.main).press()
        app.button("Context…", within=app.main).press()
        sheet = app.wait_for_window(2, "context attachment")
        app.find("check box", "Fixture repository", within=sheet).press()
        app.button("Use selected context", within=sheet).press()
        app.wait_for_window(1, "context selected")
        app.find("text", "Message", within=app.main).type("Discuss the approved source.")
        app.button("Send", within=app.main).press()
        app.wait_shows("Context: Fixture repository", within=app.main)
        app.button("Reply to Robin", within=app.main).press()
        app.wait_shows("Replying to Robin", within=app.main)
        app.find("text", "Message", within=app.main).type("Keep its audience on this reply.")
        app.button("Send", within=app.main).press()
        app.wait_shows("Keep its audience on this reply.", within=app.main)
        app.main.all("push button", "Redact message from Robin")[0].press()
        sheet = app.wait_for_window(2, "redaction reason")
        app.field("Reason", sheet).type("Fixture cleanup")
        app.button("Redact message", within=sheet).press()
        app.wait_for_window(1, "redacted message")
        app.wait_shows("Message redacted", within=app.main)


class Review(unittest.TestCase):
    # The fixture runs the actual adapter's isolated edit and syntax check,
    # creates a local Git commit, and reports evidence through the real API.
    # It deliberately publishes no branch or PR and records no fake CI pass.
    def test_review_of_an_actual_local_commit_remains_advisory(self):
        needs_accounts(self)
        supplied = os.environ.get("WELLSPENT_UI_WARTABLE_REVIEW_FIXTURE")
        if supplied:
            fixture_path = Path(supplied)
        else:
            temporary = tempfile.TemporaryDirectory(prefix="wartable-ui-review-")
            self.addCleanup(temporary.cleanup)
            fixture_path = Path(temporary.name) / "review.json"
            adapter = Path(__file__).resolve().parents[2] / "Extensions" / "WarTable" / "adapter"
            # parents[2] is Linux's repository root (UITests → Linux → root).
            result = subprocess.run([sys.executable, "tests/smoke_vapor.py", "--server", STAGING,
                                     "--review-fixture-file", str(fixture_path)], cwd=adapter,
                                    env=dict(os.environ, PYTHONPATH=str(adapter)),
                                    capture_output=True, text=True, timeout=120)
            self.assertEqual(0, result.returncode, "The isolated review fixture could not be prepared: " + result.stderr)
        fixture = json.loads(fixture_path.read_text())
        self.assertEqual(STAGING, fixture["serverURL"])
        self.assertTrue(fixture["syntheticFixture"])
        self.assertFalse(fixture["published"])
        app = launch_fresh(self)
        app.button("Sign in", within=app.main).press()
        sheet = app.wait_for_window(2, "review fixture sign in")
        app.field("Server", sheet).type(STAGING)
        app.field("Email", sheet).type(fixture["email"])
        app.field("Password", sheet).type(fixture["password"])
        app.button("Sign in", within=sheet).press()
        app.wait_for_window(1, "review fixture account")
        app.sync()
        open_board(app, fixture["groupName"])
        app.wait_shows("Claude synthetic acknowledgement", within=app.main)
        app.wait_shows("Codex synthetic acknowledgement", within=app.main)
        app.wait_shows("Gemini synthetic acknowledgement", within=app.main)
        app.picture("wartable-synthetic-provider-chat")
        app.button("People", within=app.main).press()
        app.until(lambda: all(any(provider in line for line in app.texts(app.main))
                              for provider in ("Claude Code", "ChatGPT/Codex", "Gemini CLI")),
                  "the three synthetic providers to be named")
        app.picture("wartable-synthetic-provider-people")
        app.button("Work", within=app.main).press()
        app.wait_shows("Awaiting review", within=app.main)
        app.wait_shows("Commit: " + fixture["headCommit"], within=app.main)
        self.assertFalse(app.shows("Open PR in Chrome", role="push button", within=app.main))
        app.button("Review…", within=app.main).press()
        sheet = app.wait_for_window(2, "review current commit")
        self.assertFalse(app.button("Record review", within=sheet).enabled)
        app.field("Reviewed base commit", sheet).type(fixture["baseCommit"])
        app.choose("Request changes", app.picker("Review decision", within=sheet))
        app.find("text", "Review findings", within=sheet).type("The local syntax check passed. Request clearer behavior documentation before approval.")
        app.button("Record review", within=sheet).press()
        app.wait_for_window(1, "review recorded")
        app.wait_shows("Recorded in WarTable; provider approval not confirmed", within=app.main)
        app.wait_shows("Changes requested at " + fixture["headCommit"], within=app.main)
        app.picture("wartable-advisory-review")


if __name__ == "__main__":
    unittest.main()
