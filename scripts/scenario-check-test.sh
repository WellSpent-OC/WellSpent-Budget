#!/bin/sh
# Tests scripts/scenario-check.py's --require against a throwaway Features/
# folder: one scenario on the Mac, Linux and the iPhone, with a test on the Mac
# and the iPhone but none on Linux. Requiring a platform fails only when that
# platform has a scenario with no test, and a platform it does not know is
# refused.
#
#   scripts/scenario-check-test.sh
set -eu
check="$(cd "$(dirname "$0")" && pwd)/scenario-check.py"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

mkdir -p "$tmp/root/Features" "$tmp/root/mac" "$tmp/root/phone"
cat > "$tmp/root/Features/Sample.md" <<'MD'
# Sample

## SAMP-01 Robin sees his budget
MD
cat > "$tmp/root/Features/README.md" <<'MD'
| ID | Scenario | Platforms | Has a test on |
| - | - | - | - |
| SAMP-01 | Robin sees his budget | Mac, Linux, iPhone | Mac, iPhone |
MD
echo '// Scenario SAMP-01' > "$tmp/root/mac/SampleTests.swift"
echo '// Scenario SAMP-01' > "$tmp/root/phone/SampleTests.swift"

failed=0
# expect WANT NAME ARGUMENTS...: runs the check on the throwaway root with the
# Mac's and the iPhone's tests, plus ARGUMENTS, and checks it passes (WANT=ok)
# or fails (WANT=refused).
expect() {
    want="$1" name="$2"
    shift 2
    if python3 -I "$check" --root "$tmp/root" --tests Mac=mac --tests iPhone=phone "$@" \
        > "$tmp/out" 2>&1; then got=ok; else got=refused; fi
    if [ "$got" = "$want" ]; then
        echo "pass: $name"
    else
        echo "FAIL: $name: wanted $want, got $got" >&2
        sed 's/^/    /' "$tmp/out" >&2
        failed=1
    fi
}

expect ok "with nothing required, a missing Linux test passes"
expect ok "requiring the Mac passes when the Mac has every test" --require Mac
expect ok "requiring the Mac and the iPhone passes when both have every test" --require Mac --require iPhone
expect refused "requiring Linux fails while Linux lacks a test" --require Linux
expect refused "one required platform with a gap fails the check" --require Mac --require Linux
expect refused "--require-all still fails on any platform's gap" --require-all
expect refused "a platform the check does not know is refused" --require Moon
expect refused "--require with no platform after it is refused" --require

exit "$failed"
