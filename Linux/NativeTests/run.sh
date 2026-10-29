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
"${CC:-clang}" -Wall -Wextra -Werror \
    $(pkg-config --cflags gtk4) \
    -I"$ROOT/Linux/Sources/WellSpentLinuxNative/include" \
    "$ROOT/Linux/NativeTests/wartable.c" \
    "$ROOT/Linux/Sources/WellSpentLinuxNative/wellspent_wartable.c" \
    $(pkg-config --libs gtk4) -o "$SCRATCH/wartable-test"
GDK_BACKEND=x11 GTK_A11Y=none xvfb-run --server-num=100 -a dbus-run-session -- "$SCRATCH/wartable-test"
# The native shell's sidebar, read through the accessibility tree as the UI
# tests read it. The shell's own files are built as SwiftPM builds them, so
# their unused callback parameters are not errors here either. GTK's test
# accessibility backend is what makes the gtk_test_accessible checks real.
CF="$(pkg-config --cflags gtk4 fontconfig) -I$ROOT/Linux/Sources/WellSpentLinuxNative/include -I$ROOT/Linux/Sources/WellSpentLinuxNative"
"${CC:-clang}" -Wall -Wextra -Werror $CF -c "$ROOT/Linux/NativeTests/sidebar.c" -o "$SCRATCH/sidebar.o"
"${CC:-clang}" -Wall -Werror -Wno-unused-parameter $CF -c "$ROOT/Linux/Sources/WellSpentLinuxNative/wellspent_gtk_shell.c" -o "$SCRATCH/shell.o"
"${CC:-clang}" -Wall -Werror -Wno-unused-parameter $CF -c "$ROOT/Linux/Sources/WellSpentLinuxNative/wellspent_gtk_sidebar.c" -o "$SCRATCH/sidebar-impl.o"
"${CC:-clang}" "$SCRATCH/sidebar.o" "$SCRATCH/shell.o" "$SCRATCH/sidebar-impl.o" $(pkg-config --libs gtk4 fontconfig) -lm -o "$SCRATCH/sidebar-test"
GDK_BACKEND=x11 GTK_A11Y=test xvfb-run --server-num=100 -a dbus-run-session -- "$SCRATCH/sidebar-test"
