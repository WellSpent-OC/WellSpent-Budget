"""The desktop budget has readable columns and keeps its actions reachable."""

import datetime
import unittest

from wellspent_ui import launch_fresh


class DesktopLayout(unittest.TestCase):
    def test_budget_columns_and_desktop_shortcut(self):
        app = launch_fresh(self, day=18)
        app.new_group("Desktop demo")
        app.new_budget("Pantry", "500", group="Desktop demo")
        for heading in ("Date", "Description", "Source", "Amount"):
            app.wait_shows(heading, within=app.main, role="label")
        self.assertFalse(app.shows("Added by", within=app.main, role="label"))
        app.add_entry("Hilltop Grocery", "125.00")
        app.picture("desktop-budget")

        # Scenario ENTRY-11
        app.key("ctrl+n")
        sheet = app.wait_for_window(2, "Ctrl+N to open a new transaction")
        app.field("Merchant", sheet).type("Hilltop Bakery")
        app.field("Amount", sheet).type("12.00")
        # A shortcut belongs to the main window, so cannot open another sheet.
        app.key("ctrl+n")
        self.assertEqual(2, len(app.windows()))
        app.button("Add", within=sheet).press()
        app.wait_for_window(1, "the new transaction to save")
        self.assertEqual(2, len(app.entries()))
        app.entry("Hilltop Bakery").press()
        sheet = app.wait_for_window(2, "the transaction editor")
        app.picture("desktop-entry")
        app.button("Cancel", within=sheet).press()
        app.wait_for_window(1, "the editor to close")
        app.key("ctrl+n")
        sheet = app.wait_for_window(2, "another new transaction")
        app.key("Escape")
        app.wait_for_window(1, "Escape to cancel without adding")
        self.assertEqual(2, len(app.entries()))
        app.group("Desktop demo").press()
        app.wait_shows("MONEY", within=app.main)
        app.picture("desktop-group")
        app.key("ctrl+n")
        self.assertEqual(1, len(app.windows()), "the hidden Add button kept its shortcut")

        app.budget("Pantry").press()
        path = app.write_file("statement.csv", "Date,Description,Amount\n"
                              + f"{datetime.date.today().isoformat()},MARKET,-6.75\n")
        review = app.open_statement(path)
        app.picture("desktop-import")
        app.button("Cancel", within=review).press()
        app.wait_for_window(1, "the import review to close")

    def test_extensions_flag_hides_activity_rail(self):
        app = launch_fresh(self, extensions=False)
        self.assertFalse(app.shows("Extensions", role="push button"))
        self.assertFalse(app.shows("WarTable", role="push button"))
        self.assertFalse(app.shows("Houses", role="push button"))


if __name__ == "__main__":
    unittest.main()
