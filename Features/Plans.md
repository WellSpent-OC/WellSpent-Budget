# Plans

Every account starts on the free plan, which never ends. A paid plan, in one of three sizes, opens more properties, groups and people. The server says which plan an account has; every app shows its answer. On the Mac and iPhone a plan is bought through Apple. On Linux it is bought on wellspent.space.

## PLAN-01 Account shows the free plan

- Given Robin is signed in on the free plan
- When he opens his account
- Then under "Your plan" he sees "Free plan", with a "Free" badge
- And it says "1 property, sync on every device, and 1 group shared with 1 person."
- And it says "Free forever. No card, no end date."
- And it offers "See Plans"

## PLAN-02 See Plans opens Choose a plan, with the plan that fits picked

- Given Robin is on the free plan with 1 property
- When he presses "See Plans"
- Then "Choose a plan" opens on Monthly
- And it lists Starter at $19 a month, Growth at $49 a month and Portfolio at $99 a month
- And Starter is picked

## PLAN-03 Yearly shows each plan's yearly price

- Given "Choose a plan" is open on Monthly
- When Robin picks Yearly
- Then it lists Starter at $190 a year, Growth at $490 a year and Portfolio at $990 a year
- And Yearly says "2 months free"

## PLAN-04 On Linux, Continue opens the website's checkout for the picked plan

Platforms: Linux

- Given the app sells plans, and "Choose a plan" is open on Yearly with Growth picked
- When Robin presses "Continue on wellspent.space"
- Then the website's checkout opens for Growth, yearly
- And the sheet closes

## PLAN-05 More than 15 properties offers an email to us

Platforms: Linux

- Given "Choose a plan" is open
- When Robin presses "Email us" under "More than 15 properties?"
- Then an email to dev@wellspent.space opens

## PLAN-06 Account shows a paid plan with its price and when it renews

Ruling, 2026-11-13: kept on Linux. A Linux person with an Apple plan still needs to see its state. Linux offers no button for it, so its last line differs.

- Given Robin pays for Growth monthly through Apple, with 3 properties
- When he opens his account
- Then the card says "Growth · $49 a month"
- And it says "Up to 5 properties. You have 3."
- And it says when it renews, and that it was bought through Apple
- And on the Mac and iPhone it offers "Change Plan"
- And on Linux it says the plan is managed on the Mac or iPhone, with no button

## PLAN-07 A yearly plan shows its yearly price

- Given Robin pays for Growth yearly
- When he opens his account
- Then the card says "Growth · $490 a year"

## PLAN-08 A failed renewal says everything keeps working for 16 days

Ruling, 2026-11-13: kept on Linux. A Linux person with an Apple plan still needs to see its state. Linux offers no button for it, so its last line differs.

- Given Apple couldn't renew Robin's Growth plan
- When he opens his account
- Then the card says "Apple couldn't renew your plan", with a "Growth" badge
- And it says everything keeps working for 16 days, and until when
- And on the Mac and iPhone it offers "Open Apple Settings"
- And on Linux it says the plan is managed on the Mac or iPhone, with no button

## PLAN-09 After the 16 days, the plan is paused and extras are locked

- Given Apple still couldn't take payment after 16 days
- When Robin opens his account
- Then the card says "Growth is paused", with a "Free" badge
- And it says what is locked until the payment goes through, and that nothing was deleted

## PLAN-10 A canceled plan says when it ends and offers to keep it

Ruling, 2026-11-13: kept on Linux. A Linux person with an Apple plan still needs to see its state. Linux offers no button for it, so its last line differs.

- Given Robin canceled his Growth plan, paid until Dec 9
- When he opens his account
- Then the card says "Growth · ends Dec 9"
- And it says everything works until then, and nothing is deleted
- And on the Mac and iPhone it offers "Keep My Plan"
- And on Linux it says the plan is managed on the Mac or iPhone, with no button

## PLAN-11 An ended plan says what's locked and what's open

- Given Robin's Growth plan ended, and Household stays open
- When he opens his account
- Then the card says "Free plan", with a "Free" badge
- And it says his Growth plan ended, and what is locked until he picks a plan
- And it says "Open now: Household."
- And it offers "See Plans" and "Change what stays open"

## PLAN-12 A refunded plan says so

- Given Robin's payment was refunded
- When he opens his account
- Then the card says "Refunded", with a "Free" badge
- And it says what is locked until he picks a plan

## PLAN-13 A plan bought on the website is managed there

Platforms: Mac, iPhone

- Given Robin bought Growth on wellspent.space
- When he opens his account on a Mac or iPhone
- Then the card says it was bought on wellspent.space
- And it offers "Manage on wellspent.space"

## PLAN-14 A plan that changed elsewhere shows when the app comes back to the front

- Given Robin's account is open on the free plan
- When his plan becomes Growth elsewhere, and he comes back to the app
- Then the card says "Growth · $49 a month", with no sign-in

## PLAN-17 Before the app sells plans, Choose a plan says "Coming soon"

Platforms: Mac, iPhone, Linux

- Given the app doesn't sell plans yet (the purchases flag is off)
- When Robin opens Choose a plan
- Then the three plans show with their monthly and yearly prices
- And "Coming soon" stands in place of Subscribe, or of "Continue on wellspent.space" on Linux, and can't be pressed
- And there is no Restore Purchases, in Choose a plan or under the plan card
- And a release build can't be made to sell early, even with a launch variable

## PLAN-15 Restore Purchases says what it found

Platforms: Mac, iPhone

- Given Robin is on the free plan
- When he presses "Restore Purchases" and his Apple account holds no WellSpent plan
- Then "Nothing to restore" says the Apple account has no WellSpent plan
- And it says to sign in with the email he paid with on wellspent.space

## PLAN-16 A purchase the store refuses says so and changes nothing

Platforms: Mac, iPhone

- Given Robin is on the free plan, with "Choose a plan" open
- When he presses Subscribe and the App Store refuses the purchase
- Then "The App Store couldn't finish. Try again." shows under the button
- And his plan is still the free plan

## PLAN-18 A group past the free plan says it's only on this device

Platforms: Mac, Linux, iPhone

- Given Robin made Home and Beach on his Mac before signing in, and his account is on the free plan
- When he signs in, and the server syncs Home and refuses Beach
- Then Beach shows "Only on this Mac" beside its name
- And Beach's page says "Beach is only on this Mac. Your free plan syncs 1 group, and Home is that group. Nothing in Beach is deleted."
- And before the app sells plans it ends "Paid plans are coming soon.", and after, "Choose a plan to sync it too."
- And Choose a plan doesn't open by itself
- And See Plans opens Choose a plan
- And once a plan lets the server take Beach, neither shows
