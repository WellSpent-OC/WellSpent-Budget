# A group's page

A group's page shows who is in a budget group and what each of them can do. A click on the group's name opens it, in place of a budget. Someone who runs the group invites people from it, and changes what they can do. Everyone else sees the same page with labels only, and can leave the group from it. Removing someone from the page is in Sharing.md.

## PAGE-01 A click on a group's name opens its page

- Given Household holds Groceries, and Groceries is open
- When Robin clicks Household's name in the sidebar
- Then Household's page opens in place of Groceries, headed "Household"

## PAGE-02 People… in the group's menu opens the same page

- Given Groceries is open
- When Robin opens Household's menu and picks "People…"
- Then Household's page opens, as a click on its name does

## PAGE-03 A budget takes the page's place

- Given Household's page is open
- When Robin clicks Groceries in the sidebar
- Then Groceries shows in place of the page
- And a new budget, once saved, opens in place of the page the same way

## PAGE-04 The sidebar marks the group whose page is open

Platforms: Mac, Linux

- Given Groceries is open
- When Robin clicks Household's name in the sidebar
- Then the name is marked while its page shows, and no budget is picked
- When he clicks Groceries
- Then Groceries is picked, and Household's name is no longer marked

## PAGE-05 The arrow at the end of a group's line hides and shows its budgets

- Given Household's budgets show in the sidebar
- When Robin clicks the arrow at the end of Household's line
- Then its budgets are hidden, and the arrow is labelled "Show budgets"
- And no page opens or closes
- When he clicks the arrow again
- Then the budgets show, and the arrow is labelled "Hide budgets"
- And a group left hidden stays hidden after WellSpent is quit and opened again

## PAGE-06 The line under the name says whether it is shared, how many, and who made it

- Given Robin made Household and shared it as "Robin", and Leslie joined it
- When Robin opens Household's page
- Then the line under "Household" says "Shared · 2 people · Made by you"
- And on Leslie's page for Household it says "Shared · 2 people · Made by Robin"
- And for a group of Robin's that nobody else is in, it says "Not shared · Made by you"

## PAGE-07 Signed out, the page says only that it is not shared

- Given Robin is signed out, with Household kept on this computer only
- When he clicks Household's name
- Then the page shows "Household" and "Not shared", and lists nobody
- And "Invite Someone…" opens the Share sheet, which says "Sign in first. Sharing goes through your account."

## PAGE-08 PEOPLE lists everyone, with their level and what it lets them do

- Given Robin made Household, and Leslie joined it at Add
- When Robin opens Household's page
- Then under "PEOPLE", "Robin (you)" comes first, at "Owner", with "Made the group. Can do everything, and delete it for everyone."
- And "Leslie" comes next, at "Add", with "Adds transactions, and edits or deletes their own."
- And the person who made the group always comes first, then everyone else from the highest level down, then by name

## PAGE-09 The owner may change anyone's level, remove them and invite

- Given Robin made Household, and Leslie is in it at Add
- When Robin opens Household's page
- Then Leslie's row has a level list set to "Add", offering "View", "Add", "Manage" and "Admin"
- And her row has a "Remove…" button
- And his own row shows "Owner" as a plain label, with no "Remove…"
- And "Invite Someone…" shows at the top of the page
- And there is no "Leave Group…", because the person who made a group deletes it instead

## PAGE-10 Changing someone's level from their row

- Given Robin has Household's page open, and Leslie is at Add
- When he picks "View" in Leslie's level list
- Then her row says "Sees every budget and transaction. Changes nothing."
- And once her app syncs, her budgets in Household show no "Add" and no "Import statement"
- When he picks "Admin" for her instead
- Then her row says "Can do what a manager does, and make or remove other managers and admins."

## PAGE-11 A manager may change and remove only people below Manage

- Given Leslie is at Manage in Robin's Household, and a third person is in it at Add
- When Leslie opens Household's page
- Then the third person's row offers "View" and "Add", and "Remove…"
- And Robin's row and her own show their levels as plain labels, with no "Remove…"
- And "Invite Someone…" shows, and "Leave Group…" is at the bottom

## PAGE-12 At Add or View, the page shows labels only, and Leave Group…

- Given Leslie joined Robin's Household at Add
- When she opens Household's page
- Then Robin's row shows "Owner", and "Leslie (you)" shows "Add", both as plain labels
- And there is no level list, no "Remove…" and no "Invite Someone…"
- And "Leave Group…" is at the bottom
- And at View the page is the same, with "View" as her label

## PAGE-13 Invite Someone… opens the Share sheet

- Given Robin has Household's page open
- When he presses "Invite Someone…"
- Then the "Share “Household”" sheet opens, as "Share…" in the group's menu does
- When he presses "Cancel"
- Then the sheet closes, and the page is still open

## PAGE-14 Leave Group… asks first, and always leaves

- Given Robin made Leslie an admin of Household, so its menu offers her "Delete…"
- When she presses "Leave Group…" on Household's page
- Then a question asks "Leave “Household”?", with "Leave" and "Cancel"
- And its words start "You leave the group, and it is removed from all your devices"
- When she presses "Cancel"
- Then nothing changes
- When she presses "Leave Group…" again, and then "Leave"
- Then Household and its page go from her computer
- And Robin keeps Household, with nothing deleted, and after his next sync his page lists only him

## PAGE-15 Someone who joins shows without opening the page again

- Given Robin made a link to Household, and its page is open on his computer, saying "Not shared · Made by you"
- When Leslie joins with the link
- Then at Robin's next sync her row shows, and the line says "Shared · 2 people · Made by you"
- And a page opened after she joined shows her at once

## PAGE-16 The page stays open until its own group goes

Platforms: Mac, Linux

- Given Robin has Household's page open, and also has a group called Side Business
- When he deletes Side Business from its menu in the sidebar
- Then Household's page stays open
- When he deletes Household from its menu
- Then Household's page closes
