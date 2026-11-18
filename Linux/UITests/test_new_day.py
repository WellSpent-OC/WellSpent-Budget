"""A new day in a window left open, signed out (LIFE-02), on the test clock:
the test writes a local date and time to a file and the app reads today from
it, so a day and a month can begin while the test runs. No account is
needed."""

import datetime
import time
import unittest

from wellspent_ui import Wheel, launch_fresh


def on(when):
    """The date of a test clock time such as "2026-10-31T09:00:00"."""
    return datetime.datetime.strptime(when, "%Y-%m-%dT%H:%M:%S").date()


class NewDay(unittest.TestCase):

    def started(self, at, **settings):
        """The app on the test clock at `at`, with Pantry, $310.00 a month,
        in a group of its own, $100.00 spent today, and its page open."""
        app = launch_fresh(self, clock=at, **settings)
        app.new_group("Home")
        app.new_budget("Pantry", "310", group="Home")
        app.add_entry("Hilltop Grocery", "100.00")
        app.wait_shows(Wheel("Pantry", 31_000, 10_000, day=on(at)).day_line, within=app.main)
        return app

    def expect_figures(self, app, wheel, what):
        """Beside the wheel, each of `wheel`'s figures, in words and amount."""
        for label, amount in wheel.figures:
            app.until(lambda: app.reads([label, amount], within=app.main), f"{label} {amount} {what}")

    def test_a_new_day_and_a_new_month_while_open(self):
        app = self.started("2026-10-30T12:00:00")

        # Scenario LIFE-02
        # On Linux, a window in front finds the new day by itself. On a test
        # clock it checks every second, standing in for every 30.
        # 1. The clock moves to the next day, with nothing pressed: the line
        # says day 31, the wheel's figures are the 31st's, and October's
        # transaction is still listed.
        app.set_clock("2026-10-31T09:00:00")
        last_day = Wheel("Pantry", 31_000, 10_000, day=on("2026-10-31T09:00:00"))
        app.wait_shows(last_day.day_line, within=app.main)
        self.expect_figures(app, last_day, "on the 31st")
        app.entry("Hilltop Grocery")

        # Scenario LIFE-02
        # 2. The clock moves into November: a new period, with nothing spent
        # yet, so October's transaction is no longer listed.
        app.set_clock("2026-11-01T09:00:00")
        first_day = Wheel("Pantry", 31_000, 0, day=on("2026-11-01T09:00:00"))
        app.wait_shows(first_day.day_line, within=app.main)
        self.expect_figures(app, first_day, "on November 1")
        app.until(lambda: not app.shows("Hilltop Grocery", within=app.main), "October's transaction to go")

    def test_coming_back_after_the_night_checks_the_date(self):
        # The app doesn't notice a new day by itself here, so only coming to
        # the front can move it.
        app = self.started("2026-10-17T22:00:00", clock_announces=False)
        evening = Wheel("Home", 31_000, 10_000, day=on("2026-10-17T22:00:00"), group=True)
        morning = Wheel("Home", 31_000, 10_000, day=on("2026-10-18T07:00:00"), group=True)
        self.assertNotEqual(evening.figures, morning.figures, "the test's two days show the same figures")
        app.group("Home").press()
        self.expect_figures(app, evening, "on the group's page on the 17th")

        # Scenario LIFE-02: on Linux, at once when the window comes back to
        # the front.
        # 1. Another window comes to the front, the night passes, and
        # WellSpent comes back: the group's page shows the 18th's figures.
        other = launch_fresh(self)
        other.bring_to_front()
        app.set_clock("2026-10-18T07:00:00")
        # Longer than the clock's own check takes, so a new day it wrongly
        # noticed by itself would show by now.
        time.sleep(3)
        self.expect_figures(app, evening, "while away, before coming back")
        app.bring_to_front()
        self.expect_figures(app, morning, "on the group's page after coming back the next morning")


if __name__ == "__main__":
    unittest.main()
