#!/usr/bin/env bash
#
# Line coverage of the server's own code, with a floor.
#
# coverage.sh measures the app's package and never sees Server/, a package of
# its own. This reads what `swift test --enable-code-coverage` left in
# Server's build, after CI's "Server tests on Postgres" job has run the server
# tests against a real database:
#
#   (cd Server && swift test --enable-code-coverage --filter WellSpentServerTests)
#   scripts/server-coverage.sh
#
# What is measured: Server/Sources/WellSpentServerCore, everything the routes
# run. Not main.swift, a few lines that start the server, which no test links.
#
# COVERAGE_MINIMUM sets the floor, 90 by default, the sign-off rule's number,
# which rises a point after each release. SCRATCH names a --scratch-path when
# the build used one.
set -euo pipefail

MINIMUM="${COVERAGE_MINIMUM:-90}"
cd "$(dirname "$0")/../Server"

BIN_DIR="$(swift build --show-bin-path ${SCRATCH:+--scratch-path "$SCRATCH"})"
PROFDATA="${BIN_DIR}/codecov/default.profdata"
# The test bundle is a directory on macOS and a plain binary on Linux.
TEST_BIN="$(find "${BIN_DIR}" -maxdepth 1 -name '*PackageTests.xctest' | head -1)"
if [ -d "${TEST_BIN}" ]; then
  TEST_BIN="${TEST_BIN}/Contents/MacOS/$(basename "${TEST_BIN}" .xctest)"
fi
if [ ! -f "${PROFDATA}" ] || [ ! -f "${TEST_BIN}" ]; then
  echo "No coverage data. Run the server tests with --enable-code-coverage first. Looked for:"
  echo "  ${PROFDATA}"
  echo "  ${TEST_BIN}"
  exit 1
fi

LLVM_COV="llvm-cov"
command -v llvm-cov > /dev/null || LLVM_COV="xcrun llvm-cov"

REPORT="$(mktemp)"
trap 'rm -f "${REPORT}"' EXIT
${LLVM_COV} export "${TEST_BIN}" -instr-profile "${PROFDATA}" --summary-only > "${REPORT}"

python3 - "${REPORT}" "${MINIMUM}" <<'PY'
import json, sys
report, minimum = sys.argv[1], float(sys.argv[2])
marker = "/Server/Sources/WellSpentServerCore/"
with open(report) as handle:
    files = [f for f in json.load(handle)["data"][0]["files"] if marker in f["filename"]]
if not files:
    sys.exit("FAIL: no server source file in the coverage. Were the server tests run with coverage on?")
lines = [f["summary"]["lines"] for f in files]
count, covered = sum(l["count"] for l in lines), sum(l["covered"] for l in lines)
for f in sorted(files, key=lambda f: f["summary"]["lines"]["percent"]):
    l = f["summary"]["lines"]
    name = f["filename"].split(marker)[-1]
    print(f'{l["percent"]:6.2f}%  {l["covered"]:5d}/{l["count"]:<5d}  {name}')
total = 100.0 * covered / count
print(f"\nServer line coverage: {total:.2f}%  (floor {minimum:.0f}%)")
if total < minimum:
    sys.exit(f"FAIL: the server line coverage {total:.2f}% is below the {minimum:.0f}% floor")
print("Server coverage gate passed.")
PY
