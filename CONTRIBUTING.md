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

**Found a security problem?** Do not open a public issue. Email
dev@wellspent.space with what you found and how to reproduce it.
