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
