"""A group's page (Features/GroupPage.md) in the real window, signed out, with
the samples a fresh install opens with: what opens it and what takes its
place, how the sidebar marks it, the arrow that hides a group's budgets, the
page signed out, Invite Someone…, and the page staying open until its own
group goes.

The page's people, levels and leaving, which take a second person, are in
test_group_page_shared.py."""

import unittest

from wellspent_ui import launch_fresh


class GroupPage(unittest.TestCase):

    def setUp(self):
        self.app = launch_fresh(self)

    def page_shows(self, group):
        """Whether `group`'s page is what shows: its name and the line under
        it, "Not shared" signed out, with no budget picked. (The sidebar
        writes the name in capitals.)"""
        texts = self.app.texts(self.app.main)
        return group in texts and "Not shared" in texts and not self.app.budget_open()

    def budget_shows(self, budget):
        return (self.app.reads([budget], within=self.app.main) and self.app.budget(budget).selected
                and self.app.shows("Import statement", within=self.app.main, role="push button"))

    def test_what_opens_the_page_and_what_takes_its_place(self):
        app = self.app
        app.budget("Groceries").press()
        app.until(lambda: self.budget_shows("Groceries"), "Groceries to open")

        # Scenario PAGE-01, PAGE-04
        # 1. A click on Household's name opens its page in place of Groceries.
        # The name is marked, and no budget is picked.
        app.group("Household").press()
        app.until(lambda: self.page_shows("Household"), "Household's page")
        self.assertFalse(app.shows("Import statement", within=app.main, role="push button"))
        self.assertTrue(app.group("Household").selected)
        for budget in ("Groceries", "Eating out", "Utilities", "Materials"):
            self.assertFalse(app.budget(budget).selected, f"{budget} is picked")

        # Scenario PAGE-03, PAGE-04
        # 2. A click on Groceries puts it back in place of the page. Groceries
        # is picked, and Household's name is no longer marked.
        app.budget("Groceries").press()
        app.until(lambda: self.budget_shows("Groceries"), "Groceries in place of the page")
        self.assertFalse(self.page_shows("Household"))
        self.assertFalse(app.group("Household").selected)

        # Scenario PAGE-02
        # 3. People… in Household's menu opens the same page.
        app.pick("People…", app.group_menu("Household"))
        app.until(lambda: self.page_shows("Household"), "Household's page from People…")
        self.assertTrue(app.group("Household").selected)

        # Scenario PAGE-03
        # 4. A new budget, once saved, opens in place of the page the same way.
        app.new_budget("Pantry", "100", group="Household")
        app.until(lambda: self.budget_shows("Pantry"), "Pantry in place of the page")
        self.assertFalse(self.page_shows("Household"))

    def test_the_arrow_hides_and_shows_a_groups_budgets(self):
        app = self.app
        household = ("Groceries", "Eating out", "Utilities")
        app.budget("Groceries").press()
        app.until(lambda: self.budget_shows("Groceries"), "Groceries to open")

        # Scenario PAGE-05
        # 1. The arrow hides Household's budgets and is then labelled "Show
        # budgets". Groceries stays open: no page opens or closes.
        app.near("push button", "Hide budgets", to=app.group("Household")).press()
        app.until(lambda: not any(app.has_budget(b) for b in household), "Household's budgets to hide")
        app.near("push button", "Show budgets", to=app.group("Household"))
        self.assertTrue(app.reads(["Groceries"], within=app.main))
        self.assertTrue(app.shows("Import statement", within=app.main, role="push button"))
        self.assertFalse(self.page_shows("Household"))
        self.assertTrue(app.has_budget("Materials"))

        # Scenario PAGE-05
        # 2. Again: the budgets show, and the arrow says "Hide budgets".
        app.near("push button", "Show budgets", to=app.group("Household")).press()
        app.until(lambda: all(app.has_budget(b) for b in household), "Household's budgets to show")
        app.near("push button", "Hide budgets", to=app.group("Household"))

        # Scenario PAGE-05
        # 3. Left hidden, Household stays hidden after quitting and opening
        # again.
        app.near("push button", "Hide budgets", to=app.group("Household")).press()
        app.until(lambda: not app.has_budget("Groceries"), "Household's budgets to hide")
        app.restart()
        app.near("push button", "Show budgets", to=app.group("Household"))
        self.assertFalse(any(app.has_budget(b) for b in household))
        self.assertTrue(app.has_budget("Materials"))

    def test_the_page_signed_out_and_invite_someone(self):
        app = self.app

        # Scenario PAGE-07
        # 1. Signed out, Household's page says only "Not shared", and lists
        # nobody.
        app.group("Household").press()
        app.until(lambda: self.page_shows("Household"), "Household's page")
        self.assertFalse(app.shows("PEOPLE", within=app.main))
        self.assertFalse(app.shows("Made by you", within=app.main))

        # Scenario PAGE-07, PAGE-13
        # 2. Invite Someone… opens the Share sheet for Household, which says to
        # sign in first.
        app.button("Invite Someone…", within=app.main).press()
        sheet = app.wait_for_window(2, "the Share sheet")
        texts = app.texts(sheet)
        self.assertIn("Invite someone to “Household”", texts)
        self.assertIn("Sign in first. Sharing goes through your account.", texts)

        # Scenario PAGE-13
        # 3. Cancel closes it, and the page is still open.
        app.button("Cancel", within=sheet).press()
        app.wait_for_window(1, "the Share sheet to close")
        self.assertTrue(self.page_shows("Household"))

    def test_the_page_stays_until_its_own_group_goes(self):
        app = self.app
        app.group("Household").press()
        app.until(lambda: self.page_shows("Household"), "Household's page")

        # Scenario PAGE-16
        # 1. Deleting Side Business leaves Household's page open.
        app.delete_group("Side Business")
        self.assertTrue(self.page_shows("Household"))

        # Scenario PAGE-16
        # 2. Deleting Household closes its page.
        app.delete_group("Household")
        app.until(lambda: not self.page_shows("Household"), "Household's page to close")


if __name__ == "__main__":
    unittest.main()
