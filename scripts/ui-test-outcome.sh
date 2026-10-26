#!/bin/sh
# Decides whether a UI test run passed from its result bundle, not from
# xcodebuild's exit status. With -retry-tests-on-failure, a test that fails
# once and passes on its retry counts as passed in the bundle, while some
# Xcode versions still exit non-zero for it, which read as a red run every
# night. Prints each test that needed its retry, so flakiness stays visible.
#   scripts/ui-test-outcome.sh RESULT.xcresult
# Exits 0 when the bundle's verdict is Passed, 1 otherwise, naming the tests
# that failed on their last attempt.
set -u
bundle=$1
if [ ! -d "$bundle" ]; then
    echo "ui-test-outcome: no result bundle at $bundle" >&2
    exit 1
fi
summary=$(xcrun xcresulttool get test-results summary --path "$bundle" 2>/dev/null) || {
    echo "ui-test-outcome: could not read $bundle" >&2
    exit 1
}
tests=$(xcrun xcresulttool get test-results tests --path "$bundle" 2>/dev/null)
printf '%s\n%s\n' "$summary" "$tests" | python3 -I -c '
import json, sys
raw = sys.stdin.read()
cut = raw.find("\n{", 1)
summary = json.loads(raw[:cut]) if cut > 0 else json.loads(raw)
tests = json.loads(raw[cut + 1:]) if cut > 0 else {}
retried, failed = [], []
def walk(node, test=None):
    if isinstance(node, dict):
        kind = node.get("nodeType")
        if kind == "Test Case":
            test = node.get("name")
            if node.get("result") == "Failed":
                failed.append(test)
        if kind == "Repetition" and node.get("result") == "Failed" and test:
            retried.append(test)
        for child in node.get("children", []):
            walk(child, test)
    elif isinstance(node, list):
        for child in node:
            walk(child, test)
walk(tests.get("testNodes", []))
for name in sorted(set(retried) - set(failed)):
    print(f"ui-test-outcome: {name} failed once and passed on its retry")
verdict = summary.get("result")
passed = summary.get("passedTests", 0)
failed_count = summary.get("failedTests", 0)
skipped = summary.get("skippedTests", 0)
print("ui-test-outcome: %s, %s passed, %s failed, %s skipped" % (verdict, passed, failed_count, skipped))
for name in sorted(set(failed)):
    print(f"ui-test-outcome: FAILED {name}")
sys.exit(0 if verdict == "Passed" else 1)
'
