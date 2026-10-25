#!/bin/sh
# Runs the Linux UI tests on a virtual display nobody sees, in a session of
# their own: a session bus, the accessibility bus GTK shows the window on, and
# a desktop keyring. Inside the test image (Dockerfile) or CI's job:
#
#     WELLSPENT_APP=<the built WellSpentLinux> Linux/UITests/run.sh [test names]
#
# WELLSPENT_APP                    the app to test, a staging build
# WELLSPENT_UI_OUT                 where a failing step leaves a picture of the
#                                  screen (default /tmp/wellspent-ui)
# WELLSPENT_UI_TEST_MAILBOX_TOKEN  staging's test mailbox, for the tests that
#                                  make an account; without it they're skipped
# WELLSPENT_UI_SERVER_URL         optional disposable development server;
#                                  uses the app's existing Server field
# WELLSPENT_UI_NO_SKIPS            "true" fails the run if any test is skipped
#
# Test names are unittest's, such as test_group_page or
# test_group_page.SignedOut.test_the_name_opens_the_page. None runs them all.
set -eu
HERE="$(cd "$(dirname "$0")" && pwd)"
: "${WELLSPENT_APP:?set WELLSPENT_APP to the built WellSpentLinux}"
export WELLSPENT_APP
export WELLSPENT_UI_OUT="${WELLSPENT_UI_OUT:-/tmp/wellspent-ui}"
mkdir -p "$WELLSPENT_UI_OUT"

# A live build reads and writes real budgets. Only the exact word "live" in
# its environment file makes one, so anything else is a staging build.
ENV_FILE="$(dirname "$WELLSPENT_APP")/WellSpentLinux_WellSpentLinux.resources/environment"
if [ -f "$ENV_FILE" ] && [ "$(tr -d '[:space:]' < "$ENV_FILE")" = live ]; then
    echo "run.sh: $WELLSPENT_APP is a live build. The UI tests run only on staging builds." >&2
    exit 1
fi

# Native GTK fixtures check focus, clock callbacks, WarTable keyboard guards
# and transcript scrolling without accounts, on their own virtual display.
"$HERE/../NativeTests/run.sh"

Xvfb :99 -screen 0 1280x800x24 -nolisten tcp >/dev/null 2>&1 &
XVFB=$!
trap 'kill "$XVFB" 2>/dev/null || true' EXIT
export DISPLAY=:99 GDK_BACKEND=x11
tries=0
until xdotool getdisplaygeometry >/dev/null 2>&1; do
    tries=$((tries + 1))
    [ "$tries" -lt 50 ] || { echo "run.sh: the virtual display didn't start" >&2; exit 1; }
    sleep 0.2
done

# The keyring's password is a test's own, for a keyring that ends with the run.
dbus-run-session -- sh -c '
    eval "$(printf test-keyring | gnome-keyring-daemon --unlock --components=secrets --daemonize)"
    export GNOME_KEYRING_CONTROL
    cd "$1"
    shift
    exec python3 run_tests.py "$@"
' sh "$HERE" "$@"
