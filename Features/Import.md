# Importing a statement

Importing a statement adds the lines of a bank or card statement to a budget group, without typing them in. WellSpent reads the file on this computer and shows a review first. The review says which lines match an entry already there, which will be added, which came in before, and which need a budget. Nothing is added until "Import" is pressed. The statement goes into the group of the budget that is open.

## IMPORT-01 Import statement opens a review, and nothing is added yet

- Given Robin has Groceries open, in Household
- When he presses "Import statement" and picks his bank's statement file, statement.csv
- Then a review titled "Import a statement into “Household”" opens, with "statement.csv" beside the title
- And counts for "Matched", "To add", "Already imported" and "Needs a budget" sit across the top
- And each line of the statement has a row
- And "Read on this computer. Nothing is sent until you add it." sits at the foot, beside "Cancel" and "Import"
- And nothing is in Groceries yet

## IMPORT-02 Each line shows a cleaned-up name over the bank's own words

- Given a statement with the line "TRADER JOES #123", -54.20, dated Oct 2, in this period
- When Robin imports it
- Then the line's row shows "Oct 2", "Trader Joes" with "TRADER JOES #123" under it, and "-$54.20"
- And it says what will happen to the line: "Matched to entry", "Will be added", "Already imported" or "Needs a budget"
- And once imported, the line shows in its budget as "Trader Joes", with "TRADER JOES #123" under it, "Statement" under "Source", and "$54.20"

## IMPORT-03 A line that matches an entry typed by hand is not added again

- Given Robin typed "Costco", $286.31, into Groceries on Oct 6
- When he imports a statement with the line "COSTCO WHSE #0472", -286.31, dated Oct 7
- Then that line says "Matched to entry", and "Matched" counts it
- When he presses "Import"
- Then Groceries still holds one Costco, the one he typed
- And a line matches only an entry typed by hand, with the same amount, dated within 4 days of it

## IMPORT-04 A merchant filed before goes to the same budget

- Given Groceries holds "Hilltop Grocery", $42.00, from an earlier day
- When Robin imports a statement with the line "HILLTOP GROCERY #17", -58.10
- Then that line shows "Hilltop Grocery" and says "Will be added", and "To add" counts it
- And it has no budget list, because it goes where that merchant went before
- When he presses "Import"
- Then a second "Hilltop Grocery", $58.10, shows in Groceries

## IMPORT-05 A new merchant needs a budget from the group's own budgets

- Given Household has no entry from Corner Bakery
- When Robin imports a statement with the line "CORNER BAKERY"
- Then the line says "Needs a budget", with a budget list set to "Choose"
- And the list offers Household's budgets only, and none from another group
- When he picks Groceries for it and presses "Import"
- Then "Corner Bakery" shows in Groceries

## IMPORT-06 A line left at Choose is not added

- Given the review has two lines that need a budget
- When Robin picks Groceries for one, leaves the other at "Choose", and presses "Import"
- Then only the first is added

## IMPORT-07 Importing the same statement again adds nothing twice

- Given Robin imported statement.csv, and every line of it was added
- When he imports the same file again
- Then every line says "Already imported", and its row is faded
- And "Already imported" counts every line
- When he presses "Import"
- Then nothing is added twice

## IMPORT-08 A deleted line stays deleted when its statement is imported again

- Given Robin imported "TRADER JOES #123" and "CORNER BAKERY" into Groceries
- And then he deleted "Corner Bakery"
- When he imports the same statement again
- Then both lines say "Already imported"
- When he presses "Import"
- Then the import finishes with no error, and "Corner Bakery" stays deleted
- And the same holds for a line Leslie deleted, in a group they share

## IMPORT-09 A line whose budget was deleted is offered again

- Given Robin imported both lines into Groceries, and then deleted Groceries
- When he opens Eating out, in the same group, and imports the statement again
- Then both lines say "Needs a budget", and the list offers the budgets left, such as Eating out
- When he picks Eating out for both and presses "Import"
- Then both show in Eating out, with no error
- And from then on, they count as "Already imported"

## IMPORT-10 A statement one person imported counts as imported for the others

- Given Robin and Leslie share Household, and Leslie imported statement.csv into Groceries
- When Robin's app syncs
- Then her lines show in his Groceries, with "Leslie" under "Added by" and "Statement" under "Source"
- When he imports the same statement
- Then every line says "Already imported"

## IMPORT-11 Lines dated before this period go in, but the list shows this period only

- Given Groceries' period started Oct 1
- When Robin imports a statement of September's lines and files them in Groceries
- Then they go in, but Groceries' list and total leave them out
- And importing the statement again shows them as "Already imported"

## IMPORT-12 Cancel adds nothing

- Given the review is open
- When Robin presses "Cancel"
- Then the review closes, and nothing is added
- And importing the file again offers the same lines as before

## IMPORT-13 A file that is not a statement is explained in words

- When Robin imports notes.txt, which holds a few words and no commas
- Then WellSpent says "“notes.txt” is not a statement this app can read. Download a CSV, OFX or QFX file from your bank and import that."
- When he imports header.csv, which holds only its column names
- Then it says "“header.csv” has no entries to import."
- When he imports columns.csv, which has no amount column
- Then it says "Line 1 of “columns.csv” could not be read: no amount column. Download a CSV, OFX or QFX file from your bank and import that."
- And no review opens

## IMPORT-14 At View, there is no Import statement

- Given Leslie is in Robin's Household at View
- When she opens Groceries
- Then there is no "Import statement" and no "Add"
