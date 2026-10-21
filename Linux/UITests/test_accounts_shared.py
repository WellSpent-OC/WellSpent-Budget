"""Accounts (Features/Accounts.md) on two computers at once: one signed in to
the same account as the other, which signs out everywhere. Each computer is its
own copy of the app, with its own data, keyring and session bus. Skipped
without the test mailbox's token."""

import secrets
import unittest

import test_accounts
from test_accounts import KEPT_HERE, SYNCED, fresh_address
from wellspent_ui import launch_fresh, needs_accounts, unique

SIGNED_OUT_HERE = "You were signed out on this device. Sign in again. Your budgets are still here."


class AccountsOnTwoComputers(unittest.TestCase):
    # The steps a person takes on the sheet, shared with the one-computer tests.
    # The module, not its class, is imported, so its tests don't run twice.
    open_sheet = test_accounts.Accounts.open_sheet
    create = test_accounts.Accounts.create
    confirm = test_accounts.Accounts.confirm
    done = test_accounts.Accounts.done
    sign_in = test_accounts.Accounts.sign_in
    foot = test_accounts.Accounts.foot

    def test_signed_out_from_another_computer(self):
        needs_accounts(self)
        laptop = launch_fresh(self)
        address, password = fresh_address("twohomes"), secrets.token_urlsafe(18)
        self.confirm(laptop, address, self.create(laptop, address, password))
        self.done(laptop)
        group = unique("Twohomes")
        laptop.new_group(group)
        laptop.new_budget("Books", "100", group=group)
        laptop.sync()

        desktop = launch_fresh(self)
        self.sign_in(desktop, address, password)
        desktop.wait_for_window(1, "the account sheet to close")
        desktop.until(lambda: desktop.has_budget("Books"), "the account's budget on the desktop")

        # Scenario ACCT-13
        # 1. The desktop signs out everywhere. At the laptop's next sync, its
        # sign-in sheet opens by itself with the email filled in and says
        # why, and behind it the list is what the laptop keeps signed out.
        sheet = self.open_sheet(desktop)
        desktop.button("Sign out everywhere…", within=sheet).press()
        desktop.wait_for_window(3, "the question")
        desktop.answer("Sign Out Everywhere")
        desktop.wait_for_window(1, "the account sheet to close")
        self.foot(desktop, KEPT_HERE)

        laptop.button("Sync", within=laptop.main).press()
        sheet = laptop.wait_for_window(2, "the sign-in sheet to open by itself")
        laptop.wait_shows(SIGNED_OUT_HERE, within=sheet)
        email = laptop.near("text", None, to=laptop.find("label", "Email", sheet))
        self.assertEqual(address, email.text)
        laptop.until(lambda: not laptop.has_budget("Books"), "the account's budget to leave the list")
        self.foot(laptop, KEPT_HERE)

        # Scenario ACCT-13
        # 2. Signing in again on the laptop brings the account's budgets back.
        laptop.field("Password", sheet).type(password)
        laptop.button("Sign in", within=sheet).press()
        laptop.wait_for_window(1, "the sign-in sheet to close")
        laptop.until(lambda: laptop.has_budget("Books"), "the account's budget to come back")
        self.foot(laptop, SYNCED)
        laptop.remove_group(group)


if __name__ == "__main__":
    unittest.main()
