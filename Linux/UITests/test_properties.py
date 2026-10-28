"""Properties has a door: turned on from Extensions, Houses joins the rail, and
Budgets stays exactly as it was. Off, or on a build whose flag is off, nothing
of Properties shows. Scenarios PROP-01, PROP-02 and PROP-03."""

import unittest

from wellspent_ui import launch_fresh


class Properties(unittest.TestCase):
    def test_turn_on_shows_houses_and_leaves_budgets_alone(self):
        # Scenario PROP-01
        app = launch_fresh(self, extensions=True, properties=True)
        app.new_group("Rentals")
        app.new_budget("Repairs", "300", group="Rentals")
        self.assertFalse(app.shows("Houses", role="push button"))

        app.button("Extensions", within=app.main).press()
        app.wait_shows("Properties", within=app.main, role="label")
        app.wait_shows("$5 a house a month, billed yearly", within=app.main, role="label")
        app.button("Turn on", within=app.main).press()
        app.wait_shows("Houses", role="push button")
        app.picture("desktop-houses")

        # Scenario PROP-03: Budgets exactly as before.
        app.button("Budget", within=app.main).press()
        app.wait_shows("Repairs", within=app.main)
        app.wait_shows("Rentals", within=app.main)

        # Back in the catalog the card says it is on and opens Houses.
        app.button("Extensions", within=app.main).press()
        app.wait_shows("Turned on", within=app.main, role="label")
        app.button("Open Houses", within=app.main).press()

    def test_flag_off_shows_nothing_of_properties(self):
        # Scenario PROP-02: a live build, or the flag off.
        app = launch_fresh(self, extensions=True, properties=False)
        self.assertFalse(app.shows("Houses", role="push button"))
        app.button("Extensions", within=app.main).press()
        app.wait_shows("Properties", within=app.main, role="label")
        app.wait_shows("Coming later", within=app.main, role="label")
        self.assertFalse(app.shows("Turn on", within=app.main, role="push button"))
        self.assertFalse(app.shows("Open Houses", within=app.main, role="push button"))


if __name__ == "__main__":
    unittest.main()
