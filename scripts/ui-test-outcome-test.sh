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

# A test that failed once, and then lost its retry when xcodebuild restarted
# the test runner, has fewer than two tries in the bundle: one failed try, or
# none recorded under it. testB has one and testC none. Given a file, the
# script names them there, as -only-testing names, and exits 2 so they get
# their retry. Neither is called retried: neither has passed.
cat > "$tmp/lost.json" <<'JSON'
{"testNodes": [{"nodeType": "Unit test bundle", "name": "UITests", "children": [
  {"nodeType": "Test Suite", "name": "SampleTests", "children": [
    {"nodeType": "Test Case", "name": "testA()", "result": "Passed"},
    {"nodeType": "Test Case", "name": "testB()", "result": "Failed", "children": [
      {"nodeType": "Repetition", "name": "First Run", "result": "Failed"}]}]},
  {"nodeType": "Test Suite", "name": "OtherTests", "children": [
    {"nodeType": "Test Case", "name": "testC()", "result": "Failed"}]}]}]}
JSON
# testB lost its retry, and testC failed on both tries: testC can't be fixed
# by a retry, so it's a failed run, and no retry is asked for.
cat > "$tmp/lost-and-failed.json" <<'JSON'
{"testNodes": [{"nodeType": "Unit test bundle", "name": "UITests", "children": [
  {"nodeType": "Test Suite", "name": "SampleTests", "children": [
    {"nodeType": "Test Case", "name": "testB()", "result": "Failed", "children": [
      {"nodeType": "Repetition", "name": "First Run", "result": "Failed"}]},
    {"nodeType": "Test Case", "name": "testC()", "result": "Failed", "children": [
      {"nodeType": "Repetition", "name": "First Run", "result": "Failed"},
      {"nodeType": "Repetition", "name": "Retry 1", "result": "Failed"}]}]}]}]}
JSON
# run_lost SUMMARY TESTS: as run, with a file for the lost retries.
run_lost() {
    : > "$tmp/summary.md"
    rm -f "$tmp/lost.txt"
    code=0
    GITHUB_ACTIONS=true GITHUB_STEP_SUMMARY="$tmp/summary.md" \
        python3 -I "$outcome" "$tmp/$1" "$tmp/$2" "$tmp/lost.txt" > "$tmp/out" 2>&1 || code=$?
}
nl='
'
run_lost failed.json lost.json
check "$code" 2 "when every failure lost its retry, it asks for the retries"
check "$(cat "$tmp/lost.txt")" "UITests/SampleTests/testB${nl}UITests/OtherTests/testC" "it names them as -only-testing names"
check "$(grep -c '^::warning title=Lost its retry::testB()' "$tmp/out")" 1 "a warning says testB lost its retry"
check "$(grep -c 'testB() failed once and passed on its retry' "$tmp/out" || true)" 0 "testB isn't called retried"
check "$(grep -c '^ui-test-outcome: FAILED' "$tmp/out" || true)" 0 "nothing is called failed before its retry"

run_lost failed.json lost-and-failed.json
check "$code" 1 "a test failed on both tries makes the run fail, whatever else lost its retry"
check "$(cat "$tmp/lost.txt" 2>/dev/null)" "" "and no retry is asked for"
check "$(grep -c '^ui-test-outcome: FAILED testC()' "$tmp/out")" 1 "testC is named failed"

# Without a file, as before: a lost retry is a failure.
run failed.json lost.json
check "$code" 1 "with no file for them, lost retries fail the run"
check "$(grep -c '^ui-test-outcome: FAILED testB()' "$tmp/out")" 1 "and are named failed"

# The retries' own run, read with --retry-of the file of lost retries. It
# passes only when it passed exactly those tests, with none failed or
# skipped. A name that matched no test makes xcodebuild run nothing, and
# that bundle still reads Passed, so it has to fail here.
printf 'UITests/SampleTests/testB\nUITests/OtherTests/testC\n' > "$tmp/lost-list.txt"
cat > "$tmp/retry-exact.json" <<'JSON'
{"testNodes": [{"nodeType": "Unit test bundle", "name": "UITests", "children": [
  {"nodeType": "Test Suite", "name": "SampleTests", "children": [
    {"nodeType": "Test Case", "name": "testB()", "result": "Passed"}]},
  {"nodeType": "Test Suite", "name": "OtherTests", "children": [
    {"nodeType": "Test Case", "name": "testC()", "result": "Passed"}]}]}]}
JSON
echo '{"testNodes": []}' > "$tmp/retry-none.json"
cat > "$tmp/retry-short.json" <<'JSON'
{"testNodes": [{"nodeType": "Unit test bundle", "name": "UITests", "children": [
  {"nodeType": "Test Suite", "name": "SampleTests", "children": [
    {"nodeType": "Test Case", "name": "testB()", "result": "Passed"}]}]}]}
JSON
cat > "$tmp/retry-skipped.json" <<'JSON'
{"testNodes": [{"nodeType": "Unit test bundle", "name": "UITests", "children": [
  {"nodeType": "Test Suite", "name": "SampleTests", "children": [
    {"nodeType": "Test Case", "name": "testB()", "result": "Passed"}]},
  {"nodeType": "Test Suite", "name": "OtherTests", "children": [
    {"nodeType": "Test Case", "name": "testC()", "result": "Skipped"}]}]}]}
JSON
# run_retry SUMMARY TESTS: reads a retries' run against lost-list.txt.
run_retry() {
    code=0
    python3 -I "$outcome" "$tmp/$1" "$tmp/$2" --retry-of "$tmp/lost-list.txt" > "$tmp/out" 2>&1 || code=$?
}
run_retry passed.json retry-exact.json
check "$code" 0 "a retries' run that passed exactly the lost tests passes"
check "$(grep -c 'passed on its own retry' "$tmp/out")" 2 "it says each passed on its own retry"
run_retry passed.json retry-none.json
check "$code" 1 "a retries' run that ran no test fails, though it reads Passed"
run_retry passed.json retry-short.json
check "$code" 1 "a retries' run that left a lost test out fails"
check "$(grep -c 'UITests/OtherTests/testC' "$tmp/out")" 1 "and names the one left out"
run_retry passed.json retry-skipped.json
check "$code" 1 "a retries' run that skipped a lost test fails"
run_retry failed.json retry-exact.json
check "$code" 1 "a retries' run whose verdict is Failed fails"

exit "$failed"
