"""Importing a statement (Features/Import.md) in the real window, signed out, in
a group of its own, Kitchen, with Food and Dining: the review, what each line
will do, filing lines, importing again, and files that aren't statements.

The statements are written by each test, dated from today, so "within 4
days" and "last month" hold whatever day the tests run. What a second person
changes (IMPORT-10, 14) is in test_import_shared.py."""

import datetime
import unittest

from wellspent_ui import launch_fresh, short_date

HEADER = "Date,Description,Amount\n"


def day(days_ago):
    return datetime.date.today() - datetime.timedelta(days=days_ago)


def statement(*lines):
    """A bank's CSV: each line (days ago, the bank's words, amount)."""
    return HEADER + "".join(f"{day(ago).isoformat()},{words},{amount}\n" for ago, words, amount in lines)


class Import(unittest.TestCase):

    def setUp(self):
        self.app = launch_fresh(self)
        self.app.new_group("Kitchen")
        self.app.new_budget("Dining", "300", group="Kitchen")
        self.app.new_budget("Food", "500", group="Kitchen")

    def finish(self, review, button="Import"):
        self.app.button(button, within=review).press()
        self.app.wait_for_window(1, "the review to close")

    def merchants(self):
        return [row[1] for row in self.app.entries()]

    def test_the_review_and_filing_new_lines(self):
        app = self.app
        path = app.write_file("statement.csv", statement((1, "TRADER JOES #123", "-54.20"),
                                                         (2, "CORNER BAKERY", "-6.75")))

        # Scenario IMPORT-01
        # 1. The review opens, titled for Kitchen with the file's name, its
        # counts across the top, a row a line, and the note at its foot.
        # Nothing is added yet.
        review = app.open_statement(path)
        texts = app.texts(review)
        self.assertIn("Import a statement into “Kitchen”", texts)
        self.assertIn("statement.csv", texts)
        self.assertIn("Read on this computer. Nothing is sent until you add it.", texts)
        self.assertEqual({"Matched": 0, "To add": 0, "Already imported": 0, "Needs a budget": 2},
                         app.review_counts(review))
        self.assertEqual(2, len(app.review_rows(review)))
        self.assertEqual([], app.entries())

        # Scenario IMPORT-02
        # 2. A line shows its date, a cleaned-up name over the bank's words,
        # the amount, and what will happen to it.
        self.assertIn([short_date(day(1)), "Trader Joes", "TRADER JOES #123", "-$54.20", "Needs a budget"],
                      app.review_rows(review))

        # Scenario IMPORT-05, IMPORT-06
        # 3. A new merchant needs a budget from Kitchen's own. Filed in Food,
        # it's added. One left at Choose isn't.
        bakery = app.near("combo box", None, to=app.find("label", "CORNER BAKERY", within=review))
        self.assertEqual("Choose", bakery.words)
        app.file_line(review, "TRADER JOES #123", "Food")
        self.finish(review)
        app.until(lambda: self.merchants() == ["Trader Joes"], "only Trader Joes to be added")

        # Scenario IMPORT-02
        # 4. In Food it shows the cleaned-up name, the bank's words under it,
        # Statement, and the amount spent.
        self.assertEqual([short_date(day(1)), "Trader Joes", "TRADER JOES #123", "Statement", "$54.20"],
                         app.entries()[0])

        # Scenario IMPORT-12
        # 5. Cancel adds nothing, and importing again offers the same lines.
        review = app.open_statement(path)
        before = app.review_rows(review)
        self.finish(review, "Cancel")
        self.assertEqual(["Trader Joes"], self.merchants())
        review = app.open_statement(path)
        self.assertEqual(before, app.review_rows(review))
        self.finish(review, "Cancel")

    def test_matching_and_merchants_filed_before(self):
        app = self.app
        app.add_entry("Costco", "286.31")
        app.add_entry("Hilltop Grocery", "42.00")

        # Scenario IMPORT-03, IMPORT-04
        # 1. Costco's line matches the one typed by hand. Hilltop's new
        # amount goes where Hilltop went before, with no list.
        path = app.write_file("statement.csv", statement((1, "COSTCO WHSE #0472", "-286.31"),
                                                         (1, "HILLTOP GROCERY #17", "-58.10")))
        review = app.open_statement(path)
        rows = {row[2]: row for row in app.review_rows(review)}
        self.assertEqual("Matched to entry", rows["COSTCO WHSE #0472"][-1])
        self.assertEqual(["Hilltop Grocery", "HILLTOP GROCERY #17", "-$58.10", "Will be added"],
                         rows["HILLTOP GROCERY #17"][1:])
        self.assertEqual(1, app.review_counts(review)["Matched"])
        self.assertEqual(1, app.review_counts(review)["To add"])
        self.assertEqual([], [e for e in review.all("combo box") if e.showing], "a budget list")

        # Scenario IMPORT-03, IMPORT-04
        # 2. Imported: one Costco, the typed one, and a second Hilltop Grocery.
        self.finish(review)
        app.until(lambda: sorted(self.merchants()) == ["Costco", "Hilltop Grocery", "Hilltop Grocery"],
                  "a second Hilltop Grocery and still one Costco")
        costco = next(row for row in app.entries() if row[1] == "Costco")
        self.assertEqual("Manual", costco[-2])

    def test_importing_again(self):
        app = self.app
        path = app.write_file("statement.csv", statement((1, "TRADER JOES #123", "-54.20"),
                                                         (2, "CORNER BAKERY", "-6.75")))
        review = app.open_statement(path)
        app.file_line(review, "TRADER JOES #123", "Food")
        app.file_line(review, "CORNER BAKERY", "Food")
        self.finish(review)
        app.until(lambda: len(self.merchants()) == 2, "both lines")

        # Scenario IMPORT-07
        # 1. The same file again: every line already imported, and nothing
        # added twice.
        review = app.open_statement(path)
        self.assertEqual(["Already imported"] * 2, [row[-1] for row in app.review_rows(review)])
        self.assertEqual(2, app.review_counts(review)["Already imported"])
        self.finish(review)
        self.assertEqual(2, len(self.merchants()))

        # Scenario IMPORT-08
        # 2. Corner Bakery deleted: importing again still says both came in
        # before, finishes with no error, and it stays deleted.
        app.delete_entry("Corner Bakery")
        review = app.open_statement(path)
        self.assertEqual(["Already imported"] * 2, [row[-1] for row in app.review_rows(review)])
        self.finish(review)
        self.assertEqual(1, len(app.windows()), "an error")
        self.assertEqual(["Trader Joes"], self.merchants())

        # Scenario IMPORT-09
        # 3. Food deleted: in Dining, both lines need a budget again, from
        # the budgets left. Filed in Dining, both show there, and then count
        # as imported.
        app.budget("Food").press()
        app.button("Delete…", within=app.main).press()
        app.answer("Delete")
        app.budget("Dining").press()
        review = app.open_statement(path)
        self.assertEqual(["Needs a budget"] * 2, [row[-1] for row in app.review_rows(review)])
        app.file_line(review, "TRADER JOES #123", "Dining")
        app.file_line(review, "CORNER BAKERY", "Dining")
        self.finish(review)
        self.assertEqual(1, len(app.windows()), "an error")
        app.until(lambda: sorted(self.merchants()) == ["Corner Bakery", "Trader Joes"], "both in Dining")
        review = app.open_statement(path)
        self.assertEqual(["Already imported"] * 2, [row[-1] for row in app.review_rows(review)])
        self.finish(review, "Cancel")

    def test_lines_from_before_this_period(self):
        app = self.app
        last_month = datetime.date.today().day + 5

        # Scenario IMPORT-11
        # 1. Lines from last month go in, but Food's list and total leave
        # them out. Importing again shows them as already imported.
        path = app.write_file("september.csv", statement((last_month, "MARKET", "-9.50")))
        review = app.open_statement(path)
        app.file_line(review, "MARKET", "Food")
        self.finish(review)
        app.wait_shows("Nothing spent in this budget this period.", within=app.main)
        self.assertEqual("Food $500.00", app.budget("Food").words)
        review = app.open_statement(path)
        self.assertEqual(["Already imported"], [row[-1] for row in app.review_rows(review)])
        self.finish(review, "Cancel")

    def test_a_file_that_is_not_a_statement(self):
        app = self.app

        # Scenario IMPORT-13
        # 1. Words with no commas, a header alone, and no amount column: each
        # is explained in words, and no review opens.
        for name, text, said in (
                ("notes.txt", "Things to buy on the way home\n",
                 "“notes.txt” is not a statement this app can read. Download a CSV, OFX or QFX file from your "
                 "bank and import that."),
                ("header.csv", HEADER, "“header.csv” has no entries to import."),
                ("columns.csv", "Date,Description\n2026-10-01,MARKET\n",
                 "Line 1 of “columns.csv” could not be read: no amount column. Download a CSV, OFX or QFX file "
                 "from your bank and import that.")):
            app.button("Import statement", within=app.main).press()
            app.pick_file(app.write_file(name, text))
            self.assertIn(said, app.question())
            app.answer("OK")
            self.assertEqual(1, len(app.windows()), "a review opened")

    def test_a_money_in_line_becomes_income(self):
        app = self.app
        app.new_budget("Bookings", "2000", group="Kitchen")
        path = app.write_file("payout.csv", statement((1, "AIRBNB PAYOUT", "1310.00"),
                                                      (1, "CLEANING CO", "-120.00")))
        review = app.open_statement(path)

        # Scenario INC-02
        # 1. The payout is offered as money in, Income first, with Refund to
        # choose; the charge has no such choice.
        payout = app.kind_list(review, "AIRBNB PAYOUT")
        self.assertIsNotNone(payout, "the payout has no kind list")
        self.assertEqual("Income", payout.words)
        self.assertIsNone(app.kind_list(review, "CLEANING CO"), "money out offers no kind")
        app.choose("Refund", payout)
        app.choose("Income", payout)

        # 2. Taken as Income on Bookings, it lands with its plus sign.
        app.file_line(review, "AIRBNB PAYOUT", "Bookings")
        app.file_line(review, "CLEANING CO", "Bookings")
        self.finish(review)
        app.budget("Bookings").press()
        app.until(lambda: len(app.entries()) == 2, "both lines to list")
        amounts = {row[1]: row[-1] for row in app.entries()}
        self.assertEqual("+$1310.00", amounts["Airbnb Payout"])
        self.assertEqual("$120.00", amounts["Cleaning"])

        # 3. The next payout from the same payer is offered the same way.
        again = app.write_file("payout2.csv", statement((1, "AIRBNB PAYOUT", "980.00")))
        review = app.open_statement(again)
        self.assertEqual("Income", app.kind_list(review, "AIRBNB PAYOUT").words)
        self.finish(review, "Cancel")

if __name__ == "__main__":
    unittest.main()
