#!/bin/sh
# How much of the Linux app's own code the UI tests ran: its screens
# (Linux/Sources/WellSpentLinux) and its C helpers (WellSpentLinuxNative), file
# by file, from the counts each copy of the app wrote as it quit. The shared
# code underneath has its own measure (scripts/coverage.sh). Run by
# run-in-docker.sh when UITEST_COVERAGE is set, or in CI's job:
#
#     Linux/UITests/coverage.sh <the WellSpentLinux built with coverage> <counts folder>
set -eu
APP="$1"
COUNTS="$2"
SOURCES="$(cd "$(dirname "$0")/../Sources" && pwd)"
llvm-profdata merge -sparse "$COUNTS"/*.profraw -o "$COUNTS/merged.profdata"
llvm-cov report "$APP" -instr-profile="$COUNTS/merged.profdata" \
    "$SOURCES/WellSpentLinux" "$SOURCES/WellSpentLinuxNative" | tee "$COUNTS/report.txt"
