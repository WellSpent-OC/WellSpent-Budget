#!/bin/sh
# Installs Debian packages for a CI job, and tries again when it fails. A mirror
# in the middle of a sync answers "File has unexpected size ... Mirror sync in
# progress?". That is not our fault and passes in a minute or two, so it should
# not fail the job or knock a pull request out of the merge queue.
#
#   scripts/apt-install.sh PACKAGE...
#
# Three tries, 30 then 60 seconds apart. Each try reads the package lists
# again, since the lists are what a sync breaks. APT_RETRY_WAIT changes the
# 30 seconds, for testing this script.
set -eu
[ "$#" -gt 0 ] || { echo "usage: $0 PACKAGE..." >&2; exit 2; }
wait="${APT_RETRY_WAIT:-30}"
try=1
while :; do
    if apt-get -o Acquire::Retries=3 update -q &&
       apt-get -o Acquire::Retries=3 install -y -q --no-install-recommends "$@"; then
        exit 0
    fi
    if [ "$try" -ge 3 ]; then
        echo "apt failed $try times; giving up." >&2
        exit 1
    fi
    echo "apt failed (try $try of 3); trying again in $((try * wait)) seconds." >&2
    sleep $((try * wait))
    try=$((try + 1))
done
