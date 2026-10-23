# Email invitations

Invite someone by email from a group's Share menu. An invitation waits separately from membership: the recipient sees it beside their groups, and the sender sees Pending under People. Only accepting adds the recipient to the group. The email also contains a link that opens an invitation page and the app. Existing accounts sign in in the app; new people create and confirm an account there using the invited address.

## EMAIL-01 Send an invitation by email and see Pending

- Given Robin owns Household and is signed in with a confirmed email
- When he chooses Share…
- Then "Invite someone to “Household”" asks for Their email, Their name and Your name
- And Send Invite stays disabled until the email and both names are valid
- And the offered roles and history choices follow his permissions
- When he enters Leslie's email and name, his name, and presses Send Invite
- Then WellSpent creates the invitation for Leslie's address and queues its email
- And Done closes the sheet
- And Leslie appears under People as Pending, without being counted as a member
- And Pending means she has not answered, not that the email was delivered
- And no copying a link or choosing another mail app is needed
- And a second pending invitation to that address in that group is refused

## EMAIL-02 An invitation appears beside the recipient's groups

- Given Robin has invited Leslie to Household
- When Leslie signs in with that confirmed email and syncs
- Then Household appears as Invited beside her groups, with Robin's name and Accept and Reject
- And it shows the role and history she will receive
- And she cannot yet open its budgets or transactions
- And it does not affect her totals
- And another account cannot see or accept her invitation

## EMAIL-03 Accept adds the recipient and the group's budgets

- Given Leslie sees Household's invitation in her group list
- When she presses Accept
- Then Household becomes a joined group and opens
- And every budget in it appears after sync, subject to the offered history choice
- And her invited name appears under People even at View
- And Robin's next sync shows her as a member and removes the Pending row
- And the invitation can only be accepted once

## EMAIL-04 Reject ends the invitation and requires a fresh one

- Given Leslie sees Household's invitation
- When she presses Reject
- Then WellSpent asks her to confirm and explains that joining later needs a new invitation
- And Cancel leaves the invitation waiting
- When she confirms Reject
- Then the invitation leaves her group list without adding any budgets or membership
- And it stays gone after reopening and syncing
- And Robin sees Rejected under People
- And the old email link cannot grant access
- When Robin sends a new invitation to Leslie
- Then she can accept that new invitation

## EMAIL-05 The sender can cancel a pending invitation

- Given Robin sees Leslie's Pending invitation under People
- When he chooses Cancel Invite
- Then WellSpent asks for confirmation and says she will no longer be able to accept it
- And Cancel leaves it waiting
- When he confirms Cancel Invite
- Then the pending row goes away and Leslie loses the invitation at her next sync
- And neither her Accept button nor the email link can grant access
- And Robin may send a fresh invitation later

## EMAIL-06 Invitations enforce account and group permissions

- Given Robin is signed out or has not confirmed his email
- Then he cannot send an invitation
- Given Leslie has Add access to Household
- Then she cannot invite anyone
- Given Leslie has Manage access
- Then she may invite at View or Add, following the existing group permissions
- And an invitation cannot be accepted after its sender loses permission to grant that role
- And forwarding an addressed invitation never lets a different account accept it

## EMAIL-07 Pending invitations survive reopening and failed requests

- Given Leslie has not answered an invitation
- When she quits, opens WellSpent and signs in to the same account
- Then syncing restores the invitation beside her groups
- When accepting or rejecting fails
- Then the app shows the failure and allows a retry without pretending the request succeeded
- And signing out clears that account's invitations from the screen

## EMAIL-08 Email delivery and existing invitation links

- Given an invitation is pending
- Then its email provides one invitation link, the expiry and a way to stop invitation emails
- And the invitation page opens WellSpent without asking for a password on the website
- And opening that page alone never accepts or rejects an invitation
- And a temporary email service failure is retried without creating another invitation
- And expired, rejected or cancelled invitations cannot be accepted
- And links received from an earlier WellSpent version still work until used, cancelled or expired
