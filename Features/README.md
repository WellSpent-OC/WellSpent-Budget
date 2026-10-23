# Features

What WellSpent does, written once for every platform. Each file here is one feature, told as scenarios: short examples of what a person does and what they then see. The Mac, Linux and iPhone apps must all behave the way the scenarios say. Each platform has its own user interface (UI) tests, which drive that platform's app the way a person does. Each test names the scenarios it checks. The tables at the end show which scenarios each platform's tests name so far.

## How a feature file is written

- One file per feature, named for it, such as `EditEntry.md`.
- It starts with a short title, then one paragraph saying what the feature is for.
- Then come its scenarios. Each one starts with a heading: its identifier (ID), then a one-line name.
- An ID is a short prefix for the feature and a two-digit number, such as `EDIT-04`. Once an ID is used, it stays with that scenario. It is never changed or given to another one, so tests can name it.
- When a scenario is not on all three platforms, a `Platforms:` line comes next. For example, `Platforms: Mac` for a right-click, `Platforms: iPhone` for a swipe, or `Platforms: Mac, iPhone` for something Linux's toolkit cannot do. No line means Mac, Linux and iPhone.
- The Platforms line says where a scenario applies. It does not say which platforms have built it yet.
- Each platform reads a scenario in its own words. Where a scenario says "this computer", an iPhone says "this iPhone". Where a budget opens "on the right", an iPhone opens it as its own screen, and what "the right side" says shows on Home.
- Then come Given, When and Then lines, with And for one more of the same. They say what a person sees and does, in plain English. They never say how the code does it.
- The people in the scenarios are Robin (he) and Leslie (she). No real person's name goes in.
- Only behaviour that is built goes in: on `main`, or in an open pull request. Planned behaviour stays out until it is built.

For example, the start of EDIT-15 in `EditEntry.md`:

```markdown
## EDIT-15 Right-click offers Edit… and Delete… where they are allowed

Platforms: Mac

- Given Robin may change Hilltop Grocery
- When he right-clicks its row
- Then a menu offers "Edit…" and "Delete…"
```

## How a test names a scenario

A UI test names a scenario with one comment line, directly above the step that checks it:

```swift
// Scenario PAGE-05
// 10. The arrow at the end of the group's line hides its budgets and
// shows them again. The page stays.
```

- A step that checks more than one scenario lists them all on that one line, with commas: `// Scenario PAGE-02, PAGE-03`.
- The Mac tests number their steps in comments, such as `// 10.` above. The tag goes on the line above that comment. In a test with no numbered steps, it goes above the lines that do the check.
- Only a step that checks a scenario names it. A step that sets up something another step checks, such as signing in before the real check, needs no tag.
- A tag says the step checks what the scenario is about. It does not promise that the step checks every line of it.
- The Linux and iPhone tests name scenarios with the same line.
- To find every test that names a scenario, search for its ID: `git grep -n "PAGE-05"`.
- When a tag is added or taken out, change the tables below to match.

The Mac's UI tests are in `Tests/WellSpentUITests`, the iPhone's in `iOS/UITests`, and Linux's in `Linux/UITests`, where Python names a scenario with `# Scenario` in place of `// Scenario`.

## Every scenario, and which platforms have a test for it

| Platform | Scenarios on it | Named by a test |
| - | - | - |
| Mac | 151 | 149 |
| Linux | 145 | 105 |
| iPhone | 144 | 142 |

### [Accounts.md](Accounts.md)

| ID | Scenario | Platforms | Has a test on |
| - | - | - | - |
| ACCT-01 | Signed out, budgets are kept on this computer only | Mac, Linux, iPhone | Mac, iPhone |
| ACCT-02 | Create an account | Mac, Linux, iPhone | Mac, iPhone |
| ACCT-03 | Create an account says what is wrong before sending | Mac, Linux, iPhone | Mac, iPhone |
| ACCT-04 | An email that already has an account | Mac, Linux, iPhone | Mac, iPhone |
| ACCT-05 | Confirm the email with the code | Mac, Linux, iPhone | Mac, iPhone |
| ACCT-06 | A wrong code, and another code | Mac, Linux, iPhone | Mac, iPhone |
| ACCT-07 | An email not confirmed yet is asked for again | Mac, Linux, iPhone | Mac, iPhone |
| ACCT-08 | Sign in | Mac, Linux, iPhone | Mac, iPhone |
| ACCT-09 | A wrong password | Mac, Linux, iPhone | Mac, iPhone |
| ACCT-10 | Forgot password | Mac, Linux, iPhone | Mac, iPhone |
| ACCT-11 | Sign out | Mac, Linux, iPhone | Mac, iPhone |
| ACCT-12 | Sign out everywhere asks first | Mac, Linux, iPhone | Mac, iPhone |
| ACCT-13 | Signed out from another device | Mac, Linux, iPhone | Mac, iPhone |
| ACCT-14 | Each device is listed by its own name | Mac, Linux, iPhone | Mac, iPhone |
| ACCT-15 | A staging build says so across the top | Mac, Linux, iPhone | Mac, iPhone |
| ACCT-16 | On a Mac, the Dock says STAGING too | Mac | Mac |

### [SampleGroups.md](SampleGroups.md)

| ID | Scenario | Platforms | Has a test on |
| - | - | - | - |
| SAMP-01 | A fresh install opens with two sample groups | Mac, Linux, iPhone | Mac, Linux, iPhone |
| SAMP-02 | Samples nobody changed stay out of a new account | Mac, Linux, iPhone | Mac, Linux, iPhone |
| SAMP-03 | A group made before signing up comes along, and the samples do not | Mac, Linux, iPhone | Mac, Linux, iPhone |
| SAMP-04 | A sample given an entry comes along, all of it | Mac, Linux, iPhone | Mac, Linux, iPhone |
| SAMP-05 | A sample renamed comes along under its new name | Mac, Linux, iPhone | Mac, Linux, iPhone |
| SAMP-06 | Signing in to an account made elsewhere leaves the samples here | Mac, Linux, iPhone | Mac, Linux, iPhone |
| SAMP-07 | The samples come only once | Mac, Linux, iPhone | Mac, Linux, iPhone |

### [Budgets.md](Budgets.md)

| ID | Scenario | Platforms | Has a test on |
| - | - | - | - |
| BUDGET-01 | Make a group | Mac, Linux, iPhone | Mac, Linux, iPhone |
| BUDGET-02 | Rename a group | Mac, Linux, iPhone | Mac, Linux, iPhone |
| BUDGET-03 | Make a budget in a group | Mac, Linux, iPhone | Mac, Linux, iPhone |
| BUDGET-04 | A budget needs a name and an amount above zero | Mac, Linux, iPhone | Mac, Linux, iPhone |
| BUDGET-05 | With no group to put it in, a new budget makes one | Mac, Linux, iPhone | Mac, Linux, iPhone |
| BUDGET-06 | Change a budget's name or monthly amount | Mac, Linux, iPhone | Mac, Linux, iPhone |
| BUDGET-07 | Changing budgets and groups takes Manage | Mac, Linux, iPhone | Mac, Linux, iPhone |
| BUDGET-08 | Deleting a budget asks first, and says how many transactions go with it | Mac, Linux, iPhone | Mac, Linux, iPhone |
| BUDGET-09 | A budget opens by itself when none is open | Mac, Linux | Mac, Linux |
| BUDGET-10 | With no budgets, the right side says how to start | Mac, Linux, iPhone | Mac, Linux, iPhone |
| BUDGET-11 | Deleting a group asks first, and counts what goes with it | Mac, Linux, iPhone | Mac, Linux, iPhone |
| BUDGET-12 | The owner of a shared group deletes it for everyone | Mac, Linux, iPhone | Mac, Linux, iPhone |
| BUDGET-13 | A member leaves a shared group instead of deleting it | Mac, Linux, iPhone | Mac, Linux, iPhone |
| BUDGET-14 | An open budget says what is spent and what is left this period | Mac, Linux, iPhone | Mac, Linux, iPhone |
| BUDGET-15 | Over its limit, a budget says how far over | Mac, Linux, iPhone | Mac, Linux, iPhone |
| BUDGET-16 | A budget's amount is read the way the region writes numbers | Mac, Linux, iPhone | Mac, Linux, iPhone |

### [Entries.md](Entries.md)

| ID | Scenario | Platforms | Has a test on |
| - | - | - | - |
| ENTRY-01 | Add puts a transaction in the open budget | Mac, Linux, iPhone | Mac, Linux, iPhone |
| ENTRY-02 | The sheet asks for a merchant and an amount | Mac, Linux, iPhone | Mac, Linux, iPhone |
| ENTRY-03 | Every amount is money spent, however it is typed | Mac, Linux, iPhone | Mac, Linux, iPhone |
| ENTRY-04 | A note shows under the merchant | Mac, Linux, iPhone | Mac, Linux, iPhone |
| ENTRY-05 | The newest transaction is on top | Mac, Linux, iPhone | Mac, Linux, iPhone |
| ENTRY-06 | A date before this period keeps it out of this period | Mac, Linux, iPhone | Mac, Linux, iPhone |
| ENTRY-07 | Cancel adds nothing | Mac, Linux, iPhone | Mac, Linux, iPhone |
| ENTRY-08 | In a shared group, the list says who added each transaction | Mac, Linux, iPhone | Mac, Linux, iPhone |
| ENTRY-09 | A transaction someone else adds arrives at the next sync | Mac, Linux, iPhone | Mac, Linux, iPhone |
| ENTRY-10 | At View there is no Add | Mac, Linux, iPhone | Mac, Linux, iPhone |
| ENTRY-11 | The keyboard adds and cancels | Mac, Linux | Mac, Linux |
| ENTRY-12 | Where a comma marks decimals, 12,50 is twelve fifty | Mac, Linux, iPhone | Mac, Linux, iPhone |
| ENTRY-13 | An amount that can't be read clearly is refused, never guessed | Mac, Linux, iPhone | Mac, Linux, iPhone |

### [EditEntry.md](EditEntry.md)

| ID | Scenario | Platforms | Has a test on |
| - | - | - | - |
| EDIT-01 | A click on any row opens it | Mac, Linux, iPhone | Mac, Linux, iPhone |
| EDIT-02 | Save stays dimmed until something changes | Mac, Linux, iPhone | Mac, Linux, iPhone |
| EDIT-03 | Save changes it, and the totals follow at once | Mac, Linux, iPhone | Mac, Linux, iPhone |
| EDIT-04 | Move it to another budget in the same group | Mac, Linux, iPhone | Mac, Linux, iPhone |
| EDIT-05 | A date outside this period says so | Mac, Linux, iPhone | Mac, Linux, iPhone |
| EDIT-06 | Delete… asks first, naming the transaction and its amount | Mac, Linux, iPhone | Mac, Linux, iPhone |
| EDIT-07 | Delete takes it out, and a bar offers Undo | Mac, Linux, iPhone | Mac, Linux, iPhone |
| EDIT-08 | The Undo bar goes after about 10 seconds, or at the next change | Mac, Linux, iPhone | Mac, Linux, iPhone |
| EDIT-09 | An Undo that can't be done now says why | Mac, Linux, iPhone | Mac, Linux, iPhone |
| EDIT-10 | At View, a transaction opens read-only | Mac, Linux, iPhone | Mac, Linux, iPhone |
| EDIT-11 | At Add, only what he added can be changed | Mac, Linux, iPhone | Mac, Linux, iPhone |
| EDIT-12 | Someone else deletes or changes it while it is open | Mac, Linux, iPhone | Mac, Linux, iPhone |
| EDIT-13 | Moved down while it is open, nothing is saved | Mac, Linux, iPhone | Mac, Linux, iPhone |
| EDIT-14 | A change that didn't go through is noted | Mac, Linux, iPhone | Mac, iPhone |
| EDIT-15 | Right-click offers Edit… and Delete… where they are allowed | Mac | Mac |
| EDIT-16 | The keyboard in the list and in the sheet | Mac | Mac |
| EDIT-17 | A swipe or a long press offers Edit and Delete where they are allowed | iPhone | iPhone |

### [Import.md](Import.md)

| ID | Scenario | Platforms | Has a test on |
| - | - | - | - |
| IMPORT-01 | Import statement opens a review, and nothing is added yet | Mac, Linux, iPhone | Mac, Linux, iPhone |
| IMPORT-02 | Each line shows a cleaned-up name over the bank's own words | Mac, Linux, iPhone | Mac, Linux, iPhone |
| IMPORT-03 | A line that matches an entry typed by hand is not added again | Mac, Linux, iPhone | Mac, Linux, iPhone |
| IMPORT-04 | A merchant filed before goes to the same budget | Mac, Linux, iPhone | Mac, Linux, iPhone |
| IMPORT-05 | A new merchant needs a budget from the group's own budgets | Mac, Linux, iPhone | Mac, Linux, iPhone |
| IMPORT-06 | A line left at Choose is not added | Mac, Linux, iPhone | Mac, Linux, iPhone |
| IMPORT-07 | Importing the same statement again adds nothing twice | Mac, Linux, iPhone | Mac, Linux, iPhone |
| IMPORT-08 | A deleted line stays deleted when its statement is imported again | Mac, Linux, iPhone | Mac, Linux, iPhone |
| IMPORT-09 | A line whose budget was deleted is offered again | Mac, Linux, iPhone | Mac, Linux, iPhone |
| IMPORT-10 | A statement one person imported counts as imported for the others | Mac, Linux, iPhone | Mac, iPhone |
| IMPORT-11 | Lines dated before this period go in, but the list shows this period only | Mac, Linux, iPhone | Mac, Linux, iPhone |
| IMPORT-12 | Cancel adds nothing | Mac, Linux, iPhone | Mac, Linux, iPhone |
| IMPORT-13 | A file that is not a statement is explained in words | Mac, Linux, iPhone | Mac, Linux, iPhone |
| IMPORT-14 | At View, there is no Import statement | Mac, Linux, iPhone | Mac, iPhone |

### [Sharing.md](Sharing.md)

| ID | Scenario | Platforms | Has a test on |
| - | - | - | - |
| SHARE-01 | Share… asks for your name, what they can do and what they see | Mac, Linux, iPhone | Mac, Linux, iPhone |
| SHARE-02 | Create Link makes a link that works once | Mac, Linux, iPhone | Mac, Linux, iPhone |
| SHARE-03 | Send… hands the link to another app | Mac, iPhone | Mac, iPhone |
| SHARE-04 | Signed out, Share… makes no link | Mac, Linux, iPhone | Mac, Linux, iPhone |
| SHARE-05 | Someone at Add cannot invite anyone | Mac, Linux, iPhone | Mac, Linux, iPhone |
| SHARE-06 | A manager can invite at View or Add, not Manage | Mac, Linux, iPhone | Mac, Linux, iPhone |
| SHARE-07 | Pasting a link into Join a Group… joins the group | Mac, Linux, iPhone | Mac, Linux, iPhone |
| SHARE-08 | A pasted link that is not whole says what is wrong | Mac, Linux, iPhone | Mac, Linux, iPhone |
| SHARE-09 | Joining needs a sign-in and a confirmed email | Mac, Linux, iPhone | Mac, Linux, iPhone |
| SHARE-10 | A used link says it was already accepted | Mac, Linux, iPhone | Mac, Linux, iPhone |
| SHARE-11 | At View, the person who joins sees everything and changes nothing | Mac, Linux, iPhone | Mac, Linux, iPhone |
| SHARE-12 | At Manage, the person who joins can change budgets | Mac, Linux, iPhone | Mac, Linux, iPhone |
| SHARE-13 | Only from now on hides what came before | Mac, Linux, iPhone | Mac, Linux, iPhone |
| SHARE-14 | Entries reach the others after a sync, with who added them | Mac, Linux, iPhone | Mac, Linux, iPhone |
| SHARE-15 | Leave… takes the group off your devices, and the others keep it | Mac, Linux, iPhone | Mac, Linux, iPhone |
| SHARE-16 | Remove… takes a person out, and what they added stays | Mac, Linux, iPhone | Mac, Linux, iPhone |

### [GroupPage.md](GroupPage.md)

| ID | Scenario | Platforms | Has a test on |
| - | - | - | - |
| PAGE-01 | A click on a group's name opens its page | Mac, Linux, iPhone | Mac, Linux, iPhone |
| PAGE-02 | People… in the group's menu opens the same page | Mac, Linux, iPhone | Mac, Linux, iPhone |
| PAGE-03 | A budget takes the page's place | Mac, Linux, iPhone | Mac, Linux, iPhone |
| PAGE-04 | The sidebar marks the group whose page is open | Mac, Linux | Mac, Linux |
| PAGE-05 | The arrow at the end of a group's line hides and shows its budgets | Mac, Linux, iPhone | Mac, Linux, iPhone |
| PAGE-06 | The line under the name says whether it is shared, how many, and who made it | Mac, Linux, iPhone | Mac, Linux, iPhone |
| PAGE-07 | Signed out, the page says only that it is not shared | Mac, Linux, iPhone | Mac, Linux, iPhone |
| PAGE-08 | PEOPLE lists everyone, with their level and what it lets them do | Mac, Linux, iPhone | Mac, Linux, iPhone |
| PAGE-09 | The owner may change anyone's level, remove them and invite | Mac, Linux, iPhone | Mac, Linux, iPhone |
| PAGE-10 | Changing someone's level from their row | Mac, Linux, iPhone | Mac, Linux, iPhone |
| PAGE-11 | A manager may change and remove only people below Manage | Mac, Linux, iPhone | Mac, Linux, iPhone |
| PAGE-12 | At Add or View, the page shows labels only, and Leave Group… | Mac, Linux, iPhone | Mac, Linux, iPhone |
| PAGE-13 | Invite Someone… opens the Share sheet | Mac, Linux, iPhone | Mac, Linux, iPhone |
| PAGE-14 | Leave Group… asks first, and always leaves | Mac, Linux, iPhone | Mac, Linux, iPhone |
| PAGE-15 | Someone who joins shows without opening the page again | Mac, Linux, iPhone | Mac, Linux, iPhone |
| PAGE-16 | The page stays open until its own group goes | Mac, Linux | Mac, Linux |
| PAGE-17 | Someone removed leaves what they added | Mac, Linux, iPhone | Mac, Linux, iPhone |

### [ClickToJoin.md](ClickToJoin.md)

| ID | Scenario | Platforms | Has a test on |
| - | - | - | - |
| CLICK-01 | A clicked invite link opens its invitation page | Mac, Linux, iPhone | Mac, iPhone |
| CLICK-02 | A click starts WellSpent when it is closed | Mac, Linux, iPhone | Mac, iPhone |
| CLICK-03 | The page gives the invite's own level and history | Mac, Linux, iPhone | Mac, iPhone |
| CLICK-04 | Join takes the group in and opens its page | Mac, Linux, iPhone | Mac, iPhone |
| CLICK-05 | Signed out, Sign in… stands in place of Join | Mac, Linux, iPhone | Mac, iPhone |
| CLICK-06 | Not confirmed yet, Confirm your email… stands in place of Join | Mac, Linux, iPhone | Mac, iPhone |
| CLICK-07 | The page stays through making an account | Mac, Linux, iPhone | Mac, iPhone |
| CLICK-08 | A link cut short says part of it is missing | Mac, Linux, iPhone | Mac, iPhone |
| CLICK-09 | A used link says so | Mac, Linux, iPhone | Mac, iPhone |
| CLICK-10 | A link to a group you are in already | Mac, Linux, iPhone | Mac, iPhone |
| CLICK-11 | Another link replaces the page | Mac, Linux, iPhone | Mac, iPhone |
| CLICK-12 | Picking a budget or a group takes the page down | Mac, Linux, iPhone | Mac, iPhone |
| CLICK-13 | A link from the other app says which app it is for | Mac, Linux, iPhone | Mac, iPhone |

### [Paste.md](Paste.md)

| ID | Scenario | Platforms | Has a test on |
| - | - | - | - |
| PASTE-01 | Paste puts copied text into a field | Mac, Linux, iPhone | Mac, iPhone |
| PASTE-02 | Sign in by pasting the email and the password | Mac, Linux, iPhone | Mac, iPhone |
| PASTE-03 | Paste an invite link to join a group | Mac, Linux, iPhone | Mac, iPhone |
| PASTE-04 | Select all, then typing replaces the whole field | Mac, Linux, iPhone | Mac, iPhone |
| PASTE-05 | Copy, then paste, brings the copied words back | Mac, Linux, iPhone | Mac, iPhone |
| PASTE-06 | Cut takes the words out, and paste puts them back | Mac, Linux, iPhone | Mac, iPhone |
| PASTE-07 | Undo takes back a paste | Mac | Mac |
| PASTE-08 | The Edit menu holds the editing commands | Mac | Mac |
| PASTE-09 | Every field on the account sheet takes a paste, the emailed code too | Mac, Linux, iPhone | Mac, iPhone |
| PASTE-10 | The fields for making a group or a budget, and for joining, take a paste | Mac, Linux, iPhone | Mac, iPhone |

### [MoneyWheel.md](MoneyWheel.md)

| ID | Scenario | Platforms | Has a test on |
| - | - | - | - |
| WHEEL-01 | A budget's row fills as far as its money is used | Mac, Linux, iPhone | Mac, Linux, iPhone |
| WHEEL-02 | Over its limit, the row fills all the way and says how far over | Mac, Linux, iPhone | Mac, Linux, iPhone |
| WHEEL-03 | The open budget's row keeps its fill, with an outline | Mac, Linux | Mac, Linux |
| WHEEL-04 | In dark mode, the rows use the dark colours | iPhone | iPhone |
| WHEEL-05 | A budget's page shows its wheel in place of the bar | Mac, Linux, iPhone | Mac, Linux, iPhone |
| WHEEL-06 | The wheel is full before anything is spent, and empties as money goes out | Mac, Linux, iPhone | Mac, Linux, iPhone |
| WHEEL-07 | The tick marks where an even pace would be today | Mac, Linux, iPhone | Mac, Linux, iPhone |
| WHEEL-08 | Spending faster than an even pace turns the wheel orange and says when the money runs out | Mac, Linux, iPhone | Mac, Linux, iPhone |
| WHEEL-09 | In the month's last week, more left than expected offers to lower the budget | Mac, Linux, iPhone | Mac, Linux, iPhone |
| WHEEL-10 | Over its limit, a budget's wheel is orange all the way round and says how far over | Mac, Linux, iPhone | Mac, Linux, iPhone |
| WHEEL-11 | A group's page opens with its money for the month | Mac, Linux, iPhone | Mac, Linux, iPhone |
| WHEEL-12 | Over the month's budgets, the group's wheel says how far over | Mac, Linux, iPhone | Mac, Linux, iPhone |
| WHEEL-13 | Home shows wheels only after opening a group or budget | iPhone | iPhone |

### [Lifecycle.md](Lifecycle.md)

| ID | Scenario | Platforms | Has a test on |
| - | - | - | - |
| LIFE-01 | Returning to the app brings in shared changes | Mac, Linux, iPhone | Linux |
| LIFE-02 | A new local day refreshes the displayed money | Mac, Linux, iPhone | None yet |

The lifecycle native and shared tests check focus callbacks and date handling.
They do not count as UI scenario coverage in this table.
