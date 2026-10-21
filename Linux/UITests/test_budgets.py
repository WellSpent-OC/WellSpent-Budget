"""Budgets and groups (Features/Budgets.md) in the real window, signed out:
making and renaming groups, making, changing and deleting budgets, what the
delete questions count, which budget opens by itself, the page with no
budgets, a budget over its limit, and amounts read the region's way.

The ones that need two people sharing a group (BUDGET-05's second case, 07,
12 and 13) are in test_budgets_shared.py."""

import datetime
import unittest

from wellspent_ui import Wheel, launch_fresh, short_date

GROUP_NOTE = "A group holds budgets you track together. It is also what you will share with someone else."


class Budgets(unittest.TestCase):

    def test_groups_and_budgets(self):
        app = launch_fresh(self)

        # Scenario BUDGET-01
        # 1. New Group… asks for a name, and says what a group is for. Add
        # stays dimmed while the name is empty or only spaces. Garden shows,
        # with no budgets under it.
        more = app.open_menu(app.button("More", within=app.main))
        app.pick("New Group…", more)
        sheet = app.wait_for_window(2, "the New Group sheet")
        for words in ("New Group", "Name", GROUP_NOTE):
            self.assertIn(words, app.texts(sheet))
        add = app.button("Add", within=sheet)
        self.assertFalse(add.enabled)
        app.field("Name", sheet).type("   ")
        self.assertFalse(add.enabled)
        app.field("Name", sheet).type("Garden")
        add.press()
        app.wait_for_window(1, "the sheet to close")
        self.assertEqual([], app.budgets_in("Garden"))

        # Scenario BUDGET-02
        # 2. Rename… shows the name. Save stays dimmed while it's empty or
        # only spaces. Home takes Garden's place.
        app.pick("Rename…", app.group_menu("Garden"))
        sheet = app.wait_for_window(2, "the Rename Group sheet")
        self.assertIn("Rename Group", app.texts(sheet))
        self.assertEqual("Garden", app.field("Name", sheet).text)
        save = app.button("Save", within=sheet)
        app.field("Name", sheet).type(" ")
        self.assertFalse(save.enabled)
        app.field("Name", sheet).type("Home")
        save.press()
        app.wait_for_window(1, "the sheet to close")
        app.group("Home")
        self.assertNotIn("GARDEN", app.sidebar())

        # Scenario BUDGET-03
        # 3. New Budget in Home… asks for a name, a monthly amount and the
        # group, with Home chosen, and says when it starts again.
        app.pick("New Budget in Home…", app.group_menu("Home"))
        sheet = app.wait_for_window(2, "the New Budget sheet")
        for words in ("New Budget", "Name", "Each month", "Group", "Starts again on the 1st of each month."):
            self.assertIn(words, app.texts(sheet))
        self.assertEqual(["Home"], [e.words for e in sheet.all("combo box") if e.showing])

        # Scenario BUDGET-04
        # 4. Add stays dimmed with no name, or a monthly amount that's empty,
        # 0 or not a number, and lights for 500 and 500.00.
        add = app.button("Add", within=sheet)
        name, amount = app.field("Name", sheet), app.field("Each month", sheet)
        amount.type("500")
        name.type("  ")
        self.assertFalse(add.enabled, "a name of spaces")
        name.type("Food")
        for typed in ("", "0", "lots"):
            amount.type(typed)
            self.assertFalse(add.enabled, f"each month {typed!r}")
        for typed in ("500.00", "500"):
            amount.type(typed)
            self.assertTrue(add.enabled, f"each month {typed!r}")

        # Scenario BUDGET-03
        # 5. Food shows last under HOME with $500.00, and opens: Spent
        # $0.00, Left $500.00, its wheel full.
        add.press()
        app.wait_for_window(1, "the sheet to close")
        self.assertEqual("Food $500.00", app.budgets_in("Home")[-1])
        app.until(lambda: app.budget("Food").selected, "Food to open")
        groceries = Wheel("Food", 50000, 0)
        app.wait_reads(groceries.middle, within=app.main)
        self.assertTrue(app.reads(["Spent", "$0.00"], within=app.main))
        self.assertTrue(app.reads(["Left", "$500.00"], within=app.main))

        # Scenario BUDGET-03
        # 6. Add Budget opens the same sheet, with the first group he manages
        # chosen.
        app.near("push button", "Add Budget", to=app.button("More", within=app.main)).press()
        sheet = app.wait_for_window(2, "the New Budget sheet")
        # The sidebar lists groups by name. (GTK's tree keeps them in the
        # order they were made until the app opens again, so the names are
        # sorted here rather than read in the tree's order.)
        first = sorted(line for line in app.sidebar() if line.isupper())[0]
        self.assertEqual([first], [e.words.upper() for e in sheet.all("combo box") if e.showing])
        app.button("Cancel", within=sheet).press()
        app.wait_for_window(1, "the sheet to close")

        # Scenario BUDGET-14
        # 7. Food with two transactions this month: Spent and Left, the
        # line under them, both listed, and what's left beside it in the list.
        app.add_entry("Hilltop Grocery", "142.08")
        app.add_entry("Corner Bakery", "12.00")
        today = datetime.date.today()
        app.wait_shows(f"2 transactions since {short_date(today.replace(day=1))}", within=app.main)
        self.assertTrue(app.reads(["Spent", "$154.08"], within=app.main))
        self.assertTrue(app.reads(["Left", "$345.92"], within=app.main))
        self.assertEqual({"Hilltop Grocery", "Corner Bakery"}, {row[1] for row in app.entries()})
        self.assertEqual("Food $345.92", app.budget("Food").words)

        # Scenario BUDGET-06
        # 8. Edit… shows the name and monthly amount, with no choice of group.
        # 650 makes Left $507.92 and the wheel "of $650".
        app.delete_entry("Corner Bakery")
        app.button("Edit…", within=app.main).press()
        sheet = app.wait_for_window(2, "the Edit Budget sheet")
        self.assertIn("Edit Budget", app.texts(sheet))
        self.assertEqual("Food", app.field("Name", sheet).text)
        self.assertEqual("500.00", app.field("Each month", sheet).text)
        self.assertEqual([], [e for e in sheet.all("combo box") if e.showing], "a choice of group")
        app.field("Each month", sheet).type("650")
        app.button("Save", within=sheet).press()
        app.wait_for_window(1, "the sheet to close")
        app.wait_reads(["Left", "$507.92"], within=app.main)
        self.assertTrue(app.shows("of $650", within=app.main))
        self.assertEqual("Food $507.92", app.budget("Food").words)

        # Scenario BUDGET-15
        # 9. Treats, $100.00, with $40.00 then $75.00: Spent $115.00, Over
        # $15.00, and "$15.00 over" in the list.
        app.new_budget("Treats", "100", group="Home")
        app.add_entry("Cake", "40.00")
        app.add_entry("Pie", "75.00")
        app.wait_reads(["Spent", "$115.00"], within=app.main)
        self.assertTrue(app.reads(["Over", "$15.00"], within=app.main))
        self.assertEqual("Treats $15.00 over", app.budget("Treats").words)

    def test_deleting_asks_first_and_counts(self):
        app = launch_fresh(self)
        app.new_group("Garage")
        app.new_budget("Tools", "300", group="Garage")
        for merchant in ("Hammer", "Saw", "Drill"):
            app.add_entry(merchant, "10.00")

        # Scenario BUDGET-08
        # 1. Delete… asks first, counting its 3 transactions. Cancel changes
        # nothing.
        app.button("Delete…", within=app.main).press()
        self.assertEqual("Delete “Tools”? Its 3 transactions will be deleted too. This cannot be undone.",
                         app.question())
        app.button("Delete", within=app.front)
        app.answer("Cancel")
        self.assertEqual(3, len(app.entries()))

        # Scenario BUDGET-11
        # 2. With a second budget, the group's Delete… counts 2 budgets and
        # its 3 transactions. One deleted already isn't counted. Cancel keeps
        # them all.
        app.new_budget("Paint", "100", group="Garage")
        app.add_entry("Brush", "5.00")
        app.budget("Tools").press()
        app.delete_entry("Drill")
        app.pick("Delete…", app.group_menu("Garage"))
        self.assertEqual("Delete “Garage”? Its 2 budgets and 3 transactions will be deleted too. "
                         "This cannot be undone.", app.question())
        app.answer("Cancel")
        self.assertEqual(["Tools $280.00", "Paint $95.00"], app.budgets_in("Garage"))

        # Scenario BUDGET-08
        # 3. With 1 transaction it says so. With none, it says only that it
        # can't be undone. Delete takes the budget away.
        app.budget("Paint").press()
        app.button("Delete…", within=app.main).press()
        self.assertEqual("Delete “Paint”? Its 1 transaction will be deleted too. This cannot be undone.",
                         app.question())
        app.answer("Delete")
        app.until(lambda: not app.has_budget("Paint"), "Paint to go")
        app.new_budget("Empty", "50", group="Garage")
        app.button("Delete…", within=app.main).press()
        self.assertEqual("Delete “Empty”? This cannot be undone.", app.question())
        app.answer("Delete")
        app.until(lambda: not app.has_budget("Empty"), "Empty to go")

        # Scenario BUDGET-11
        # 4. Delete takes Garage, its budget and its transactions away, and
        # no other group changes.
        others = [line for line in app.sidebar() if line != "GARAGE" and line not in app.budgets_in("Garage")]
        app.delete_group("Garage")
        self.assertEqual(others, app.sidebar())

        # Scenario BUDGET-11
        # 5. A group with 3 budgets and nothing spent counts the budgets
        # only. An empty group says only that it can't be undone.
        app.new_group("Shed")
        for name in ("Pots", "Seeds", "Soil"):
            app.new_budget(name, "20", group="Shed")
        app.pick("Delete…", app.group_menu("Shed"))
        self.assertEqual("Delete “Shed”? Its 3 budgets will be deleted too. This cannot be undone.",
                         app.question())
        app.answer("Cancel")
        app.new_group("Attic")
        app.pick("Delete…", app.group_menu("Attic"))
        self.assertEqual("Delete “Attic”? This cannot be undone.", app.question())
        app.answer("Delete")

    def test_what_opens_and_the_page_with_no_budgets(self):
        app = launch_fresh(self)
        app.delete_group("Side Business")

        # Scenario BUDGET-09
        # 1. With Groceries open, deleting it opens Eating out in its place.
        app.budget("Groceries").press()
        app.button("Delete…", within=app.main).press()
        app.answer("Delete")
        app.until(lambda: app.budget("Eating out").selected, "Eating out to open")

        # Scenario BUDGET-09
        # 2. Opened again, with budgets, one of them is open already.
        app.restart()
        app.until(lambda: any(app.budget(name).selected for name in ("Eating out", "Utilities")),
                  "a budget to be open")

        # Scenario BUDGET-10
        # 3. With no budgets, the right side says how to start, and its Add
        # Budget opens the New Budget sheet.
        app.delete_group("Household")
        app.wait_shows("No budgets yet", within=app.main)
        self.assertIn("A budget is an amount to spend each month.", app.texts(app.main))
        sidebar_add = app.near("push button", "Add Budget", to=app.button("More", within=app.main))
        page_add = [b for b in app.main.all("push button", "Add Budget") if b.showing and b.node != sidebar_add.node]
        self.assertEqual(1, len(page_add))
        page_add[0].press()
        sheet = app.wait_for_window(2, "the New Budget sheet")

        # Scenario BUDGET-05
        # 4. With no group to put it in, the sheet asks for a group's name,
        # Personal to start with. Add stays dimmed while it's empty or only
        # spaces. Groceries then shows under PERSONAL, and opens.
        self.assertIn("New Budget", app.texts(sheet))
        group = app.field("Group", sheet)
        self.assertEqual("Personal", group.text)
        app.field("Name", sheet).type("Groceries")
        app.field("Each month", sheet).type("500")
        add = app.button("Add", within=sheet)
        group.type("  ")
        self.assertFalse(add.enabled)
        group.type("Personal")
        add.press()
        app.wait_for_window(1, "the sheet to close")
        self.assertEqual(["PERSONAL", "Groceries $500.00"], app.sidebar())
        app.until(lambda: app.budget("Groceries").selected, "Groceries to open")

    def test_a_budget_in_a_comma_region(self):
        app = launch_fresh(self, region="de_DE.UTF-8")

        # Scenario BUDGET-16
        # 1. In Germany, the empty Each month shows "500,00", and "1.500,00"
        # makes Pantry fifteen hundred a month.
        app.near("push button", "Add Budget", to=app.button("More", within=app.main)).press()
        sheet = app.wait_for_window(2, "the New Budget sheet")
        self.assertEqual("500,00", app.field("Each month", sheet).placeholder)
        app.field("Name", sheet).type("Pantry")
        amount = app.field("Each month", sheet)
        add = app.button("Add", within=sheet)

        # Scenario BUDGET-16
        # 2. "500.00" isn't how Germany writes it: Add stays dimmed, and the
        # line says how to type it.
        amount.type("500.00")
        app.wait_shows("That amount can't be read clearly. Type it like 12,50.", within=sheet)
        self.assertFalse(add.enabled)
        amount.type("1.500,00")
        app.until(lambda: add.enabled, "Add to light")
        add.press()
        app.wait_for_window(1, "the sheet to close")
        self.assertEqual("Pantry $1500.00", app.budget("Pantry").words)
        self.assertTrue(app.shows("of $1,500", within=app.main))


if __name__ == "__main__":
    unittest.main()
