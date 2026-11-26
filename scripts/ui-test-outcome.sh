#!/bin/sh
# Decides whether a UI test run passed from its result bundle, not from
# xcodebuild's exit status. With -retry-tests-on-failure, a test that fails
# once and passes on its retry counts as passed in the bundle, while some
# Xcode versions still exit non-zero for it, which read as a red run every
# night. Prints each test that needed its retry, so flakiness stays visible,
# and on GitHub puts them in the run's summary too (scripts/ui-test-outcome.py).
#   scripts/ui-test-outcome.sh RESULT.xcresult [LOST]
# Exits 0 when the bundle's verdict is Passed, 1 otherwise, naming the tests
# that failed on their last attempt. Given LOST, a file, and when every failed
# test lost its retry to a test runner restart, it names them there and exits
# 2, so each can have its retry on its own.
set -u
bundle=$1
if [ ! -d "$bundle" ]; then
    echo "ui-test-outcome: no result bundle at $bundle" >&2
    exit 1
fi
here="$(cd "$(dirname "$0")" && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
xcrun xcresulttool get test-results summary --path "$bundle" > "$tmp/summary.json" 2>/dev/null || {
    echo "ui-test-outcome: could not read $bundle" >&2
    exit 1
}
xcrun xcresulttool get test-results tests --path "$bundle" > "$tmp/tests.json" 2>/dev/null
python3 -I "$here/ui-test-outcome.py" "$tmp/summary.json" "$tmp/tests.json" ${2:+"$2"}
