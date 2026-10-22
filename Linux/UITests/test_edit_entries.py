"""Changing and deleting a transaction (Features/EditEntry.md) in the real
window, signed out, in a group of its own: the sheet a click opens, when Save
lights, saving and moving, and deleting with its question and Undo.

What changes with a second person, at View, Add or Manage, is in
test_edit_entries_shared.py."""

import unittest

from wellspent_ui import Wheel, launch_fresh


class EditEntries(unittest.TestCase):

    def setUp(self):
        # Undo stays 8 seconds: long enough for the steps below to beat it,
        # short enough to see it go without a long wait.
        self.app = launch_fresh(self, undo_seconds=8)
        self.app.new_group("Home")
        self.app.new_budget("Treats", "200", group="Home")
        self.app.new_budget("Food", "500", group="Home")
        self.app.add_entry("Hilltop Grocery", "142.08")

    def open_hilltop(self):
        self.app.entry("Hilltop Grocery").press()
        return self.app.wait_for_window(2, "Hilltop Grocery to open")

    def test_the_sheet_and_when_save_lights(self):
        app = self.app

        # Scenario EDIT-01
        # 1. A click on the row opens "Transaction", filled in, with the
        # budget, where it came from, and Delete…, Cancel and Save, Save
        # dimmed.
        sheet = self.open_hilltop()
        texts = app.texts(sheet)
        for words in ("Transaction", "Manual", "Merchant", "Amount", "Date", "Note", "Budget"):
            self.assertIn(words, texts)
        self.assertEqual("Hilltop Grocery", app.field("Merchant", sheet).text)
        self.assertEqual("142.08", app.field("Amount", sheet).text)
        self.assertEqual("Food", app.near("combo box", None, to=app.find("label", "Budget", within=sheet)).words)
        save = app.button("Save", within=sheet)
        app.button("Delete…", within=sheet)
        app.button("Cancel", within=sheet)
        self.assertFalse(save.enabled)

        # Scenario EDIT-02
        # 2. Any change lights Save, and putting it back dims it again. $142.08
        # counts the same as 142.08.
        for label, changed, original in (("Merchant", "Hilltop", "Hilltop Grocery"),
                                         ("Amount", "140.00", "142.08"),
                                         ("Note", "milk", "")):
            app.field(label, sheet).type(changed)
            self.assertTrue(save.enabled, f"{label} changed")
            app.field(label, sheet).type(original)
            self.assertFalse(save.enabled, f"{label} put back")
        app.field("Amount", sheet).type("$142.08")
        self.assertFalse(save.enabled, "$142.08 is the same amount")

        # Scenario EDIT-02
        # 3. Save stays dimmed while the merchant is empty or spaces, or the
        # amount isn't a number.
        app.field("Merchant", sheet).type("  ")
        self.assertFalse(save.enabled, "a merchant of spaces")
        app.field("Merchant", sheet).type("Hilltop Grocery")
        app.field("Amount", sheet).type("lots")
        self.assertFalse(save.enabled, "an amount in words")
        app.button("Cancel", within=sheet).press()
        app.wait_for_window(1, "the sheet to close")

    def test_saving_and_moving(self):
        app = self.app

        # Scenario EDIT-03
        # 1. 124.08 and Save: the sheet closes, the row shows $124.08, and
        # what's spent and left follow at once.
        sheet = self.open_hilltop()
        app.field("Amount", sheet).type("124.08")
        app.button("Save", within=sheet).press()
        app.wait_for_window(1, "the sheet to close")
        app.until(lambda: app.entries() and app.entries()[0][-1] == "$124.08", "the row to show $124.08")
        food = Wheel("Food", 50000, 12408)
        app.wait_reads(food.middle, within=app.main)
        self.assertTrue(app.reads(["Spent", "$124.08"], within=app.main))
        self.assertEqual("Food $375.92", app.budget("Food").words)

        # Scenario EDIT-04
        # 2. Budget offers Home's budgets only. Moved to Treats, it leaves
        # Food's list and total, and Treats lists and counts it.
        sheet = self.open_hilltop()
        budget = app.near("combo box", None, to=app.find("label", "Budget", within=sheet))
        app.choose("Treats", budget)
        app.button("Save", within=sheet).press()
        app.wait_for_window(1, "the sheet to close")
        app.wait_shows("Nothing spent in this budget this period.", within=app.main)
        self.assertEqual("Food $500.00", app.budget("Food").words)
        self.assertEqual("Treats $75.92", app.budget("Treats").words)
        app.budget("Treats").press()
        app.until(lambda: [row[1] for row in app.entries()] == ["Hilltop Grocery"], "Treats to list it")

    def test_deleting_and_undo(self):
        app = self.app

        # Scenario EDIT-06
        # 1. Delete… asks first, naming it, its amount, and where it comes
        # out of. Cancel keeps it, with the sheet open.
        sheet = self.open_hilltop()
        app.button("Delete…", within=sheet).press()
        self.assertEqual("Delete “Hilltop Grocery”, $142.08? It comes out of Food.", app.question())
        app.button("Delete", within=app.front)
        app.answer("Cancel")
        self.assertEqual(2, len(app.windows()), "the sheet stays open")

        # Scenario EDIT-07
        # 2. Delete: the sheet closes, it leaves the list and the total, and a
        # bar offers Undo.
        app.button("Delete…", within=app.front).press()
        app.answer("Delete")
        app.wait_for_window(1, "the sheet to close")
        app.wait_shows("Deleted “Hilltop Grocery”, $142.08.", within=app.main)
        self.assertEqual([], app.entries())
        self.assertEqual("Food $500.00", app.budget("Food").words)

        # Scenario EDIT-07
        # 3. Undo brings it back as it was, and the bar goes.
        app.button("Undo", within=app.main).press()
        app.until(lambda: [row[1:] for row in app.entries()] == [["Hilltop Grocery", "Manual", "$142.08"]],
                  "Hilltop Grocery to come back")
        app.wait_gone("Deleted “Hilltop Grocery”, $142.08.", within=app.main)

        # Scenario EDIT-08
        # 4. Left alone, the bar goes after its time, and the delete stays.
        app.delete_entry("Hilltop Grocery")
        app.wait_shows("Deleted “Hilltop Grocery”, $142.08.", within=app.main)
        app.wait_gone("Deleted “Hilltop Grocery”, $142.08.", within=app.main)
        self.assertEqual([], app.entries())

        # Scenario EDIT-08
        # 5. Another change takes the bar away at once. A second delete
        # replaces it, so only the last can be undone.
        app.add_entry("Market", "9.50")
        app.add_entry("Bakery", "4.00")
        app.delete_entry("Market")
        app.wait_shows("Deleted “Market”, $9.50.", within=app.main)
        app.delete_entry("Bakery")
        app.wait_shows("Deleted “Bakery”, $4.00.", within=app.main)
        self.assertFalse(app.shows("Deleted “Market”, $9.50.", within=app.main))
        app.add_entry("Corner shop", "2.00")
        # Checked at once, well inside the bar's 8 seconds.
        self.assertFalse(app.shows("Deleted “Bakery”, $4.00.", within=app.main))
        self.assertEqual(["Corner shop"], [row[1] for row in app.entries()])


if __name__ == "__main__":
    unittest.main()
