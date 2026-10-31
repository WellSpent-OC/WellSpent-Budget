"""Importing a statement in a shared group (Features/Import.md), two people
on the disposable server: one person's import counts as imported for the
others (IMPORT-10), and at View there is nothing to import or add (IMPORT-14).
And a change that did not go through is noted (Features/EditEntry.md,
EDIT-14)."""

import unittest

from wellspent_ui import launch_fresh, needs_accounts, unique

NOTICE_ROW = "Your change didn't go through."
NOTICE_SHEET = "Your last change to this didn't go through. This is the version everyone sees."


def statement(*lines):
    return "Date,Description,Amount\n" + "".join(f"2026-10-{day:02d},{words},{amount}\n" for day, words, amount in lines)


class ImportShared(unittest.TestCase):

    def setUp(self):
        needs_accounts(self)
        # Robin's copy syncs only when he presses Sync, so a change of his can
        # be saved before a change of Leslie's is taken in.
        self.robin = launch_fresh(self, autosync_seconds=3600)
        self.leslie = launch_fresh(self)

    def robins_group(self, *entries):
        robin = self.robin
        robin.sign_in_as("Robin")
        name = unique("Shop")
        robin.new_group(name)
        self.addCleanup(robin.remove_group, name)
        food = f"{name} food"
        robin.new_budget(food, "800", group=name)
        for merchant, amount in entries:
            robin.add_entry(merchant, amount)
        robin.sync()
        return name, food

    def joined(self, name, level="Add"):
        """Leslie in Robin's group at `level`, with the budget open."""
        link = self.robin.legacy_invite(name, "Robin", level)
        self.leslie.sign_in_as("Leslie")
        self.leslie.join(link, "Leslie")
        self.addCleanup(self.leslie.remove_group, name)

    def open_budget(self, app, budget):
        app.budget(budget).press()
        app.until(lambda: app.reads([budget], within=app.main), f"{budget} to open")

    def change_entry(self, app, merchant, field, words):
        app.entry(merchant).press()
        editor = app.wait_for_window(2, f"{merchant} to open")
        app.field(field, editor).type(words)
        app.button("Save", within=editor).press()
        app.wait_for_window(1, "the editor to close")

    def test_one_persons_import_counts_for_the_others(self):
        name, food = self.robins_group()
        self.joined(name)
        leslie, robin = self.leslie, self.robin

        # Scenario IMPORT-10
        # 1. Leslie imports a statement into the budget. Once Robin's app
        # syncs, its lines are in his list, each added by Leslie, from a
        # statement.
        self.open_budget(leslie, food)
        path = leslie.write_file("statement.csv", statement((28, "TRADER JOES #123", "-54.20"),
                                                             (28, "CORNER BAKERY", "-12.00")))
        review = leslie.open_statement(path)
        leslie.file_line(review, "TRADER JOES #123", food)
        leslie.file_line(review, "CORNER BAKERY", food)
        leslie.button("Import", within=review).press()
        leslie.wait_for_window(1, "the review to close")
        leslie.sync()
        robin.sync()
        self.open_budget(robin, food)
        robin.until(lambda: {row[1] for row in robin.entries()} >= {"Trader Joes", "Corner Bakery"},
                    "Leslie's lines to arrive")
        for row in robin.entries():
            self.assertIn("Leslie", row, f"{row[1]} is not by Leslie")
            self.assertIn("Statement", row, f"{row[1]} is not from a statement")

        # Scenario IMPORT-10
        # 2. Robin imports the same statement: every line says Already
        # imported. Cancel adds nothing.
        same = robin.write_file("statement.csv", statement((28, "TRADER JOES #123", "-54.20"),
                                                            (28, "CORNER BAKERY", "-12.00")))
        review = robin.open_statement(same)
        self.assertEqual(["Already imported", "Already imported"], [row[-1] for row in robin.review_rows(review)])
        robin.button("Cancel", within=review).press()
        robin.wait_for_window(1, "the review to close")
        self.assertEqual(2, len(robin.entries()))

    def test_at_view_there_is_nothing_to_import_or_add(self):
        name, food = self.robins_group(("Hilltop Grocery", "42.00"))
        self.joined(name, level="View")
        leslie = self.leslie

        # Scenario IMPORT-14
        # 1. At View, the open budget has no Import statement and no Add.
        self.open_budget(leslie, food)
        leslie.until(lambda: any(row[1] == "Hilltop Grocery" for row in leslie.entries()), "Robin's entry to show")
        self.assertFalse(leslie.shows("Import statement", within=leslie.main, role="push button"), "Import statement, at View")
        self.assertFalse(leslie.shows("Add", within=leslie.main, role="push button"), "Add, at View")

    def test_a_change_that_did_not_go_through_is_noted(self):
        name, food = self.robins_group(("Hilltop Grocery", "42.00"))
        self.joined(name, level="Manage")
        leslie, robin = self.leslie, self.robin
        self.open_budget(leslie, food)
        leslie.until(lambda: any(row[1] == "Hilltop Grocery" for row in leslie.entries()), "Robin's entry to show")

        # Scenario EDIT-14
        # 1. Robin opens Hilltop Grocery and types a new amount. Meanwhile
        # Leslie changes its note, then its amount, and her app sends both.
        # He saves before his app has taken either in; his copy syncs only
        # when he presses Sync. Once it syncs, the row shows her version with
        # a quiet line under the merchant saying his change didn't go through.
        self.open_budget(robin, food)
        robin.entry("Hilltop Grocery").press()
        editor = robin.wait_for_window(2, "Hilltop Grocery to open")
        robin.field("Amount", editor).type("150.00")
        self.change_entry(leslie, "Hilltop Grocery", "Note", "two loaves")
        self.change_entry(leslie, "Hilltop Grocery", "Amount", "124.08")
        leslie.sync()
        robin.button("Save", within=editor).press()
        robin.wait_for_window(1, "the editor to close")
        robin.sync()
        robin.until(lambda: NOTICE_ROW in [l.words for l in robin.entry("Hilltop Grocery").all("label")],
                    "the line saying his change didn't go through")
        # A sync can redraw the list mid-read, so the read is retried.
        row = robin.until(lambda: next((r for r in robin.entries() if r[1] == "Hilltop Grocery"), None),
                          "Hilltop Grocery's row")
        self.assertIn("two loaves", row)
        self.assertIn("$124.08", row)
        self.assertNotIn("$150.00", row)

        # Scenario EDIT-14
        # 2. Opened, the sheet says his last change didn't go through and
        # this is the version everyone sees. The row's line is gone.
        robin.entry("Hilltop Grocery").press()
        editor = robin.wait_for_window(2, "Hilltop Grocery to open")
        robin.wait_shows(NOTICE_SHEET, within=editor)
        self.assertEqual("124.08", robin.field("Amount", editor).text)
        robin.button("Cancel", within=editor).press()
        robin.wait_for_window(1, "the editor to close")
        robin.until(lambda: NOTICE_ROW not in [l.words for l in robin.entry("Hilltop Grocery").all("label")],
                    "the row's line to go")


if __name__ == "__main__":
    unittest.main()
