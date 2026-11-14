#!/bin/sh
# Tests scripts/linux-ui-names.sh: names go to the app when their module is in
# Linux/UITests and to Properties otherwise, and anything that isn't a test
# name is refused.
#
#   scripts/linux-ui-names-test.sh
set -eu
names="$(cd "$(dirname "$0")" && pwd)/linux-ui-names.sh"
failed=0
# expect WANT NAME ARGUMENTS...: checks the printed line is WANT, or that the
# script refuses when WANT is "refused".
expect() {
    want="$1" what="$2"
    shift 2
    if got="$("$names" "$@" 2>/dev/null)"; then :; else got=refused; fi
    if [ "$got" = "$want" ]; then
        echo "pass: $what"
    else
        echo "FAIL: $what: wanted \"$want\", got \"$got\"" >&2
        failed=1
    fi
}

expect "test_import test_paste.SignedOut.test_x" "the app's modules go to the app" app test_import test_paste.SignedOut.test_x test_houses
expect "test_houses test_houses.Houses.test_y" "a module the app lacks goes to Properties" properties test_import test_houses test_houses.Houses.test_y
expect "" "a side with none of the names prints an empty line" properties test_import
expect refused "a name with a shell character is refused" app 'test_import;ls'
expect refused "a name with a space inside one argument is refused" app 'test_import test_paste'
expect refused "no name at all is refused" app
expect refused "a side that isn't app or properties is refused" moon test_import

exit "$failed"
