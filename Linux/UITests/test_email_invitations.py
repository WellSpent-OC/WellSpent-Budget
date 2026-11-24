"""Addressed invitations in two real apps: no membership before Accept,
all budgets after it, and rejection or cancellation ending the invitation.
The server's test mailbox captures delivery; no recipient is a real person.
"""

import unittest

from wellspent_ui import launch_fresh, needs_accounts, unique

# What every app says for a server it can't reach (AccountWording, for
# URLError.cannotConnectToHost, the failure switch's own error).
UNREACHABLE = "Could not reach the server. Check its address and your connection."


class EmailInvitations(unittest.TestCase):

    def setUp(self):
        needs_accounts(self)
        self.robin = launch_fresh(self)
        self.leslie = launch_fresh(self)
        self.robin.sign_in_as("Robin")
        self.leslie.sign_in_as("Leslie")
        self.group = unique("Home")
        self.robin.new_group(self.group)
        self.addCleanup(self.robin.remove_group, self.group)
        self.robin.new_budget("Food", "500", group=self.group)
        self.robin.add_entry("Hilltop Grocery", "12.50")
        self.robin.new_budget("Travel", "200", group=self.group)
        self.robin.sync()

    def send(self):
        self.robin.invite(self.group, "Robin", self.leslie.email, "Leslie")
        self.robin.group(self.group).press()
        self.robin.wait_shows(self.leslie.email, within=self.robin.main)
        self.robin.near("label", "Pending", to=self.robin.find("label", self.leslie.email,
                                                               within=self.robin.main))
        self.leslie.sync()
        self.leslie.invitation_button(self.group, "Accept")

    def test_pending_survives_reopening_and_accept_brings_all_budgets(self):
        robin, leslie = self.robin, self.leslie

        # Scenario EMAIL-01, EMAIL-02
        self.send()
        self.assertTrue(leslie.shows("Invited", within=leslie.main))
        self.assertTrue(leslie.shows("Invited by Robin", within=leslie.main))
        self.assertFalse(leslie.shows(self.group.upper(), within=leslie.main, role="push button"))
        self.assertFalse(leslie.has_budget("Food"))
        self.assertFalse(leslie.has_budget("Travel"))

        leslie.picture("email-invitation-inbox")

        # Both answers fit on one line in the normal-width sidebar. Compare
        # with another native button so the check follows the desktop theme.
        single_line_height = leslie.button("Account", within=leslie.main).height
        self.assertGreater(single_line_height, 0)
        for action in ("Reject", "Accept"):
            height = leslie.invitation_button(self.group, action).height
            self.assertGreater(height, 0)
            self.assertLessEqual(height, single_line_height + 2,
                                 f"{action} wraps in the invitation row")

        # Scenario EMAIL-07
        leslie.restart()
        leslie.sync()
        leslie.invitation_button(self.group, "Accept")
        self.assertFalse(leslie.has_budget("Food"))

        # Scenario EMAIL-03
        leslie.accept_invitation(self.group)
        leslie.until(lambda: len(leslie.budgets_in(self.group)) == 2, "both budgets after accepting")
        self.assertEqual({"Food $487.50", "Travel $200.00"}, set(leslie.budgets_in(self.group)))
        self.assertTrue(leslie.shows(self.group, within=leslie.main))
        self.assertFalse(leslie.shows("Accept", within=leslie.main, role="push button"))
        self.assertEqual(1, len(leslie.windows()), "acceptance asked for another form")
        leslie.budget("Food").press()
        leslie.until(lambda: any(row[1] == "Hilltop Grocery" for row in leslie.entries()),
                     "the existing transaction after accepting")
        robin.sync()
        robin.person("Leslie")
        self.assertFalse(robin.shows(self.leslie.email, within=robin.main), "a pending row remains")

    def test_reject_ends_the_invitation_until_a_fresh_one_is_sent(self):
        robin, leslie = self.robin, self.leslie
        self.send()

        # Scenario EMAIL-04
        leslie.invitation_button(self.group, "Reject").press()
        self.assertIn("To join later, ask for a new invitation.", leslie.question())
        leslie.answer("Cancel")
        leslie.invitation_button(self.group, "Accept")
        leslie.reject_invitation(self.group)
        self.assertFalse(leslie.has_budget("Food"))
        robin.sync()
        robin.near("label", "Rejected", to=robin.find("label", leslie.email, within=robin.main))
        self.assertFalse(robin.shows("Cancel Invite", within=robin.main, role="push button"))
        leslie.restart()
        leslie.sync()
        self.assertFalse(leslie.shows(self.group.upper(), within=leslie.main))

        robin.invite(self.group, "Robin", leslie.email, "Leslie")
        leslie.sync()
        leslie.accept_invitation(self.group)
        leslie.until(lambda: len(leslie.budgets_in(self.group)) == 2, "both budgets from a new invitation")

    def test_an_accept_or_reject_that_cant_reach_the_server_says_so(self):
        robin, leslie = self.robin, self.leslie
        self.send()

        def still_invited():
            """The invitation is in her list with Accept and Reject, she isn't
            in the group, and the server still holds it as pending."""
            leslie.invitation_button(self.group, "Accept")
            leslie.invitation_button(self.group, "Reject")
            self.assertFalse(leslie.shows(self.group.upper(), within=leslie.main, role="push button"),
                             "the group shows as joined")
            self.assertFalse(leslie.has_budget("Food"))
            self.assertFalse(leslie.has_budget("Travel"))
            robin.sync()
            robin.near("label", "Pending", to=robin.find("label", leslie.email, within=robin.main))

        # Scenario EMAIL-10
        # 1. Accept can't reach the server: the app says so, and she is not in
        # the group, and the invitation stays with Accept and Reject.
        leslie.set_faults("invitation.accept", "invitation.reject")
        leslie.invitation_button(self.group, "Accept").press()
        leslie.wait_shows(UNREACHABLE, within=leslie.main)
        still_invited()

        # Scenario EMAIL-10
        # 2. Reject can't either: the app says so, and the invitation isn't
        # gone. Reopened first, so the Accept's words are gone and these are
        # the Reject's own.
        leslie.restart()
        leslie.sync()
        leslie.invitation_button(self.group, "Reject")
        self.assertFalse(leslie.shows(UNREACHABLE, within=leslie.main), "the Accept's failure outlived a restart")
        leslie.invitation_button(self.group, "Reject").press()
        leslie.answer("Reject")
        leslie.wait_shows(UNREACHABLE, within=leslie.main)
        still_invited()

        # Scenario EMAIL-10
        # 3. With the server in reach, Accept again: she is in the group, as
        # in EMAIL-03, with both budgets, and Robin's Pending row goes.
        leslie.set_faults()
        leslie.accept_invitation(self.group)
        leslie.until(lambda: len(leslie.budgets_in(self.group)) == 2, "both budgets after accepting")
        self.assertEqual({"Food $487.50", "Travel $200.00"}, set(leslie.budgets_in(self.group)))
        # The invitation, and its failure with it, is gone from her list.
        self.assertFalse(leslie.shows("Accept", within=leslie.main, role="push button"), "the invitation stayed")
        robin.sync()
        robin.person("Leslie")
        self.assertFalse(robin.shows(leslie.email, within=robin.main), "a pending row remains")

    def accepted_but_unheard(self):
        """Leslie presses Accept, the server takes it, and its answer never
        reaches her app, so the app says it couldn't reach the server."""
        leslie = self.leslie
        self.send()
        leslie.set_faults("invitation.accept.answerLost")
        leslie.invitation_button(self.group, "Accept").press()
        leslie.wait_shows(UNREACHABLE, within=leslie.main)
        leslie.set_faults()

    def joined(self):
        """She is in the group, as in EMAIL-03, with both budgets. Nothing says
        the invitation was accepted already, and the invitation, with its
        failure, is gone from her list. The sidebar's footer can still say the
        earlier sync failed: that is ops#379, not this scenario."""
        robin, leslie = self.robin, self.leslie
        leslie.until(lambda: len(leslie.budgets_in(self.group)) == 2, "both budgets after accepting")
        self.assertEqual({"Food $487.50", "Travel $200.00"}, set(leslie.budgets_in(self.group)))
        self.assertFalse(leslie.shows("Accept", within=leslie.main, role="push button"), "the invitation stayed")
        self.assertFalse(leslie.shows("Invited by Robin", within=leslie.main), "the invitation stayed")
        said = [t for t in leslie.texts(leslie.main) if "already" in t.lower()]
        self.assertEqual([], said, "an error about the invitation being accepted already")
        robin.sync()
        robin.person("Leslie")
        self.assertFalse(robin.shows(leslie.email, within=robin.main), "a pending row remains")

    def test_accepting_again_after_a_lost_answer_joins(self):
        # Scenario EMAIL-12
        # 1. The server took her Accept, and its answer was lost.
        self.accepted_but_unheard()

        # Scenario EMAIL-12
        # 2. She presses Accept again: she is in the group, with no error
        # about it being accepted already.
        self.leslie.accept_invitation(self.group)
        self.joined()

    def test_a_sync_after_a_lost_answer_joins(self):
        # Scenario EMAIL-12
        # 1. The server took her Accept, and its answer was lost.
        self.accepted_but_unheard()

        # Scenario EMAIL-12
        # 2. The app syncs: she presses the footer's sync button, which after
        # the failed Accept says "Sync failed" (ops#379). She is in the group,
        # with no error about it being accepted already.
        leslie = self.leslie
        footer = leslie.until(lambda: next((b for b in leslie.main.all("push button")
                                            if b.showing and b.words in ("Sync", "Sync failed")), None),
                              "the footer's sync button")
        footer.press()
        self.joined()

    def test_sender_can_cancel_a_pending_invitation(self):
        robin, leslie = self.robin, self.leslie
        self.send()

        # Scenario EMAIL-05
        email = robin.find("label", leslie.email, within=robin.main)
        robin.near("push button", "Cancel Invite", to=email).press()
        self.assertIn("They will no longer be able to accept this invitation.", robin.question())
        robin.answer("Cancel")
        robin.near("label", "Pending", to=robin.find("label", leslie.email, within=robin.main))
        robin.near("push button", "Cancel Invite", to=robin.find("label", leslie.email,
                                                                within=robin.main)).press()
        robin.answer("Cancel Invite")
        robin.wait_gone(leslie.email, within=robin.main)
        leslie.sync()
        leslie.wait_gone(self.group.upper(), within=leslie.main)
        self.assertFalse(leslie.has_budget("Food"))
        self.assertFalse(leslie.has_budget("Travel"))


if __name__ == "__main__":
    unittest.main()
