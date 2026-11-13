#!/bin/sh
# Sorts the Linux UI test names a hand run of CI was given into the app's and
# Properties'. A name whose module is in Linux/UITests is the app's; any other
# is Properties' (its UITests/Linux). Prints the chosen side's names on one
# line, which may be empty. Anything but test names is refused, so nothing
# else reaches a shell, and so is a list with no name in it.
#
#   scripts/linux-ui-names.sh app|properties NAME...
set -eu
[ "$#" -ge 1 ] || { echo "usage: $0 app|properties NAME..." >&2; exit 2; }
side="$1"
shift
case "$side" in app|properties) ;; *) echo "linux-ui-names: app or properties, not $side" >&2; exit 2 ;; esac
tests="$(cd "$(dirname "$0")/../Linux/UITests" && pwd)"
[ "$#" -ge 1 ] || { echo "linux-ui-names: no test name given" >&2; exit 1; }
chosen=""
for name in "$@"; do
    case "$name" in
        ""|*[!A-Za-z0-9_.]*) echo "linux-ui-names: \"$name\" is not a test name, such as test_import.Class.test_name" >&2; exit 1 ;;
    esac
    module="${name%%.*}"
    if [ -f "$tests/$module.py" ]; then mine=app; else mine=properties; fi
    if [ "$mine" = "$side" ]; then chosen="$chosen${chosen:+ }$name"; fi
done
echo "$chosen"
