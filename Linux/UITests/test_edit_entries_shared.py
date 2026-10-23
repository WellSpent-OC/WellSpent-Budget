"""Changing and deleting a transaction in a shared group (Features/EditEntry.md),
with two people on staging: who added it, what each level may change, and
what happens when the group changes under an open transaction or an Undo.

Leslie makes the group and adds Hilltop Grocery, $142.08, to Food. Robin
joins at Manage unless a step says otherwise. Each person's account is made
once per run, so these are skipped without the test mailbox's token. Each
test names its group for itself and removes it at the end."""

import datetime
import unittest

from wellspent_ui import launch_fresh, needs_accounts, unique


class EditEntriesShared(unittest.TestCase):

    def setUp(self):
        needs_accounts(self)
        self.robin = launch_fresh(self, undo_seconds=30)
        self.leslie = launch_fresh(self)
        self.robin.sign_in_as("Robin")
        self.leslie.sign_in_as("Leslie")
        self.home = unique("Home")
        leslie = self.leslie
        leslie.new_group(self.home)
        self.addCleanup(leslie.remove_group, self.home)
        leslie.new_budget(f"{self.home} treats", "200", group=self.home)
        leslie.new_budget(f"{self.home} food", "500", group=self.home)
        leslie.add_entry("Hilltop Grocery", "142.08")
        leslie.sync()
        self.robin.join(leslie.legacy_invite(self.home, "Leslie", level="Manage"), "Robin")
        self.robin.sync()
        self.food = f"{self.home} food"
        self.treats = f"{self.home} treats"

    def open(self, app, merchant):
        app.budget(self.food).press()
        app.entry(merchant).press()
        return app.wait_for_window(2, f"{merchant} to open")

    def row(self, app, merchant):
        return app.until(lambda: next((r for r in app.entries() if r[1] == merchant), None), f"{merchant}")

    def test_who_added_it_and_what_follows_for_the_other(self):
        robin, leslie = self.robin, self.leslie

        # Scenario EDIT-01
        # 1. The sheet says who added it and where it came from.
        sheet = self.open(robin, "Hilltop Grocery")
        self.assertIn("Added by Leslie · Manual", robin.texts(sheet))

        # Scenario EDIT-03
        # 2. Robin's 124.08 shows at once, still added by Leslie, and on
        # Leslie's after her next sync.
        robin.field("Amount", sheet).type("124.08")
        robin.button("Save", within=sheet).press()
        robin.wait_for_window(1, "the sheet to close")
        self.assertEqual(["Hilltop Grocery", "Leslie", "Manual", "$124.08"], self.row(robin, "Hilltop Grocery")[1:])
        robin.sync()
        leslie.sync()
        leslie.budget(self.food).press()
        leslie.until(lambda: self.row(leslie, "Hilltop Grocery")[-1] == "$124.08", "Leslie to see $124.08")

        # Scenario EDIT-06
        # 3. In a shared group, the delete question says it comes out for
        # everyone.
        sheet = self.open(robin, "Hilltop Grocery")
        robin.button("Delete…", within=sheet).press()
        self.assertEqual(f"Delete “Hilltop Grocery”, $124.08? It comes out of {self.food} for everyone in "
                         f"{self.home}.", robin.question())

        # Scenario EDIT-07
        # 4. Deleted, it goes from Leslie's at her next sync, and Undo brings
        # it back there too, still added by Leslie.
        robin.answer("Delete")
        robin.wait_for_window(1, "the sheet to close")
        robin.sync()
        leslie.sync()
        leslie.until(lambda: all(r[1] != "Hilltop Grocery" for r in leslie.entries()), "it to go from Leslie's")
        robin.button("Undo", within=robin.main).press()
        self.assertEqual("Leslie", self.row(robin, "Hilltop Grocery")[2])
        robin.sync()
        leslie.sync()
        self.row(leslie, "Hilltop Grocery")

        # Scenario EDIT-04
        # 5. Moved to treats, it shows there on Leslie's after her next sync.
        sheet = self.open(robin, "Hilltop Grocery")
        robin.choose(self.treats, robin.near("combo box", None, to=robin.find("label", "Budget", within=sheet)))
        robin.button("Save", within=sheet).press()
        robin.wait_for_window(1, "the sheet to close")
        robin.sync()
        leslie.sync()
        leslie.budget(self.treats).press()
        self.row(leslie, "Hilltop Grocery")

    def test_what_each_level_may_change(self):
        robin, leslie = self.robin, self.leslie
        robin.budget(self.food).press()
        robin.add_entry("Market", "9.50")
        robin.sync()

        # Scenario EDIT-11
        # 1. At Add, Leslie's opens read-only, saying who may change it, with
        # Done alone. His own he can change and delete.
        leslie.set_level(self.home, "Robin", "Add")
        robin.sync()
        sheet = self.open(robin, "Hilltop Grocery")
        robin.wait_shows("Only Leslie, or a manager, can change this.", within=sheet)
        self.assertEqual(["Done"], [b.words for b in sheet.all("push button") if b.showing])
        robin.button("Done", within=sheet).press()
        robin.wait_for_window(1, "the sheet to close")
        sheet = self.open(robin, "Market")
        robin.button("Save", within=sheet)
        robin.button("Delete…", within=sheet)
        robin.button("Cancel", within=sheet).press()
        robin.wait_for_window(1, "the sheet to close")

        # Scenario EDIT-10
        # 2. At View, it opens as plain words, with the line and Done alone.
        # What he added before says he can only view the group now.
        leslie.set_level(self.home, "Robin", "View")
        robin.sync()
        sheet = self.open(robin, "Hilltop Grocery")
        texts = robin.texts(sheet)
        self.assertIn("$142.08", texts)
        self.assertIn("You can view this group but not change it.", texts)
        self.assertEqual(["Done"], [b.words for b in sheet.all("push button") if b.showing])
        robin.button("Done", within=sheet).press()
        robin.wait_for_window(1, "the sheet to close")
        sheet = self.open(robin, "Market")
        robin.wait_shows("You can only view this group now, so you can't change what you added.", within=sheet)
        robin.button("Done", within=sheet).press()
        robin.wait_for_window(1, "the sheet to close")

    def test_changes_under_an_open_transaction(self):
        robin, leslie = self.robin, self.leslie

        # Scenario EDIT-12
        # 1. Leslie deletes it while Robin has it open with a new amount. At
        # his sync, Save saves nothing: the sheet turns read-only and says
        # Leslie deleted it.
        sheet = self.open(robin, "Hilltop Grocery")
        robin.field("Amount", sheet).type("100.00")
        leslie.budget(self.food).press()
        leslie.delete_entry("Hilltop Grocery")
        leslie.sync()
        robin.button("Sync", within=robin.main).press()
        robin.until(lambda: robin.button("Sync", within=robin.main).enabled, "Robin's sync")
        robin.button("Save", within=robin.front).press()
        robin.wait_shows("Leslie deleted this while you had it open.", within=robin.front)
        self.assertEqual(["Done"], [b.words for b in robin.front.all("push button") if b.showing])
        robin.button("Done", within=robin.front).press()
        robin.wait_for_window(1, "the sheet to close")
        robin.until(lambda: all(r[1] != "Hilltop Grocery" for r in robin.entries()), "it to stay deleted")

        # Scenario EDIT-13
        # 2. Moved down to View while Market is open with a new amount: Save
        # saves nothing, and the sheet shows it as it was.
        leslie.add_entry("Market", "9.50")
        leslie.sync()
        robin.sync()
        sheet = self.open(robin, "Market")
        robin.field("Amount", sheet).type("1.00")
        leslie.set_level(self.home, "Robin", "View")
        robin.button("Sync", within=robin.main).press()
        robin.until(lambda: robin.button("Sync", within=robin.main).enabled, "Robin's sync")
        robin.button("Save", within=robin.front).press()
        robin.wait_shows("Nothing was changed. You can view this group but not change it.", within=robin.front)
        self.assertIn("$9.50", robin.texts(robin.front))
        robin.button("Done", within=robin.front).press()
        robin.wait_for_window(1, "the sheet to close")
        self.assertEqual("$9.50", self.row(robin, "Market")[-1])

    def test_an_undo_that_cant_be_done(self):
        robin, leslie = self.robin, self.leslie

        # Scenario EDIT-09
        # 1. Robin deletes Hilltop Grocery. Moved down to View before Undo,
        # nothing comes back, the bar goes, and the app says why.
        robin.budget(self.food).press()
        robin.delete_entry("Hilltop Grocery")
        robin.sync()
        leslie.set_level(self.home, "Robin", "View")
        robin.sync()
        robin.button("Undo", within=robin.main).press()
        self.assertIn("This can't be undone now. You can view this group but not change it.", robin.question())
        robin.answer("OK")
        robin.wait_gone("Undo", within=robin.main, role="push button")
        self.assertEqual([], robin.entries())


if __name__ == "__main__":
    unittest.main()
