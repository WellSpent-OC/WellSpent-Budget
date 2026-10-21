#!/bin/sh
# Prints the -only-testing flags for one share of a UI test bundle's classes,
# so CI can run the classes in several jobs at once. The classes are read
# from the test files, so a new class needs no list kept, and every class
# lands in exactly one share. Each class goes to the share with the fewest
# tests so far, the largest class first, so the shares come out about even.
#
#   scripts/ui-test-shard.sh FOLDER BUNDLE SHARE/SHARES
#   scripts/ui-test-shard.sh Tests/WellSpentUITests WellSpentUITests 2/3
set -eu

if [ $# -ne 3 ]; then
    echo "usage: $0 FOLDER BUNDLE SHARE/SHARES" >&2
    exit 2
fi
folder=$1
bundle=$2
share=${3%%/*}
shares=${3#*/}
case "$3" in
    */*/* | /* | */ | *[!0-9/]* | [!/]* ) [ "$share" != "$3" ] || { echo "SHARE/SHARES must be two numbers, such as 2/3, not $3" >&2; exit 2; } ;;
esac
case "$share/$shares" in
    */*/* | /* | */ | *[!0-9/]*)
        echo "SHARE/SHARES must be two numbers, such as 2/3, not $3" >&2
        exit 2 ;;
esac
if [ "$share" -lt 1 ] || [ "$share" -gt "$shares" ]; then
    echo "share $share is not between 1 and $shares" >&2
    exit 2
fi

# One line per class: how many tests it holds, then its name.
for file in "$folder"/*.swift; do
    awk '
        /class [A-Za-z0-9_]+: XCTestCase/ {
            match($0, /class [A-Za-z0-9_]+:/)
            current = substr($0, RSTART + 6, RLENGTH - 7)
            tests[current] += 0
            next
        }
        /func test[A-Za-z0-9_]*\(/ && current != "" { tests[current]++ }
        END { for (name in tests) print tests[name], name }
    ' "$file"
done | sort -k1,1nr -k2,2 | awk -v share="$share" -v shares="$shares" -v bundle="$bundle" '
    {
        best = 1
        for (s = 2; s <= shares; s++) if (load[s] < load[best]) best = s
        load[best] += ($1 > 0 ? $1 : 1)
        if (best == share) { printf "-only-testing:%s/%s\n", bundle, $2; found++ }
    }
    END {
        # An empty share would run every test, so it is an error.
        if (!found) { print "share " share " of " shares " holds no class. Use fewer shares." > "/dev/stderr"; exit 3 }
    }'
