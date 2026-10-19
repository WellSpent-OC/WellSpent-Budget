# Databases from earlier releases

Each file here was written by a released version's own code. `UpgradeTests` opens a copy
with today's code, which runs every migration added since, and checks that nothing was
lost. Never edit one by hand, and never write one with today's code: then it no longer
shows what that release really left on someone's Mac.

## wellspent-0.1.0.sqlite

- **Release:** 0.1.0, the first TestFlight builds, commit `6a9308c`.
- **Made with:** a temporary test in a checkout of that commit, never committed. It
  opened `WellSpentDatabase.open(at:)` on a new file and used 0.1.0's `AppModel`, signed
  out:
  - groups "Home" and "Road Trip"
  - budgets "Groceries" ($500.00) and "Eating Out" ($200.00) in Home, "Fuel" ($300.00)
    in Road Trip
  - transactions "Hilltop Grocery" ($42.00, note "weekly shop") and "Market" ($9.50) in
    Groceries, "Taqueria" ($18.75) in Eating Out, "Shell" ($60.00) and "Wrong charge"
    ($1.00) in Fuel, all dated 1,760,000,000 seconds after 1 January 1970
  - "Wrong charge" deleted
  - each amount stored negative, as spending always is
- **Then:** `sqlite3 <file> "PRAGMA wal_checkpoint(TRUNCATE); PRAGMA journal_mode=DELETE;
  VACUUM;"`, so it is one file.
- **What it holds:** migrations v1 to v10, and 10 changes waiting to sync (6 for Home, 4
  for Road Trip).

## Adding the next one

At each release whose database differs, make one the same way from its tag, add a
section here, and add a test beside the 0.1.0 one.
