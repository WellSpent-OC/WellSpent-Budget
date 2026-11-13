#!/bin/sh
# Checks out the private Properties package at the commit this repo names in
# .github/properties-ref, with the read-only deploy key. A fixed commit, not
# Properties' main: when Properties and the app change together, the app's
# pull request moves the pointer with its own pins, so both switch in one
# merge and no run in between builds one side's new code against the other's
# old code.
#
#   PROPERTIES_DEPLOY_KEY=... scripts/checkout-properties.sh DEST
#
# PROPERTIES_URL changes where it fetches from and PROPERTIES_REF_FILE which
# file names the commit, for testing this script (scripts/checkout-properties-test.sh).
# With PROPERTIES_URL set, no key is used.
set -eu
# Run from under a git hook, GIT_DIR and its kin would send the git calls
# below to the hook's repository. Clear git's own list of them first.
unset $(git rev-parse --local-env-vars)
[ "$#" -eq 1 ] || { echo "usage: $0 DEST" >&2; exit 2; }
dest="$1"
ref_file="${PROPERTIES_REF_FILE:-$(dirname "$0")/../.github/properties-ref}"
ref="$(tr -d '[:space:]' < "$ref_file")"
case "$ref" in
    *[!0-9a-f]*|'') echo "$ref_file must hold one full commit hash, not '$ref'" >&2; exit 1 ;;
esac
[ "${#ref}" -eq 40 ] || { echo "$ref_file must hold a full 40 character commit hash, not '$ref'" >&2; exit 1; }

url="${PROPERTIES_URL:-}"
if [ -z "$url" ]; then
    url=git@github.com:WellSpent-OC/WellSpent-Properties.git
    key="$HOME/.ssh/properties_deploy_key"
    mkdir -p ~/.ssh
    printf '%s\n' "$PROPERTIES_DEPLOY_KEY" > "$key"
    chmod 600 "$key"
    trap 'rm -f "$key"' EXIT
    # GitHub's published host key, so the clone trusts the right host
    # without a scan that can fail quietly on a runner.
    echo 'github.com ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOMqqnkVzrm0SdG6UOoqKLsabgH5C9okWi0dh2l9GKJl' >> ~/.ssh/known_hosts
    export GIT_SSH_COMMAND="ssh -i $key -o IdentitiesOnly=yes -o UserKnownHostsFile=$HOME/.ssh/known_hosts -o StrictHostKeyChecking=yes"
fi

git init -q "$dest"
git -C "$dest" fetch -q --depth 1 "$url" "$ref"
git -C "$dest" checkout -q --detach FETCH_HEAD
echo "Properties checked out at $ref"
