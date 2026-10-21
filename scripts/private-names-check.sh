#!/usr/bin/env bash
# Checks that nothing public names a person, a team seat or a machine. The list
# of those names is private, so it comes from PRIVATE_NAMES (the repository's
# WELLSPENT_PRIVATE_NAMES secret), two lines of Perl-style patterns:
#
#   anycase:<pattern>     matched in any case: people, machines, addresses
#   aswritten:<pattern>   matched only as written: names that are also words
#
#   scripts/private-names-check.sh [--files] [--commits BASE HEAD] [TEXT_FILE ...]
#
# --files checks every file git tracks, --commits the message of every commit in
# BASE..HEAD, and each TEXT_FILE is checked whole, such as a pull request's
# description. It says where a name is, never which: the log is public, and
# GitHub hides a secret there only when the whole of it appears.
set -euo pipefail

[ -n "${PRIVATE_NAMES:-}" ] || { echo "private names: PRIVATE_NAMES is not set" >&2; exit 2; }
anycase="$(printf '%s\n' "$PRIVATE_NAMES" | sed -n 's/^anycase://p')"
aswritten="$(printf '%s\n' "$PRIVATE_NAMES" | sed -n 's/^aswritten://p')"
[ -n "$anycase" ] && [ -n "$aswritten" ] || {
    echo "private names: the list needs an anycase line and an aswritten line" >&2
    exit 2
}

found=0
say() {
    echo "private names: $1 holds a name that must not be public"
    found=1
}

# True when standard input holds a name.
holds_a_name() {
    local text
    text="$(cat)"
    printf '%s\n' "$text" | grep -q -i -P -- "$anycase" && return 0
    printf '%s\n' "$text" | grep -q -P -- "$aswritten"
}

while [ $# -gt 0 ]; do
    case "$1" in
        --files)
            shift
            # Where only: the path and the line, never the line itself.
            while IFS= read -r place; do
                say "$place"
            done < <(git ls-files -z | xargs -0 -r grep -I -n -H -i -P -- "$anycase" 2>/dev/null | cut -d: -f1,2 || true
                     git ls-files -z | xargs -0 -r grep -I -n -H -P -- "$aswritten" 2>/dev/null | cut -d: -f1,2 || true)
            ;;
        --commits)
            base="$2"
            head="$3"
            shift 3
            for commit in $(git rev-list "$base..$head"); do
                if git log -1 --format=%B "$commit" | holds_a_name; then
                    say "the message of commit $(git rev-parse --short "$commit")"
                fi
            done
            ;;
        *)
            if holds_a_name < "$1"; then
                say "the $(basename "$1")"
            fi
            shift
            ;;
    esac
done

[ "$found" -eq 0 ] || exit 1
echo "private names: none found"
