"""Repeat expenses in a shared group (Features/RepeatExpenses.md), with two
people: only the person who added a bill turns its repeat on, and someone who
may only read a repeat's bill sees whether it repeats in a plain row.

Leslie makes the group and adds Water, $40.00. Robin joins at Manage, then
Leslie moves him to Add. Each person's account is made once per run, so these
are skipped without the test mailbox's token. The group is named for this
test and removed at the end."""

import unittest

from wellspent_ui import launch_fresh, needs_accounts, unique

REPEATS = "Repeats every month"


class RepeatsShared(unittest.TestCase):

    def setUp(self):
        needs_accounts(self)
        self.robin = launch_fresh(self)
        self.leslie = launch_fresh(self)
        self.robin.sign_in_as("Robin")
        self.leslie.sign_in_as("Leslie")
        self.home = unique("Home")
        self.bills = f"{self.home} bills"
        leslie = self.leslie
        leslie.new_group(self.home)
        self.addCleanup(leslie.remove_group, self.home)
        leslie.new_budget(self.bills, "600", group=self.home)
        leslie.add_entry("Water", "40.00")
        leslie.sync()
        self.robin.join(leslie.legacy_invite(self.home, "Leslie", level="Manage"), "Robin")
        self.robin.sync()

    def open(self, app, merchant):
        app.budget(self.bills).press()
        app.entry(merchant).press()
        return app.wait_for_window(2, f"{merchant} to open")

    def close(self, app, sheet, button):
        app.button(button, within=sheet).press()
        app.wait_for_window(1, "the sheet to close")

    def plain_row(self, app, sheet):
        """What the read-only sheet says beside "Repeats every month"."""
        texts = app.texts(sheet)
        return texts[texts.index(REPEATS) + 1] if REPEATS in texts else None

    def test_only_who_added_it_turns_it_on_and_a_reader_sees_a_plain_row(self):
        robin, leslie = self.robin, self.leslie

        # Scenario REPEAT-17
        # 1. A manager who opens Leslie's bill sees the switch off and dimmed.
        sheet = self.open(robin, "Water")
        switch = robin.find("check box", REPEATS, within=sheet)
        self.assertFalse(switch.checked, "on before anyone turned it on")
        self.assertFalse(switch.enabled, "a manager may turn on a repeat for someone else's bill")
        self.close(robin, sheet, "Cancel")

        # Scenario REPEAT-17
        # 2. Leslie turns it on for her own bill, and Robin, now at Add, sees
        # one Water bill.
        leslie.set_level(self.home, "Robin", "Add")
        sheet = self.open(leslie, "Water")
        leslie.find("check box", REPEATS, within=sheet).press()
        self.close(leslie, sheet, "Save")
        leslie.sync()
        robin.sync()
        robin.budget(self.bills).press()
        robin.until(lambda: [r[1] for r in robin.entries()] == ["Water"] or None, "one Water bill on Robin's")
        self.assertEqual("Leslie", robin.entries()[0][2], "Robin's list doesn't say Leslie added it")

        # Scenario REPEAT-18
        # 3. Robin may only read it: the sheet says it repeats in a plain row.
        sheet = self.open(robin, "Water")
        robin.wait_shows(REPEATS, within=sheet)
        self.assertEqual("On", self.plain_row(robin, sheet))
        self.assertFalse(robin.shows(REPEATS, within=sheet, role="check box"), "a reader has a switch")
        robin.picture("repeat-read-only")
        self.close(robin, sheet, "Done")

        # Scenario REPEAT-18
        # 4. Once Leslie stops it, the row says Off.
        sheet = self.open(leslie, "Water")
        leslie.button("Stop repeating…", within=sheet).press()
        leslie.answer("Stop Repeating")
        leslie.wait_for_window(1, "the sheet to close")
        leslie.sync()
        robin.sync()
        sheet = self.open(robin, "Water")
        robin.until(lambda: self.plain_row(robin, sheet) == "Off" or None, "the row to say Off")
        self.close(robin, sheet, "Done")


if __name__ == "__main__":
    unittest.main()
