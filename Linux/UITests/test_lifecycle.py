"""Returning to a window brings in changes from another device."""

import unittest

from wellspent_ui import launch_fresh, needs_accounts, unique


class Lifecycle(unittest.TestCase):
    def test_returning_to_the_window_receives_another_devices_entry(self):
        needs_accounts(self)
        # Keep the periodic sync out of the test: returning to the window
        # must be enough even when the next timer is an hour away.
        robin = launch_fresh(self, autosync_seconds=3600)
        leslie = launch_fresh(self, autosync_seconds=3600)
        robin.sign_in_as("Robin")
        leslie.sign_in_as("Leslie")
        home = unique("Home")
        robin.new_group(home)
        self.addCleanup(robin.remove_group, home)
        robin.new_budget("Food", "500", group=home)
        robin.sync()
        leslie.join(robin.share(home, "Robin"), "Leslie")
        robin.budget("Food").press()
        robin.sync()

        # Scenario LIFE-01
        leslie.bring_to_front()
        leslie.budget("Food").press()
        leslie.add_entry("Grocery delivery", "24.00")
        leslie.sync()
        self.assertFalse(any(row[1] == "Grocery delivery" for row in robin.entries()))

        robin.bring_to_front()
        robin.until(lambda: any(row[1] == "Grocery delivery" for row in robin.entries()),
                    "the entry to arrive when returning to the window", wait=20)
        self.assertTrue(robin.reads(["Spent", "$24.00"], within=robin.main))
        self.assertTrue(robin.reads(["Left", "$476.00"], within=robin.main))


if __name__ == "__main__":
    unittest.main()
