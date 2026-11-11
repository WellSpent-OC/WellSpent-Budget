"""The app keeps answering while it shows a change. A screen reader asks the
app what is on screen all the time, so a main thread busy for seconds after
a change leaves a person who uses one with nothing to hear."""

import time
import unittest

import test_import
from wellspent_ui import launch_fresh

# How long after the change to keep asking.
WATCH = 6.0
# The longest the app may go without answering. A screen reader that hears
# nothing for longer sounds like the app has hung. The tree itself gives up on
# an ask after 0.8 seconds, so one second is the shortest wait it can tell
# from that.
LONGEST_SILENCE = 1.0


def longest_silence(app, seconds):
    """Asks the app how many windows it has, again and again for `seconds`.
    Gives back the longest time, in seconds, from an ask until the app next
    answered one. The tree gives up on an app that hasn't answered within 0.8
    seconds, and says -1, so a long silence is several asks in a row."""
    longest = 0.0
    waiting_since = None
    start = time.monotonic()
    while time.monotonic() < start + seconds:
        asked = time.monotonic()
        answer = app._root().get_child_count()
        if waiting_since is None:
            waiting_since = asked
        if answer != -1:
            longest = max(longest, time.monotonic() - waiting_since)
            waiting_since = None
        time.sleep(0.05)
    if waiting_since is not None:
        longest = max(longest, time.monotonic() - waiting_since)
    return round(longest, 2)


class Responsive(unittest.TestCase):

    def test_the_app_answers_while_it_shows_a_new_transaction(self):
        app = launch_fresh(self, counts=True)
        # The screens the window made at launch. Laying the window out
        # again must not make them again: each one made adds a watcher.
        watchers = app.debug_counts()["watchers"]
        app.new_group("Kitchen")
        app.new_budget("Food", "5000", group="Kitchen")
        # A busy month of shopping, 81 rows on the page: Market filed
        # in Food once, then the rest of the month's Market lines follow it.
        first = app.write_file("first.csv", test_import.statement((1, "MARKET", "-9.50")))
        review = app.open_statement(first)
        app.file_line(review, "MARKET", "Food")
        app.button("Import", within=review).press()
        app.wait_for_window(1, "the review to close")
        month = app.write_file("month.csv", test_import.statement(
            *[(i % 9 + 1, "MARKET", f"-{10 + i}.25") for i in range(80)]))
        review = app.open_statement(month)
        app.button("Import", within=review).press()
        app.wait_for_window(1, "the review to close")
        app.until(lambda: len(app.entries()) == 81, "the month's transactions", wait=60)

        # Scenario ENTRY-15
        app.button("Add", within=app.main).press()
        sheet = app.wait_for_window(2, "the New transaction sheet")
        app.field("Merchant", sheet).type("Hilltop Grocery")
        app.field("Amount", sheet).type("12.00")
        before = app.debug_counts()
        app.button("Add", within=sheet).press()
        silence = longest_silence(app, WATCH)
        after = app.debug_counts()
        # Each is told apart, so a run that fails one still says the others.
        with self.subTest("screens made once"):
            self.assertEqual(watchers, after["watchers"], "screens waiting on a reload, as at launch")
        with self.subTest("at most two draws for one change"):
            # Closing the sheet and saving its transaction were four draws.
            # Two are left, one for the sheet and one for the saved
            # transaction, because each object that changes draws on its own.
            # One is the aim (wellspent-ops #367).
            self.assertLessEqual(after["draws"] - before["draws"], 2, "times the window drew for one new transaction")
        with self.subTest("still answering"):
            self.assertLessEqual(silence, LONGEST_SILENCE, "seconds the app went without answering after Add")


if __name__ == "__main__":
    unittest.main()
