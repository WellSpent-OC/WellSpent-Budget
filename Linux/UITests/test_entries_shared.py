"""Adding a transaction in a shared group (Features/Entries.md), with two people
on staging, each in a copy of the app of their own: who added each
transaction, one arriving at the next sync, and no Add at View.

Each person's account is made once per run, through staging's test mailbox,
and signed into after that, so these are skipped without its token. Each test
names its groups for itself and removes them at the end."""

import unittest

from wellspent_ui import launch_fresh, needs_accounts, unique


class EntriesShared(unittest.TestCase):

    def setUp(self):
        needs_accounts(self)
        self.robin = launch_fresh(self)
        self.leslie = launch_fresh(self)
        self.robin.sign_in_as("Robin")
        self.leslie.sign_in_as("Leslie")

    def find(self, app, merchant):
        return app.until(lambda: next((e for e in app.entries() if e[1] == merchant), None),
                         f"{merchant} in the list")

    def test_who_added_each_transaction_and_the_next_sync(self):
        robin, leslie = self.robin, self.leslie
        home = unique("Home")
        robin.new_group(home)
        self.addCleanup(robin.remove_group, home)
        robin.new_budget("Food", "500", group=home)
        robin.add_entry("Market", "10.00")

        # Scenario ENTRY-08
        # 1. In a group nobody else is in, the list doesn't say who added
        # anything.
        self.assertEqual(["Market", "Manual", "$10.00"], self.find(robin, "Market")[1:])

        # 2. Robin shares Home as Robin, and Leslie joins as Leslie.
        robin.sync()
        leslie.join(robin.share(home, "Robin"), "Leslie")

        # Scenario ENTRY-09
        # 3. Leslie adds Corner Bakery, 99.00. At Robin's next sync it shows in
        # his Food, added by Leslie, and counts in what's spent and left.
        leslie.budget("Food").press()
        leslie.add_entry("Corner Bakery", "99.00")
        leslie.sync()
        robin.sync()
        robin.budget("Food").press()
        bakery = self.find(robin, "Corner Bakery")
        self.assertEqual(["Corner Bakery", "Leslie", "Manual", "$99.00"], bakery[1:])
        self.assertTrue(robin.reads(["Spent", "$109.00"], within=robin.main))
        self.assertTrue(robin.reads(["Left", "$391.00"], within=robin.main))

        # Scenario ENTRY-08
        # 4. Beside each, who added it: "You" for his, "Leslie" for hers. On
        # Leslie's, the other way round.
        self.assertEqual(["Market", "You", "Manual", "$10.00"], self.find(robin, "Market")[1:])
        leslie.sync()
        self.assertEqual(["Market", "Robin", "Manual", "$10.00"], self.find(leslie, "Market")[1:])
        self.assertEqual(["Corner Bakery", "You", "Manual", "$99.00"], self.find(leslie, "Corner Bakery")[1:])

    def test_at_view_there_is_no_add(self):
        robin, leslie = self.robin, self.leslie

        # Scenario ENTRY-10
        # 1. Leslie makes Club with Snacks, and shares it with Robin at View.
        club = unique("Club")
        leslie.new_group(club)
        self.addCleanup(leslie.remove_group, club)
        leslie.new_budget("Snacks", "100", group=club)
        leslie.sync()
        robin.join(leslie.share(club, "Leslie", level="View"), "Robin")

        # Scenario ENTRY-10
        # 2. Robin opens Snacks: no Add and no Import statement. Leslie, who
        # made it, has both.
        robin.budget("Snacks").press()
        robin.wait_shows("Snacks", within=robin.main, role="label")
        self.assertFalse(robin.shows("Add", within=robin.main, role="push button"))
        self.assertFalse(robin.shows("Import statement", within=robin.main, role="push button"))
        leslie.budget("Snacks").press()
        leslie.button("Add", within=leslie.main)
        leslie.button("Import statement", within=leslie.main)


if __name__ == "__main__":
    unittest.main()
