# Changing and deleting a transaction

A click on a transaction in a budget's list opens it, to change it, move it to another budget in the same group, or delete it. A delete can be undone for about 10 seconds. In a shared group, what a person may change follows their level: at View nothing, at Add only what they added, and at Manage, Admin or Owner anyone's. In these scenarios Robin and Leslie share Household, whose budgets are Groceries and Eating out, and Leslie added Hilltop Grocery, $142.08, to Groceries on Oct 5. Robin is at Manage unless a scenario says otherwise.

## EDIT-01 A click on any row opens it

- Given Robin has Groceries open
- When he clicks or taps Hilltop Grocery
- Then a sheet titled "Transaction" opens, with its "Merchant", "Amount", "Date" and "Note" filled in, and "Budget" set to Groceries
- And a line above the fields says "Added by Leslie · Manual"
- And its buttons are "Delete…", "Cancel" and "Save", with Save dimmed
- And a transaction he added says "Added by you · Manual", and one from someone who gave no name says "Added by a member · Manual"
- And in a group nobody else is in, the line says only where it came from, such as "Manual"
- And a refund from a statement adds "Refund", as in "Added by Leslie · Statement · Refund"
- And a line imported from a statement shows the bank's own text in Note, such as "CORNER BAKERY"

## EDIT-02 Save stays dimmed until something changes

- Given Hilltop Grocery is open
- Then "Save" is dimmed
- When Robin changes any of Merchant, Amount, Date, Note or Budget
- Then Save lights
- When he puts it back as it was
- Then Save dims again, and an amount of $142.08 counts the same as 142.08
- And Save stays dimmed while Merchant is empty or only spaces, or Amount is not a number

## EDIT-03 Save changes it, and the totals follow at once

- Given Hilltop Grocery is open
- When Robin changes Amount to 124.08 and presses "Save"
- Then the sheet closes, and the row shows "$124.08"
- And what is spent, the wheel and what is left change at once, before any sync
- And the row still says Leslie added it
- And Leslie's app shows "$124.08" after its next sync
- And a refund stays a refund: a new amount never turns money in into money spent

## EDIT-04 Move it to another budget in the same group

- Given Hilltop Grocery is open
- Then "Budget" offers Household's budgets only: Groceries and Eating out
- When Robin picks Eating out and presses "Save"
- Then Hilltop Grocery leaves Groceries' list and total
- And Eating out lists it and counts it
- And Leslie's app shows it in Eating out after its next sync

## EDIT-05 A date outside this period says so

- Given it is October 18, and Hilltop Grocery is open
- When Robin sets "Date" to Sep 28
- Then a line under the date says "This moves it out of this period."
- When he sets the date back to Oct 5
- Then the line goes
- When he sets Sep 28 again and presses "Save"
- Then Hilltop Grocery leaves Groceries' list and this period's total

## EDIT-06 Delete… asks first, naming the transaction and its amount

- Given Hilltop Grocery is open
- When Robin presses "Delete…"
- Then a question asks "Delete “Hilltop Grocery”, $142.08?", with "Delete" and "Cancel"
- And it says "It comes out of Groceries for everyone in Household."
- And in a group nobody else is in, it says "It comes out of Groceries."
- When he presses "Cancel"
- Then nothing changes, and the sheet stays open

## EDIT-07 Delete takes it out, and a bar offers Undo

- Given Robin pressed "Delete…" in Hilltop Grocery's sheet, and the question shows
- When he presses "Delete"
- Then the sheet closes, and Hilltop Grocery leaves Groceries' list and total
- And a bar across the top of the budget says "Deleted “Hilltop Grocery”, $142.08.", with an "Undo" button
- When he presses "Undo"
- Then Hilltop Grocery is back, with the same details, still added by Leslie, and the bar goes
- And Leslie's app sees it go, and come back, at its next sync

## EDIT-08 The Undo bar goes after about 10 seconds, or at the next change

- Given Robin has just deleted Hilltop Grocery, and the bar offers "Undo"
- When about 10 seconds pass
- Then the bar goes, and Hilltop Grocery stays deleted
- And another change he makes first, such as adding a transaction, takes the bar away at once, and the delete stays
- And a sync that brings in other people's changes leaves the bar where it is
- And a second delete replaces the bar, so only the last delete can be undone

## EDIT-09 An Undo that can't be done now says why

- Given Robin has just deleted Hilltop Grocery, and the bar offers "Undo"
- And a sync brings in that he was moved down to View
- When he presses "Undo"
- Then nothing comes back, the bar goes, and the app says "This can't be undone now. You can view this group but not change it."
- And moved down to Add instead, it says "This can't be undone now. Only Leslie, or a manager, can change this."
- And when Groceries was deleted meanwhile, it says "This can't be undone now, because Groceries was deleted."

## EDIT-10 At View, a transaction opens read-only

- Given Robin is at View in Household
- When he clicks or taps Hilltop Grocery
- Then the sheet shows its merchant, amount, date and budget as plain text, such as "$142.08" and "Oct 5, 2026", and its note when it has one
- And a line says "You can view this group but not change it."
- And "Done" is the only button
- And a transaction he added before he was moved down to View says "You can only view this group now, so you can't change what you added."
- And in the list, the rows he can't change look like every other row

## EDIT-11 At Add, only what he added can be changed

- Given Robin is at Add in Household
- When he clicks or taps Leslie's Hilltop Grocery
- Then it opens read-only, saying "Only Leslie, or a manager, can change this.", with "Done" as the only button
- And when Leslie gave no name for the group, it says "Only the person who added this, or a manager, can change this."
- When he opens a transaction he added
- Then he can change it and delete it
- And at Manage, Admin or Owner, he can change and delete anyone's, and each keeps who added it

## EDIT-12 Someone else deletes or changes it while it is open

- Given Hilltop Grocery is open, with a new amount typed
- And a sync brings in Leslie's delete of it
- When Robin presses "Save" or "Delete…"
- Then nothing is saved, and Hilltop Grocery stays deleted
- And the sheet turns read-only and says "Leslie deleted this while you had it open.", with "Done" as the only button
- And when the person who deleted it gave no name, it says "Someone deleted this while you had it open."
- And when he deleted it himself on another computer, it says "You deleted this on another computer while it was open here."
- And when the sync brought Leslie's new note instead, Save keeps her note and takes his amount

## EDIT-13 Moved down while it is open, nothing is saved

- Given Hilltop Grocery is open, with a new amount typed
- And a sync brings in that Robin was moved down to View
- When he presses "Save" or "Delete…"
- Then nothing is saved, and the sheet turns read-only, with "Done" as the only button
- And it shows Hilltop Grocery as it was when he opened it, not what he typed
- And it says "Nothing was changed. You can view this group but not change it."
- And moved down to Add instead, it says "Nothing was changed. Only Leslie, or a manager, can change this."

## EDIT-14 A change that didn't go through is noted

- Given Robin changed Hilltop Grocery before his app synced, and a newer change from Leslie reached the server first
- When his app syncs
- Then the row shows Leslie's version, with a quiet line under the merchant: "Your change didn't go through."
- When he opens Hilltop Grocery
- Then the sheet says "Your last change to this didn't go through. This is the version everyone sees."
- And the row's line is gone
- And the same note shows when the server refuses his change, such as after a move down from Manage to Add before it synced
- And Leslie sees no note

## EDIT-15 Right-click offers Edit… and Delete… where they are allowed

Platforms: Mac

- Given Robin may change Hilltop Grocery
- When he right-clicks its row
- Then a menu offers "Edit…" and "Delete…"
- And "Edit…" opens its sheet, and "Delete…" asks the sheet's question, with the same bar after "Delete"
- And on a row he may not change, at View or on Leslie's transaction at Add, a right-click shows no menu
- And when he was moved down to Add after the question was asked, "Delete" changes nothing, and the app says "Nothing was changed. Only Leslie, or a manager, can change this."

## EDIT-16 The keyboard in the list and in the sheet

Platforms: Mac

- Given Groceries lists Market above Hilltop Grocery, and Market's sheet was just closed with Escape
- When Robin presses the Down arrow
- Then Hilltop Grocery is selected, and nothing opens
- When he presses Return
- Then Hilltop Grocery's sheet opens
- And Tab moves from each field to the next
- And Return saves when "Save" is lit, and Escape closes the sheet without saving
- And in the delete question, Escape is "Cancel"
- And after a delete, Command-Z leaves the transaction deleted, and the bar stays

## EDIT-17 A swipe or a long press offers Edit and Delete where they are allowed

Platforms: iPhone

- Given Robin may change Hilltop Grocery
- When he swipes its row to the left
- Then it offers "Edit" and "Delete"
- And a long press on the row offers the same two in a menu
- And "Edit" opens its sheet, and "Delete" asks the sheet's question, with the same bar after "Delete"
- And on a row he may not change, at View or on Leslie's transaction at Add, a swipe offers nothing and a long press shows no menu
