#!/bin/sh
# A tiny GTK fixture on a private virtual display. No WellSpent executable,
# accounts, or database. Run in the same image as Linux/UITests.
set -eu
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SCRATCH="$(mktemp -d)"
trap 'rm -rf "$SCRATCH"' EXIT
"${CC:-clang}" -Wall -Wextra -Werror \
    $(pkg-config --cflags gtk4) \
    -I"$ROOT/Linux/Sources/WellSpentLinuxNative/include" \
    "$ROOT/Linux/NativeTests/lifecycle.c" \
    "$ROOT/Linux/Sources/WellSpentLinuxNative/wellspent_lifecycle.c" \
    $(pkg-config --libs gtk4) -o "$SCRATCH/lifecycle-test"
# The main UI runner owns :99. Keep this fixture on another display so its
# X server can finish stopping without racing the main runner's startup.
GDK_BACKEND=x11 GTK_A11Y=none xvfb-run --server-num=100 -a dbus-run-session -- "$SCRATCH/lifecycle-test"
