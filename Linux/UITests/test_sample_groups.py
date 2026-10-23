"""Sample groups (Features/SampleGroups.md) in the real window: what a fresh
install opens with, and which samples come along into an account made on it.

Every scenario but the first makes or signs in to an account on staging, so
those are skipped without the test mailbox's token. Each makes an account of
its own, since what an account starts with is the point."""

import datetime
import unittest

from wellspent_ui import launch_fresh, needs_accounts, unique

SAMPLES = ["HOUSEHOLD", "Groceries", "Eating out", "Utilities", "SIDE BUSINESS", "Materials"]
NO_BUDGETS = ("No budgets yet", "A budget is an amount to spend each month.")


def names(app):
    """The sidebar's lines with the amounts left off: group names and budget names."""
    return [line.rsplit(" $", 1)[0] for line in app.sidebar()]


class SampleGroups(unittest.TestCase):

    def expect_empty(self, app):
        app.until(lambda: app.sidebar() == [], "an empty list")
        for words in NO_BUDGETS:
            app.wait_shows(words, within=app.main)

    def test_a_fresh_install_opens_with_two_samples(self):
        app = launch_fresh(self)
        today = datetime.date.today()

        # Scenario SAMP-01
        # 1. Household with Groceries, Eating out and Utilities, and Side
        # Business with Materials, at their limits.
        self.assertEqual(SAMPLES, names(app))
        for budget, limit in (("Groceries", "$1,000"), ("Eating out", "$300"), ("Utilities", "$450"),
                              ("Materials", "$5,000")):
            app.budget(budget).press()
            app.wait_shows(f"of {limit}", within=app.main)

        # Scenario SAMP-01
        # 2. Six sample entries in their budgets, each 3 to 12 days before
        # today. A budget lists only this month's, so past the 12th all six
        # show, and earlier any from last month don't.
        expected = {"Hilltop Grocery": "Groceries", "Costco": "Groceries", "Sunny's": "Groceries",
                    "Sunrise Cafe": "Eating out", "Riverside Grill": "Eating out", "Regional Power": "Utilities"}
        listed = {}
        for budget in ("Groceries", "Eating out", "Utilities"):
            app.budget(budget).press()
            app.until(lambda: app.reads([budget], within=app.main), f"{budget} to open")
            for date, merchant, *_ in app.entries():
                self.assertEqual(budget, expected.get(merchant), f"{merchant} in {budget}")
                listed[merchant] = datetime.datetime.strptime(f"{date} {today.year}", "%b %d %Y").date()
        for merchant, day in listed.items():
            self.assertTrue(today - datetime.timedelta(days=12) <= day <= today - datetime.timedelta(days=3),
                            f"{merchant} dated {day}")
            self.assertEqual(today.month, day.month, f"{merchant}, from last month, is listed")
        if today.day > 12:
            self.assertEqual(set(expected), set(listed))

    def test_untouched_samples_stay_out_of_a_new_account(self):
        needs_accounts(self)
        app = launch_fresh(self)

        # Scenario SAMP-02
        # 1. Looking changes nothing: open the budgets, hide and show them,
        # then make an account. It starts empty.
        app.budget("Utilities").press()
        arrow = app.near("push button", "Hide budgets", to=app.group("Household"))
        arrow.press()
        app.near("push button", "Show budgets", to=app.group("Household")).press()
        name = unique("Looker")
        app.sign_up(name)
        self.expect_empty(app)

        # Scenario SAMP-02
        # 2. The samples never reached the server: another computer signed in
        # to it shows no group.
        other = launch_fresh(self)
        other.sign_in_as(name)
        self.expect_empty(other)

    def test_a_group_made_before_signing_up_comes_along(self):
        needs_accounts(self)
        app = launch_fresh(self)

        # Scenario SAMP-03
        # 1. Road trip, with Fuel and Gas station, made before the account: it
        # comes along, alone.
        app.new_group("Road trip")
        app.new_budget("Fuel", "200", group="Road trip")
        app.add_entry("Gas station", "45.00")
        name = unique("Driver")
        app.sign_up(name)
        app.until(lambda: names(app) == ["ROAD TRIP", "Fuel"], "only Road trip")
        app.budget("Fuel").press()
        app.until(lambda: [row[1] for row in app.entries()] == ["Gas station"], "Gas station")

        # Scenario SAMP-03
        # 2. It synced: another computer signed in to the account gets it.
        app.sync()
        other = launch_fresh(self)
        other.sign_in_as(name)
        other.until(lambda: names(other) == ["ROAD TRIP", "Fuel"], "Road trip on the other computer")

    def test_a_sample_given_an_entry_comes_along(self):
        needs_accounts(self)
        app = launch_fresh(self)

        # Scenario SAMP-04
        # 1. Farmers market added to Groceries: Household comes along whole,
        # with its sample entries, and Side Business stays out.
        app.budget("Groceries").press()
        app.add_entry("Farmers market", "18.00")
        app.sign_up(unique("Gardener"))
        app.until(lambda: names(app) == ["HOUSEHOLD", "Groceries", "Eating out", "Utilities"], "only Household")
        app.budget("Groceries").press()
        listed = app.until(lambda: {row[1] for row in app.entries()} or None, "Groceries' entries")
        self.assertIn("Farmers market", listed)
        self.assertTrue(listed & {"Hilltop Grocery", "Costco", "Sunny's"}, "the sample entries came along")

    def test_a_renamed_sample_comes_along_under_its_new_name(self):
        needs_accounts(self)
        app = launch_fresh(self)

        # Scenario SAMP-05
        # 1. Side Business renamed Pottery: it comes along as Pottery, with
        # Materials, and Household stays out.
        app.pick("Rename…", app.group_menu("Side Business"))
        sheet = app.wait_for_window(2, "the Rename Group sheet")
        app.field("Name", sheet).type("Pottery")
        app.button("Save", within=sheet).press()
        app.wait_for_window(1, "the sheet to close")
        app.sign_up(unique("Potter"))
        app.until(lambda: names(app) == ["POTTERY", "Materials"], "only Pottery")

    def test_signing_in_elsewhere_leaves_the_samples_here(self):
        needs_accounts(self)
        maker = launch_fresh(self)
        name = unique("Traveller")
        maker.sign_up(name)
        trip = unique("Trip")
        maker.new_group(trip)
        self.addCleanup(maker.remove_group, trip)
        maker.sync()

        # Scenario SAMP-06
        # 1. A fresh install signs in to an account made elsewhere: only that
        # account's group shows, no sample.
        app = launch_fresh(self)
        self.assertEqual(SAMPLES, names(app))
        app.sign_in_as(name)
        app.until(lambda: names(app) == [trip.upper()], "only the account's group")

        # Scenario SAMP-06
        # 2. Signed out, the samples show again, as they were.
        app.sign_out()
        app.until(lambda: names(app) == SAMPLES, "the samples back")

    def test_the_samples_come_only_once(self):
        needs_accounts(self)
        app = launch_fresh(self)

        # Scenario SAMP-07
        # 1. An account made here, then signed out: the list is empty, and
        # stays empty after quitting and opening again.
        app.sign_up(unique("Once"))
        app.sign_out()
        self.expect_empty(app)
        app.restart()
        self.expect_empty(app)

        # Scenario SAMP-07
        # 2. An account Leslie makes on this computer next starts empty too.
        app.sign_up(unique("Second"))
        self.expect_empty(app)


if __name__ == "__main__":
    unittest.main()
