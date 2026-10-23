"""Return submits a valid form, leaves invalid input open, and respects a
focused Cancel button. Every action uses the real sheet and keyboard."""

import unittest

from wellspent_ui import launch_fresh


class DefaultAction(unittest.TestCase):

    def test_return_saves_a_budget_only_when_valid(self):
        app = launch_fresh(self)
        app.new_group("Shop")
        app.pick("New Budget in Shop…", app.group_menu("Shop"))
        sheet = app.wait_for_window(2, "the New Budget sheet")
        name = app.field("Name", sheet)
        amount = app.field("Each month", sheet)
        app.until(lambda: name.focused, "Name to have the keyboard")

        name.type("Food")
        amount.type("0")
        self.assertFalse(app.button("Add", within=sheet).enabled)
        app.key("Return")
        self.assertEqual(2, len(app.windows()), "invalid input submitted")
        self.assertFalse(app.has_budget("Food"))

        amount.type("500")
        self.assertTrue(app.button("Add", within=sheet).enabled)
        app.key("Return")
        app.wait_for_window(1, "Return to save the budget")
        self.assertEqual("Food $500.00", app.budget("Food").words)

        # Reopening also verifies the old sheet's default button was released.
        app.button("Edit…", within=app.main).press()
        sheet = app.wait_for_window(2, "the Edit Budget sheet")
        app.field("Each month", sheet).type("650")
        app.key("Return")
        app.wait_for_window(1, "Return to save the changed budget")
        self.assertEqual("Food $650.00", app.budget("Food").words)

    # Scenario ENTRY-11
    def test_return_adds_an_entry_and_cancel_keeps_its_own_action(self):
        app = launch_fresh(self)
        app.new_group("Shop")
        app.new_budget("Food", "500", group="Shop")
        app.button("Add", within=app.main).press()
        sheet = app.wait_for_window(2, "the New transaction sheet")
        merchant = app.field("Merchant", sheet)
        app.until(lambda: merchant.focused, "Merchant to have the keyboard")
        merchant.type("Hilltop Grocery")
        app.field("Amount", sheet).type("twelve")
        self.assertFalse(app.button("Add", within=sheet).enabled)
        app.key("Return")
        self.assertEqual(2, len(app.windows()), "invalid input submitted")
        self.assertEqual([], app.entries())

        app.field("Amount", sheet).type("12.50")
        app.key("Return")
        app.wait_for_window(1, "Return to add the transaction")
        app.until(lambda: len(app.entries()) == 1, "the transaction to show")
        self.assertEqual("Hilltop Grocery", app.entries()[0][1])
        self.assertEqual("$12.50", app.entries()[0][-1])

        app.button("Add", within=app.main).press()
        sheet = app.wait_for_window(2, "another New transaction sheet")
        app.field("Merchant", sheet).type("Should not be saved")
        app.field("Amount", sheet).type("7.00")
        cancel = app.button("Cancel", within=sheet)
        for _ in range(20):
            if cancel.focused:
                break
            app.key("Tab")
        self.assertTrue(cancel.focused, "Tab did not reach Cancel")
        app.key("Return")
        app.wait_for_window(1, "Return on Cancel to close the sheet")
        self.assertEqual(["Hilltop Grocery"], [row[1] for row in app.entries()])


if __name__ == "__main__":
    unittest.main()
