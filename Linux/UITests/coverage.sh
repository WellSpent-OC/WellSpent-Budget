#!/bin/sh
# How much of the Linux app's own code the UI tests ran: its screens
# (Linux/Sources/WellSpentLinux) and its C helpers (WellSpentLinuxNative), file
# by file, from the counts each copy of the app wrote as it quit. The shared
# code underneath has its own measure (scripts/coverage.sh). Run by
# run-in-docker.sh when UITEST_COVERAGE is set, or in CI's job:
#
#     Linux/UITests/coverage.sh <the WellSpentLinux built with coverage> <counts folder> [floor]
#
# With a floor, a whole number of percent, it fails when the lines run fall
# below it: the sign-off rule's 90 for every part's own code, rising a point
# with each release, as scripts/coverage.sh holds the shared code to its own.
set -eu
APP="$1"
COUNTS="$2"
FLOOR="${3:-}"
SOURCES="$(cd "$(dirname "$0")/../Sources" && pwd)"
llvm-profdata merge -sparse "$COUNTS"/*.profraw -o "$COUNTS/merged.profdata"
llvm-cov report "$APP" -instr-profile="$COUNTS/merged.profdata" \
    "$SOURCES/WellSpentLinux" "$SOURCES/WellSpentLinuxNative" | tee "$COUNTS/report.txt"
TOTAL="$(awk '$1 == "TOTAL" { sub("%", "", $10); print $10 }' "$COUNTS/report.txt")"
printf '\nLinux app line coverage: %s%%' "$TOTAL"
if [ -n "$FLOOR" ]; then
    printf '  (floor %s%%)\n' "$FLOOR"
    awk -v total="$TOTAL" -v floor="$FLOOR" 'BEGIN {
        if (total + 0 < floor + 0) { printf "FAIL: %.2f%% is below the %d%% floor\n", total, floor; exit 1 }
    }'
else
    printf '\n'
fi
