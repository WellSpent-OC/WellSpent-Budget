#!/usr/bin/env bash
#
# Line coverage over the library targets, with a floor.
#
# What is measured: the six library targets, which is everything the tests link
# against.
#
# What is NOT measured, and why it matters when reading the number:
#   - WellSpentApp. It is an executable target and no test target depends on it,
#     so it is never linked into the test binary and llvm-cov cannot see it. It
#     has no automated tests at all. That is recorded in STATUS.md.
#   - Server/. A separate package with its own tests, run separately.
#
# So this floor guards the core, not the whole product. Raising it is cheap;
# pretending it covers the app would not be.
set -euo pipefail

MINIMUM="${COVERAGE_MINIMUM:-85}"
cd "$(dirname "$0")/.."

echo "Running tests with coverage..."
swift test --enable-code-coverage ${FLAGS:-} > /dev/null

BIN_DIR="$(swift build --show-bin-path)"
PROFDATA="${BIN_DIR}/codecov/default.profdata"
# The test bundle is a directory on macOS and a plain binary on Linux.
TEST_BIN="$(find "${BIN_DIR}" -name '*PackageTests.xctest' -maxdepth 1 | head -1)"
if [ -d "${TEST_BIN}" ]; then
  TEST_BIN="${TEST_BIN}/Contents/MacOS/$(basename "${TEST_BIN}" .xctest)"
fi

if [ ! -f "${PROFDATA}" ] || [ ! -f "${TEST_BIN}" ]; then
  echo "Could not find coverage data. Looked for:"
  echo "  ${PROFDATA}"
  echo "  ${TEST_BIN}"
  exit 1
fi

IGNORE='(\.build|Tests)/'
xcrun llvm-cov report "${TEST_BIN}" -instr-profile "${PROFDATA}" -ignore-filename-regex="${IGNORE}"

TOTAL="$(xcrun llvm-cov export "${TEST_BIN}" -instr-profile "${PROFDATA}" \
          -ignore-filename-regex="${IGNORE}" --summary-only \
        | python3 -c 'import json,sys; print(json.load(sys.stdin)["data"][0]["totals"]["lines"]["percent"])')"

printf '\nLine coverage: %.2f%%  (floor %s%%)\n' "${TOTAL}" "${MINIMUM}"

python3 - "${TOTAL}" "${MINIMUM}" <<'PY'
import sys
total, minimum = float(sys.argv[1]), float(sys.argv[2])
if total < minimum:
    print(f"FAIL: line coverage {total:.2f}% is below the {minimum:.0f}% floor")
    sys.exit(1)
print("Coverage gate passed.")
PY
