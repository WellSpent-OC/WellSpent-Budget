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

## PASTE-09 Every field on the account sheet takes a paste, the emailed code too

- Given Robin is not signed in
- When he pastes into "Email", "Password" and "Server" on "Sign in"
- And he pastes into "Email", "Password" and the password again on "Create account"
- And he asks for a reset code, then pastes the code as the email shows it, with its dash, and a new password twice
- Then each field that shows its words holds what he pasted
- And each step's main button turns on once its fields are pasted: "Sign in", "Create account" and "Set password"

## PASTE-10 The fields for making a group or a budget, and for joining, take a paste

- Given Robin is not signed in, with the sample groups
- When he pastes into a new group's name, and a new budget's name and amount, such as $1,250.00
- And he pastes an invite link and his name into "Join a Group…"
- Then each field holds what he pasted
