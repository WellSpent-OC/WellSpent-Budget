"""Repeat expenses (Features/RepeatExpenses.md) in the real window, signed out,
as the Mac's RepeatTests: setting one, the short list and a repeat's own
sheet, which months a change reaches, stopping, the two ways to delete, and
Undo. Then a later month's bill, on the test clock: each month, after time
away, and in a short month. Who may change a repeat is the shared code's test
(RepeatsTests)."""

import datetime
import unittest

from wellspent_ui import launch_fresh, short_date

BILL = "Phone bill"
REPEATS = "Repeats every month"


class Repeats(unittest.TestCase):

    def started(self):
        """Bills, a budget in a group of its own, open, with no repeats yet.
        (A sample group has a Utilities.) The Undo bar stays longer than its
        10 seconds, so a slow run reaches it."""
        app = launch_fresh(self, undo_seconds=120)
        app.new_group("Home")
        app.new_budget("Bills", "600", group="Home")
        return app

    def add_repeat(self, app, merchant, amount):
        """Add, the merchant and amount, Repeats every month, Add."""
        app.button("Add", within=app.main).press()
        sheet = app.wait_for_window(2, "the New transaction sheet")
        app.field("Merchant", sheet).type(merchant)
        app.field("Amount", sheet).type(amount)
        app.find("check box", REPEATS, within=sheet).press()
        app.button("Add", within=sheet).press()
        app.wait_for_window(1, "the New transaction sheet to close")
        app.entry(merchant)

    def open(self, app, merchant):
        app.entry(merchant).press()
        return app.wait_for_window(2, f"{merchant} to open")

    def save(self, app, sheet):
        app.button("Save", within=sheet).press()
        app.wait_for_window(1, "the sheet to close")

    def switch(self, app, sheet):
        return app.find("check box", REPEATS, within=sheet)

    def count(self, app):
        """The count line's repeats, such as "2 repeats", or None."""
        hits = [e for e in app.main.all("push button") if e.showing and e.words.endswith((" repeat", " repeats"))]
        return hits[0].words if hits else None

    def expect_repeat(self, app, says):
        """Opens the short list, checks what the bill's row says, and closes it."""
        app.button(self.count(app), within=app.main).press()
        sheet = app.wait_for_window(2, "the short list")
        app.until(lambda: any(says in t for t in app.texts(sheet)) or None,
                  f"the repeat to say {says}. The list says {app.texts(sheet)}")
        app.button("Done", within=sheet).press()
        app.wait_for_window(1, "the short list to close")

    def test_setting_a_repeat_and_finding_it(self):
        app = self.started()

        # Scenario REPEAT-12
        # With none, the count line doesn't mention repeats.
        self.assertIsNone(self.count(app), "a budget with none says it has repeats")

        # Scenario REPEAT-01
        self.add_repeat(app, BILL, "85.00")
        self.assertEqual(1, sum(row[1] == BILL for row in app.entries()), "the bill is not in the list once")

        # Scenario REPEAT-12
        # Two repeats: "2 repeats" opens the list, and a row opens its own
        # sheet, with Stop repeating and Save for its owner.
        self.add_repeat(app, "Internet", "60.00")
        app.until(lambda: self.count(app) == "2 repeats" or None, "the count to say 2 repeats")
        app.button("2 repeats", within=app.main).press()
        sheet = app.wait_for_window(2, "the short list")
        app.wait_shows("Repeats in Bills", within=sheet)
        app.picture("repeats-list")
        [row] = [b for b in sheet.all("push button") if any(l.words == BILL for l in b.all("label"))]
        row.press()
        app.until(lambda: app.shows("Stop repeating…", within=app.front, role="push button") or None,
                  "the repeat's own sheet")
        self.assertTrue(app.shows("Save", within=app.front, role="push button"), "the owner has no Save")
        app.picture("repeat-own-sheet")

    def test_the_switch_tells_the_truth_on_save_and_reopen(self):
        app = self.started()
        app.add_entry("Water", "40.00", note="Meter 12")

        # Scenario REPEAT-17
        sheet = self.open(app, "Water")
        self.assertFalse(self.switch(app, sheet).checked, "on before turning it on")
        self.switch(app, sheet).press()
        self.save(app, sheet)
        app.until(lambda: self.count(app) == "1 repeat" or None, "the count to say 1 repeat")
        rows = [row for row in app.entries() if row[1] == "Water"]
        self.assertEqual(1, len(rows), "the bill is not in the list once")
        self.assertIn("Meter 12", rows[0], "the note changed")
        self.assertIn("Repeat", rows[0], "its source doesn't say Repeat")

        # Scenario REPEAT-18
        # Reopened it reads on. Off and saved, the repeat stops and it reads off.
        sheet = self.open(app, "Water")
        self.assertTrue(self.switch(app, sheet).checked, "off, reopened after turning it on")
        app.picture("repeat-switch-on")
        self.switch(app, sheet).press()
        self.save(app, sheet)
        app.until(lambda: self.count(app) is None or None, "a stopped repeat to leave the count")
        sheet = self.open(app, "Water")
        self.assertFalse(self.switch(app, sheet).checked, "on, reopened after stopping")

        # Scenario REPEAT-18
        # On again is the same repeat: the count is one, not two.
        self.switch(app, sheet).press()
        self.save(app, sheet)
        app.until(lambda: self.count(app) == "1 repeat" or None, "the count to say 1 repeat again")
        self.assertEqual(1, sum(row[1] == "Water" for row in app.entries()), "a second bill")

    def test_money_in_does_not_repeat(self):
        app = self.started()
        app.button("Add", within=app.main).press()
        sheet = app.wait_for_window(2, "the New transaction sheet")
        self.switch(app, sheet)

        # Scenario REPEAT-13
        app.find("check box", "Money in", within=sheet).press()
        app.wait_gone(REPEATS, within=sheet)

    def test_a_change_says_which_months_it_reaches(self):
        app = self.started()
        self.add_repeat(app, BILL, "85.00")

        # Scenario REPEAT-06
        # A change to this month only leaves the repeat at its old amount.
        sheet = self.open(app, BILL)
        amount = app.field("Amount", sheet)
        amount.type("92.00")
        which = app.picker("Which months?", sheet)
        self.assertEqual("This month only", which.words, "it does not start on This month only")
        self.save(app, sheet)
        app.until(lambda: any("$92.00" in row for row in app.entries()) or None, "the bill to change")
        self.expect_repeat(app, "$85.00")

        # Scenario REPEAT-07
        # A change to this month and later changes the repeat too.
        sheet = self.open(app, BILL)
        app.field("Amount", sheet).type("95.00")
        app.choose("This month and later", app.picker("Which months?", sheet))
        app.picture("repeat-which-months")
        self.save(app, sheet)
        app.until(lambda: any("$95.00" in row for row in app.entries()) or None, "the bill to change")
        self.expect_repeat(app, "$95.00")

    def test_stop_repeating_ends_the_repeat_and_keeps_the_bill(self):
        app = self.started()
        self.add_repeat(app, BILL, "85.00")

        # Scenario REPEAT-08
        sheet = self.open(app, BILL)
        app.button("Stop repeating…", within=sheet).press()
        app.answer("Stop Repeating")
        app.wait_for_window(1, "the sheet to close")
        app.until(lambda: self.count(app) is None or None, "the stopped repeat to leave the count")
        app.entry(BILL)

        # Scenario REPEAT-10
        # Undo carries the repeat on.
        app.button("Undo", within=app.main).press()
        app.until(lambda: self.count(app) == "1 repeat" or None, "Undo to bring the repeat back")

    def test_deleting_a_made_bill_asks_both_choices(self):
        app = self.started()
        self.add_repeat(app, BILL, "85.00")

        # Scenario REPEAT-09
        sheet = self.open(app, BILL)
        app.button("Delete…", within=sheet).press()
        app.until(lambda: len(app.windows()) > 2 or None, "the question")
        app.picture("repeat-delete-question")
        self.assertTrue(app.shows("Delete This Month Only", within=app.front, role="push button"),
                        "no Delete This Month Only")
        app.answer("Delete and Stop Repeating")
        app.wait_for_window(1, "the sheet to close")
        app.until(lambda: all(row[1] != BILL for row in app.entries()) or None, "the bill to go")
        app.until(lambda: self.count(app) is None or None, "the repeat to leave the count")

        # Scenario REPEAT-10
        # Undo brings back both.
        app.button("Undo", within=app.main).press()
        app.entry(BILL)
        app.until(lambda: self.count(app) == "1 repeat" or None, "Undo to bring the repeat back")


class RepeatsOnTheClock(unittest.TestCase):
    """A repeat's later months, on the test clock: the test writes a local
    date and time to a file and the app reads today from it. The app is
    closed, the clock moves, and the app is opened again, as a person who
    comes back another day. No account is needed."""

    def repeating(self, start):
        """Bills in Home on the test clock at `start`, with the $85.00 phone
        bill set to repeat that day. (A sample group has a Utilities, so the
        scenarios' Utilities is Bills here, as in the class above.)"""
        app = launch_fresh(self, clock=start)
        app.new_group("Home")
        app.new_budget("Bills", "600", group="Home")
        app.button("Add", within=app.main).press()
        sheet = app.wait_for_window(2, "the New transaction sheet")
        app.field("Merchant", sheet).type(BILL)
        app.field("Amount", sheet).type("85.00")
        app.find("check box", REPEATS, within=sheet).press()
        app.button("Add", within=sheet).press()
        app.wait_for_window(1, "the New transaction sheet to close")
        self.expect_one_bill(app, start, "on the day it was set")
        return app

    def reopen(self, app, when):
        """Closes the app, moves the clock to `when`, opens the app again and
        opens Bills."""
        # Closed first, so the open window can't notice the new day itself:
        # the bill must come from opening the app.
        app.quit()
        app.launch(**dict(app.launched_with, clock=when))
        app.budget("Bills").press()
        app.until(lambda: app.budget("Bills").selected, "Bills to open")

    def expect_one_bill(self, app, day, what):
        """The phone bill is listed once, dated the day of `day`, a clock
        time, at $85.00. Gives its row's texts."""
        date = short_date(datetime.datetime.strptime(day, "%Y-%m-%dT%H:%M:%S").date())

        def bills():
            rows = [row for row in app.entries() if BILL in row]
            return rows if rows and rows[0][0] == date else None
        rows = app.until(bills, f"the phone bill dated {date}, {what}. The list says {app.entries()}")
        self.assertEqual(1, len(rows), f"{len(rows)} phone bills {what}: {rows}")
        self.assertIn("$85.00", rows[0], f"the bill {what} is not $85.00")
        return rows[0]

    def test_it_shows_up_each_month(self):
        app = self.repeating("2026-11-14T09:00:00")

        # Scenario REPEAT-02
        # 1. December 14 comes and the app is opened: a new $85.00 bill is in
        # Bills, dated Dec 14, with Source reading Repeat.
        self.reopen(app, "2026-12-14T09:00:00")
        row = self.expect_one_bill(app, "2026-12-14T09:00:00", "on December 14")
        self.assertIn("Repeat", row, "its source doesn't say Repeat")

    def test_catching_up_after_time_away(self):
        # Every month between getting its bill, once, is proven by RepeatsTests
        # (eachMonthThatHasComeGetsOneBill): no screen shows an earlier
        # month's bills without moving the date, and moving it makes the
        # missing bill itself.
        app = self.repeating("2026-10-15T09:00:00")

        # Scenario REPEAT-03
        # 1. Opened again on December 20, after this month's 15th, Bills shows
        # December's phone bill once, dated the 15th, at $85.00.
        self.reopen(app, "2026-12-20T09:00:00")
        self.expect_one_bill(app, "2026-12-15T09:00:00", "in December, after two months away")

    def test_a_short_month(self):
        app = self.repeating("2026-10-31T09:00:00")

        # Scenario REPEAT-04
        # 1. A bill that repeats on the 31st shows up in November on the 30th,
        # the month's last day.
        self.reopen(app, "2026-11-30T09:00:00")
        self.expect_one_bill(app, "2026-11-30T09:00:00", "in November")


if __name__ == "__main__":
    unittest.main()
