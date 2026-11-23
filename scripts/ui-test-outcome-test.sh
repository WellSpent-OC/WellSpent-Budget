#!/bin/sh
# Tests scripts/ui-test-outcome.py on result-bundle readings made by hand, in
# the shape xcresulttool gives. A run with one test that failed once and
# passed on its retry lists it, and on GitHub puts it in the summary with a
# warning. A run with none adds nothing. A failed run exits 1.
#
#   scripts/ui-test-outcome-test.sh
set -eu
outcome="$(cd "$(dirname "$0")" && pwd)/ui-test-outcome.py"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

echo '{"result": "Passed", "passedTests": 2, "failedTests": 0, "skippedTests": 0}' > "$tmp/passed.json"
echo '{"result": "Failed", "passedTests": 1, "failedTests": 1, "skippedTests": 0}' > "$tmp/failed.json"
# testA passed first time. testB failed once and passed on its retry.
cat > "$tmp/retried.json" <<'JSON'
{"testNodes": [{"nodeType": "Unit test bundle", "name": "UITests", "children": [
  {"nodeType": "Test Suite", "name": "SampleTests", "children": [
    {"nodeType": "Test Case", "name": "testA()", "result": "Passed"},
    {"nodeType": "Test Case", "name": "testB()", "result": "Passed", "children": [
      {"nodeType": "Repetition", "name": "First Run", "result": "Failed"},
      {"nodeType": "Repetition", "name": "Retry 1", "result": "Passed"}]}]}]}]}
JSON
cat > "$tmp/clean.json" <<'JSON'
{"testNodes": [{"nodeType": "Test Suite", "name": "SampleTests", "children": [
  {"nodeType": "Test Case", "name": "testA()", "result": "Passed"},
  {"nodeType": "Test Case", "name": "testB()", "result": "Passed"}]}]}
JSON
# testB failed on both tries: it's failed, not retried.
cat > "$tmp/both.json" <<'JSON'
{"testNodes": [{"nodeType": "Test Suite", "name": "SampleTests", "children": [
  {"nodeType": "Test Case", "name": "testA()", "result": "Passed"},
  {"nodeType": "Test Case", "name": "testB()", "result": "Failed", "children": [
    {"nodeType": "Repetition", "name": "First Run", "result": "Failed"},
    {"nodeType": "Repetition", "name": "Retry 1", "result": "Failed"}]}]}]}
JSON

failed=0
check() {
    if [ "$1" = "$2" ]; then echo "pass: $3"; else echo "FAIL: $3: got [$1], wanted [$2]"; failed=1; fi
}
# run SUMMARY TESTS: on GitHub, with a fresh summary file. Leaves the output in
# $tmp/out, the summary in $tmp/summary.md, and the exit code in $code.
run() {
    : > "$tmp/summary.md"
    code=0
    GITHUB_ACTIONS=true GITHUB_STEP_SUMMARY="$tmp/summary.md" \
        python3 -I "$outcome" "$tmp/$1" "$tmp/$2" > "$tmp/out" 2>&1 || code=$?
}

run passed.json retried.json
check "$code" 0 "a run with a retried pass is green"
check "$(head -1 "$tmp/summary.md")" "### Needed a retry: 1" "the summary counts the retried test"
check "$(grep -c '^- ' "$tmp/summary.md")" 1 "the summary lists one test"
check "$(grep '^- ' "$tmp/summary.md")" "- testB()" "the summary names testB"
check "$(grep -c '^::warning title=Needed a retry::testB()' "$tmp/out")" 1 "one warning, for testB"

run passed.json clean.json
check "$code" 0 "a clean run is green"
check "$(wc -c < "$tmp/summary.md" | tr -d ' ')" 0 "a clean run adds nothing to the summary"
check "$(grep -c '::warning' "$tmp/out" || true)" 0 "a clean run warns about nothing"

run failed.json both.json
check "$code" 1 "a failed run exits 1"
check "$(grep -c '^ui-test-outcome: FAILED testB()' "$tmp/out")" 1 "the failed test is named"
check "$(wc -c < "$tmp/summary.md" | tr -d ' ')" 0 "a test failed on both tries isn't called retried"

# Off GitHub, the retried test is printed, with no warning and no summary.
code=0
env -u GITHUB_ACTIONS -u GITHUB_STEP_SUMMARY python3 -I "$outcome" "$tmp/passed.json" "$tmp/retried.json" \
    > "$tmp/out" 2>&1 || code=$?
check "$(grep -c 'testB() failed once and passed on its retry' "$tmp/out")" 1 "off GitHub, the retry is printed"
check "$(grep -c '::warning' "$tmp/out" || true)" 0 "off GitHub, no warning"

exit "$failed"
