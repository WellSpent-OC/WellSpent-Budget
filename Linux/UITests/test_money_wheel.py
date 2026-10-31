"""The money wheel (Features/MoneyWheel.md) in the real window, signed out, in
a group of its own: each budget's row and its fill, a budget's wheel, its tick
and figures, the pace words, a budget over its limit, and the group's MONEY.

The app is launched with its wheels on the 18th of this month, or the 26th for
the month's last week, whatever day the tests run, as the Mac's tests do. The
words each step expects are worked out for that day (`Wheel`)."""

import datetime
import unittest

from wellspent_ui import Wheel, launch_fresh

# Mid-month, before the last week of any month.
MID_MONTH = 18
# In the last week of every month, February's too.
LAST_WEEK = 26


def cents(dollars):
    return round(dollars * 100)


class MoneyWheel(unittest.TestCase):

    def expect_wheel(self, app, wheel):
        """The open page's wheel says what `wheel` says: its middle, each
        figure, and its pace words or none."""
        app.wait_reads(wheel.middle, within=app.main)
        for label, amount in wheel.figures:
            self.assertTrue(app.reads([label, amount], within=app.main), f"{label} {amount}")
        if wheel.expected_left is None:
            self.assertFalse(app.shows("Expected left by today", within=app.main))
        if wheel.pace:
            app.wait_shows(wheel.pace, within=app.main)
        else:
            self.assertFalse(any(t.startswith(("At this pace", "$")) and t.endswith(("early.", "next month?"))
                                 for t in app.texts(app.main)), "pace words where none belong")

    def expect_row(self, app, wheel):
        """The budget's row in the sidebar says what's left or how far over,
        and tells a screen reader how much is used."""
        words, value = wheel.row
        row = app.until(lambda: app.budget(wheel.name) if app.budget(wheel.name).words == words else None,
                        f"the row to say {words!r}")
        self.assertEqual(row.value, value)

    def test_rows_wheels_and_a_groups_money(self):
        app = launch_fresh(self, day=MID_MONTH)

        # 1. A group of its own, with Food, $1,000.00 a month. Saving opens it.
        app.new_group("Wheel")
        app.new_budget("Food", "1000", group="Wheel")

        # Scenario WHEEL-05, WHEEL-06
        # 2. Food's page: the day line, and in place of the bar a wheel, full
        # before anything is spent.
        app.wait_shows(Wheel("Food", 100000, 0, MID_MONTH).day_line, within=app.main)
        self.expect_wheel(app, Wheel("Food", 100000, 0, MID_MONTH))

        # Scenario WHEEL-06
        # 3. $250.00 spent: the wheel's middle says $750 at once.
        app.add_entry("Market", "250.00")
        self.expect_wheel(app, Wheel("Food", 100000, cents(250), MID_MONTH))

        # Scenario WHEEL-05, WHEEL-07
        # 4. $555.36 spent in all: Left $445 of $1,000, Spent, Left, and
        # Expected left by today for the 18th. More is left than expected, so
        # nothing is said about the pace.
        app.add_entry("Bakery", "305.36")
        food = Wheel("Food", 100000, cents(555.36), MID_MONTH)
        self.expect_wheel(app, food)

        # Scenario WHEEL-01
        # 5. Food's row says what's left, and how much is used.
        self.expect_row(app, food)

        # Scenario WHEEL-10, WHEEL-02
        # 6. Treats, $100.00, with $115.00 spent: Over $15 of $100, Spent and
        # Over beside it, nothing expected and no pace. Its row says $15.00
        # over, and Over budget to a screen reader.
        app.new_budget("Treats", "100", group="Wheel")
        app.add_entry("Cake", "115.00")
        treats = Wheel("Treats", 10000, cents(115), MID_MONTH)
        self.expect_wheel(app, treats)
        self.expect_row(app, treats)

        # Scenario WHEEL-10
        # 7. $100.20 spent: Over $1, never $0.
        app.new_budget("Tea", "100", group="Wheel")
        app.add_entry("Teashop", "100.20")
        self.expect_wheel(app, Wheel("Tea", 10000, cents(100.20), MID_MONTH))

        # Scenario WHEEL-03
        # 8. The open budget's row is the one picked. Picking Food moves it.
        self.assertTrue(app.budget("Tea").selected)
        app.budget("Food").press()
        app.until(lambda: app.budget("Food").selected, "Food to be picked")
        self.assertFalse(app.budget("Tea").selected)
        self.assertFalse(app.budget("Treats").selected)

        # Scenario WHEEL-11, WHEEL-03
        # 9. Wheel's page opens with MONEY: every budget added up for the
        # month, the figures, and the line under them. No budget is picked
        # while it shows.
        app.group("Wheel").press()
        app.wait_shows("MONEY", within=app.main)
        group = Wheel("Wheel", 100000 + 10000 + 10000, cents(555.36 + 115 + 100.20), MID_MONTH, group=True)
        self.expect_wheel(app, group)
        app.wait_shows(group.note, within=app.main)
        for name in ("Food", "Treats", "Tea"):
            self.assertFalse(app.budget(name).selected, f"{name} picked while the group's page shows")

        # Scenario WHEEL-11
        # 10. A budget hidden in the sidebar still counts.
        app.near("push button", "Hide budgets", to=app.group("Wheel")).press()
        app.until(lambda: not app.has_budget("Food"), "Wheel's budgets to hide")
        self.expect_wheel(app, group)
        app.near("push button", "Show budgets", to=app.group("Wheel")).press()

        # Scenario WHEEL-12
        # 11. Over the month's budgets in all: Over this month, how far, and
        # no tick's figure.
        app.budget("Food").press()
        app.add_entry("Feast", "500.00")
        app.group("Wheel").press()
        over = Wheel("Wheel", 120000, cents(555.36 + 500 + 115 + 100.20), MID_MONTH, group=True)
        self.expect_wheel(app, over)

        # Scenario WHEEL-11
        # 12. A group with no budgets shows no MONEY.
        app.new_group("Empty")
        app.group("Empty").press()
        app.wait_shows("Empty", within=app.main, role="label")
        self.assertFalse(app.shows("MONEY", within=app.main))

    def test_money_in_on_a_groups_wheel(self):
        """The wheel's step 2 on a group's page: money in refills the group's
        wheel toward full, its middle says money in against money out, and
        borrowed money and savings draws are named without refilling it. One
        group, Rentals, with one budget, Rent, $4,080.00 a month, on the 18th:
        the Mac's test, with the same numbers."""
        app = launch_fresh(self, day=MID_MONTH)
        app.new_group("Rentals")
        app.new_budget("Rent", "4080", group="Rentals")
        limit = cents(4080)

        def month(spent, money_in=0, borrowed=0, from_savings=0):
            return Wheel("Rentals", limit, spent, MID_MONTH, group=True, money_in_cents=money_in,
                         borrowed_cents=borrowed, from_savings_cents=from_savings)

        def expect(wheel):
            app.group("Rentals").press()
            app.wait_shows("MONEY", within=app.main)
            self.expect_wheel(app, wheel)
            app.wait_shows(wheel.note, within=app.main)

        def add(merchant, amount, money_in=False):
            app.budget("Rent").press()
            app.button("Add", within=app.main).press()
            sheet = app.wait_for_window(2, "the New transaction sheet")
            app.field("Merchant", sheet).type(merchant)
            app.field("Amount", sheet).type(amount)
            if money_in:
                app.find("check box", "Money in", within=sheet).press()
            app.button("Add", within=sheet).press()
            app.wait_for_window(1, "the New transaction sheet to close")

        # Scenario WHEEL-16
        # 1. $2,777.96 spent and no money in: the wheel is step 1's, with no
        # In figure, and the note ends "added up."
        add("Landlord", "2777.96")
        plain = month(cents(2777.96))
        expect(plain)
        self.assertFalse(app.shows("In", within=app.main, role="label"), "an In figure with no money in")

        # Scenario WHEEL-14, WHEEL-15, WHEEL-20
        # 2. $1,230.00 of income: the wheel refills, the middle says money in,
        # money out and the cash flow, In leads the figures, and Expected left
        # by today is what it was, since money in never moves the tick.
        add("Paycheck", "1230", money_in=True)
        refilled = month(cents(2777.96), cents(1230))
        self.assertEqual(plain.expected_left, refilled.expected_left)
        expect(refilled)

        # Scenario WHEEL-17
        # 3. Spending to $4,500.00 passes the budgets, and the money in covers
        # it: the wheel stays green and one line says so.
        add("Repairs", "1722.04")
        covered = month(cents(4500), cents(1230))
        self.assertIsNotNone(covered.covered_line, "the test's own numbers are covered")
        expect(covered)
        app.wait_shows(covered.covered_line, within=app.main)

        # Scenario WHEEL-18
        # 4. $1,030.00 more puts the spending past the budgets and the money
        # in together: the wheel turns orange and says how far over.
        add("Plumber", "1030")
        over = month(cents(5530), cents(1230))
        self.assertTrue(over.is_over, "the test's own numbers are over")
        expect(over)
        self.assertIsNone(over.covered_line)
        self.assertFalse(app.shows("Over the month's budgets", within=app.main))

        # Scenario WHEEL-14, WHEEL-15
        # 5. $5,000.00 more income: the wheel is full and no fuller, and the
        # cash flow is ahead.
        add("Bonus", "5000", money_in=True)
        full = month(cents(5530), cents(6230))
        self.assertEqual(full.limit, full.left_shown, "the test's own numbers fill the wheel")
        expect(full)

        # Scenario WHEEL-19
        # 6. A loan draw and a savings draw from a statement are named under
        # the figures and refill nothing.
        app.budget("Rent").press()
        on = datetime.date.today().replace(day=MID_MONTH).isoformat()
        path = app.write_file("draws.csv", "Date,Description,Amount\n"
                              f"{on},CREDIT UNION LOAN,500.00\n{on},SAVINGS XFER,300.00\n")
        review = app.open_statement(path)
        app.choose("Borrowed", app.kind_list(review, "CREDIT UNION LOAN"))
        app.choose("From savings", app.kind_list(review, "SAVINGS XFER"))
        app.file_line(review, "CREDIT UNION LOAN", "Rent")
        app.file_line(review, "SAVINGS XFER", "Rent")
        app.button("Import", within=review).press()
        app.wait_for_window(1, "the review to close")
        drawn = month(cents(5530), cents(6230), borrowed=cents(500), from_savings=cents(300))
        self.assertEqual(full.middle, drawn.middle)
        self.assertEqual(full.figures, drawn.figures)
        expect(drawn)
        for line in drawn.other_money_lines:
            app.wait_shows(line, within=app.main)

    def test_spending_faster_than_an_even_pace(self):
        app = launch_fresh(self, day=MID_MONTH)
        app.new_group("Pace")

        # Scenario WHEEL-08
        # 1. Gas, $180.00, with $122.00 spent by the 18th: faster than an even
        # pace, so the words say when its money runs out.
        app.new_budget("Gas", "180", group="Pace")
        app.add_entry("Station", "122.00")
        gas = Wheel("Gas", 18000, cents(122), MID_MONTH)
        self.assertIsNotNone(gas.pace, "on the 18th, $122.00 of $180.00 is faster than an even pace")
        self.expect_wheel(app, gas)

        # Scenario WHEEL-08
        # 2. Edit Budget… beside the words opens Gas's Edit Budget sheet, and
        # Cancel closes it.
        app.button("Edit Budget…", within=app.main).press()
        sheet = app.wait_for_window(2, "the Edit Budget sheet")
        self.assertEqual(app.field("Name", sheet).text, "Gas")
        app.button("Cancel", within=sheet).press()
        app.wait_for_window(1, "the sheet to close")

        # Scenario WHEEL-08
        # 3. Rent, paid in full, has nothing left to run out: no pace words.
        app.new_budget("Rent", "1850", group="Pace")
        app.add_entry("Landlord", "1850.00")
        self.expect_wheel(app, Wheel("Rent", 185000, 185000, MID_MONTH))

    def test_the_last_week_offers_to_lower_a_budget(self):
        app = launch_fresh(self, day=LAST_WEEK)
        app.new_group("Books")

        # Scenario WHEEL-09
        # 1. On the 26th, Books, $1,000.00, with $500.00 spent: more is left
        # than expected, so the words offer to lower it.
        app.new_budget("Novels", "1000", group="Books")
        app.add_entry("Bookshop", "500.00")
        novels = Wheel("Novels", 100000, cents(500), LAST_WEEK)
        self.assertIsNotNone(novels.pace, "the 26th is in the month's last week")
        self.expect_wheel(app, novels)

        # Scenario WHEEL-09
        # 2. Edit Budget… beside the words opens the sheet.
        app.button("Edit Budget…", within=app.main).press()
        sheet = app.wait_for_window(2, "the Edit Budget sheet")
        app.button("Cancel", within=sheet).press()
        app.wait_for_window(1, "the sheet to close")

        # Scenario WHEEL-09
        # 3. On the 24th, before the month's last week, nothing is said.
        app.quit()
        app.launch(day=24)
        app.budget("Novels").press()
        self.expect_wheel(app, Wheel("Novels", 100000, cents(500), 24))


if __name__ == "__main__":
    unittest.main()
