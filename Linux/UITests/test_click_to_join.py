"""Clicking an invite link (Features/ClickToJoin.md) on Linux. A click while
the app is open is a second launch that hands the link to the open copy
(`launch_again`); a click while it is closed is a launch with the link. Two
people on the disposable server, each in a copy of their own."""

import unittest

from wellspent_ui import launch_fresh, needs_accounts, unique

NOT_WHOLE = "Part of that invite link is missing. Ask the person who sent it to send it again."
SIGN_IN_FIRST = "Sign in first, or create an account. Joining adds the group to your account."
ADD_LINES = ("Adds transactions, and edits or deletes their own.", "You'd see everything so far.")
VIEW_LINES = ("Sees every budget and transaction. Changes nothing.",
              "You'd see the group's budgets, and only transactions added from now on.")


def invited(name):
    return f"Robin invited you to “{name}”."


class ClickToJoin(unittest.TestCase):

    def setUp(self):
        needs_accounts(self)
        self.robin = launch_fresh(self)
        self.robin.sign_in_as("Robin")

    def robins_link(self, level="Add", history="all"):
        """A group of Robin's with one budget, removed at the end, and a link
        to it. Gives back the group's name and the link."""
        robin = self.robin
        name = unique("Link")
        robin.new_group(name)
        self.addCleanup(robin.remove_group, name)
        robin.new_budget(f"{name} food", "800", group=name)
        return name, robin.legacy_invite(name, "Robin", level, history)

    def page(self, app):
        return app.texts(app.main)

    def offer(self, app, level, lines):
        """Waits for the page to give the level, which the Linux page draws as
        three texts with the level's name in bold, and the lines under it."""
        app.until(lambda: app.reads(["You'd join at ", level, "."], within=app.main), f"the page to say You'd join at {level}.")
        for line in lines:
            app.until(lambda: line in self.page(app), f"the page to say {line!r}")

    def test_a_click_opens_the_invitation_and_join_takes_the_group_in(self):
        name, link = self.robins_link()
        leslie = launch_fresh(self)
        leslie.new_group("Mine")
        leslie.new_budget("Snacks", "50", group="Mine")
        # The test server is not the build's own, and a signed-out copy asks
        # the server it last signed in to, so her copy learns it once.
        leslie.sign_in_as("Leslie")
        leslie.sign_out()

        # Scenario CLICK-08
        # 1. A link cut short, the way a message app cuts one, handed to the
        # open copy: a page headed Join a Group says part of it is missing,
        # with no name field and no Join.
        self.assertEqual(0, leslie.launch_again(link[:len(link) // 2]))
        leslie.until(lambda: NOT_WHOLE in self.page(leslie), "the line about the missing part")
        self.assertIn("Join a Group", self.page(leslie))
        self.assertFalse(leslie.shows("Join", within=leslie.main, role="push button"), "Join, for a cut link")
        self.assertFalse(leslie.shows("Your name", within=leslie.main), "a name field, for a cut link")

        # Scenario CLICK-01, CLICK-05
        # 2. The whole link, clicked while signed out: who invited her and to
        # what at once, then the level, what it lets her do and what she would
        # see. The notice and Sign in… stand in place of Join. The link itself
        # is not shown, and there is no Decline.
        self.assertEqual(0, leslie.launch_again(link))
        leslie.until(lambda: invited(name) in self.page(leslie), "who invited her")
        self.offer(leslie, "Add", ADD_LINES)
        texts = self.page(leslie)
        self.assertIn(SIGN_IN_FIRST, texts)
        self.assertTrue(leslie.shows("Sign in…", within=leslie.main, role="push button"))
        self.assertFalse(leslie.shows("Join", within=leslie.main, role="push button"), "Join, while signed out")
        self.assertFalse(any(link.split("#")[-1][:12] in t for t in texts), "the link itself is shown")
        self.assertFalse(leslie.shows("Decline", within=leslie.main))

        # Scenario CLICK-05
        # 3. Sign in… opens the account sheet. Signed in, the page is still up
        # and Join takes the notice's place.
        leslie.button("Sign in…", within=leslie.main).press()
        leslie.sign_in_on_sheet("Leslie")
        leslie.until(lambda: leslie.shows("Join", within=leslie.main, role="push button"), "Join once signed in")
        self.assertIn(invited(name), self.page(leslie))
        self.assertNotIn(SIGN_IN_FIRST, self.page(leslie))

        # Scenario CLICK-04, PAGE-06
        # 4. Join is dimmed until a name is typed. Pressed, the group is in
        # the sidebar and its page opens in place of the invitation.
        self.assertFalse(leslie.button("Join", within=leslie.main).enabled, "Join lit with no name")
        leslie.field("Your name", leslie.main).type("Leslie")
        leslie.until(lambda: leslie.button("Join", within=leslie.main).enabled, "Join to light")
        leslie.button("Join", within=leslie.main).press()
        leslie.until(lambda: leslie.reads(["Shared · 2 people · Made by Robin"], within=leslie.main),
                     "the group's page with both people")
        self.assertNotIn(invited(name), self.page(leslie))
        self.assertTrue(leslie.shows(name.upper(), within=leslie.main, role="push button"), "the group in the sidebar")
        self.addCleanup(leslie.remove_group, name)
        self.robin.sync()
        self.robin.group(name).press()
        self.robin.until(lambda: self.robin.shows("Leslie", within=self.robin.main), "Leslie on Robin's page")

        # Scenario CLICK-12
        # 5. Another click brings the invitation back; picking a budget takes
        # it down, and a group's name opens that group's page in its place.
        self.assertEqual(0, leslie.launch_again(link))
        leslie.until(lambda: invited(name) in self.page(leslie), "the invitation again")
        leslie.budget("Snacks").press()
        leslie.until(lambda: invited(name) not in self.page(leslie) and leslie.reads(["Snacks"], within=leslie.main),
                     "the budget in place of the page")
        self.assertEqual(0, leslie.launch_again(link))
        leslie.until(lambda: invited(name) in self.page(leslie), "the invitation once more")
        leslie.group("Mine").press()
        leslie.until(lambda: invited(name) not in self.page(leslie)
                     and any(t.startswith("Not shared") for t in self.page(leslie)),
                     "Mine's page in place of the invitation")

    def test_a_click_starts_the_app_and_another_link_replaces_the_page(self):
        name, link = self.robins_link(level="View", history="fromNow")
        other, other_link = self.robins_link()

        # Scenario CLICK-02, CLICK-03
        # 1. Closed, a click starts the app on the invitation page, which
        # gives the link's own level and history: View, only from now on.
        leslie = launch_fresh(self)
        leslie.sign_in_as("Leslie")
        leslie.sign_out()
        leslie.quit()
        leslie.launch(link)
        leslie.until(lambda: invited(name) in self.page(leslie), "the invitation at launch")
        self.offer(leslie, "View", VIEW_LINES)

        # Scenario CLICK-11
        # 2. A link to another group replaces the page.
        self.assertEqual(0, leslie.launch_again(other_link))
        leslie.until(lambda: invited(other) in self.page(leslie), "the other group's invitation")
        self.assertNotIn(invited(name), self.page(leslie))
        self.offer(leslie, "Add", ADD_LINES)


if __name__ == "__main__":
    unittest.main()
