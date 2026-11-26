#!/bin/sh
# Fails unless a UI test run passed at least the tests it was meant to run.
# A job that runs only some classes (-only-testing) passes with nothing run
# when those classes stop joining the project: a folder moved, a class
# renamed, an optional path no longer found. This makes that a failure.
#
#   scripts/passed-at-least.sh COUNT RESULT.xcresult [RESULT.xcresult ...]
#
# Each bundle must exist and hold at least COUNT passed tests. Unlike
# skipped-tests.sh, a missing bundle fails: no bundle means nothing ran. A
# bundle's passes include those in NAME-retry.xcresult beside it, when there
# is one: make iphone-ui-test runs there the retries a runner restart lost,
# and a test that passed on that retry is still Failed in the first bundle.
set -eu

[ $# -ge 2 ] || { echo "usage: scripts/passed-at-least.sh COUNT RESULT.xcresult [RESULT.xcresult ...]" >&2; exit 2; }
want="$1"
shift

for bundle in "$@"; do
    [ -d "$bundle" ] || { echo "::error::no result bundle at $bundle, so no test ran"; exit 1; }
    passed=0
    for part in "$bundle" "${bundle%.xcresult}-retry.xcresult"; do
        [ "$part" = "$bundle" ] || [ -d "$part" ] || continue
        count=$(xcrun xcresulttool get test-results summary --path "$part" --format json \
            | python3 -I -c 'import json, sys; print(json.load(sys.stdin).get("passedTests", 0))')
        passed=$((passed + count))
    done
    if [ "$passed" -lt "$want" ]; then
        echo "::error::$bundle passed $passed tests, fewer than the $want expected"
        exit 1
    fi
    echo "$bundle: $passed passed (at least $want expected)"
done
