#!/bin/sh
# Tests scripts/checkout-properties.sh against a throwaway local repository, so
# it needs no network and no key: a full hash checks out, and a short hash, a
# branch name and a hash the repository lacks are each refused.
#
#   scripts/checkout-properties-test.sh
set -eu
script="$(cd "$(dirname "$0")" && pwd)/checkout-properties.sh"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# Named main, so a pointer that says "main" would check out if the script let it.
git init -q -b main "$tmp/repo"
echo properties > "$tmp/repo/README.md"
git -C "$tmp/repo" add README.md
git -C "$tmp/repo" -c user.name=test -c user.email=test@example.com commit -q -m one
good="$(git -C "$tmp/repo" rev-parse HEAD)"

failed=0
# expect WANT REF NAME: runs the checkout with REF in the pointer file and
# checks it succeeds (WANT=ok) or is refused (WANT=refused).
expect() {
    printf '%s\n' "$2" > "$tmp/ref"
    rm -rf "$tmp/dest"
    if PROPERTIES_URL="file://$tmp/repo" PROPERTIES_REF_FILE="$tmp/ref" \
        "$script" "$tmp/dest" > "$tmp/out" 2>&1; then got=ok; else got=refused; fi
    if [ "$got" = ok ] && [ "$(git -C "$tmp/dest" rev-parse HEAD)" != "$good" ]; then got="ok at the wrong commit"; fi
    if [ "$got" = "$1" ]; then
        echo "pass: $3"
    else
        echo "FAIL: $3: wanted $1, got $got" >&2
        sed 's/^/    /' "$tmp/out" >&2
        failed=1
    fi
}

expect ok "$good" "a full hash checks out that commit"
expect refused "$(printf '%s' "$good" | cut -c1-7)" "a short hash is refused"
expect refused main "a branch name is refused"
expect refused 0000000000000000000000000000000000000000 "a hash the repository lacks is refused"
expect refused "" "an empty pointer is refused"
exit "$failed"
