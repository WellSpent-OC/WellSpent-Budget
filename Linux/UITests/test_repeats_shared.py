"""Repeat expenses in a shared group (Features/RepeatExpenses.md), with two
people: only the person who added a bill turns its repeat on, and someone who
may only read a repeat's bill sees whether it repeats in a plain row.

Leslie makes the group and adds Water, $40.00. Robin joins at Manage, then
Leslie moves him to Add. Each person's account is made once per run, so these
are skipped without the test mailbox's token. The group is named for this
test and removed at the end."""

import datetime
import unittest

from wellspent_ui import launch_fresh, needs_accounts, short_date, unique

REPEATS = "Repeats every month"
BILL = "Phone bill"


class RepeatsShared(unittest.TestCase):

    def setUp(self):
        needs_accounts(self)
        self.robin = launch_fresh(self)
        self.leslie = launch_fresh(self)
        self.robin.sign_in_as("Robin")
        self.leslie.sign_in_as("Leslie")
        self.home = unique("Home")
        self.bills = f"{self.home} bills"
        leslie = self.leslie
        leslie.new_group(self.home)
        self.addCleanup(leslie.remove_group, self.home)
        leslie.new_budget(self.bills, "600", group=self.home)
        leslie.add_entry("Water", "40.00")
        leslie.sync()
        self.robin.join(leslie.legacy_invite(self.home, "Leslie", level="Manage"), "Robin")
        self.robin.sync()

    def open(self, app, merchant):
        app.budget(self.bills).press()
        app.entry(merchant).press()
        return app.wait_for_window(2, f"{merchant} to open")

    def close(self, app, sheet, button):
        app.button(button, within=sheet).press()
        app.wait_for_window(1, "the sheet to close")

    def plain_row(self, app, sheet):
        """What the read-only sheet says beside "Repeats every month"."""
        texts = app.texts(sheet)
        return texts[texts.index(REPEATS) + 1] if REPEATS in texts else None

    def test_only_who_added_it_turns_it_on_and_a_reader_sees_a_plain_row(self):
        robin, leslie = self.robin, self.leslie

        # Scenario REPEAT-17
        # 1. A manager who opens Leslie's bill sees the switch off and dimmed.
        sheet = self.open(robin, "Water")
        switch = robin.find("check box", REPEATS, within=sheet)
        self.assertFalse(switch.checked, "on before anyone turned it on")
        self.assertFalse(switch.enabled, "a manager may turn on a repeat for someone else's bill")
        self.close(robin, sheet, "Cancel")

        # Scenario REPEAT-17
        # 2. Leslie turns it on for her own bill, and Robin, now at Add, sees
        # one Water bill.
        leslie.set_level(self.home, "Robin", "Add")
        sheet = self.open(leslie, "Water")
        leslie.find("check box", REPEATS, within=sheet).press()
        self.close(leslie, sheet, "Save")
        leslie.sync()
        robin.sync()
        robin.budget(self.bills).press()
        robin.until(lambda: [r[1] for r in robin.entries()] == ["Water"] or None, "one Water bill on Robin's")
        self.assertEqual("Leslie", robin.entries()[0][2], "Robin's list doesn't say Leslie added it")

        # Scenario REPEAT-18
        # 3. Robin may only read it: the sheet says it repeats in a plain row.
        sheet = self.open(robin, "Water")
        robin.wait_shows(REPEATS, within=sheet)
        self.assertEqual("On", self.plain_row(robin, sheet))
        self.assertFalse(robin.shows(REPEATS, within=sheet, role="check box"), "a reader has a switch")
        robin.picture("repeat-read-only")
        self.close(robin, sheet, "Done")

        # Scenario REPEAT-18
        # 4. Once Leslie stops it, the row says Off.
        sheet = self.open(leslie, "Water")
        leslie.button("Stop repeating…", within=sheet).press()
        leslie.answer("Stop Repeating")
        leslie.wait_for_window(1, "the sheet to close")
        leslie.sync()
        robin.sync()
        sheet = self.open(robin, "Water")
        robin.until(lambda: self.plain_row(robin, sheet) == "Off" or None, "the row to say Off")
        self.close(robin, sheet, "Done")


class RepeatsSharedOnTheClock(unittest.TestCase):
    """A repeat on the test clock, signed in: two copies of the app on one
    account make one bill for a month (REPEAT-05), and only the owner or a
    manager may change a repeat's later months (REPEAT-11). The app is closed,
    the clock moves, and the app is opened again, as a person who comes back
    another day. Each copy has its own clock file. The timed sync is an hour
    away, so only a test's own Sync sends anything. The group is named for
    this test and removed at the end."""

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

    def reopen(self, app, when, budget):
        """Opens a closed app again with its clock at `when`, on `budget`.
        It was closed first, so a bill comes from opening the app."""
        app.launch(**dict(app.launched_with, clock=when))
        self.open_budget(app, budget)

    def open_budget(self, app, budget):
        app.until(lambda: app.has_budget(budget) or None, f"{budget} in the sidebar")
        app.budget(budget).press()
        app.until(app.budget_open, f"{budget} to open")

    def bills(self, app, day):
        """The phone bills listed in the open budget, dated the day of `day`."""
        date = short_date(datetime.datetime.strptime(day, "%Y-%m-%dT%H:%M:%S").date())
        return [row for row in app.entries() if BILL in row and row[0] == date]

    def expect_one_bill(self, app, day, what):
        """The phone bill is listed once, dated `day`, at $85.00."""
        rows = app.until(lambda: self.bills(app, day) or None,
                         f"the phone bill dated {day[:10]}, {what}. The list says {app.entries()}")
        self.assertEqual(1, len(rows), f"{len(rows)} phone bills {what}: {rows}")
        self.assertIn("$85.00", rows[0], f"the bill {what} is not $85.00")
        return rows[0]

    def test_two_copies_on_one_account_make_one_bill(self):
        needs_accounts(self)
        set_on, opened_on = "2026-11-14T09:00:00", "2026-12-16T09:00:00"
        robin = launch_fresh(self, clock=set_on, autosync_seconds=3600)
        other = launch_fresh(self, clock=set_on, autosync_seconds=3600)
        robin.sign_in_as("Robin")
        other.sign_in_as("Robin")
        home, utilities = unique("Home"), unique("Utilities")

        # 1. Robin sets the phone bill to repeat on November 14, and both
        # copies, signed in to his account, take it in.
        robin.new_group(home)
        self.addCleanup(robin.remove_group, home)
        robin.new_budget(utilities, "600", group=home)
        self.add_repeat(robin, BILL, "85.00")
        robin.sync()
        other.sync()
        self.open_budget(other, utilities)
        self.expect_one_bill(other, set_on, "on the other copy in November")

        # Scenario REPEAT-05
        # 2. Both are closed, and both are opened on December 16, after the
        # 14th. Each shows December's bill on opening.
        robin.quit()
        other.quit()
        self.reopen(robin, opened_on, utilities)
        self.reopen(other, opened_on, utilities)
        december = "2026-12-14T09:00:00"
        self.expect_one_bill(robin, december, "on Robin's copy, made on opening")
        self.expect_one_bill(other, december, "on the other copy, made on opening")

        # Scenario REPEAT-05
        # 3. Once both have synced, each has one bill for December.
        robin.sync()
        other.sync()
        robin.sync()
        self.expect_one_bill(robin, december, "on Robin's copy after both synced")
        self.expect_one_bill(other, december, "on the other copy after both synced")

    def test_only_the_owner_or_a_manager_changes_the_rule(self):
        needs_accounts(self)
        set_on, december = "2026-11-14T09:00:00", "2026-12-14T09:00:00"
        robin = launch_fresh(self, clock=set_on, autosync_seconds=3600)
        robin.sign_in_as("Robin")
        household, utilities = unique("Household"), unique("Utilities")

        # 1. Robin sets the phone bill to repeat in Household on November 14.
        # December 14 comes, and his app makes December's bill. He invites
        # Leslie at Add and Kim at Manage.
        robin.new_group(household)
        self.addCleanup(robin.remove_group, household)
        robin.new_budget(utilities, "600", group=household)
        self.add_repeat(robin, BILL, "85.00")
        robin.quit()
        self.reopen(robin, december, utilities)
        self.expect_one_bill(robin, december, "Robin's December")
        robin.sync()
        leslie_link = robin.legacy_invite(household, "Robin", level="Add")
        kim_link = robin.legacy_invite(household, "Robin", level="Manage")

        # Scenario REPEAT-11
        # 2. Leslie, at Add, opens December's phone bill: it opens read-only,
        # with no This month and later and no Stop repeating.
        leslie = launch_fresh(self, clock=december, autosync_seconds=3600)
        leslie.sign_in_as("Leslie")
        leslie.join(leslie_link, "Leslie")
        leslie.sync()
        self.open_budget(leslie, utilities)
        self.expect_one_bill(leslie, december, "December's bill, for Leslie")
        leslie.entry(BILL).press()
        sheet = leslie.wait_for_window(2, "the bill to open")
        leslie.wait_shows("Done", within=sheet, role="push button")
        self.assertFalse(leslie.shows("Save", within=sheet, role="push button"), "Save on Leslie's read-only bill")
        self.assertFalse(leslie.shows("This month and later", within=sheet), "This month and later for Leslie")
        self.assertFalse(any(e.showing for e in sheet.all("combo box") if "Which months?" in (e.words, e.value)),
                         "Which months? for Leslie")
        self.assertFalse(leslie.shows("Stop repeating…", within=sheet), "Stop repeating for Leslie")
        leslie.button("Done", within=sheet).press()
        leslie.wait_for_window(1, "the bill to close")

        # Scenario REPEAT-11
        # 3. She opens the repeat from Utilities' list of repeats: its sheet
        # says only Robin or a manager can change it, and has nothing to change.
        leslie.button("1 repeat", within=leslie.main).press()
        sheet = leslie.wait_for_window(2, "the short list")
        [row] = [b for b in sheet.all("push button") if any(l.words == BILL for l in b.all("label"))]
        row.press()
        leslie.until(lambda: leslie.shows("Only Robin or a manager can change this repeat.", within=leslie.front)
                     or None, "the repeat's own sheet to say only Robin or a manager can change it")
        self.assertFalse(leslie.shows("Save", within=leslie.front, role="push button"), "Save on Leslie's repeat")
        self.assertFalse(leslie.shows("Stop repeating…", within=leslie.front), "Stop repeating on Leslie's repeat")
        self.assertFalse([e for e in leslie.front.all("text") if e.showing and e.enabled],
                         "a field Leslie can change on the repeat")

        # Scenario REPEAT-11
        # 4. Kim, a manager, opens December's phone bill and changes its
        # amount: Which months? offers This month only and This month and
        # later, and Stop repeating is there.
        kim = launch_fresh(self, clock=december, autosync_seconds=3600)
        kim.sign_in_as("Kim")
        kim.join(kim_link, "Kim")
        kim.sync()
        self.open_budget(kim, utilities)
        self.expect_one_bill(kim, december, "December's bill, for Kim")
        kim.entry(BILL).press()
        sheet = kim.wait_for_window(2, "the bill to open")
        kim.field("Amount", sheet).type("92.00")
        which = kim.picker("Which months?", sheet)
        self.assertEqual(["This month only", "This month and later"], kim.offered(which))
        self.assertTrue(kim.button("Stop repeating…", within=sheet).enabled, "no Stop repeating for Kim")


if __name__ == "__main__":
    unittest.main()
