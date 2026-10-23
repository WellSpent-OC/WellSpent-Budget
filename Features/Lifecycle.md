# Returning to the app and starting a new day

The app refreshes when someone returns to it. An open window also follows the
local calendar, even while signed out, so a new month shows that month's money.

## LIFE-01 Returning to the app brings in shared changes

- Given Robin and Leslie share a group, and Robin is signed in
- And Robin leaves WellSpent open while using another app
- When Leslie adds a transaction, and Robin returns to WellSpent
- Then the transaction appears without Robin pressing Sync
- And opening or closing a sheet within WellSpent does not count as leaving and returning to the app

## LIFE-02 A new local day refreshes the displayed money

- Given Robin has left WellSpent open, signed out
- When a new local day begins
- Then the money wheels use that day's pace and expected amount
- And when a new month begins, the displayed spending and transactions use the new period
- And returning to the app after sleep checks the date immediately
- And a date check on the same day does not reload the budgets or contact the server

## Verification

The Linux UI test `test_lifecycle.py` covers LIFE-01. The native fixture in
`Linux/NativeTests/lifecycle.c` checks window and sheet focus, recurring clock
callbacks, duplicate installation, and shutdown. Shared workspace tests cover
the date check and its budget reload. **LIFE-02 still needs a full UI scenario
test on Linux; native and shared tests are not a substitute for that test.**
