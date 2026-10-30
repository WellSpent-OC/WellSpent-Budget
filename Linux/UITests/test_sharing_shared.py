"""Sharing a group between people (Features/Sharing.md), each in a copy of the
app of their own: who may invite at which level, joining with a pasted link
and what stops it, what each level then sees and may change, entries
reaching the others, leaving, and removing someone.

Each person's account is made once per run and signed into after that, so
these are skipped without the test mailbox's token. Each test names its group
for itself and removes it at the end."""

import datetime
import unittest

from wellspent_ui import STAGING, launch_fresh, needs_accounts, unique

LEAVE = ("You leave the group, and it is removed from all your devices, with its 1 budget and 2 "
         "transactions. The others in it keep it. ")
CHANGES = ("Anything you changed in it on this device that has not synced yet still goes to them first. "
           "Changes on your other devices that have not synced yet do not reach them. ")
ONLY = ("Only the person who made it, or an admin, can delete it for everyone. "
        "To come back, ask for a new invite link.")


class SharingShared(unittest.TestCase):

    def setUp(self):
        needs_accounts(self)
        self.robin = launch_fresh(self)
        self.leslie = launch_fresh(self)

    def robins_group(self, *entries):
        """A group of Robin's with one budget, $800 a month, holding
        `entries` (merchant, amount) of his, removed at the end of the test.
        Gives back its name and the budget's."""
        robin = self.robin
        robin.sign_in_as("Robin")
        name = unique("Flat")
        robin.new_group(name)
        self.addCleanup(robin.remove_group, name)
        food = f"{name} food"
        robin.new_budget(food, "800", group=name)
        for merchant, amount in entries:
            robin.add_entry(merchant, amount)
        robin.sync()
        return name, food

    def join_sheet(self, app):
        app.pick("Join a Group…", app.open_menu(app.button("More", within=app.main)))
        return app.wait_for_window(2, "the Join a Group sheet")

    def merchants(self, app, budget):
        app.budget(budget).press()
        app.until(lambda: app.reads([budget], within=app.main), f"{budget} to open")
        return {row[1]: row for row in app.entries()}

    def says(self, app, group, words):
        """Waits for the line under a group's name on its page to say
        `words`. Invite Someone… can sit between the two."""
        def line_under():
            texts = app.texts(app.main)
            return group in texts and words in texts[texts.index(group) + 1:texts.index(group) + 3]
        app.until(line_under, f"{words!r} under {group}")

    def menu_of(self, app, group):
        menu = app.group_menu(group)
        items = app.menu_items(menu)
        app.close_menu(menu)
        return items

    def test_who_may_invite_and_at_what_level(self):
        robin, leslie = self.robin, self.leslie
        leslie.sign_in_as("Leslie")
        flat, food = self.robins_group()
        leslie.join(robin.legacy_invite(flat, "Robin", "Manage"), "Leslie")
        leslie.sync()

        # Scenario SHARE-12
        # 1. At Manage, Leslie's menu offers a new budget and Rename…, and ends
        # with Leave…. The budget offers Edit…, Delete…, Add and Import
        # statement.
        items = self.menu_of(leslie, flat)
        self.assertIn(f"New Budget in {flat}…", items)
        self.assertIn("Rename…", items)
        self.assertEqual("Leave…", items[-1])
        leslie.budget(food).press()
        leslie.until(lambda: leslie.reads([food], within=leslie.main), f"{food} to open")
        for button in ("Edit…", "Delete…", "Add", "Import statement"):
            leslie.button(button, within=leslie.main)

        # Scenario SHARE-06
        # 2. A manager may invite at View or Add only, Add chosen.
        leslie.pick("Share…", leslie.group_menu(flat))
        sheet = leslie.wait_for_window(2, "the Share sheet")
        role = [e for e in sheet.all("combo box") if e.showing][0]
        self.assertEqual("Add", role.words)
        self.assertEqual(["View", "Add"], leslie.offered(role))
        leslie.button("Cancel", within=sheet).press()
        leslie.wait_for_window(1, "the Share sheet to close")

        # Scenario SHARE-05
        # 3. At Add, she may invite nobody: the sheet says why, offers no
        # level, and Send Invite stays dimmed even with its fields filled.
        robin.set_level(flat, "Leslie", "Add")
        leslie.sync()
        leslie.pick("Share…", leslie.group_menu(flat))
        sheet = leslie.wait_for_window(2, "the Share sheet")
        leslie.wait_shows("Only a manager or admin can invite people to this group.", within=sheet)
        self.assertFalse(leslie.shows("They can", within=sheet))
        self.assertEqual(1, len([e for e in sheet.all("combo box") if e.showing]), "a level to choose")
        leslie.field("Your name", sheet).type("Leslie")
        leslie.field("Their email", sheet).type(robin.email)
        leslie.field("Their name", sheet).type("Robin")
        self.assertFalse(leslie.button("Send Invite", within=sheet).enabled)
        leslie.button("Cancel", within=sheet).press()
        leslie.wait_for_window(1, "the Share sheet to close")

    def test_joining_with_a_pasted_link_and_entries_after(self):
        robin, leslie = self.robin, self.leslie
        kim = launch_fresh(self)
        leslie.sign_in_as("Leslie")
        kim.sign_in_as("Kim")
        flat, food = self.robins_group(("Hilltop Grocery", "42.00"))

        # Scenario SHARE-14
        # 1. With nobody else in it, Robin's list has no Added by.
        self.assertEqual(4, len(self.merchants(robin, food)["Hilltop Grocery"]), "an Added by column")
        link = robin.legacy_invite(flat, "Robin", "Add")

        # Scenario SHARE-07
        # 2. Join a Group… asks for the link, with a hint in the empty box,
        # and for her name.
        sheet = self.join_sheet(leslie)
        self.assertIn("Join a Group", leslie.texts(sheet))
        box = leslie.field("Invite link", sheet)
        self.assertEqual("Paste the link you were sent", box.placeholder)
        leslie.field("Your name", sheet)
        join = leslie.button("Join", within=sheet)

        # Scenario SHARE-08
        # 3. A web address, then the link cut short: each says what's wrong,
        # and Join stays dimmed.
        for pasted, said in (("https://wellspent.space/help", "That is not a WellSpent invite link."),
                             (link[:len(link) // 2], "Part of that invite link is missing. Ask the person "
                                                     "who sent it to send it again.")):
            box.type(pasted)
            leslie.wait_shows(said, within=sheet)
            self.assertFalse(join.enabled)

        # Scenario SHARE-07, EMAIL-08
        # 4. The whole link says who invited her where. Join stays dimmed until
        # she types her name. Joined, the sheet closes, and the group is hers,
        # with Robin's entry marked as his.
        box.type(link)
        leslie.wait_shows(f"Robin invited you to “{flat}”.", within=sheet)
        self.assertFalse(join.enabled)
        leslie.field("Your name", sheet).type("Leslie")
        leslie.until(lambda: join.enabled, "Join to light")
        join.press()
        leslie.wait_for_window(1, "the Join a Group sheet to close")
        leslie.group(flat)
        self.assertIn("Robin", self.merchants(leslie, food)["Hilltop Grocery"])

        # Scenario SHARE-10
        # 5. Kim pastes the same link: it was used, and she isn't added.
        sheet = self.join_sheet(kim)
        kim.field("Invite link", sheet).type(link)
        kim.field("Your name", sheet).type("Kim")
        kim.until(lambda: kim.button("Join", within=sheet).enabled, "Join to light")
        kim.button("Join", within=sheet).press()
        kim.wait_shows("That invite has already been accepted.", within=sheet)
        kim.button("Cancel", within=sheet).press()
        kim.wait_for_window(1, "the Join a Group sheet to close")
        self.assertFalse(kim.shows(flat.upper(), within=kim.main))

        # Scenario SHARE-14
        # 6. Leslie adds Costco, $99.00, and her app sends it by itself.
        # Robin's Sync brings it, marked Leslie, with his own marked You, and
        # both their totals count it.
        leslie.add_entry("Costco", "99.00")
        robin.until(lambda: robin.sync() or "Costco" in self.merchants(robin, food), "Costco at Robin's sync",
                    wait=60)
        rows = self.merchants(robin, food)
        self.assertIn("Leslie", rows["Costco"])
        self.assertIn("You", rows["Hilltop Grocery"])
        for app in (robin, leslie):
            app.until(lambda: app.budget(food).words == f"{food} $659.00", f"{food} to count Costco")

    def test_view_and_only_from_now_on(self):
        robin, leslie = self.robin, self.leslie
        kim = launch_fresh(self)
        leslie.sign_in_as("Leslie")
        kim.sign_in_as("Kim")
        flat, food = self.robins_group(("Hilltop Grocery", "42.00"))

        # Scenario SHARE-11
        # 1. At View, Leslie sees Robin's entry, marked his, with no Add and
        # no Import statement. The group offers her only Share…, People… and
        # Leave…, and nothing offers to change the budget.
        leslie.join(robin.legacy_invite(flat, "Robin", "View"), "Leslie")
        leslie.sync()
        self.assertIn("Robin", self.merchants(leslie, food)["Hilltop Grocery"])
        for button in ("Add", "Import statement", "Edit…", "Delete…"):
            self.assertFalse(leslie.shows(button, within=leslie.main, role="push button"), button)
        self.assertEqual(["Share…", "People…", "Leave…"], self.menu_of(leslie, flat))

        # Scenario SHARE-13
        # 2. Kim joins with Only from now on: Hilltop Grocery is hidden from
        # her, and her total leaves it out.
        link = robin.legacy_invite(flat, "Robin", history="fromNow")
        kim.join(link.replace("\n", "").replace(" ", ""), "Kim")
        kim.sync()
        self.assertEqual({}, self.merchants(kim, food))
        self.assertEqual(f"{food} $800.00", kim.budget(food).words)

        # Scenario SHARE-13
        # 3. Costco, added by Robin after she joined, reaches her. Hilltop
        # Grocery stays hidden, even after Robin changes it.
        robin.budget(food).press()
        robin.add_entry("Costco", "99.00")
        robin.entry("Hilltop Grocery").press()
        editor = robin.wait_for_window(2, "Hilltop Grocery to open")
        robin.field("Amount", editor).type("45.00")
        robin.button("Save", within=editor).press()
        robin.wait_for_window(1, "Hilltop Grocery to close")
        robin.sync()
        kim.until(lambda: kim.sync() or "Costco" in self.merchants(kim, food), "Costco at Kim's sync", wait=60)
        self.assertEqual(["Costco"], list(self.merchants(kim, food)))

    def test_joining_needs_a_sign_in_and_a_confirmed_email(self):
        robin, leslie = self.robin, self.leslie
        flat, _ = self.robins_group()
        link = robin.legacy_invite(flat, "Robin", "Add")

        # Scenario SHARE-09
        # 1. Signed out, the link says to sign in first, and Join stays dimmed.
        sheet = self.join_sheet(leslie)
        leslie.field("Invite link", sheet).type(link)
        leslie.field("Your name", sheet).type("Leslie")
        leslie.wait_shows("Sign in first, or create an account. Joining adds the group to your account.",
                          within=sheet)
        self.assertFalse(leslie.button("Join", within=sheet).enabled)
        leslie.button("Cancel", within=sheet).press()
        leslie.wait_for_window(1, "the Join a Group sheet to close")

        # Scenario SHARE-09
        # 2. Signed in to an account whose email isn't confirmed, the sheet
        # says to confirm it first. Join anyway also says so, and she isn't
        # added.
        self.sign_up_without_confirming(leslie)
        sheet = self.join_sheet(leslie)
        leslie.field("Invite link", sheet).type(link)
        leslie.field("Your name", sheet).type("Leslie")
        leslie.wait_shows("Confirm your email first. Joining a shared group needs it.", within=sheet)
        leslie.until(lambda: leslie.button("Join", within=sheet).enabled, "Join to light")
        leslie.button("Join", within=sheet).press()
        leslie.wait_shows("Confirm your email address first, then try again.", within=sheet)
        self.assertFalse(leslie.shows(flat.upper(), within=leslie.main))

        # Scenario SHARE-09
        # 3. Confirm your email… closes the sheet and opens the account sheet.
        leslie.button("Confirm your email…", within=sheet).press()
        leslie.until(lambda: len(leslie.windows()) == 2 and not leslie.shows("Join a Group", within=leslie.front),
                     "the account sheet in place of the Join sheet")
        leslie.wait_shows("Your account", within=leslie.front)

    def sign_up_without_confirming(self, app):
        """Create an account, then Not now at the emailed code: signed in, the
        email not confirmed."""
        email = f"linux-unconfirmed-{datetime.datetime.now():%m%d%H%M%S%f}@example.com"
        app.button("Sign in", within=app.main).press()
        sheet = app.wait_for_window(2, "the account sheet")
        if STAGING != "https://staging.wellspent.space":
            app.field("Server", sheet).type(STAGING)
        app.button("Create an account", within=sheet).press()
        app.wait_shows("Confirm password")
        password = "unconfirmed-" + email
        app.field("Email", app.front).type(email)
        app.field("Password", app.front).type(password)
        app.field("Confirm password", app.front).type(password)
        app.button("Create account", within=app.front).press()
        app.wait_shows("Confirm your email")
        app.button("Not now", within=app.front).press()
        app.wait_for_window(1, "the account sheet to close")
        app.button("Account", within=app.main)

    def test_leaving_and_removing(self):
        robin, leslie = self.robin, self.leslie
        leslie.sign_in_as("Leslie")
        flat, food = self.robins_group(("Hilltop Grocery", "42.00"))
        leslie.join(robin.legacy_invite(flat, "Robin", "Add"), "Leslie")
        leslie.sync()
        self.merchants(leslie, food)
        leslie.add_entry("Costco", "99.00")
        leslie.sync()
        elsewhere = launch_fresh(self)
        elsewhere.sign_in_as("Leslie")
        elsewhere.group(flat)

        # Scenario SHARE-15
        # 1. Leslie's menu ends with Leave…, not Delete…. It asks first, with
        # every sentence about what leaving does.
        items = self.menu_of(leslie, flat)
        self.assertEqual("Leave…", items[-1])
        self.assertNotIn("Delete…", items)
        leslie.pick("Leave…", leslie.group_menu(flat))
        self.assertEqual(f"Leave “{flat}”? " + LEAVE + CHANGES + ONLY, leslie.question())
        leslie.button("Cancel", within=leslie.front)

        # Scenario SHARE-15
        # 2. Leave: the group goes from her sidebar, and from her other
        # computer at its next sync. Robin keeps it, her entry included, and
        # after his sync its page lists only him.
        leslie.answer("Leave")
        leslie.until(lambda: not leslie.shows(flat.upper(), within=leslie.main), f"{flat} to go")
        # The leave reaches the server in her app's next sync, a moment later
        # by itself, after anything of hers not yet sent.
        leslie.sync()
        elsewhere.sync()
        elsewhere.until(lambda: not elsewhere.shows(flat.upper(), within=elsewhere.main), f"{flat} to go there")
        robin.sync()
        self.assertEqual({"Hilltop Grocery", "Costco"}, set(self.merchants(robin, food)))
        robin.group(flat).press()
        self.says(robin, flat, "Not shared · Made by you")

        # Scenario SHARE-15
        # 3. A new link brings it back to her, whole. At View, leaving asks
        # without the two sentences about changes not synced.
        leslie.join(robin.legacy_invite(flat, "Robin", "View"), "Leslie")
        leslie.sync()
        self.assertEqual({"Hilltop Grocery", "Costco"}, set(self.merchants(leslie, food)))
        leslie.pick("Leave…", leslie.group_menu(flat))
        self.assertEqual(f"Leave “{flat}”? " + LEAVE + ONLY, leslie.question())
        leslie.answer("Cancel")

        # Scenario SHARE-16
        # 4. Robin removes her from the page. It asks first, then her row goes,
        # the page says so, and the line under the name says it isn't shared.
        robin.sync()
        robin.group(flat).press()
        robin.find("push button", "Remove…", within=robin.person("Leslie")).press()
        self.assertEqual(f"Remove Leslie? Leslie loses “{flat}” on every device. What they added stays.",
                         robin.question())
        robin.button("Cancel", within=robin.front)
        robin.answer("Remove")
        robin.wait_shows("Leslie was removed.", within=robin.main)
        self.says(robin, flat, "Not shared · Made by you")
        self.assertFalse(robin.shows("Leslie", within=robin.main, role="label"))

        # Scenario SHARE-16
        # 5. Costco stays in his budget, and the group goes from her sidebar at
        # her next sync.
        self.assertIn("Costco", self.merchants(robin, food))
        leslie.sync()
        leslie.until(lambda: not leslie.shows(flat.upper(), within=leslie.main), f"{flat} to leave her sidebar")


if __name__ == "__main__":
    unittest.main()
