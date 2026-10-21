"""Budgets and groups shared by two people (Features/Budgets.md), each in a
copy of the app of their own: what each level's menus offer, a new budget
with no group of one's own, the owner's delete for everyone, and a member's
leave.

Each person's account is made once per run and signed into after that, so
these are skipped without the test mailbox's token. Each test names its
groups for itself and removes them at the end."""

import unittest

from wellspent_ui import launch_fresh, needs_accounts, unique

LEAVE = ("You leave the group, and it is removed from all your devices, with its 1 budget and 2 "
         "transactions. The others in it keep it. ")
CHANGES = ("Anything you changed in it on this device that has not synced yet still goes to them first. "
           "Changes on your other devices that have not synced yet do not reach them. ")
ONLY = ("Only the person who made it, or an admin, can delete it for everyone. "
        "To come back, ask for a new invite link.")


class BudgetsShared(unittest.TestCase):

    def setUp(self):
        needs_accounts(self)
        self.robin = launch_fresh(self)
        self.leslie = launch_fresh(self)

    def group_with_spending(self, owner, name):
        """A group of `owner`'s with 1 budget and 2 transactions, removed at
        the end of the test."""
        owner.new_group(name)
        self.addCleanup(owner.remove_group, name)
        owner.new_budget(f"{name} rent", "1000", group=name)
        owner.add_entry("Landlord", "500.00")
        owner.add_entry("Plumber", "80.00")
        owner.sync()

    def menu_of(self, app, group):
        menu = app.group_menu(group)
        items = app.menu_items(menu)
        app.key("Escape")
        return items

    def test_what_each_level_may_change(self):
        robin, leslie = self.robin, self.leslie
        # Robin has no group of his own on this computer or in his account.
        robin.delete_group("Side Business")
        robin.delete_group("Household")
        robin.sign_in_as("Robin")
        leslie.sign_in_as("Leslie")
        home = unique("Home")
        leslie.new_group(home)
        self.addCleanup(leslie.remove_group, home)
        leslie.new_budget("Food", "500", group=home)

        # Scenario BUDGET-07
        # 1. Leslie, who made it, is offered everything for the group and for
        # Food.
        self.assertEqual(["Share…", "People…", f"New Budget in {home}…", "Rename…", "Delete…"],
                         self.menu_of(leslie, home))
        leslie.button("Edit…", within=leslie.main)
        leslie.button("Delete…", within=leslie.main)

        # Scenario BUDGET-07
        # 2. Shared with Robin at Add: the group offers him only Share…,
        # People… and Leave…, and Food no Edit… or Delete….
        leslie.sync()
        robin.join(leslie.share(home, "Leslie"), "Robin")
        self.assertEqual(["Share…", "People…", "Leave…"], self.menu_of(robin, home))
        robin.budget("Food").press()
        robin.wait_shows("Food", within=robin.main, role="label")
        self.assertFalse(robin.shows("Edit…", within=robin.main, role="push button"))
        self.assertFalse(robin.shows("Delete…", within=robin.main, role="push button"))

        # Scenario BUDGET-05
        # 3. In Leslie's group at Add, Robin manages no group, so Add Budget
        # asks for a group's name of his own, Personal to start with.
        robin.near("push button", "Add Budget", to=robin.button("More", within=robin.main)).press()
        sheet = robin.wait_for_window(2, "the New Budget sheet")
        self.assertEqual("Personal", robin.field("Group", sheet).text)
        robin.button("Cancel", within=sheet).press()
        robin.wait_for_window(1, "the sheet to close")

        # Scenario BUDGET-07
        # 4. Leslie moves him up to Manage. At his next sync he's offered
        # Edit… and Delete… for Food, and New Budget… and Rename… for the
        # group, and still Leave… in place of Delete….
        leslie.group(home).press()
        leslie.sync()
        level = leslie.near("combo box", None, to=leslie.find("label", "Robin", within=leslie.main))
        leslie.choose("Manage", level)
        leslie.sync()
        robin.sync()
        robin.budget("Food").press()
        robin.button("Edit…", within=robin.main)
        robin.button("Delete…", within=robin.main)
        self.assertEqual(["Share…", "People…", f"New Budget in {home}…", "Rename…", "Leave…"],
                         self.menu_of(robin, home))

    def test_the_owner_deletes_a_shared_group_for_everyone(self):
        robin, leslie = self.robin, self.leslie
        robin.sign_in_as("Robin")
        leslie.sign_in_as("Leslie")
        flat = unique("Flat")
        self.group_with_spending(robin, flat)
        leslie.join(robin.share(flat, "Robin"), "Leslie")
        robin.sync()

        # Scenario BUDGET-12
        # 1. Robin made it, so Delete… deletes it for everyone, and says so.
        robin.pick("Delete…", robin.group_menu(flat))
        self.assertEqual(f"Delete “{flat}”? It's deleted for everyone in it, with its 1 budget and 2 "
                         "transactions. This cannot be undone.", robin.question())
        robin.answer("Delete")
        robin.sync()

        # Scenario BUDGET-12
        # 2. At Leslie's next sync it's gone from hers too.
        leslie.sync()
        leslie.until(lambda: not leslie.shows(flat.upper(), within=leslie.main), f"{flat} to go from Leslie's")

    def test_a_member_leaves_instead_of_deleting(self):
        robin, leslie = self.robin, self.leslie
        robin.sign_in_as("Robin")
        leslie.sign_in_as("Leslie")
        flat = unique("Flat")
        self.group_with_spending(leslie, flat)
        robin.join(leslie.share(flat, "Leslie"), "Robin")

        # Scenario BUDGET-13
        # 1. At Add, Robin is asked to leave, never to delete, in these words.
        robin.pick("Leave…", robin.group_menu(flat))
        self.assertEqual(f"Leave “{flat}”? " + LEAVE + CHANGES + ONLY, robin.question())
        robin.button("Leave", within=robin.front)

        # Scenario BUDGET-13
        # 2. Leave takes it off his list, and Leslie keeps it.
        robin.answer("Leave")
        robin.until(lambda: not robin.shows(flat.upper(), within=robin.main), f"{flat} to go from Robin's")
        leslie.sync()
        leslie.group(flat)

        # Scenario BUDGET-13
        # 3. At View, the question leaves out the sentences about changes: he
        # has none to send.
        club = unique("Club")
        self.group_with_spending(leslie, club)
        robin.join(leslie.share(club, "Leslie", level="View"), "Robin")
        robin.pick("Leave…", robin.group_menu(club))
        self.assertEqual(f"Leave “{club}”? " + LEAVE + ONLY, robin.question())
        robin.answer("Cancel")


if __name__ == "__main__":
    unittest.main()
