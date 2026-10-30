# Properties

Properties is a paid extension for rental houses: bookings, income into the budget, and each house's page with its runway. It plugs into the core through one seam: a feature flag, a card in the Extensions catalog, a Houses place on the rail or in the tabs, and a field that marks a group as claimed by an extension. The core knows nothing else about it, and switching it off cannot change a budget. The houses, their bookings and the PriceLabs importer live in a private package; what is here is the door.

The people are Robin (he) and Leslie (she), as in every feature file.

## PROP-01 Properties appears in the catalog and joins the rail when turned on

Platforms: Mac, Linux, iPhone

- Given a staging build with extensions on
- When Robin opens Extensions and turns on Properties
- Then Houses appears on the rail (desktop) or as a tab (iPhone) beside Budgets
- And the Budgets screens look exactly as before

## PROP-02 With Properties off, nothing of it shows

Platforms: Mac, Linux, iPhone

- Given a live build, or Properties turned off
- When Robin uses the app
- Then there is no Houses on the rail, no Properties tab, and no house group marked as one

## PROP-04 All houses at a glance

- Given Robin has three houses with money in and out this month
- When he opens Houses
- Then he sees cash flow this month for all houses, booked against break-even, and nights booked in the next 30 days
- And one card per house with its wheel, its cash flow in the middle, and the day the mortgage was covered, or "Not covered yet"

## PROP-05 A house below break-even reads as rust

- Given City Loft has more money out than in this month
- When Robin looks at Houses
- Then City Loft's wheel, its cash flow and its sidebar row are in the over colour
- And its cash flow carries a minus sign

## PROP-06 Needs you lists today's turnover and tomorrow's check-in

- Given Pool House has a check-out at 10:00 AM and a check-in at 4:00 PM today, from its bookings
- When Robin opens Houses
- Then Needs you says "Turnover today at Pool House" with both times
- And a check-in tomorrow at City Loft is listed under it

## PROP-07 Needs you names an empty night between two stays

- Given Mountain Cabin has a stay ending Oct 23 and the next starting Oct 25
- When Robin opens Houses
- Then Needs you says "One empty night at Mountain Cabin, Oct 24"

## PROP-08 Needs you is empty when nothing needs him

- Given no turnover, no check-in, no gap night and every house above break-even
- When Robin opens Houses
- Then Needs you says there is nothing to do today, in one plain sentence

## PROP-14 Connecting PriceLabs brings in bookings as income entries

- Given Robin pastes his PriceLabs key
- When the connection is made
- Then his listings are offered as houses to confirm
- And a listing with no group yet gets a new group named for the listing, claimed by Properties, which he can rename
- And a listing he does not confirm makes nothing
- And each confirmed booking becomes an income entry on that house, plus a booking with its dates and nights
- And the Houses screen says when PriceLabs last brought bookings in

## PROP-15 The key stays on the person's devices, and WellSpent only reads

- Given PriceLabs is connected
- Then the key is never sent to WellSpent's server
- And WellSpent never changes a price in PriceLabs

## PROP-17 A paused connection says so, calmly

- Given the PriceLabs key stops working
- When Robin opens Houses
- Then a line says PriceLabs is paused and the date of the last bookings it brought in
- And a "Reconnect" button opens the key sheet
- And nothing already brought in is lost
