# Clicking an invite link

Clicking an invite link lets someone join a group straight from the message it came in. WellSpent opens on an invitation page. The page says who invited them, to which group, what they could do there, and how much of it they would see. They type the name the group will see, press "Join", and the group's page opens. A link has no invite to decline, so the page has no Decline. Pasting a link into "Join a Group…" still works too (see Sharing.md).

## CLICK-01 A clicked invite link opens its invitation page

- Given Robin made a link to Household at Add, with "Everything so far", and sent it to Leslie
- And Leslie is signed in, with her email confirmed, and WellSpent is open
- When she clicks the link
- Then WellSpent comes to the front, on the invitation page
- And the page says "Robin invited you to “Household”." at once
- And once the server answers, it adds "You'd join at Add.", "Adds transactions, and edits or deletes their own." and "You'd see everything so far."
- And it asks for "Your name", with "How the group will see you" in the empty field, and has a "Join" button
- And the link itself is not shown, and there is no "Decline"

## CLICK-02 A click starts WellSpent when it is closed

- Given WellSpent is not running
- When Leslie clicks Robin's link
- Then WellSpent starts, and opens on the invitation page for Household

## CLICK-03 The page gives the invite's own level and history

- Given Robin's link invites at View, with "Only from now on"
- When Leslie clicks it
- Then the page says "You'd join at View.", "Sees every budget and transaction. Changes nothing." and "You'd see the group's budgets, and only transactions added from now on."

## CLICK-04 Join takes the group in and opens its page

- Given the invitation page for Robin's link is up, with "Join" dimmed
- When Leslie types "Leslie" in "Your name"
- Then "Join" lights
- When she presses "Join"
- Then the button says "Joining…" while it works
- And then Household is in her sidebar, and its page opens in place of the invitation, saying "Shared · 2 people · Made by Robin"
- And after Robin's next sync, his page for Household lists Leslie

## CLICK-05 Signed out, Sign in… stands in place of Join

- Given Leslie is signed out
- When she clicks Robin's link
- Then the page still says who invited her, the level, and what she would see
- And it says "Sign in first, or create an account. Joining adds the group to your account.", with a "Sign in…" button and no "Join"
- When she presses "Sign in…"
- Then the account sheet opens
- When she signs in there, to an account whose email is confirmed
- Then the invitation page is still up, with "Join" in place of the notice

## CLICK-06 Not confirmed yet, Confirm your email… stands in place of Join

- Given Leslie is signed in, and has not confirmed her email
- When she clicks Robin's link
- Then the page says "Confirm your email first. Joining a shared group needs it.", with a "Confirm your email…" button and no "Join"
- When she presses "Confirm your email…"
- Then the account sheet opens, where she can confirm her email
- When she confirms it there
- Then the invitation page shows "Join"

## CLICK-07 The page stays through making an account

- Given Leslie has no account, and is signed out
- And she clicked Robin's link, and typed "Leslie" in "Your name"
- When she presses "Sign in…", creates an account, and confirms her email with the code sent to it
- Then the invitation page is still up, with "Leslie" still in "Your name"
- And "Join" is lit, and takes her into Household

## CLICK-08 A link cut short says part of it is missing

- Given a message app cut Robin's link short
- When Leslie clicks it
- Then WellSpent opens on a page headed "Join a Group"
- And it says "Part of that invite link is missing. Ask the person who sent it to send it again."
- And there is no "Your name" and no "Join"

## CLICK-09 A used link says so

- Given Leslie is signed in, with her email confirmed
- And someone already joined Household with Robin's link, which works once
- When she clicks the link
- Then the page still says "Robin invited you to “Household”."
- And it has no level or history lines, and says "That invite was not found. It may have been cancelled."
- When she types her name and presses "Join" anyway
- Then it says "That invite has already been accepted.", and Household is not added

## CLICK-10 A link to a group you are in already

- Given Robin is signed in, with his email confirmed, and made a link to his own Household
- When he clicks it, types his name and presses "Join"
- Then the page says "You are already in that group."
- And the link is not used up, so it still works for Leslie

## CLICK-11 Another link replaces the page

- Given the invitation page for Household is up
- When Leslie clicks a link to another group
- Then that link's invitation page replaces it

## CLICK-12 Picking a budget or a group takes the page down

- Given the invitation page is up
- When Leslie picks one of her budgets in the sidebar
- Then the budget shows in place of the page
- And a click on a group's name instead opens that group's page in its place
- And the invitation comes back only by clicking the link again

## CLICK-13 A link from the other app says which app it is for

- Given Robin made a link to Household in WellSpent Staging, the test copy of the app
- When Leslie opens it in WellSpent, by pasting it or opening it by hand
- Then the page says "That invite link is for WellSpent Staging. Open it in WellSpent Staging."
- And there is no "Your name" and no "Join"
- And a link made in WellSpent says the same in WellSpent Staging, naming WellSpent
