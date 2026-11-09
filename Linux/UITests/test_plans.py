"""Plans (Features/Plans.md) in the real window: the plan card on Account, and
Choose a plan, which on Linux continues on the website. The browser and the
mail program are the UI tests' recorder (wellspent_ui._record_browser), so
nothing leaves the container. Each test makes a fresh account, which starts on
the free plan, so it is skipped without the test mailbox's token."""

import unittest

from wellspent_ui import launch_fresh, needs_accounts, unique

FREE_LINE = "1 property, sync on every device, and 1 group shared with 1 person."
CHECKOUT = "https://wellspent.space/checkout"


class Plans(unittest.TestCase):
    def open_plans(self, app):
        """Account, then See Plans on the card: Choose a plan opens in the
        account sheet's place."""
        app.button("Account", within=app.main).press()
        sheet = app.wait_for_window(2, "the account sheet")
        app.wait_shows("Your plan", within=sheet)
        app.button("See Plans", within=sheet).press()
        app.until(lambda: app.shows("Choose a plan", within=app.front), "Choose a plan to open")
        return app.front

    def test_a_new_account_is_on_the_free_plan(self):
        needs_accounts(self)
        app = launch_fresh(self)
        app.sign_up(unique("plan-free"))
        app.button("Account", within=app.main).press()
        sheet = app.wait_for_window(2, "the account sheet")
        # Scenario PLAN-01
        # The card says the free plan and what it includes, and offers See Plans.
        app.wait_shows("Your plan", within=sheet)
        app.wait_shows("Free plan", within=sheet)
        app.wait_shows(FREE_LINE, within=sheet)
        self.assertTrue(app.button("See Plans", within=sheet).enabled)

    def test_continue_opens_checkout_for_the_picked_plan(self):
        needs_accounts(self)
        app = launch_fresh(self)
        app.sign_up(unique("plan-checkout"))
        sheet = self.open_plans(app)
        # Scenario PLAN-02
        # Monthly first, with the plan that fits a free account picked.
        starter = app.find("push button", "Starter $19 a month", within=sheet)
        self.assertTrue(starter.selected)
        # Scenario PLAN-03
        # Yearly shows each plan's price for the year.
        app.button("Yearly 2 months free", within=sheet).press()
        growth = app.find("push button", "Growth $490 a year", within=sheet)
        growth.press()
        app.until(lambda: app.find("push button", "Growth $490 a year", within=app.front).selected,
                  "Growth to be picked")
        # Scenario PLAN-04
        # Continue opens checkout for that plan and period, and the sheet closes.
        app.button("Continue on wellspent.space", within=app.front).press()
        app.wait_for_window(1, "Choose a plan to close")
        app.until(lambda: f"{CHECKOUT}?plan=growth&period=yearly" in app.opened_links(),
                  "checkout for Growth, yearly, to open")

    def test_more_than_fifteen_emails_us(self):
        needs_accounts(self)
        app = launch_fresh(self)
        app.sign_up(unique("plan-email"))
        sheet = self.open_plans(app)
        # Scenario PLAN-05
        # More than 15 properties? Email us opens an email to WellSpent.
        app.button("Email us", within=sheet).press()
        app.until(lambda: any(link.startswith("mailto:dev@wellspent.space") for link in app.opened_links()),
                  "an email to WellSpent to open")


if __name__ == "__main__":
    unittest.main()
