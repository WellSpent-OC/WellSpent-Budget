"""A statement line and a repeat's bill (Features/RepeatExpenses.md), in the
real window, signed out: the line takes the bill's place, or keeps both. Bills,
in a group of its own, has an $85.00 phone bill that repeats, made today. The
statement's line is dated today too, so it's within 4 days whatever day the
tests run. The rules themselves are the shared code's StatementMatchTests."""

import datetime
import unittest

from wellspent_ui import launch_fresh

BILL = "Phone bill"
LINE = "PHONE CO"


class ImportRepeats(unittest.TestCase):

    def setUp(self):
        app = self.app = launch_fresh(self)
        app.new_group("Home")
        app.new_budget("Bills", "600", group="Home")
        app.button("Add", within=app.main).press()
        sheet = app.wait_for_window(2, "the New transaction sheet")
        app.field("Merchant", sheet).type(BILL)
        app.field("Amount", sheet).type("85.00")
        app.find("check box", "Repeats every month", within=sheet).press()
        app.button("Add", within=sheet).press()
        app.wait_for_window(1, "the New transaction sheet to close")
        app.entry(BILL)
        path = app.write_file("statement.csv", "Date,Description,Amount\n"
                              f"{datetime.date.today().isoformat()},{LINE},-85.40\n")
        self.review = app.open_statement(path)
        self.replaces = f"Replaces {datetime.date.today():%B}'s {BILL}, $85.00"

    def finish(self):
        self.app.button("Import", within=self.review).press()
        self.app.wait_for_window(1, "the review to close")

    def amounts(self):
        return sorted(row[-1] for row in self.app.entries())

    def test_a_statement_line_replaces_that_months_bill(self):
        app, review = self.app, self.review

        # Scenario REPEAT-14
        # 1. The review row says what it replaces, under Matched.
        app.wait_shows(self.replaces, within=review)
        self.assertEqual(1, app.review_counts(review)["Matched"])
        app.picture("import-replaces")

        # Scenario REPEAT-14
        # 2. Imported, the bank's line takes the bill's place: one row, at the
        # bank's amount, and Spent counts it once.
        self.finish()
        app.until(lambda: self.amounts() == ["$85.40"] or None, f"one row at $85.40, not {self.amounts()}")
        self.assertNotIn(BILL, [row[1] for row in app.entries()])
        self.assertTrue(app.reads(["Spent", "$85.40"], within=app.main), "Spent isn't $85.40")

    def test_keep_both(self):
        app, review = self.app, self.review
        keep = app.find("check box", "Keep both", within=review)
        self.assertFalse(keep.checked)

        # Scenario REPEAT-15
        # 1. Keep both: the line will be added instead, and counts under To
        # add. Unticked, it replaces the bill again.
        keep.press()
        app.until(lambda: app.review_counts(review).get("To add") == 1 or None, "the line to count under To add")
        app.wait_shows("Will be added", within=review)
        keep.press()
        app.wait_shows(self.replaces, within=review)
        keep.press()
        app.wait_shows("Will be added", within=review)
        app.picture("import-keep-both")

        # Scenario REPEAT-15
        # 2. Imported, both stay, and neither is changed.
        self.finish()
        app.until(lambda: self.amounts() == ["$85.00", "$85.40"] or None, f"both rows, not {self.amounts()}")
        self.assertIn(BILL, [row[1] for row in app.entries()])


if __name__ == "__main__":
    unittest.main()
