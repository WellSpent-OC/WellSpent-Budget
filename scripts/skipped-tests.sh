#!/bin/sh
# Lists the tests a UI test run skipped, from its result bundles, and fails
# when there are any. The Definition of Done counts a skipped test as not
# passed: "100 percent of unit, integration and UI tests pass, and nothing
# is skipped to get there."
#
#   scripts/skipped-tests.sh RESULT.xcresult [RESULT.xcresult ...]
#
# A missing bundle is passed over, since a run that stopped early has
# already failed for its own reason. CI runs this only when the test mailbox
# token is there: without it, as for a fork, the signed-in tests skip by
# design.
set -eu

[ $# -ge 1 ] || { echo "usage: scripts/skipped-tests.sh RESULT.xcresult [RESULT.xcresult ...]" >&2; exit 2; }

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
count=0
for bundle in "$@"; do
    [ -d "$bundle" ] || { echo "skipped tests: no result bundle at $bundle, so nothing to read"; continue; }
    count=$((count + 1))
    xcrun xcresulttool get test-results tests --path "$bundle" --format json > "$work/tests-$count.json"
done
[ "$count" -gt 0 ] || exit 0

python3 -I - "$work"/tests-*.json <<'PY'
import json, sys

skipped = []

def walk(node, path):
    name = node.get("name", "")
    here = path + [name] if name else path
    if node.get("nodeType") == "Test Case" and node.get("result") == "Skipped":
        reason = next((child.get("name", "") for child in node.get("children", [])
                       if child.get("nodeType") in ("Failure Message", "Skip Message", "Message")), "")
        skipped.append((" / ".join(here[-2:]), reason))
    for child in node.get("children", []):
        walk(child, here)

for path in sys.argv[1:]:
    with open(path) as handle:
        report = json.load(handle)
    for node in report.get("testNodes", []):
        walk(node, [])

if not skipped:
    print("skipped tests: none")
    sys.exit(0)
for test, reason in skipped:
    print(f"::warning::Skipped: {test}" + (f" ({reason})" if reason else ""))
print(f"skipped tests: {len(skipped)}, and a skipped test is not a passed one")
sys.exit(1)
PY
