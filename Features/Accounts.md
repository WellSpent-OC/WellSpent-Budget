# Accounts

An account keeps Robin's budgets on WellSpent's server, so they sync to his other devices and he can share them. Without one, WellSpent still works, and his budgets stay on the one computer. These scenarios cover making an account, confirming its email with a code, signing in and out, a forgotten password, the name each device goes by in the account, and the orange bar that marks a staging build, the version of the app made for testing.

## ACCT-01 Signed out, budgets are kept on this computer only

- Given Robin is not signed in
- When WellSpent opens
- Then the foot of the list says "Kept on this computer only", with a "Sign in" button
- And no "Sync" button shows
- When he signs in
- Then the foot of the list says "Syncs through WellSpent's server"
- And it still says so when a sync fails, because he is still signed in

## ACCT-02 Create an account

- Given Robin is not signed in
- When he presses "Sign in", then "Create an account"
- Then the sheet shows "Create an account", with "Email", "Password", "Confirm password" and "Server"
- And it says "Your budgets sync through WellSpent's server. Connections and backups are encrypted. The server can read your budgets. That's how it checks who may change what, and why resetting a forgotten password doesn't lose your budgets."
- And "Create account" stays dimmed until Email, Password and Confirm password all hold something
- When he types "Robin@Example.com", types the same password of at least 10 characters in both password fields, and presses "Create account"
- Then the sheet moves on to "Confirm your email" and says "Enter the code sent to robin@example.com."
- And the foot of the list says "Syncs through WellSpent's server"
- And the live server emails him a code, with a subject such as "Your WellSpent code: ABCD-EFGH"
- And the staging server sends no email, and puts the code in its log instead

## ACCT-03 Create an account says what is wrong before sending

- Given Robin is on "Create an account"
- When he types "robin" as the email, "short" as the password and something else in "Confirm password", and presses "Create account"
- Then under each field it says what is wrong: "That does not look like an email address.", "A password needs at least 10 characters." and "The two passwords are not the same."
- And nothing is sent, and he is still not signed in

## ACCT-04 An email that already has an account

- Given an account already exists for robin@example.com
- When Robin tries to create an account with that email
- Then the sheet stays on "Create an account" and says "That email already has an account. Sign in, or reset its password."
- And he is still not signed in, and the budgets on this computer stay as they were

## ACCT-05 Confirm the email with the code

- Given Robin has just made his account, and the sheet says "Enter the code sent to robin@example.com."
- Then "Confirm" stays dimmed until the "Code" field holds all 8 letters and numbers
- When he types the code from the email, in capitals or not, with or without its dash, and presses "Confirm"
- Then the sheet moves to "Your account" and says "Your email is confirmed."
- And it says "Signed in as robin@example.com.", with "Change password…", "Sign out", "Sign out everywhere…" and "Done"
- And the email is still confirmed after WellSpent is quit and opened again

## ACCT-06 A wrong code, and another code

- Given the sheet says "Enter the code sent to robin@example.com."
- When Robin types a wrong or expired code and presses "Confirm"
- Then it says "That code is wrong or has expired." and stays on "Confirm your email"
- When he presses "Send another code"
- Then it says "If a code was sent in the last minute, use that one. Otherwise a new code is on its way. Only the newest code works."

## ACCT-07 An email not confirmed yet is asked for again

- Given Robin's account has not confirmed its email, for example because he pressed "Not now" on another computer
- When he signs in
- Then the sheet moves to "Confirm your email", says "Confirm your email so a forgotten password can be reset, and so you can join shared budgets." and offers "Send a code"
- When he presses "Not now"
- Then the sheet closes, and he stays signed in
- When he later opens "Account" with a budget open
- Then "Your account" says the same words, with a "Confirm your email…" button that leads back to the code

## ACCT-08 Sign in

- Given Robin has an account with a confirmed email and some budgets, and is not signed in on this computer
- When he presses "Sign in", types his email and password, and presses "Sign in"
- Then the sheet closes, and the list shows his account's budgets, brought in by a sync
- And none of the budgets this computer keeps when nobody is signed in show
- And the foot of the list says "Syncs through WellSpent's server"
- And on a Mac or Linux, "Account" and "Sync" buttons show in place of "Sign in"
- And on an iPhone, "Account" shows in place of "Sign in", and pulling Home down syncs
- And he is still signed in after WellSpent is quit and opened again

## ACCT-09 A wrong password

- Given Robin is not signed in
- When he signs in with a wrong password, or with an email that has no account
- Then the sheet stays on "Sign in" and says "That email or password is wrong."
- And nothing syncs, and the foot of the list still says "Kept on this computer only", with no failure under it
- And after too many tries in a short time, it says "Too many attempts. Try again in a few minutes."

## ACCT-10 Forgot password

- Given Robin has an account with a confirmed email, and is not signed in
- When he types his email on "Sign in" and presses "Forgot your password?"
- Then the sheet shows "Reset your password", with his email already filled in
- When he presses "Send code"
- Then it says "If robin@example.com has an account and has been confirmed, a code is on its way. It lasts 30 minutes."
- And it asks for "Code", "New password" and "Confirm password", with "Start over" to go back to the email
- When he types the code from the email and a new password twice, and presses "Set password"
- Then the sheet moves to "Your account" and says "Your password is changed, and you are signed in. Every other device was signed out."
- And an email that was never confirmed gets no code, though the sheet says the same words

## ACCT-11 Sign out

- Given Robin is signed in, with a budget open
- When he presses "Account", then "Sign out"
- Then the sheet closes, and the foot of the list says "Kept on this computer only"
- And the list shows what this computer keeps when nobody is signed in, and none of his account's budgets
- And he is signed out even when the server cannot be reached
- And he is still signed out after WellSpent is quit and opened again
- When he signs in again
- Then his account's budgets are back

## ACCT-12 Sign out everywhere asks first

- Given Robin is signed in, with a budget open
- When he presses "Account", then "Sign out everywhere…"
- Then it asks "Sign out everywhere?" and says "Every device signed in to this account is signed out, this one too. Each device keeps its budgets."
- And it offers "Sign Out Everywhere" and "Cancel"
- When he presses "Cancel"
- Then nothing changes, and he stays signed in
- When he presses "Sign Out Everywhere"
- Then the sheet closes, and this computer is signed out
- And if the server cannot be reached, he stays signed in, and the sheet says why, such as "This computer is not connected to the internet."

## ACCT-13 Signed out from another device

- Given Robin is signed in on his laptop and on his desktop
- When he signs out everywhere on the desktop, or changes or resets his password there
- Then at the laptop's next sync, its sign-in sheet opens by itself, with his email filled in
- And it says "You were signed out on this device. Sign in again. Your budgets are still here."
- And behind the sheet, the list shows what the laptop keeps when nobody is signed in
- When he signs in again on the laptop
- Then his account's budgets are back

## ACCT-14 Each device is listed by its own name

- Given Robin's Mac is named "Robin's MacBook" in System Settings
- When he signs in on it
- Then his account's list of signed-in devices, which the server keeps, names it "Robin's MacBook"
- And not a network name such as "robins-macbook.local"
- And a Linux computer is listed by its host name, the computer's own name, without ".local"
- And an iPhone is listed as "iPhone"
- And signing in does not wait on the network to look up the name
- And the app has no screen for this list yet

## ACCT-15 A staging build says so across the top

- Given a staging build of WellSpent, the version made for testing
- When it opens
- Then an orange bar across the top says "STAGING"
- Given the live build
- When it opens
- Then there is no bar

## ACCT-16 On a Mac, the Dock says STAGING too

Platforms: Mac

- Given a staging build on a Mac
- When it opens
- Then its Dock icon carries a "STAGING" badge
- When Robin holds the pointer over the orange bar
- Then it says "A test build, with its own budgets. It never connects to the live server."
