"""Adding a transaction (Features/Entries.md) in the real window, signed out, in
a group of its own: the sheet, what Add puts in the open budget, amounts
however they're typed, notes, Cancel, and amounts read the way the region
writes numbers.

A test that needs two people sharing a group (ENTRY-08 to 10) is in
test_entries_shared.py."""

import datetime
import unittest

from wellspent_ui import Wheel, launch_fresh, short_date

UNCLEAR_US = "That amount can't be read clearly. Type it like 12.50."
UNCLEAR_COMMA = "That amount can't be read clearly. Type it like 12,50."


class Entries(unittest.TestCase):

    def open_sheet(self, app):
        app.button("Add", within=app.main).press()
        return app.wait_for_window(2, "the New transaction sheet")

    def test_adding_transactions(self):
        app = launch_fresh(self)
        today = datetime.date.today()
        app.new_group("Shop")
        app.new_budget("Food", "500", group="Shop")

        # Scenario ENTRY-02
        # 1. Add opens "New transaction", asking for Merchant, Amount, Date and
        # Note, with Cancel and Add, and no budget to choose. Date starts in
        # this month.
        sheet = self.open_sheet(app)
        texts = app.texts(sheet)
        for words in ("New transaction", "Merchant", "Amount", "Date", "Note", f"{today:%B}", str(today.year)):
            self.assertIn(words, texts)
        self.assertEqual([], [e for e in sheet.all("combo box") if e.showing], "a budget to choose")
        add = app.button("Add", within=sheet)
        app.button("Cancel", within=sheet)

        # Scenario ENTRY-02
        # 2. Add stays dimmed while Merchant is empty or only spaces, or Amount
        # is empty or not a number.
        merchant, amount = app.field("Merchant", sheet), app.field("Amount", sheet)
        self.assertFalse(add.enabled, "nothing typed")
        amount.type("12.00")
        self.assertFalse(add.enabled, "no merchant")
        merchant.type("   ")
        self.assertFalse(add.enabled, "a merchant of spaces")
        merchant.type("Hilltop")
        amount.type("twelve")
        self.assertFalse(add.enabled, "an amount in words")
        amount.type("")
        self.assertFalse(add.enabled, "no amount")
        amount.type("42.00")
        self.assertTrue(add.enabled)

        # Scenario ENTRY-07
        # 3. Cancel closes the sheet and adds nothing.
        app.button("Cancel", within=sheet).press()
        app.wait_for_window(1, "the sheet to close")
        app.wait_shows("Nothing spent in this budget this period.", within=app.main)
        self.assertEqual([], app.entries())

        # Scenario ENTRY-01
        # 4. Hilltop Grocery, 142.08: the sheet closes, and Food lists it with
        # today's date, Manual and $142.08. Food's figures and its row count
        # it.
        app.add_entry("Hilltop Grocery", "142.08")
        app.until(lambda: app.entries(), "the transaction to show")
        self.assertEqual([[short_date(today), "Hilltop Grocery", "Manual", "$142.08"]], app.entries())
        food = Wheel("Food", 50000, 14208)
        for label, figure in food.figures[:2]:
            self.assertTrue(app.reads([label, figure], within=app.main), f"{label} {figure}")
        app.wait_shows(f"1 transaction since {short_date(today.replace(day=1))}", within=app.main)
        self.assertEqual("Food $357.92", app.budget("Food").words)

        # Scenario ENTRY-04
        # 5. A note shows under the merchant.
        app.add_entry("Corner Bakery", "12.00", note="birthday cake")
        bakery = app.until(lambda: next((e for e in app.entries() if e[1] == "Corner Bakery"), None),
                           "Corner Bakery to show")
        self.assertEqual("birthday cake", bakery[2])

    def test_a_date_before_this_period(self):
        app = launch_fresh(self)
        today = datetime.date.today()
        last_month = today.replace(day=1) - datetime.timedelta(days=1)
        app.new_group("Shop")
        app.new_budget("Food", "500", group="Shop")

        # Scenario ENTRY-06
        # 1. Hilltop, 42.00, dated last month with the calendar's Previous
        # month: Food doesn't list it, and still says $0.00 and no
        # transactions since the 1st.
        sheet = self.open_sheet(app)
        app.field("Merchant", sheet).type("Hilltop")
        app.field("Amount", sheet).type("42.00")
        app.button("Previous month", within=sheet).press()
        app.wait_shows(f"{last_month:%B}", within=sheet)
        app.button("Add", within=sheet).press()
        app.wait_for_window(1, "the sheet to close")
        app.wait_shows("Nothing spent in this budget this period.", within=app.main)
        self.assertEqual([], app.entries())
        self.assertTrue(app.reads(["Spent", "$0.00"], within=app.main))
        app.wait_shows(f"0 transactions since {short_date(today.replace(day=1))}", within=app.main)

        # Scenario ENTRY-06
        # 2. It's kept all the same: deleting Food counts it.
        app.button("Delete…", within=app.main).press()
        self.assertEqual("Delete “Food”? Its 1 transaction will be deleted too. This cannot be undone.",
                         app.question())
        app.answer("Cancel")

    def test_every_amount_is_money_spent(self):
        app = launch_fresh(self)
        app.new_group("Shop")
        app.new_budget("Spending", "1000", group="Shop")

        # Scenario ENTRY-03
        # 1. 42.50, -42.50, (42.50) and $42.50 each show as $42.50, and each
        # adds $42.50 to what is spent.
        for typed in ("42.50", "-42.50", "(42.50)", "$42.50"):
            app.add_entry(f"Typed {typed}", typed)
        app.until(lambda: len(app.entries()) == 4, "four transactions")
        self.assertEqual(["$42.50"] * 4, [row[-1] for row in app.entries()])
        self.assertTrue(app.reads(["Spent", "$170.00"], within=app.main))

        # Scenario ENTRY-03
        # 2. $1,234.56 shows as $1234.56.
        app.add_entry("Big shop", "$1,234.56")
        big = app.until(lambda: next((e for e in app.entries() if e[1] == "Big shop"), None), "Big shop")
        self.assertEqual("$1234.56", big[-1])

    def test_an_unclear_amount_is_refused(self):
        app = launch_fresh(self)

        # Scenario ENTRY-13
        # 1. In the United States, "12,50" can't be read clearly: Add stays
        # dimmed and the line under the amount says how to type it. "12.50"
        # takes the line away and lights Add.
        sheet = self.open_sheet(app)
        app.field("Merchant", sheet).type("Hilltop Grocery")
        app.field("Amount", sheet).type("12,50")
        app.wait_shows(UNCLEAR_US, within=sheet)
        self.assertFalse(app.button("Add", within=sheet).enabled)
        app.field("Amount", sheet).type("12.50")
        app.wait_gone(UNCLEAR_US, within=sheet)
        self.assertTrue(app.button("Add", within=sheet).enabled)

    def test_where_a_comma_marks_decimals(self):
        app = launch_fresh(self, region="de_DE.UTF-8")
        app.new_group("Shop")
        app.new_budget("Food", "500", group="Shop")

        # Scenario ENTRY-12
        # 1. In Germany, "12,50" is twelve fifty, and opened again its amount
        # reads "12,50".
        app.add_entry("Hilltop Grocery", "12,50")
        row = app.until(lambda: next((e for e in app.entries() if e[1] == "Hilltop Grocery"), None),
                        "Hilltop Grocery")
        self.assertEqual("$12.50", row[-1])
        app.entry("Hilltop Grocery").press()
        editor = app.wait_for_window(2, "Hilltop Grocery to open")
        self.assertEqual("12,50", app.field("Amount", editor).text)
        app.button("Cancel", within=editor).press()
        app.wait_for_window(1, "the transaction to close")

        # Scenario ENTRY-12
        # 2. A German "1,250" is one and a quarter: refused, with the way to
        # type it. Never twelve hundred and fifty.
        sheet = self.open_sheet(app)
        app.field("Merchant", sheet).type("Corner Bakery")
        app.field("Amount", sheet).type("1,250")
        app.wait_shows(UNCLEAR_COMMA, within=sheet)
        self.assertFalse(app.button("Add", within=sheet).enabled)
        app.button("Cancel", within=sheet).press()
        app.wait_for_window(1, "the sheet to close")
        self.assertEqual(["Hilltop Grocery"], [e[1] for e in app.entries()])


if __name__ == "__main__":
    unittest.main()
