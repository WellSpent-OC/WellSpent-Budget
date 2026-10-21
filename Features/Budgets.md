# Budgets and groups

A budget is an amount to spend each month, and it starts again on the 1st. Budgets live in groups. A group holds budgets tracked together, and a group is what gets shared with someone else. These scenarios cover making, renaming, changing and deleting groups and budgets, which budget is open on the right, and what an open budget says about this period: how much is spent, how much is left, and how many transactions it holds.

## BUDGET-01 Make a group

- Given Robin has WellSpent open
- When he chooses "New Group…"
- Then a sheet titled "New Group" asks for a "Name" and says "A group holds budgets you track together. It is also what you will share with someone else."
- And "Add" stays dimmed while Name is empty or only spaces
- When he types Household and presses "Add"
- Then the sheet closes, and the list shows "HOUSEHOLD" with no budgets under it

## BUDGET-02 Rename a group

- Given Robin made Household
- When he picks "Rename…" from Household's menu
- Then a sheet titled "Rename Group" shows Household in "Name"
- And "Save" stays dimmed while Name is empty or only spaces
- When he changes the name to Home and presses "Save"
- Then the list shows "HOME" in place of "HOUSEHOLD"

## BUDGET-03 Make a budget in a group

- Given Robin made Household
- When he picks "New Budget in Household…" from Household's menu
- Then a sheet titled "New Budget" asks for "Name", "Each month" and "Group", with Household chosen as the group
- And it says "Starts again on the 1st of each month."
- When he types Groceries and 500 and presses "Add"
- Then Groceries shows last under "HOUSEHOLD" in the list, with $500.00 beside it
- And Groceries opens on the right, saying "$0.00", "of $500.00 this period" and "$500.00 left"
- And "Add Budget" opens the same sheet, with the first group he manages chosen

## BUDGET-04 A budget needs a name and an amount above zero

- Given the "New Budget" sheet is open
- When "Name" is empty or only spaces
- Then "Add" stays dimmed
- When "Each month" is empty, 0, or not a number, such as "lots"
- Then "Add" stays dimmed
- When Name says Groceries and Each month says 500 or 500.00
- Then "Add" lights

## BUDGET-05 With no group to put it in, a new budget makes one

- Given Robin manages no group, because he has none yet, or he is only in Leslie's Household at Add
- When he presses "Add Budget"
- Then the "New Budget" sheet asks for a "Group" name in place of a list of groups, with "Personal" filled in
- And "Add" stays dimmed while the group name is empty or only spaces
- When he types Groceries and 500 and presses "Add"
- Then the list shows "PERSONAL" with Groceries under it, and Groceries opens

## BUDGET-06 Change a budget's name or monthly amount

- Given Groceries is $500.00 a month, and $142.08 is spent this period
- When Robin picks "Edit…" for Groceries
- Then a sheet titled "Edit Budget" shows Groceries in "Name" and 500.00 in "Each month", with no choice of group
- When he changes Each month to 650 and presses "Save"
- Then Groceries says "of $650.00 this period" and "$507.92 left"
- And the list shows $507.92 beside Groceries

## BUDGET-07 Changing budgets and groups takes Manage

- Given Leslie made Household, which holds Groceries
- Then Household's menu offers her "Share…", "People…", "New Budget in Household…", "Rename…" and "Delete…"
- And Groceries offers her "Edit…" and "Delete…"
- When she shares Household with Robin at Add
- Then Household's menu offers him only "Share…", "People…" and "Leave…"
- And Groceries offers him no "Edit…" and no "Delete…"
- When she moves him up to Manage, and his app syncs
- Then he is offered "Edit…" and "Delete…" for Groceries, and "New Budget in Household…" and "Rename…" for the group
- And he is still offered "Leave…" in place of "Delete…" for the group

## BUDGET-08 Deleting a budget asks first, and says how many transactions go with it

- Given Groceries holds 3 transactions, one of them from last month
- When Robin picks "Delete…" for Groceries
- Then a question asks "Delete “Groceries”?" and says "Its 3 transactions will be deleted too. This cannot be undone."
- And it offers "Delete" and "Cancel"
- When he presses "Cancel"
- Then nothing changes
- When he asks again and presses "Delete"
- Then Groceries and its 3 transactions are gone
- And with 1 transaction the question says "Its 1 transaction will be deleted too. This cannot be undone.", and with none it says only "This cannot be undone."

## BUDGET-09 A budget opens by itself when none is open

Platforms: Mac, Linux

- Given Household is Robin's only group, with Groceries and Eating out, and Groceries is open
- When he deletes Groceries
- Then Eating out opens on the right in its place
- And when WellSpent opens and he has budgets, one of them is already open

## BUDGET-10 With no budgets, the right side says how to start

- Given Robin has no budgets, such as after deleting his last one
- Then the right side says "No budgets yet" and "A budget is an amount to spend each month."
- And it offers "Add Budget", which opens the "New Budget" sheet

## BUDGET-11 Deleting a group asks first, and counts what goes with it

- Given nobody else is in Household, and it holds Groceries and Eating out, with 3 transactions in all, one of them from two months ago
- When Robin picks "Delete…" from Household's menu
- Then a question asks "Delete “Household”?" and says "Its 2 budgets and 3 transactions will be deleted too. This cannot be undone."
- When he presses "Cancel"
- Then Household, its budgets and its transactions all stay
- When he asks again and presses "Delete"
- Then Household, both budgets and all 3 transactions are gone, and no other group changes
- And a transaction already deleted is not counted
- And a count of none is left out: a group with 3 budgets and no transactions says "Its 3 budgets will be deleted too. This cannot be undone.", and an empty group says only "This cannot be undone."

## BUDGET-12 The owner of a shared group deletes it for everyone

- Given Robin made Household and shared it with Leslie, and it holds 1 budget and 2 transactions
- When he picks "Delete…" from Household's menu
- Then a question asks "Delete “Household”?" and says "It's deleted for everyone in it, with its 1 budget and 2 transactions. This cannot be undone."

## BUDGET-13 A member leaves a shared group instead of deleting it

- Given Leslie made Household, which holds 1 budget and 2 transactions, and shared it with Robin at Add
- When he picks "Leave…" from Household's menu
- Then a question asks "Leave “Household”?", with "Leave" and "Cancel"
- And it says "You leave the group, and it is removed from all your devices, with its 1 budget and 2 transactions. The others in it keep it. Anything you changed in it on this device that has not synced yet still goes to them first. Changes on your other devices that have not synced yet do not reach them. Only the person who made it, or an admin, can delete it for everyone. To come back, ask for a new invite link."
- When he presses "Leave"
- Then Household goes from his list, and Leslie keeps it
- And at View the question leaves out the two sentences about changes, since he has none to send

## BUDGET-14 An open budget says what is spent and what is left this period

- Given it is October 18, and Groceries is $500.00 a month
- And Groceries holds Hilltop Grocery, $142.08, and Corner Bakery, $12.00, from this month, and Market, $9.50, from September
- When Robin picks Groceries in the list
- Then Groceries opens on the right and says "Spent" $154.08 and "Left" $345.92
- And its wheel shows what is left of the $500.00
- And the line under them says "2 transactions since Oct 1"
- And it lists Hilltop Grocery and Corner Bakery, and not Market
- And the list shows $345.92 beside Groceries
- And with one transaction, the line says "1 transaction since Oct 1"

## BUDGET-15 Over its limit, a budget says how far over

- Given Groceries is $100.00 a month
- When Robin adds $40.00 and then $75.00 to it
- Then Groceries says "Spent" $115.00
- And in place of what is left it says "Over" $15.00, in a warning colour
- And its wheel is orange all the way round
- And the list shows "$15.00 over" beside Groceries

## BUDGET-16 A budget's amount is read the way the region writes numbers

- Given Robin's computer is set to a region that writes decimals with a comma, such as Germany
- When he opens "New Budget"
- Then the empty "Each month" shows "500,00" as its example
- When he types Groceries as the name, and "1.500,00" for each month
- Then "Add" lights, and adding makes Groceries $1,500.00 a month
- When he types "500.00" for each month instead
- Then "Add" stays dimmed
- And under the amount it says "That amount can't be read clearly. Type it like 12,50."
