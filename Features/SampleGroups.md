# Sample groups

A fresh install opens with two made-up groups, so there is something to look at before Robin has budgets of his own. Looking at them changes nothing. A sample he never changed stays out of the account he makes, so a real account never starts with made-up budgets. A sample he changed or added to is his, and comes along.

## SAMP-01 A fresh install opens with two sample groups

- Given WellSpent has never been opened on this computer
- When Robin opens it, without signing in
- Then the list shows two groups, "Household" and "Side Business", their names in capitals
- And "Household" holds the budgets "Groceries", "Eating out" and "Utilities", with limits of $1000.00, $300.00 and $450.00
- And "Side Business" holds "Materials", with a limit of $5000.00
- And six sample entries are dated 3 to 12 days before that first opening: "Hilltop Grocery", "Costco" and "Sunny's" in Groceries, "Sunrise Cafe" and "Riverside Grill" in Eating out, and "Regional Power" in Utilities
- And a budget lists only this month's entries, so early in a month some of them are not shown

## SAMP-02 Samples nobody changed stay out of a new account

- Given a fresh install, where Robin has only looked at the samples: opened their budgets, and hidden and shown their budgets in the list
- When he creates an account
- Then his account starts with no groups: the list is empty, and the right side says "No budgets yet" and "A budget is an amount to spend each month."
- And the samples never reach the server, so his account shows no sample group on any other device

## SAMP-03 A group made before signing up comes along, and the samples do not

- Given a fresh install, where Robin made a group "Road trip" with a budget "Fuel" and an entry "Gas station"
- When he creates an account
- Then the list holds only "Road trip", with its budget and its entry
- And "Road trip" syncs to his account, so his other devices get it

## SAMP-04 A sample given an entry comes along, all of it

- Given a fresh install, where Robin added "Farmers market" to the sample budget "Groceries"
- When he creates an account
- Then "Household" comes along with its three budgets, its sample entries and "Farmers market", and syncs to his account
- And "Side Business", which he did not change, stays out
- And any saved change counts: adding, changing or deleting an entry or a budget in the group, or renaming it, even a change he then put back

## SAMP-05 A sample renamed comes along under its new name

- Given a fresh install, where Robin renamed "Side Business" to "Pottery"
- When he creates an account
- Then the list holds "Pottery", with its budget "Materials"
- And "Household", which he did not change, stays out

## SAMP-06 Signing in to an account made elsewhere leaves the samples here

- Given a fresh install, with the samples
- When Robin signs in to the account he made on another computer
- Then the list shows that account's budgets only, and no sample group
- When he signs out
- Then the samples show again, as they were

## SAMP-07 The samples come only once

- Given Robin made his account on this computer, after a fresh install
- When he signs out
- Then the list is empty, and the right side says "No budgets yet"
- And the samples do not come back, even after WellSpent is quit and opened again
- And an account Leslie then makes on this computer starts empty too
