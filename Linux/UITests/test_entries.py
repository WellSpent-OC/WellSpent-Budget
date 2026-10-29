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

    def test_the_newest_is_on_top(self):
        app = launch_fresh(self)
        today = datetime.date.today()
        app.new_group("Shop")
        app.new_budget("Food", "500", group="Shop")

        # Scenario ENTRY-05
        # 1. Corner Bakery, dated the day before by the keyboard: Tab to the
        # calendar, then Left. (On the 1st no earlier day is in this period, so
        # it keeps today, and only the order it was added in counts.)
        sheet = self.open_sheet(app)
        app.field("Merchant", sheet).type("Corner Bakery")
        app.field("Amount", sheet).type("6.75")
        if today.day > 1:
            calendar = app.calendar(sheet)
            for _ in range(15):
                if calendar.focused:
                    break
                app.key("Tab")
            self.assertTrue(calendar.focused, "Tab never reached the calendar")
            app.key("Left")
        app.button("Add", within=sheet).press()
        app.wait_for_window(1, "the sheet to close")

        # Scenario ENTRY-05
        # 2. Then Hilltop and Market at today: Market is on top, then
        # Hilltop, then Corner Bakery, dated the day before. (The tree lists
        # rows in the order they were made, not the order they're drawn in,
        # until the list is drawn anew. So the order is read after opening
        # the app again.)
        app.add_entry("Hilltop", "42.00")
        app.add_entry("Market", "9.50")
        app.until(lambda: len(app.entries()) == 3, "three transactions")
        app.restart()
        app.budget("Food").press()
        rows = app.until(lambda: app.entries() if len(app.entries()) == 3 else None, "three transactions")
        self.assertEqual(["Market", "Hilltop", "Corner Bakery"], [row[1] for row in rows])
        if today.day > 1:
            self.assertEqual(short_date(today - datetime.timedelta(days=1)), rows[2][0])

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

    def test_an_entry_can_be_money_in(self):
        app = launch_fresh(self)
        app.new_group("Pool House")
        app.new_budget("Bookings", "2000", group="Pool House")
        app.add_entry("Cleaner", "400.00")
        before = app.sidebar()

        # Scenario INC-01
        # 1. $1,310.00 marked as money in: its row shows a plus sign, the
        # spending row does not, and what Bookings has spent does not change.
        sheet = self.open_sheet(app)
        app.field("Merchant", sheet).type("Guest deposit")
        app.field("Amount", sheet).type("1310.00")
        app.find("check box", "Money in", within=sheet).press()
        app.button("Add", within=sheet).press()
        app.wait_for_window(1, "the New transaction sheet to close")
        app.until(lambda: any(row[1] == "Guest deposit" for row in app.entries()), "the money in to list")
        amounts = {row[1]: row[-1] for row in app.entries()}
        self.assertEqual("+$1310.00", amounts["Guest deposit"])
        self.assertEqual("$400.00", amounts["Cleaner"])
        self.assertEqual(before, app.sidebar())

        # 2. Opened, the entry still says it is money in.
        app.entry("Guest deposit").press()
        editor = app.wait_for_window(2, "Guest deposit to open")
        self.assertIn("Manual · Income", app.texts(editor))
        app.button("Cancel", within=editor).press()
        app.wait_for_window(1, "the editor to close")

if __name__ == "__main__":
    unittest.main()
