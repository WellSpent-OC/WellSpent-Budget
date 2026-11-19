"""Plans (Features/Plans.md) in the real window: the plan card on Account, and
Choose a plan, which on Linux continues on the website once the purchases
flag is on, and says "Coming soon" until then. The browser and the
mail program are the UI tests' recorder (wellspent_ui._record_browser), so
nothing leaves the container. The plan answer comes from a file
(`pinned_plan`), the free plan, as on the Mac. It is read again each time
the app comes to the front, so a test changes the plan by rewriting the file
and coming back from a second copy of the app. Each test signs up a fresh
account, so it is skipped without the test mailbox's token."""

import datetime
import unittest

from wellspent_ui import (PLANS_SERVER, free_plan, launch_fresh, needs_accounts, pinned_plan, set_test_plan,
                         unique, write_plan)

FREE_LINE = "1 property, sync on every device, and 1 group shared with 1 person."
CHECKOUT = "https://wellspent.space/checkout"
MANAGED = "Bought through Apple, so it's managed on your Mac or iPhone."
# Every button a plan card can have. On Linux an Apple plan has none of them.
CARD_BUTTONS = ("See Plans", "Change Plan", "Keep My Plan", "Open Apple Settings", "Manage on wellspent.space")
# When the last paid plan ended, fixed for the run, as on the Mac.
ENDED = datetime.datetime.now(datetime.timezone.utc).replace(hour=12, minute=0, second=0, microsecond=0) \
    - datetime.timedelta(days=2)


def stamp(day):
    return day.strftime("%Y-%m-%dT%H:%M:%SZ")


def in_days(days):
    """Noon UTC that many days from today, so the shown day is the same in
    any time zone a runner has."""
    today = datetime.datetime.now(datetime.timezone.utc).replace(hour=12, minute=0, second=0, microsecond=0)
    return today + datetime.timedelta(days=days)


def shown_day(day):
    """A day as the card writes it: "Dec 9", with the year when it isn't this one."""
    words = f"{day:%b} {day.day}"
    return words if day.year == datetime.date.today().year else f"{words}, {day.year}"


def answer(tier="growth", state="active", period="monthly", paid_until=None, properties=1, locked_houses=0,
           last_plan=None, open_group=None):
    """A plan answer in the server's shape, bought through Apple, as the
    Mac's PlanTests writes them. `locked_houses` locks that many properties.
    `last_plan` ("ended" or "refunded") is a Growth plan that ended on ENDED."""
    plan = free_plan()
    free = tier == "free"
    plan.update({
        "tier": tier, "period": "none" if free else period, "state": state, "source": "none" if free else "apple",
        "paidUntil": stamp(paid_until) if paid_until else None, "renews": state == "active",
        "limits": {"properties": {"free": 1, "starter": 2, "growth": 5, "portfolio": 15}[tier]},
        "used": {"properties": properties},
    })
    if locked_houses:
        plan["locked"] = {"groupIDs": [], "people": [],
                          "houseIDs": [f"00000000-0000-4000-8000-{n:012d}" for n in range(1, locked_houses + 1)]}
    if last_plan:
        plan["lastPlan"] = {"tier": "growth", "endedOn": stamp(ENDED), "reason": last_plan}
    if open_group:
        plan["open"] = {"groupID": open_group, "person": None, "houseIDs": [], "groupChangedAt": None}
    return plan


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
        app = launch_fresh(self, plan_file=pinned_plan(self))
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
        app = launch_fresh(self, plan_file=pinned_plan(self), purchases=True)
        app.sign_up(unique("plan-checkout"))
        sheet = self.open_plans(app)
        # Scenario PLAN-02
        # Monthly first, with the plan that fits a free account picked.
        starter = app.find("push button", "Starter $19 a month", within=sheet)
        self.assertTrue(starter.selected)
        # Scenario PLAN-03
        # Yearly shows each plan's price for the year.
        self.assertTrue(app.find("push button", "Monthly", within=sheet).selected)
        app.button("Yearly 2 months free", within=sheet).press()
        app.until(lambda: app.find("push button", "Yearly 2 months free", within=app.front).selected,
                  "Yearly to be picked")
        self.assertFalse(app.find("push button", "Monthly", within=app.front).selected)
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

    def test_before_the_app_sells_plans_it_says_coming_soon(self):
        needs_accounts(self)
        app = launch_fresh(self, plan_file=pinned_plan(self), purchases=False)
        app.sign_up(unique("plan-soon"))
        sheet = self.open_plans(app)
        # Scenario PLAN-17
        # The plans and their prices show, and Coming soon stands in place of
        # Continue, and can't be pressed.
        for plan in ("Starter $19 a month", "Growth $49 a month", "Portfolio $99 a month"):
            app.find("push button", plan, within=sheet)
        self.assertFalse(app.button("Coming soon", within=sheet).enabled)
        self.assertFalse(app.shows("Continue on wellspent.space", within=sheet))
        self.assertFalse(app.shows("Restore Purchases", within=sheet))

    def test_more_than_fifteen_emails_us(self):
        needs_accounts(self)
        app = launch_fresh(self, plan_file=pinned_plan(self))
        app.sign_up(unique("plan-email"))
        sheet = self.open_plans(app)
        # Scenario PLAN-05
        # More than 15 properties? Email us opens an email to WellSpent.
        app.button("Email us", within=sheet).press()
        app.until(lambda: any(link.startswith("mailto:dev@wellspent.space") for link in app.opened_links()),
                  "an email to WellSpent to open")


    def test_the_card_in_each_plan_state(self):
        needs_accounts(self)
        path = pinned_plan(self)
        app = launch_fresh(self, plan_file=path, autosync_seconds=3600)
        other = launch_fresh(self)
        app.sign_up(unique("plan-card"))
        household = unique("Household")
        app.new_group(household)
        app.sync()
        household_id = app.group_id(household)

        def show(plan):
            """The plan changes elsewhere; going to the other window and back shows it."""
            write_plan(path, plan)
            other.bring_to_front()
            app.bring_to_front()

        def card(title, *lines, badge=None, buttons=()):
            """Account, then the card: its title, badge and lines, these
            buttons and no other card button. Leaves the sheet open."""
            app.button("Account", within=app.main).press()
            sheet = app.wait_for_window(2, "the account sheet")
            app.wait_shows(title, within=sheet)
            if badge:
                self.assertIn(badge, app.texts(sheet), f"no {badge} badge")
            for line in lines:
                app.wait_shows(line, within=sheet)
            for words in CARD_BUTTONS:
                self.assertEqual(app.shows(words, within=sheet), words in buttons, f"the card and {words!r}")
            return sheet

        def done():
            app.button("Done", within=app.front).press()
            app.wait_for_window(1, "the account sheet to close")

        # Scenario PLAN-14
        # On the free plan, the plan becomes Growth elsewhere. Back in the
        # window, the card says Growth, and nothing asks to sign in.
        card("Free plan", FREE_LINE, buttons=("See Plans",))
        done()
        renews = in_days(30)
        show(answer(paid_until=renews, properties=3))
        self.assertEqual(len(app.windows()), 1, "something opened on coming back")
        sheet = card("Growth · $49 a month")
        self.assertFalse(app.shows("Sign In", within=sheet) or app.shows("Password", within=sheet),
                         "the account sheet asks to sign in")

        # Scenario PLAN-06
        # Its price, its properties, when it renews, and that it was bought
        # through Apple and is managed on the Mac or iPhone. `card` above
        # found no button on it.
        for line in ("Up to 5 properties. You have 3.", f"Renews {shown_day(renews)}.", MANAGED):
            app.wait_shows(line, within=sheet)
        done()

        # Scenario PLAN-07
        show(answer(period="yearly", paid_until=renews))
        card("Growth · $490 a year", MANAGED)
        done()

        # Scenario PLAN-08
        # Everything keeps working for 16 days, until when. On Linux it says
        # to update the payment in Apple's settings on the Mac or iPhone, with
        # no button.
        lapsed = in_days(-1)
        card_until = shown_day(lapsed + datetime.timedelta(days=16))
        show(answer(state="grace", paid_until=lapsed))
        card("Apple couldn't renew your plan",
             f"Everything keeps working for 16 days, until {card_until}, while Apple tries again.",
             "Update your payment in your Apple account settings, on your Mac or iPhone.", badge="Growth")
        done()

        # Scenario PLAN-09
        # Paused, what is locked until the payment goes through, and nothing deleted.
        show(answer(state="billingProblem", paid_until=in_days(-20), locked_houses=2))
        card("Growth is paused",
             "Apple still couldn't take payment, so you're on the free plan for now.",
             "2 properties are locked until the payment goes through. Nothing was deleted.", badge="Free")
        done()

        # Scenario PLAN-10
        # When it ends, that everything works until then and nothing is
        # deleted, and on Linux managed on the Mac or iPhone, with no button.
        ends = shown_day(renews)
        show(answer(state="canceled", paid_until=renews))
        card(f"Growth · ends {ends}",
             f"You canceled. Everything works until {ends}, then you move to the free plan.",
             "Nothing is deleted.", MANAGED)
        done()

        # Scenario PLAN-11
        # Ended, with Household open: what's locked until a plan is picked,
        # Open now, See Plans and Change what stays open.
        show(answer(tier="free", state="free", locked_houses=2, last_plan="ended", open_group=household_id))
        card("Free plan", f"Your Growth plan ended {shown_day(ENDED)}.",
             "2 properties are locked until you pick a plan. Nothing was deleted.",
             f"Open now: {household}.", badge="Free", buttons=("See Plans",))
        self.assertTrue(app.button("Change what stays open", within=app.front).enabled)
        done()

        # Scenario PLAN-12
        # Refunded, and what is locked until a plan is picked.
        show(answer(tier="free", state="free", locked_houses=2, last_plan="refunded"))
        card("Refunded", f"Your {shown_day(ENDED)} payment was refunded, so you're on the free plan.",
             "2 properties are locked until you pick a plan. Nothing was deleted.", badge="Free",
             buttons=("See Plans",))
        done()

    def test_a_group_past_the_free_plan_says_its_only_on_this_computer(self):
        needs_accounts(self)
        self.assertIsNotNone(PLANS_SERVER, "no server with plans on (WELLSPENT_UI_PLANS_SERVER_URL)")
        # Before the app sells plans. The answer is the server's, not a file.
        app = launch_fresh(self, purchases=False)
        home, beach = unique("Home"), unique("Beach")
        app.new_group(home)
        app.new_group(beach)
        app.sign_up(unique("plan-held"), server=PLANS_SERVER)
        app.sync()

        # Scenario PLAN-18
        # 1. Signed in on the free plan, the server takes one group and refuses
        # the other, which says "Only on this computer" beside its name. Which
        # one it takes isn't fixed, so the test reads which the list marks.
        marker = "Only on this computer"
        held = app.until(lambda: [g for g in (home, beach) if app.group(g).value == marker] or None,
                         f"one group to say {marker}")
        self.assertEqual(1, len(held), f"{held} say {marker}")
        held = held[0]
        synced = beach if held == home else home
        self.assertEqual("", app.group(synced).value, f"{synced}, which the server took, says something")
        # The line drawn under its name, read as a person sees it: once, after
        # the held group's name and before the next group's.
        texts = app.texts(app.main)
        self.assertEqual(1, texts.count(marker), f"not one {marker!r} line: {texts}")
        at, held_at, synced_at = texts.index(marker), texts.index(held.upper()), texts.index(synced.upper())
        self.assertTrue(held_at < at and (synced_at < held_at or at < synced_at),
                        f"{marker!r} isn't under {held}: {texts}")

        # Scenario PLAN-18
        # 2. Choose a plan doesn't open by itself.
        self.assertEqual(1, len(app.windows()), "something opened by itself")
        self.assertFalse(app.shows("Choose a plan"), "Choose a plan opened by itself")

        # Scenario PLAN-18
        # 3. The held group's page says why, and before the app sells plans it
        # ends "Paid plans are coming soon."
        notice = (f"{held} is only on this computer. Your free plan syncs 1 group, and {synced} is that group. "
                  f"Nothing in {held} is deleted. ")
        app.group(held).press()
        app.wait_shows(notice + "Paid plans are coming soon.", within=app.main)
        app.picture("plan-held-group")

        # Scenario PLAN-18
        # 4. See Plans opens Choose a plan.
        app.button("See Plans", within=app.main).press()
        app.until(lambda: app.shows("Choose a plan", within=app.front), "Choose a plan to open")
        app.button("Not Now", within=app.front).press()
        app.wait_for_window(1, "Choose a plan to close")

        # Scenario PLAN-18
        # 5. Once the app sells plans, it ends "Choose a plan to sync it too."
        app.quit()
        app.launch(**dict(app.launched_with, purchases=True))
        app.group(held).press()
        app.wait_shows(notice + "Choose a plan to sync it too.", within=app.main)

        # Scenario PLAN-18
        # 6. Once a plan lets the server take it, neither the mark nor the
        # notice shows.
        set_test_plan(app.email, "growth", PLANS_SERVER)
        app.sync()
        app.until(lambda: app.group(held).value == "" or None, f"{held} to stop saying {marker}")
        app.wait_gone(marker, within=app.main)
        app.group(held).press()
        app.wait_gone(notice + "Choose a plan to sync it too.", within=app.main)
        self.assertFalse(app.main.all(starts=f"{held} is only on this computer"), "the notice stayed")


if __name__ == "__main__":
    unittest.main()
