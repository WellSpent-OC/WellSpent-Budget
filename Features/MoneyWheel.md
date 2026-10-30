# The money wheel

The money wheel shows at a glance how the month is going. Each budget's row in the list fills from the left as its money is used. A budget's page shows its wheel: full before anything is spent, emptying as money goes out, with a tick where an even pace would be today. A group's wheel adds up all of its budgets. It counts budgets and what is spent from them, nothing else.

## WHEEL-01 A budget's row fills as far as its money is used

- Given Groceries is $500.00 a month, and $125.00 of it is spent this month
- When Robin looks at the list
- Then Groceries' row is filled from the left a quarter of the way
- And it still says $375.00 at the right
- And Eating out, with nothing spent this month, shows only its empty track

## WHEEL-02 Over its limit, the row fills all the way and says how far over

- Given Groceries is $100.00 a month, and $115.00 of it is spent this month
- When Robin looks at the list
- Then Groceries' row is filled all the way, in the over colour
- And at the right it says "$15.00 over"

## WHEEL-03 The open budget's row keeps its fill, with an outline

Platforms: Mac, Linux

- Given Groceries is half used, and Eating out a quarter
- When Robin picks Groceries in the sidebar
- Then Groceries' row keeps its fill, and a dark outline marks it in place of the usual highlight
- When he picks Eating out
- Then the outline moves to Eating out, and Groceries keeps its fill
- And while a group's page is open, no budget's row has the outline

## WHEEL-04 In dark mode, the rows use the dark colours

Platforms: iPhone

- Given Robin's iPhone is set to dark mode
- When he opens WellSpent
- Then each budget's row on Home has a dark track, a dark green fill, and a dark rust fill when over, with light words
- When he sets the iPhone back to light
- Then the rows show the light colours again

## WHEEL-05 A budget's page shows its wheel in place of the bar

- Given it is October 18, and Groceries is $1,000.00 a month with $555.36 spent this month
- When Robin opens Groceries
- Then under its name it says "October · day 18 of 31"
- And in place of the bar there is a wheel, and its middle says "Left", "$445" and "of $1,000"
- And beside the wheel it says "Spent" $555.36, "Left" $444.64 and "Expected left by today" $419.35

## WHEEL-06 The wheel is full before anything is spent, and empties as money goes out

- Given it is October 10, and Groceries is $1,000.00 a month with nothing spent this month
- When Robin opens Groceries
- Then its wheel is green all the way round
- When he adds $250.00 to it
- Then the green at once runs only three quarters of the way round, clockwise from the top
- And the wheel's middle says "$750"

## WHEEL-07 The tick marks where an even pace would be today

- Given it is October 18, day 18 of 31, and Groceries is $1,000.00 a month with $555.36 spent
- When Robin opens Groceries
- Then a tick crosses the wheel where the green would end today if he spent the same each day, 13 days in 31 of the way round from the top
- And "Expected left by today" says $419.35, the same share of $1,000.00
- And with more left than that, the green reaches past the tick

## WHEEL-08 Spending faster than an even pace turns the wheel orange and says when the money runs out

- Given it is October 18, and Gas is $180.00 a month with $122.00 spent
- When Robin, who may change budgets, opens Gas
- Then the filled part of its wheel is orange, and stops short of the tick
- And under the figures it says "At this pace, Gas runs out around Oct 26, five days early."
- And beside those words, "Edit Budget…" opens the Edit Budget sheet
- And Leslie, at Add, sees the same words with no button
- And Rent, $1,850.00 a month and paid in full on October 1, has nothing left to run out, so it says nothing about the pace

## WHEEL-09 In the month's last week, more left than expected offers to lower the budget

- Given it is October 26, and Groceries is $1,000.00 a month with $500.00 spent
- When Robin, who may change budgets, opens Groceries
- Then under the figures it says "$339 more left than expected by today. Keep this budget, or lower it for next month?"
- And beside those words, "Edit Budget…" opens the Edit Budget sheet
- And on October 24, before the month's last week, it says nothing about the pace
- And Leslie, at Add, is not asked

## WHEEL-10 Over its limit, a budget's wheel is orange all the way round and says how far over

- Given Groceries is $100.00 a month, with $115.00 spent this month
- When Robin opens Groceries
- Then its wheel is orange all the way round, with no tick
- And its middle says "Over", "$15" and "of $100"
- And beside the wheel it says "Spent" $115.00 and "Over" $15.00, with nothing about the pace
- And with $100.20 spent, its middle says "Over", "$1" and "of $100", never "$0"

## WHEEL-11 A group's page opens with its money for the month

- Given it is October 18, and Household holds Groceries, $1,000.00 a month with $555.36 spent, and Eating out, $300.00 with $110.60 spent
- When Robin clicks Household's name in the sidebar
- Then the page shows MONEY above PEOPLE
- And Household's wheel adds up both budgets, and its middle says "Left this month", "$634" and "of $1,300"
- And beside it, "Spent" $665.96, "Left" $634.04 and "Expected left by today" $545.16
- And on iPhone, the figures sit below the centered wheel
- And under them, "Day 18 of 31. Every budget in Household, added up."
- And it has the same tick as a budget's wheel, and stays green while the group is not over
- And a budget hidden in the sidebar still counts
- And a group with no budgets shows no MONEY

## WHEEL-12 Over the month's budgets, the group's wheel says how far over

- Given Household's budgets add up to $1,300.00, and $1,420.00 is spent from them this month
- When Robin looks at Household's wheel
- Then it is orange all the way round, with no tick
- And its middle says "Over this month", "$120" and "of $1,300"

## WHEEL-13 Home shows wheels only after opening a group or budget

Platforms: iPhone

- Given Household holds a budget
- When Robin opens WellSpent
- Then Home shows the groups and budgets with no summary card or wheel
- When Robin taps Household
- Then its group wheel shows
- When Robin returns Home and opens a budget
- Then that budget's wheel shows
- And returning Home shows no wheel

## WHEEL-14 Money in refills a group's wheel, never past full

Platforms: Mac, Linux, iPhone

- Given Household's budgets add up to $4,080.00, $2,777.96 is spent from them this month, and $1,230.00 of income has come in
- When Robin looks at Household's wheel
- Then it is green, filled to $2,532.04 of $4,080.00, with the tick where it was
- And with $4,800.00 of income instead, it is full, and "Left" says $4080.00

## WHEEL-15 A group's wheel says money in against money out, and the cash flow

Platforms: Mac, Linux, iPhone

- Given the same Household with $1,230.00 in
- When Robin looks at the wheel's middle
- Then it says "$1,230 in", "$2,778 out" and "−$1,548", with "this month" under it
- And beside the wheel "In" says +$1230.00 above "Spent" $2777.96
- And the note ends "added up, and money in."
- And with $4,800.00 in, the cash flow reads "+$2,022" in the word colour

## WHEEL-16 With no money in, a group's wheel looks exactly as before

Platforms: Mac, Linux, iPhone

- Given Household has no income this month
- When Robin looks at Household's wheel
- Then the middle says "Left this month", "$1,302" and "of $4,080", there is no "In" line, and the note ends "added up."
- And nothing differs from release 0.2.0

## WHEEL-17 Over the month's budgets while money in covers it, the wheel stays green and says so

Platforms: Mac, Linux, iPhone

- Given Household's budgets add up to $4,080.00, $4,500.00 is spent and $1,230.00 has come in
- When Robin looks at Household's wheel
- Then it is green, filled to $810.00, with its tick
- And under the figures, in the warning colour, "Over the month's budgets by $420.00. Money in covers it."

## WHEEL-18 Out beyond the budgets and the money in together turns the group's wheel orange

Platforms: Mac, Linux, iPhone

- Given $4,500.00 is spent and $200.00 has come in
- When Robin looks at Household's wheel
- Then it is orange all the way round with no tick
- And its middle says "$200 in", "$4,500 out" and "−$4,300"
- And beside it "Over" says $220.00 in the warning colour, and there is no "Expected left by today"

## WHEEL-19 Refunds, loan draws, savings draws, transfers and card payments never count as money in

Platforms: Mac, Linux, iPhone

- Given Household has a $50.00 refund to Groceries, a $500.00 loan draw, a $300.00 savings draw, a $200.00 transfer and a $900.00 card payment this month, and no income
- When Robin looks at Household's wheel
- Then there is no "In" line and the middle reads as WHEEL-16
- And Groceries' spent is $50.00 lower, as a refund does today
- And under the figures it says "$500.00 borrowed this month" and "$300.00 from savings this month"

## WHEEL-20 The tick marks spending pace, and money in does not move it

Platforms: Mac, Linux, iPhone

- Given it is day 18 of 31 and $4,800.00 has come in
- When Robin looks at Household's wheel
- Then the tick sits where it sits with no money in, and "Expected left by today" is unchanged
