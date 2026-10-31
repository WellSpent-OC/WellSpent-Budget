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


class Clicking(unittest.TestCase):
    """What every click test starts from: Robin signed in on a copy of his
    own, and a link to a group of his."""

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


class ClickToJoin(Clicking):

    def test_a_click_opens_the_invitation_and_join_takes_the_group_in(self):
        name, link = self.robins_link()
        leslie = launch_fresh(self)
        leslie.new_group("Mine")
        leslie.new_budget("Snacks", "50", group="Mine")
        # The test server is not the build's own, and a signed-out copy asks
        # the server it last signed in to, so her copy learns it once. Her own
        # account for this test, made now, so "Mine" comes along (SAMP-03):
        # signing in to an account made earlier leaves it on this computer
        # (SAMP-06), and the sidebar would not show it once she signs in.
        leslie.sign_in_as("Leslie click")
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
        leslie.sign_in_on_sheet("Leslie click")
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



class ClickToJoinRefusals(Clicking):
    """The links that do not take a person in: a used one, your own, and the
    other app's. And the two sign-up states a click can meet."""

    def test_a_used_link_your_own_link_and_the_other_apps(self):
        name, link = self.robins_link()
        leslie = launch_fresh(self)
        leslie.sign_in_as("Leslie")
        kim = launch_fresh(self)
        kim.sign_in_as("Kim")

        # Scenario CLICK-10
        # 1. Robin clicks his own link, types his name and presses Join: the
        # page says he is already in that group, and the link is not used up.
        self.assertEqual(0, self.robin.launch_again(link))
        self.robin.until(lambda: invited(name) in self.page(self.robin), "the invitation on Robin's copy")
        self.robin.field("Your name", self.robin.main).type("Robin")
        self.robin.until(lambda: self.robin.button("Join", within=self.robin.main).enabled, "Join to light")
        self.robin.button("Join", within=self.robin.main).press()
        self.robin.until(lambda: "You are already in that group." in self.page(self.robin), "the page to say he is in it")

        # 2. Leslie joins with the same link, which works once.
        self.assertEqual(0, leslie.launch_again(link))
        leslie.until(lambda: leslie.shows("Join", within=leslie.main, role="push button"), "Join for Leslie")
        leslie.field("Your name", leslie.main).type("Leslie")
        leslie.until(lambda: leslie.button("Join", within=leslie.main).enabled, "Join to light")
        leslie.button("Join", within=leslie.main).press()
        leslie.until(lambda: leslie.shows(name.upper(), within=leslie.main, role="push button"), "the group in her sidebar")
        self.addCleanup(leslie.remove_group, name)

        # Scenario CLICK-09
        # 3. Kim clicks the used link: the page still says who invited her,
        # with no level lines, and says the invite was not found. Join
        # anyway says it has already been accepted, and nothing is added.
        self.assertEqual(0, kim.launch_again(link))
        kim.until(lambda: invited(name) in self.page(kim), "the invitation on Kim's copy")
        kim.until(lambda: "That invite was not found. It may have been cancelled." in self.page(kim), "the not-found line")
        self.assertFalse(kim.reads(["You'd join at ", "Add", "."], within=kim.main), "level lines, for a used link")
        kim.field("Your name", kim.main).type("Kim")
        kim.until(lambda: kim.button("Join", within=kim.main).enabled, "Join to light")
        kim.button("Join", within=kim.main).press()
        kim.until(lambda: "That invite has already been accepted." in self.page(kim), "the page to refuse")
        self.assertFalse(kim.shows(name.upper(), within=kim.main, role="push button"), "the group was added anyway")

        # Scenario CLICK-13
        # 4. A link from the other app says which app it is for, with no name
        # field and no Join.
        other = link.replace("wellspent-staging://", "wellspent://", 1)
        self.assertEqual(0, kim.launch_again(other))
        kim.until(lambda: "That invite link is for WellSpent. Open it in WellSpent." in self.page(kim), "the other app's line")
        self.assertFalse(kim.shows("Join", within=kim.main, role="push button"), "Join, for the other app's link")
        self.assertFalse(kim.shows("Your name", within=kim.main), "a name field, for the other app's link")

    def test_the_page_waits_through_confirming_and_making_an_account(self):
        name, link = self.robins_link()
        pat = launch_fresh(self)
        # The test server is not the build's own: the copy learns it once.
        pat.sign_in_as("Pat")
        pat.sign_out()

        # Scenario CLICK-07
        # 1. With no account signed in, Pat clicks the link and types a name,
        # then Sign in…, and makes a new account there, confirming the email
        # with the code. The page is still up, the name still typed, and Join
        # lit; it takes Pat into the group.
        self.assertEqual(0, pat.launch_again(link))
        pat.until(lambda: invited(name) in self.page(pat), "the invitation")
        pat.field("Your name", pat.main).type("Pat")
        pat.button("Sign in…", within=pat.main).press()
        pat.sign_up_on_sheet("Pat Two")
        pat.until(lambda: pat.shows("Join", within=pat.main, role="push button"), "Join once signed up")
        self.assertIn(invited(name), self.page(pat))
        self.assertEqual("Pat", pat.field("Your name", pat.main).text)
        pat.until(lambda: pat.button("Join", within=pat.main).enabled, "Join lit")
        pat.button("Join", within=pat.main).press()
        pat.until(lambda: pat.shows(name.upper(), within=pat.main, role="push button"), "the group in the sidebar")
        self.addCleanup(pat.remove_group, name)

    def test_not_confirmed_yet_confirm_your_email_stands_in_place_of_join(self):
        name, link = self.robins_link()
        quinn = launch_fresh(self)
        quinn.sign_in_as("Quinn")
        quinn.sign_out()
        quinn.sign_up_unconfirmed("Quinn Two")

        # Scenario CLICK-06
        # 1. Signed in but not confirmed, the page says to confirm first, with
        # Confirm your email… and no Join. Confirming there brings Join.
        self.assertEqual(0, quinn.launch_again(link))
        quinn.until(lambda: "Confirm your email first. Joining a shared group needs it." in self.page(quinn), "the confirm line")
        self.assertFalse(quinn.shows("Join", within=quinn.main, role="push button"), "Join, before confirming")
        quinn.button("Confirm your email…", within=quinn.main).press()
        quinn.confirm_on_sheet()
        quinn.until(lambda: quinn.shows("Join", within=quinn.main, role="push button"), "Join once confirmed")
        self.assertIn(invited(name), self.page(quinn))


if __name__ == "__main__":
    unittest.main()
