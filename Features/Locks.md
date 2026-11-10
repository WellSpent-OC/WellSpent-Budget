# Locks

When a paid plan ends, nothing is deleted. The free plan keeps 1 group, 1 person and 1 property open, and the rest is locked until a plan is picked. The person who pays picks what stays open. Anyone in a locked group can pay to open it for everyone in it.

## LOCK-01 A group the payer kept locked shows why, in place of its page

- Given Robin's paid plan has ended, and his group "Beach" is locked while "Home" is open
- When he opens "Beach"
- Then he sees "This group is locked" in place of its page
- And it says "Your free plan keeps 1 group open: Home."
- And it says "The people in this group can't see it either."
- And it offers "See Plans"

## LOCK-02 A group whose payer is past their plan asks a member to pay for it

- Given Leslie pays for "Cabin", which Robin joined, and her paid plan has ended with "Cabin" locked
- When Robin opens "Cabin"
- Then he sees "This group needs a paid plan" in place of its page
- And it says "Leslie's plan doesn't cover it right now."
- And it says "Paying opens it for everyone in it. Nobody else is charged."
- And it offers "Pay for This Group"

## LOCK-03 A locked group says Locked beside its name

- Given Robin's group "Beach" is locked
- When he looks at his groups
- Then "Beach" says "Locked" beside its name
- And "Home", which is open, does not

## LOCK-04 Change what stays open saves the pick

- Given Robin's paid plan has ended, and his account shows "Change what stays open"
- When he presses it
- Then "Pick what stays open" lists his groups, with the open one picked
- And when he picks another group and presses "Keep These Open", the pick is saved and the sheet closes

## LOCK-05 Skip keeps the first ones, and says so before

- Given "Pick what stays open" is open for Robin
- Then it says which group, person and property Skip keeps open
- And when he presses "Skip", those are saved and the sheet closes

## LOCK-06 A locked property says which one is open

- Given Robin is on the free plan with 2 properties, and "Pool House" is open
- When he opens "Mountain Cabin"
- Then he sees "This property is locked" in place of its page
- And it says "Your free plan keeps Pool House open."
- And it offers "Switch Which Is Open" and "See Plans"

## LOCK-07 The open group changes at most once in 30 days

- Given Robin changed his open group 10 days ago
- When he opens "Pick what stays open"
- Then it says "You can change the open group on" a date 30 days after the change
- And picking another group changes nothing
