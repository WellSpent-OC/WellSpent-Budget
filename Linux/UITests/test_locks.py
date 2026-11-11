"""Locks (Features/Locks.md) in the real window: the lock card in place of a
locked group, "Locked" beside its name, and Pick what stays open. The app
shows a plan answer from a file the test writes (`plan_file`), read again
each time it comes to the front, so the test can lock what it made. A second
copy of the app is the other window it comes back from."""

import datetime
import unittest

from wellspent_ui import ScreenError, launch_fresh, needs_accounts, pinned_plan, unique, write_plan


def stamp(day):
    return day.strftime("%Y-%m-%dT%H:%M:%SZ")


def answer(locked=None, open_=None, ended=False):
    """A free plan answer in the server's shape. With `ended`, a Growth plan
    ended two days ago, which offers Change what stays open."""
    now = datetime.datetime.now(datetime.timezone.utc)
    plan = {
        "tier": "free", "period": "none", "state": "free", "source": "none", "paidUntil": None,
        "renews": False, "nextTier": None, "limits": {"properties": 1}, "used": {"properties": 0},
        "extensionsOpen": [], "canSyncPriceLabs": False, "refreshMinutes": 60, "appleAccountToken": None,
    }
    if ended:
        plan["lastPlan"] = {"tier": "growth", "endedOn": stamp(now - datetime.timedelta(days=2)), "reason": "ended"}
    if locked is not None:
        plan["locked"] = {"groupIDs": locked, "people": [], "houseIDs": []}
    if open_ is not None:
        plan["open"] = open_
    return plan


def opened(group, changed_days_ago=None):
    changed = None
    if changed_days_ago is not None:
        changed = stamp(datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(days=changed_days_ago))
    return {"groupID": group, "person": None, "houseIDs": [], "groupChangedAt": changed}


def shown_day(day):
    """A day as the app writes it: "Dec 9", with the year when it isn't this one."""
    words = f"{day:%b} {day.day}"
    return words if day.year == datetime.date.today().year else f"{words}, {day.year}"


class Locks(unittest.TestCase):
    def show(self, app, other, path, plan):
        """The plan changes elsewhere; going to the other window and back shows it."""
        write_plan(path, plan)
        other.bring_to_front()
        app.bring_to_front()

    def open_pick(self, app):
        """Account, then Change what stays open on the card: the pick opens in
        the account sheet's place."""
        # Right after the pick sheet closes, a press on Account is sometimes
        # lost, 1 run in 3 here. A person would press again, so the test does.
        for attempt in range(2):
            app.button("Account", within=app.main).press()
            try:
                app.until(lambda: len(app.windows()) == 2, "the account sheet", wait=5 if attempt == 0 else 15)
                break
            except ScreenError:
                if attempt == 1:
                    raise
        sheet = app.front
        app.button("Change what stays open", within=sheet).press()
        app.until(lambda: app.shows("Pick what stays open", within=app.front), "Pick what stays open to open")
        return app.front

    def test_the_payer_sees_locked_groups_and_picks_what_stays_open(self):
        needs_accounts(self)
        path = pinned_plan(self)
        app = launch_fresh(self, plan_file=path, autosync_seconds=3600)
        other = launch_fresh(self)
        app.sign_up(unique("locks"))
        home, beach = unique("Home"), unique("Beach")
        app.new_group(home)
        app.new_group(beach)
        # Synced, so the app knows this person made both and pays for them.
        app.sync()
        home_id, beach_id = app.group_id(home), app.group_id(beach)
        self.show(app, other, path, answer(locked=[beach_id], open_=opened(home_id), ended=True))

        # Scenario LOCK-03
        app.until(lambda: app.group(beach).value == "Locked", "Beach to say Locked")
        self.assertEqual(app.group(home).value, "")

        # Scenario LOCK-01
        app.group(beach).press()
        app.wait_shows("This group is locked", within=app.main)
        app.wait_shows(f"Your free plan keeps 1 group open: {home}.", within=app.main)
        app.wait_shows("The people in this group can't see it either.", within=app.main)
        self.assertTrue(app.button("See Plans", within=app.main).enabled)

        # Scenario LOCK-05
        sheet = self.open_pick(app)
        app.wait_shows(f"Skip keeps {home} open.", within=sheet)
        app.button("Skip", within=sheet).press()
        app.wait_for_window(1, "Pick what stays open to close")

        # Scenario LOCK-04
        sheet = self.open_pick(app)
        self.assertTrue(app.find("push button", home, within=sheet).selected)
        app.find("push button", beach, within=sheet).press()
        app.until(lambda: app.find("push button", beach, within=app.front).selected, "Beach to be picked")
        app.button("Keep These Open", within=app.front).press()
        app.wait_for_window(1, "Pick what stays open to close")

        # Scenario LOCK-07
        self.show(app, other, path, answer(locked=[beach_id], open_=opened(home_id, changed_days_ago=10),
                                           ended=True))
        changeable = datetime.date.today() + datetime.timedelta(days=20)
        changes_on = f"You can change the open group on {shown_day(changeable)}."
        # The lock card says it first, once the new answer is in.
        app.wait_shows(changes_on, within=app.main)
        sheet = self.open_pick(app)
        app.wait_shows(changes_on, within=sheet)
        app.find("push button", beach, within=sheet).press()
        self.assertTrue(app.find("push button", home, within=app.front).selected)
        self.assertFalse(app.find("push button", beach, within=app.front).selected)

    def test_a_member_is_asked_to_pay_for_a_locked_group(self):
        needs_accounts(self)
        path = pinned_plan(self)
        robin = launch_fresh(self, plan_file=path, autosync_seconds=3600)
        leslie = launch_fresh(self, autosync_seconds=3600)
        robin.sign_in_as("Robin")
        leslie.sign_in_as("Leslie")
        cabin = unique("Cabin")
        leslie.new_group(cabin)
        self.addCleanup(leslie.remove_group, cabin)
        leslie.sync()
        robin.join(leslie.legacy_invite(cabin, "Leslie"), "Robin")
        self.show(robin, leslie, path, answer(locked=[robin.group_id(cabin)]))

        # Scenario LOCK-02
        robin.group(cabin).press()
        robin.wait_shows("This group needs a paid plan", within=robin.main)
        robin.wait_shows("Leslie's plan doesn't cover it right now.", within=robin.main)
        robin.wait_shows("Paying opens it for everyone in it. Nobody else is charged.", within=robin.main)
        robin.button("Pay for This Group", within=robin.main).press()
        robin.until(lambda: robin.shows("Choose a plan", within=robin.front), "Choose a plan to open")
        # On Linux, paying continues on the website. The group waits for the
        # plan to reach the server, then opens (the shared PurchaseCoordinator).
        robin.button("Continue on wellspent.space", within=robin.front).press()
        robin.wait_for_window(1, "Choose a plan to close")
        robin.until(lambda: any(link.startswith("https://wellspent.space/checkout?plan=starter")
                                for link in robin.opened_links()), "checkout to open")


if __name__ == "__main__":
    unittest.main()
