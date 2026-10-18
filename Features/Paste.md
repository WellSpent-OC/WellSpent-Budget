# Copy and paste

Every text field takes the usual editing commands, so a code, an email, a password or an invite link copied from somewhere else can be pasted in. On a Mac they are Command-V to paste, Command-C to copy, Command-X to cut, Command-A to select all and Command-Z to undo, and they are in the Edit menu too. On Linux they are Ctrl+V, Ctrl+C, Ctrl+X and Ctrl+A. On an iPhone, Paste, Copy, Cut and Select All are in the menu a text field shows when it is touched and held. The scenarios say paste, copy, cut and select all, in whichever of these forms the device has.

## PASTE-01 Paste puts copied text into a field

- Given Robin is not signed in, and he has copied robin@example.com
- When he presses "Sign in" and pastes into "Email", with Command-V on a Mac, Ctrl+V on Linux, or Paste in the field's menu on an iPhone
- Then Email shows robin@example.com

## PASTE-02 Sign in by pasting the email and the password

- Given Robin has an account, and he is not signed in
- When he pastes his email into "Email" and his password into "Password", and presses "Sign in"
- Then he is signed in, and the foot of the list says "Syncs through WellSpent's server"

## PASTE-03 Paste an invite link to join a group

- Given Leslie sent Robin an invite link to Household, and he copied it
- When he chooses "Join a Group…" and pastes the link into "Invite link"
- Then the field holds the whole link, and the sheet says "Leslie invited you to “Household”."

## PASTE-04 Select all, then typing replaces the whole field

- Given a transaction's sheet is open, with Hilltop in "Merchant"
- When Robin selects all in Merchant and types Probe
- Then Merchant shows Probe, and nothing of Hilltop is left
- And select all works the same in "Amount" and "Note"

## PASTE-05 Copy, then paste, brings the copied words back

- Given a transaction's sheet is open, with Probe in "Merchant"
- When Robin selects all, copies, types X over it, then selects all again and pastes
- Then Merchant shows Probe
- And copy and paste work the same in "Amount" and "Note"

## PASTE-06 Cut takes the words out, and paste puts them back

- Given a transaction's sheet is open, with weekly shop in "Note"
- When Robin selects all and cuts
- Then Note is empty
- When he pastes
- Then Note shows weekly shop again

## PASTE-07 Undo takes back a paste

Platforms: Mac

- Given a transaction's sheet is open, and Robin has just pasted Probe over X in "Merchant"
- When he presses Command-Z
- Then Merchant shows X again

## PASTE-08 The Edit menu holds the editing commands

Platforms: Mac

- Given WellSpent is open
- When Robin opens the Edit menu in the menu bar
- Then it offers Undo, Redo, Cut, Copy, Paste and Select All
- And their keys are Command-Z, Shift-Command-Z, Command-X, Command-C, Command-V and Command-A
- When the cursor is in a field and he picks Paste from the Edit menu
- Then the copied text goes into that field
