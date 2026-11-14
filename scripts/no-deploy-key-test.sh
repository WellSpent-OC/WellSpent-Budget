#!/bin/sh
# Tests scripts/no-deploy-key.sh: with PROPERTIES_DEPLOY_KEY missing, a job in
# this repository fails, and only a fork passes with its note. A fork is its
# own Actions (another repository's name) or a pull request to this one from
# another repository, which runs here with no secrets.
#
#   scripts/no-deploy-key-test.sh
set -eu
script="$(cd "$(dirname "$0")" && pwd)/no-deploy-key.sh"
failed=0
# expect WANT WHAT REPOSITORY EVENT HEAD_REPO: runs the script as that job
# would and checks it passes (WANT=ok) or fails (WANT=fails).
expect() {
    want="$1" what="$2"
    if GITHUB_REPOSITORY="$3" GITHUB_EVENT_NAME="$4" HEAD_REPO="$5" "$script" > /dev/null 2>&1; then got=ok; else got=fails; fi
    if [ "$got" = "$want" ]; then
        echo "pass: $what"
    else
        echo "FAIL: $what: wanted $want, got $got" >&2
        failed=1
    fi
}

ours=WellSpent-OC/WellSpent-Budget
expect fails "the nightly here fails" "$ours" schedule ""
expect fails "a hand run here fails" "$ours" workflow_dispatch ""
expect fails "the merge queue here fails" "$ours" merge_group ""
expect fails "our own pull request fails" "$ours" pull_request "$ours"
expect ok "a fork's pull request to us passes with the note" "$ours" pull_request "someone/WellSpent-Budget"
expect ok "a fork's own Actions pass with the note" "someone/WellSpent-Budget" push ""
expect fails "a pull request with no head repository named fails" "$ours" pull_request ""
expect fails "no repository named at all fails" "" schedule ""

exit "$failed"
