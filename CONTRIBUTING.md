# Contributing

Thank you for wanting to help.

**Your contribution is MIT licensed, like the rest of the project.** By opening a
pull request, you agree that what you send can be used under the MIT License in
`LICENSE`. There is nothing to sign.

**Bigger changes start with an issue.** Say what you want to change and why, so no
one spends a week on something that will not be merged.

**How a pull request gets in**

1. Open it against `main`, saying what changed, why, and how you checked it.
2. The checks run. The first time you contribute, a maintainer reads your change
   and then lets them run. A pull request merges only when every check passes:
   Unit tests, Coverage floor, Linux container builds, Server tests on Postgres,
   Linux client tests, Linux app builds, Gate, and review.
3. A maintainer reviews it. Anything the checks cannot cover, such as a screen,
   is tried by hand on a test server, never with real budgets.
4. A maintainer merges it by rebasing your commits onto `main`, so your name stays
   on your work.

**Write tests that fail without your change.** A fix comes with a test that fails
on the code before it and passes after it.

**Use plain words** in code comments, commit messages and pull requests. Keep
real people's names, addresses and secrets out of code, tests and examples.

**How the code is written**

Every app shares as much as it can, so each thing is written once and not again in
every app. These practices keep it that way.

- **Build every feature as a module.** A feature has a clear edge. Its rules and
  words are written once, in the shared code, with their own tests. Each platform's
  screens for it sit in files of their own. Nothing reaches into another feature's
  insides.
- **When something should be its own module, make it one.** Code written twice, or
  a file doing two jobs, is split out as part of the change, or as the next small
  pull request.
- **Composition over inheritance.** Build a type from the parts it has, not from a
  parent it is. To share code, give a type the shared piece as a property, or a
  small protocol it adopts. Inherit only where it is decided, such as where a
  framework requires a subclass, and say why in the code.
- **Rules live in the shared code, and screens only draw.** What a screen shows and
  what its words say are decided in the shared code (today
  `Sources/WellSpentAppCore/Screens/`), with a unit test, so every app behaves the
  same. A view decides nothing.
- **The server has the last word.** When the server and the apps both apply a
  rule, such as who may change an entry, the server decides. The apps' copy of the
  rule is tested against an in-memory server, so the two can't drift apart.
- **Each platform's screens are built that platform's way.** The apps share rules
  and words, not layouts. A view is shared between platforms only where it is
  already right on each of them.
- **Tests check what a person can see and do,** through public behavior, not a
  type's insides. Each flow a person can take has a user interface test that acts
  the way a person would.
- **Behavior is written once, in plain words.** Each feature's scenarios are in
  `Features/`, one file per feature. Each platform's user interface tests name the
  scenarios they check, so every app is held to the same behavior.
  `Features/README.md` says how a scenario is written and how a test names one.

**Found a security problem?** Do not open a public issue. Email
dev@wellspent.space with what you found and how to reproduce it.
