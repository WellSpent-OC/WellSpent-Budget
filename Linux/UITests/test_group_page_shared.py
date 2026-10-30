"""A group's page with more than one person (Features/GroupPage.md), each in a
copy of the app of their own: the line under the name, the people and their
levels, what each level may change there, someone joining while it's open,
leaving, and what someone removed leaves behind.

Each person's account is made once per run and signed into after that, so
these are skipped without the test mailbox's token. Each test names its group
for itself and removes it at the end."""

import unittest

from wellspent_ui import launch_fresh, needs_accounts, unique

OWNER = "Made the group. Can do everything, and delete it for everyone."
ADMIN = "Can do what a manager does, and make or remove other managers and admins."
MANAGE = "Edits budgets, edits or deletes anyone's transactions, and invites other people."
ADD = "Adds transactions, and edits or deletes their own."
VIEW = "Sees every budget and transaction. Changes nothing."


def line(*parts):
    """The line under a group's name: "Shared · 2 people · Made by you"."""
    return " · ".join(parts)


class GroupPageShared(unittest.TestCase):

    def setUp(self):
        needs_accounts(self)
        self.robin = launch_fresh(self)
        self.leslie = launch_fresh(self)

    def robins_group(self):
        """A group of Robin's with one budget, removed at the end of the test.
        Gives back its name and the budget's."""
        robin = self.robin
        robin.sign_in_as("Robin")
        name = unique("Flat")
        robin.new_group(name)
        self.addCleanup(robin.remove_group, name)
        food = f"{name} food"
        robin.new_budget(food, "800", group=name)
        robin.sync()
        return name, food

    def open_page(self, app, group):
        app.group(group).press()
        app.until(lambda: app.reads([group], within=app.main) and not app.budget_open(), f"{group}'s page")

    def says(self, app, group, words):
        """Waits for the line under the group's name to say `words`. Invite
        Someone… can sit between the two."""
        def line_under():
            texts = app.texts(app.main)
            return group in texts and words in texts[texts.index(group) + 1:texts.index(group) + 3]
        app.until(line_under, f"{words!r} under {group}")

    def test_the_line_the_people_and_someone_joining(self):
        robin, leslie = self.robin, self.leslie
        leslie.sign_in_as("Leslie")
        flat, _ = self.robins_group()

        # Scenario PAGE-06, PAGE-15
        # 1. Nobody else in it: "Not shared · Made by you", and Robin alone.
        self.open_page(robin, flat)
        self.says(robin, flat, line("Not shared", "Made by you"))

        # Scenario PAGE-15
        # 2. Leslie joins with Robin's link while the page is open. At his
        # next sync her row shows, and the line says so.
        link = robin.legacy_invite(flat, "Robin", "Add")
        leslie.join(link, "Leslie")
        robin.sync()
        self.says(robin, flat, line("Shared", "2 people", "Made by you"))
        robin.person("Leslie")

        # Scenario PAGE-06
        # 3. On Leslie's page, it was made by Robin.
        leslie.sync()
        self.open_page(leslie, flat)
        self.says(leslie, flat, line("Shared", "2 people", "Made by Robin"))

        # Scenario PAGE-15
        # 4. A page opened after she joined shows her at once.
        robin.budget(f"{flat} food").press()
        robin.until(lambda: robin.budget_open(), "the budget to open")
        self.open_page(robin, flat)
        robin.person("Leslie")

        # Scenario PAGE-08
        # 5. Under PEOPLE, Robin first, at Owner, then Leslie at Add, each with
        # what the level lets them do.
        texts = robin.texts(robin.main)
        self.assertIn("PEOPLE", texts)
        self.assertEqual(["Robin (you)", OWNER], texts[texts.index("Robin (you)"):texts.index("Robin (you)") + 2])
        self.assertEqual(["Leslie", ADD], texts[texts.index("Leslie"):texts.index("Leslie") + 2])
        self.assertLess(texts.index("PEOPLE"), texts.index("Robin (you)"))
        self.assertLess(texts.index("Robin (you)"), texts.index("Leslie"))

        # Scenario PAGE-09
        # 6. Robin, the owner, may change Leslie's level, among View, Add,
        # Manage and Admin, and remove her. His own row is a label, and has no
        # Remove…. He may invite, and has no Leave Group….
        self.assertEqual(("Add", True), robin.level("Leslie"))
        self.assertEqual(["View", "Add", "Manage", "Admin"], robin.offered(robin.level_list("Leslie")))
        robin.find("push button", "Remove…", within=robin.person("Leslie"))
        self.assertEqual(("Owner", False), robin.level("Robin (you)"))
        self.assertEqual([], robin.person("Robin (you)").all("push button", "Remove…"))
        robin.button("Invite Someone…", within=robin.main)
        self.assertFalse(robin.shows("Leave Group…", within=robin.main))
        robin.picture("desktop-shared-group")

    def test_levels_from_the_page_and_leaving(self):
        robin, leslie = self.robin, self.leslie
        leslie.sign_in_as("Leslie")
        flat, food = self.robins_group()
        leslie.join(robin.legacy_invite(flat, "Robin", "Add"), "Leslie")
        robin.sync()
        leslie.sync()

        # Scenario PAGE-12
        # 1. At Add, Leslie's page shows labels only: Robin at Owner, herself
        # at Add. No level list, no Remove…, no Invite Someone…, and Leave
        # Group… at the bottom.
        self.open_page(leslie, flat)
        self.assertEqual(("Owner", False), leslie.level("Robin"))
        self.assertEqual(("Add", False), leslie.level("Leslie (you)"))
        self.assertEqual([], [e for e in leslie.main.all("combo box") if e.showing])
        self.assertFalse(leslie.shows("Remove…", within=leslie.main))
        self.assertFalse(leslie.shows("Invite Someone…", within=leslie.main))
        leslie.button("Leave Group…", within=leslie.main)

        # Scenario PAGE-10
        # 2. Robin picks View on her row: it says what View lets her do. Once
        # her app syncs, her budget offers no Add and no Import statement.
        self.open_page(robin, flat)
        robin.choose("View", robin.level_list("Leslie"))
        robin.until(lambda: robin.reads(["Leslie", VIEW], within=robin.main), "View's words on her row")
        robin.sync()
        leslie.sync()
        leslie.budget(food).press()
        leslie.until(lambda: leslie.reads([food], within=leslie.main), f"{food} to open")
        self.assertFalse(leslie.shows("Add", within=leslie.main, role="push button"))
        self.assertFalse(leslie.shows("Import statement", within=leslie.main, role="push button"))

        # Scenario PAGE-12
        # 3. At View, her page is the same, with View as her label.
        self.open_page(leslie, flat)
        self.assertEqual(("View", False), leslie.level("Leslie (you)"))
        self.assertEqual([], [e for e in leslie.main.all("combo box") if e.showing])
        leslie.button("Leave Group…", within=leslie.main)

        # Scenario PAGE-10
        # 4. Admin instead: her row says what an admin may do.
        robin.choose("Admin", robin.level_list("Leslie"))
        robin.until(lambda: robin.reads(["Leslie", ADMIN], within=robin.main), "Admin's words on her row")
        robin.sync()

        # Scenario PAGE-14
        # 5. As an admin, Leslie's menu for the group offers Delete…. Leave
        # Group… on the page asks first, and Cancel changes nothing.
        leslie.sync()
        menu = leslie.group_menu(flat)
        self.assertIn("Delete…", leslie.menu_items(menu))
        leslie.close_menu(menu)
        self.open_page(leslie, flat)
        leslie.button("Leave Group…", within=leslie.main).press()
        question = leslie.question()
        self.assertTrue(question.startswith(f"Leave “{flat}”? You leave the group, and it is removed from all "
                                            "your devices"), question)
        leslie.button("Leave", within=leslie.front)
        leslie.answer("Cancel")
        self.assertTrue(leslie.reads([flat], within=leslie.main))
        leslie.group(flat)

        # Scenario PAGE-14
        # 6. Leave: the group and its page go from her computer. Robin keeps
        # it, and after his next sync his page lists only him.
        leslie.button("Leave Group…", within=leslie.main).press()
        leslie.answer("Leave")
        leslie.until(lambda: not leslie.shows(flat.upper(), within=leslie.main), f"{flat} to go")
        self.assertFalse(leslie.reads([flat], within=leslie.main))
        # The leave reaches the server in her app's next sync, a moment later
        # by itself, after anything of hers not yet sent.
        leslie.sync()
        robin.sync()
        self.open_page(robin, flat)
        self.says(robin, flat, line("Not shared", "Made by you"))
        robin.wait_gone("Leslie", within=robin.main)
        robin.budget(food)

    def test_a_manager_and_someone_removed(self):
        robin, leslie = self.robin, self.leslie
        kim = launch_fresh(self)
        leslie.sign_in_as("Leslie")
        kim.sign_in_as("Kim")
        flat, food = self.robins_group()
        leslie.join(robin.legacy_invite(flat, "Robin", "Manage"), "Leslie")
        kim.join(robin.legacy_invite(flat, "Robin", "Add"), "Kim")
        for app in (robin, leslie, kim):
            app.sync()

        # Scenario PAGE-11
        # 1. Leslie, at Manage, may change and remove only Kim, at Add, and
        # only to View or Add. Robin and she show labels, with no Remove….
        # She may invite, and Leave Group… is at the bottom.
        self.open_page(leslie, flat)
        self.assertEqual(("Add", True), leslie.level("Kim"))
        self.assertEqual(["View", "Add"], leslie.offered(leslie.level_list("Kim")))
        leslie.find("push button", "Remove…", within=leslie.person("Kim"))
        self.assertEqual(("Owner", False), leslie.level("Robin"))
        self.assertEqual(("Manage", False), leslie.level("Leslie (you)"))
        for person in ("Robin", "Leslie (you)"):
            self.assertEqual([], leslie.person(person).all("push button", "Remove…"), person)
        leslie.button("Invite Someone…", within=leslie.main)
        leslie.button("Leave Group…", within=leslie.main)

        # Scenario PAGE-17
        # 2. Kim adds Costco, then Robin removes Kim from the page.
        kim.budget(food).press()
        kim.until(lambda: kim.reads([food], within=kim.main), f"{food} to open")
        kim.add_entry("Costco", "286.31")
        kim.sync()
        self.open_page(robin, flat)
        robin.find("push button", "Remove…", within=robin.person("Kim")).press()
        self.assertEqual(f"Remove Kim? Kim loses “{flat}” on every device. What they added stays.",
                         robin.question())
        robin.answer("Remove")
        robin.wait_shows("Kim was removed.", within=robin.main)

        # Scenario PAGE-17
        # 3. At the next sync, Costco is still there for Robin and Leslie,
        # added by Kim, and each of them, at Manage or above, may delete it.
        # Kim no longer has the group.
        for app in (robin, leslie):
            app.sync()
            app.budget(food).press()
            row = app.until(lambda: next((r for r in app.entries() if r[1] == "Costco"), None), "Costco")
            self.assertIn("Kim", row)
            app.entry("Costco").press()
            editor = app.wait_for_window(2, "Costco to open")
            app.button("Delete…", within=editor)
            app.button("Cancel", within=editor).press()
            app.wait_for_window(1, "Costco to close")
        kim.sync()
        kim.until(lambda: not kim.shows(flat.upper(), within=kim.main), f"{flat} to leave Kim's computer")


if __name__ == "__main__":
    unittest.main()
