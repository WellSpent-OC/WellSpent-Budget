# Sharing a group

Sharing lets two or more people keep one budget group together. The person who shares a group makes an invite link. They choose what the other person can do there: View, Add or Manage. They also choose whether that person sees everything so far, or only what is added from now on. The other person pastes the link into "Join a Group…", or clicks it (see ClickToJoin.md). After that, each person's entries reach the others at their next sync, marked with who added them. A member can leave a group, and someone who manages it can remove a member.

## SHARE-01 Share… asks for your name, what they can do and what they see

- Given Robin is signed in, and made Household
- When he opens Household's menu and picks "Share…"
- Then a sheet titled "Share “Household”" opens
- And it asks for "Your name", with "How the group will see you" in the empty field
- And "They can" offers "View", "Add" and "Manage", with "Add" chosen
- And "They see" offers "Everything so far" and "Only from now on", with "Everything so far" chosen
- And a line says what the chosen level lets someone do: "Sees every budget and transaction. Changes nothing." for View, "Adds transactions, and edits or deletes their own." for Add, and "Edits budgets, edits or deletes anyone's transactions, and invites other people." for Manage
- And "You get a link to send by text or email." sits beside "Cancel" and "Create Link"
- And "Create Link" stays dimmed until he types a name
- And the next time he shares Household, "Your name" already holds the name he used for it

## SHARE-02 Create Link makes a link that works once

- Given Robin is signed in, and the Share sheet for Household holds "Robin" as his name, with "Add" chosen
- When he presses "Create Link"
- Then the button says "Creating…" while it works
- And then the sheet shows the link, which starts "wellspent://join"
- And under it, "Send this to the person you are inviting. It works once and expires in 7 days."
- And it offers "Copy Link" and "Done"
- When he presses "Copy Link"
- Then the link is on the clipboard, ready to paste into a message
- When he presses "Done"
- Then the sheet closes

## SHARE-03 Send… hands the link to another app

Platforms: Mac, iPhone

- Given Robin made a link in the Share sheet
- When he presses "Send…"
- Then the system's ways to share open, with the link ready to send

## SHARE-04 Signed out, Share… makes no link

- Given Robin is signed out, with Household kept on this computer only
- When he opens Household's menu and picks "Share…"
- Then the sheet says "Sign in first. Sharing goes through your account."
- And "Create Link" stays dimmed, even with a name typed

## SHARE-05 Someone at Add cannot invite anyone

- Given Leslie is in Robin's Household at Add
- When she opens Household's menu and picks "Share…"
- Then the sheet says "Only a manager or admin can invite people to this group."
- And it offers no level to choose
- And "Create Link" stays dimmed

## SHARE-06 A manager can invite at View or Add, not Manage

- Given Leslie is in Robin's Household at Manage
- When she opens Household's menu and picks "Share…"
- Then "They can" offers "View" and "Add" only, with "Add" chosen

## SHARE-07 Pasting a link into Join a Group… joins the group

- Given Robin made a link to Household at Add, with "Everything so far", and sent it to Leslie
- And Leslie is signed in, with her email confirmed
- When she opens the menu beside "Add Budget" and picks "Join a Group…"
- Then a sheet titled "Join a Group" asks for "Invite link", with "Paste the link you were sent" in the empty field, and for "Your name"
- When she pastes the link
- Then the sheet says "Robin invited you to “Household”."
- And "Join" stays dimmed until she types a name
- When she types "Leslie" and presses "Join"
- Then the button says "Joining…" while it works
- And then the sheet closes, and Household is in her sidebar, with Robin's budgets and entries
- And his entries say "Robin" under "Added by"

## SHARE-08 A pasted link that is not whole says what is wrong

- Given Leslie has "Join a Group…" open
- When she pastes something that is not an invite link, such as a web address
- Then the sheet says "That is not a WellSpent invite link."
- When she pastes an invite link that a message app cut short
- Then the sheet says "Part of that invite link is missing. Ask the person who sent it to send it again."
- And "Join" stays dimmed either way

## SHARE-09 Joining needs a sign-in and a confirmed email

- Given Leslie is signed out
- When she pastes Robin's link into "Join a Group…"
- Then the sheet says "Sign in first, or create an account. Joining adds the group to your account."
- And "Join" stays dimmed
- Given Leslie is signed in, and has not confirmed her email
- When she pastes Robin's link into "Join a Group…"
- Then the sheet says "Confirm your email first. Joining a shared group needs it."
- And a "Confirm your email…" button closes the sheet and opens the account sheet
- When she types her name and presses "Join" anyway
- Then the sheet also says "Confirm your email address first, then try again.", and she is not added

## SHARE-10 A used link says it was already accepted

- Given someone already joined Household with Robin's link
- And Leslie is signed in, with her email confirmed
- When she pastes the same link into "Join a Group…", types her name and presses "Join"
- Then the sheet says "That invite has already been accepted."
- And she is not added to Household

## SHARE-11 At View, the person who joins sees everything and changes nothing

- Given Robin made a link to Household at View, and Leslie joined with it
- When she opens Groceries
- Then she sees Robin's entries, with "Robin" under "Added by"
- And there is no "Add" and no "Import statement"
- And Household's menu offers only "Share…", "People…" and "Leave…"
- And nothing offers to edit or delete Groceries

## SHARE-12 At Manage, the person who joins can change budgets

- Given Robin made a link to Household at Manage, and Leslie joined with it
- When she opens Household's menu
- Then it offers "New Budget in Household…" and "Rename…", and its last item is "Leave…"
- And Groceries offers her "Edit…" and "Delete…"
- And Groceries has "Add" and "Import statement"

## SHARE-13 Only from now on hides what came before

- Given Groceries in Household holds "Hilltop Grocery"
- And Robin made a link to Household with "Only from now on"
- When Leslie joins with the link and opens Groceries
- Then she sees Groceries without "Hilltop Grocery", and Groceries' total on her screen leaves it out
- When Robin adds "Costco" after she joined
- Then "Costco" reaches her at her next sync
- And "Hilltop Grocery" stays hidden from her, even after Robin changes it

## SHARE-14 Entries reach the others after a sync, with who added them

- Given Robin made Household, and his Groceries list has no "Added by" column while nobody else is in it
- And Leslie joined Household at Add, as "Leslie"
- When she adds "Costco", $99.00, to Groceries, and her app sends it a moment later
- And Robin presses "Sync", or leaves WellSpent open for up to two minutes
- Then "Costco" shows in his Groceries list, with "Leslie" under "Added by"
- And his own entries say "You" under "Added by"
- And Groceries' total counts it on both their screens

## SHARE-15 Leave… takes the group off your devices, and the others keep it

- Given Leslie is in Robin's Household at Add, and her computer holds its 1 budget and 2 transactions
- When she opens Household's menu, whose last item is "Leave…" and not "Delete…", and picks "Leave…"
- Then a question asks "Leave “Household”?", with "Leave" and "Cancel"
- And it says "You leave the group, and it is removed from all your devices, with its 1 budget and 2 transactions. The others in it keep it. Anything you changed in it on this device that has not synced yet still goes to them first. Changes on your other devices that have not synced yet do not reach them. Only the person who made it, or an admin, can delete it for everyone. To come back, ask for a new invite link."
- When she presses "Leave"
- Then Household goes from her sidebar, and from her other devices at their next sync
- And Robin keeps Household and all it holds, her entries included
- And after his next sync, Household's page lists only him
- And a new link from Robin brings Household back to her, whole
- And at View, the question leaves out the two sentences about changes not synced yet

## SHARE-16 Remove… takes a person out, and what they added stays

- Given Robin made Household, and Leslie joined at Add and added "Costco"
- When Robin presses "Remove…" in Leslie's row on Household's page
- Then a question asks "Remove Leslie?", with "Remove" and "Cancel"
- And it says "Leslie loses “Household” on every device. What they added stays."
- When he presses "Remove"
- Then Leslie's row goes, and "Leslie was removed." shows at the top of the page
- And the line under the group's name says "Not shared · Made by you"
- And "Costco" stays in his Groceries
- And Household goes from Leslie's sidebar at her next sync
