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
#
# A try that runs past APT_TRY_SECONDS (10 minutes) is stopped and counts as a
# failure, so a mirror that answers slowly rather than not at all is tried
# again instead of using up the job. On GitHub, a container's Ubuntu image
# names archive.ubuntu.com and security.ubuntu.com, which can crawl for many
# minutes. The runner itself uses Azure's mirror, in the same network, so the
# container is pointed there too.
#
# APT_MIRROR names that mirror's host, such as http://azure.archive.ubuntu.com/,
# for a build GitHub runs that can't tell it's on GitHub: the server image's
# Dockerfile passes it in as a build argument. Unset, and off GitHub, the
# image's own hosts are used. APT_RECOMMENDS=1 installs recommended packages
# too, as the server image always has.
#
# APT_ETC is where the sources files are (default /etc/apt), for testing this
# script.
set -eu
[ "$#" -gt 0 ] || { echo "usage: $0 PACKAGE..." >&2; exit 2; }
wait="${APT_RETRY_WAIT:-30}"
limit="${APT_TRY_SECONDS:-600}"
mirror="${APT_MIRROR:-}"
etc="${APT_ETC:-/etc/apt}"
[ -z "$mirror" ] && [ "${GITHUB_ACTIONS:-}" = true ] && mirror=http://azure.archive.ubuntu.com/
if [ -n "$mirror" ]; then
    for sources in "$etc/sources.list" "$etc"/sources.list.d/*.sources "$etc"/sources.list.d/*.list; do
        [ -f "$sources" ] || continue
        sed -i -e "s#http://archive\\.ubuntu\\.com/#$mirror#g" \
               -e "s#http://security\\.ubuntu\\.com/#$mirror#g" "$sources"
    done
fi
recommends=--no-install-recommends
[ "${APT_RECOMMENDS:-}" = 1 ] && recommends=
try=1
while :; do
    if timeout "$limit" apt-get -o Acquire::Retries=3 update -q &&
       timeout "$limit" apt-get -o Acquire::Retries=3 install -y -q $recommends "$@"; then
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
