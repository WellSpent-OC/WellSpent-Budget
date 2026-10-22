# Adding a transaction

Add puts money spent into the budget that is open. A transaction has a merchant, an amount, a date and a note, and it counts against its budget in the period its date falls in. In a shared group, everyone in it sees what each person adds, and who added it.

## ENTRY-01 Add puts a transaction in the open budget

- Given it is October 18, and Groceries is open, at $500.00 a month, with nothing spent
- When Robin presses "Add", types Hilltop Grocery in "Merchant" and 142.08 in "Amount", and presses "Add" in the sheet
- Then the sheet closes
- And Groceries lists Hilltop Grocery, with "Oct 18", "Manual" and "$142.08"
- And Groceries says "Spent" $142.08, "Left" $357.92 and "1 transaction since Oct 1"
- And the list shows $357.92 beside Groceries

## ENTRY-02 The sheet asks for a merchant and an amount

- Given Groceries is open
- When Robin presses "Add"
- Then a sheet titled "New transaction" asks for "Merchant", "Amount", "Date" and "Note", with "Cancel" and "Add"
- And Date starts at today
- And there is no budget to choose, because the transaction goes in the open budget
- And "Add" stays dimmed while Merchant is empty or only spaces, or Amount is empty or not a number, such as "twelve"

## ENTRY-03 Every amount is money spent, however it is typed

- Given Groceries is open
- When Robin adds four transactions, with the amount typed as 42.50, -42.50, (42.50) and $42.50
- Then each one shows as "$42.50", and each adds $42.50 to what is spent
- And an amount typed as $1,234.56 shows as "$1234.56"

## ENTRY-04 A note shows under the merchant

- Given Groceries is open
- When Robin adds Corner Bakery, 12.00, with "birthday cake" in "Note"
- Then Groceries lists Corner Bakery with "birthday cake" under it

## ENTRY-05 The newest transaction is on top

- Given it is October 18, and Groceries is open
- When Robin adds Corner Bakery dated Oct 3, then Hilltop, then Market, leaving both of their dates at today
- Then Groceries lists Market, then Hilltop, then Corner Bakery, from the top

## ENTRY-06 A date before this period keeps it out of this period

- Given it is October 18, and Groceries is open and holds no transactions
- When Robin adds Hilltop, 42.00, with "Date" set to Sep 28
- Then Groceries does not list it, and still says "$0.00" and "0 transactions since Oct 1"
- And it is kept all the same: deleting Groceries asks "Delete “Groceries”?" and says "Its 1 transaction will be deleted too. This cannot be undone."

## ENTRY-07 Cancel adds nothing

- Given the "New transaction" sheet is open, with Hilltop and 42.00 filled in
- When Robin presses "Cancel"
- Then the sheet closes, and nothing is added

## ENTRY-08 In a shared group, the list says who added each transaction

- Given Robin made Household and shared it with Leslie, who joined as Leslie
- When Groceries holds a transaction from each of them
- Then beside each one Groceries says who added it: "You" for his, and "Leslie" for hers
- And a transaction from someone who gave no name says "A member"
- And in a group nobody else is in, Groceries does not say who added anything

## ENTRY-09 A transaction someone else adds arrives at the next sync

- Given Robin and Leslie share Household, and Robin has Groceries open
- When Leslie adds Corner Bakery, 99.00, to Groceries in her app
- And Robin's app syncs
- Then Corner Bakery shows in his Groceries, added by "Leslie"
- And his Groceries counts it in what is spent and what is left

## ENTRY-10 At View there is no Add

- Given Leslie made Household and shared it with Robin at View
- When he opens Groceries
- Then there is no "Add" and no "Import statement"
- And Leslie, who made it, has both

## ENTRY-11 The keyboard adds and cancels

Platforms: Mac

- Given Groceries is open
- When Robin presses Command-N
- Then the "New transaction" sheet opens
- When he fills in Merchant and Amount and presses Return
- Then the transaction is added, and the sheet closes
- And Escape closes the sheet without adding anything

## ENTRY-12 Where a comma marks decimals, 12,50 is twelve fifty

- Given Robin's computer is set to a region that writes decimals with a comma, such as Germany
- And Groceries is open
- When he adds Hilltop Grocery with the amount "12,50"
- Then Hilltop Grocery shows $12.50 in Groceries' list
- And when he opens it again, its amount reads "12,50"

## ENTRY-13 An amount that can't be read clearly is refused, never guessed

- Given Robin's computer is set to a region that writes decimals with a dot, such as the United States
- And the "New transaction" sheet is open, with Hilltop Grocery as the merchant
- When he types "12,50" as the amount
- Then "Add" stays dimmed
- And under the amount it says "That amount can't be read clearly. Type it like 12.50."
- When he types "12.50" instead
- Then the line goes, and "Add" lights
- And where a comma marks decimals, such as in Germany, "1,250" is refused the same way, with "Type it like 12,50.", since a dollar has only two decimals. It is never read as $1250.00
