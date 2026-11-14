# Repeat expenses

A bill that comes every month, such as a phone bill, can repeat. It shows up on its day each month, and a change can reach one month or that month and later. This is for everyone, with Properties on or off.

## REPEAT-01 Setting a repeat

Platforms: Mac, Linux, iPhone

- Given Robin is adding an $85.00 phone bill to Utilities
- When he turns on "Repeats every month" and saves
- Then the bill is in Utilities once, and it repeats on that day of each month

## REPEAT-17 Turning it on for a bill already there

Platforms: Mac, Linux, iPhone

- Given Utilities has a $40.00 water bill Robin added on the 5th of this month
- When he opens it, turns on "Repeats every month" and saves
- Then the bill is in Utilities once, with its date, its note and who added it unchanged
- And its source says "Repeat", and the count line says "1 repeat"
- And next month has one water bill, not two
- And only the person who added a bill can turn this on. A manager who opens someone else's bill sees the switch off and dimmed, and the bill stays as it is

## REPEAT-18 The switch shows the truth

Platforms: Mac, Linux, iPhone

- Given a bill a repeat made, in any month
- When Robin opens it
- Then "Repeats every month" is on, and turning it off is the only thing the switch can do
- When he turns it off and saves
- Then the repeat stops, as "Stop repeating" does, and the bills already made stay
- And when he opens the bill again, the switch is off
- When he turns it on and saves
- Then that same repeat starts again from this month, and the months it was stopped aren't made
- And someone who may change the bill but not the repeat sees the switch, dimmed
- And on a read-only sheet, a repeat's bill has a plain row, "Repeats every month" with "On", or "Off" once it has stopped

## REPEAT-02 It shows up each month

Platforms: Mac, Linux, iPhone

- Given the phone bill repeats on the 14th
- When December 14 comes and Robin opens the app
- Then a new $85.00 bill is in Utilities, with Source reading Repeat

## REPEAT-03 Catching up after time away

Platforms: Mac, Linux, iPhone

- Given Robin didn't open the app for two months
- When he opens it
- Then each month that has come has its bill, one each

## REPEAT-04 A short month

Platforms: Mac, Linux, iPhone

- Given a bill repeats on the 31st
- Then in November it shows up on the 30th

## REPEAT-05 Two devices make one bill

Platforms: Mac, Linux, iPhone

- Given Robin's Mac and iPhone are both signed in
- When both open after the 14th
- Then there is one bill for that month

## REPEAT-06 This month only

Platforms: Mac, Linux, iPhone

- Given December's phone bill is $85.00
- When Robin changes it to $92.00 and chooses "This month only"
- Then December is $92.00 and January is $85.00
- And "Which months?" is on the sheet with the bill's other fields, starting on "This month only"

## REPEAT-07 This month and later

Platforms: Mac, Linux, iPhone

- When Robin changes December's bill to $92.00 and chooses "This month and later"
- Then December and every later month are $92.00
- And months before December stay as they were

## REPEAT-08 Stopping

Platforms: Mac, Linux, iPhone

- When Robin chooses "Stop repeating"
- Then no later month is made, and months already made stay
- And it leaves the count of repeats and the short list at once, and this month's bill stays

## REPEAT-09 Deleting a made bill asks

Platforms: Mac, Linux, iPhone

- When Robin deletes December's bill
- Then he's asked "Delete This Month Only" or "Delete and Stop Repeating"
- And the second deletes this month's bill and makes no later month, and earlier months stay
- And a month deleted this way doesn't come back

## REPEAT-10 Undo

Platforms: Mac, Linux, iPhone

- Given Robin just deleted a made bill, or stopped a repeat
- When he chooses Undo
- Then the bill returns, or the repeat carries on, and both return if he chose "Delete and Stop Repeating"

## REPEAT-11 Only the owner or a manager changes the rule

Platforms: Mac, Linux, iPhone

- Given Robin set the repeat, and Leslie is at Add level
- When Leslie changes a made bill she can edit
- Then she's offered only "This month only"

## REPEAT-12 Finding them all

Platforms: Mac, Linux, iPhone

- Given Utilities has two repeats
- Then its count line says "2 repeats", which opens a short list
- And choosing a row opens that repeat's own sheet, which changes this month and later, or stops it
- And someone other than the owner or a manager sees that sheet with nothing to change
- And a budget with none doesn't say it

## REPEAT-13 Money in doesn't repeat

Platforms: Mac, Linux, iPhone

- Given Robin is adding money in
- Then there is no "Repeats every month" row

## REPEAT-14 A statement line replaces that month's repeat

Platforms: Mac, Linux, iPhone

- Given December's $85.00 phone bill was made, and a statement has an $85.40 line on Dec 15
- When Robin imports it to Utilities
- Then the review row says "Replaces December's Phone bill, $85.00", under the Matched tile
- And if he goes ahead, the statement line takes its place and the bill counts once
- And the bank's line takes the bill's budget and its house mark, so NOI and the wheel don't move because of the swap
- A match is a made bill not already matched, in this group and the line's budget, within 4 days and within 10 percent or $5, whichever is larger. If two fit, the closest date wins
- An exact amount on a made bill works the same way: the bank's line wins

## REPEAT-15 Saying no to a match

Platforms: Mac, Linux, iPhone

- When Robin presses "Keep both" on that match
- Then both stay, and neither is changed

## REPEAT-16 A house's repeat

Ruling, 2026-11-13: Linux added. The Platforms line was out of date: Linux has Houses now, and the apps match feature for feature.

- Given Properties is on and Robin sets a repeat with House set to Pool House
- Then each month's bill is marked with Pool House
