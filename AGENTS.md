# Git workflow

Before every push to this repository and before creating or updating a pull
request, fetch the latest remote state and rebase the working branch onto the
latest `origin/main`:

```sh
git fetch origin
git rebase origin/main
```

Resolve any rebase conflicts and run the checks appropriate to the resulting
changes before pushing or creating/updating the PR. Do not proceed while a
rebase is incomplete or checks are failing.

If rebasing a previously pushed branch requires rewriting remote history, use
`git push --force-with-lease`, never `git push --force`.
