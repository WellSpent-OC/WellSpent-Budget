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

- Given "Choose a plan" is open on Yearly with Growth picked
- When Robin presses "Continue on wellspent.space"
- Then the website's checkout opens for Growth, yearly
- And the sheet closes

## PLAN-05 More than 15 properties offers an email to us

Platforms: Linux

- Given "Choose a plan" is open
- When Robin presses "Email us" under "More than 15 properties?"
- Then an email to dev@wellspent.space opens
