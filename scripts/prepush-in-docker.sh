#!/bin/sh
# make prepush for a machine with no Swift on the host, such as a Linux box
# that builds in containers. The pre-push hook runs it there in place of
# make prepush. The Swift half (make gates and wartable-test) runs in the
# Linux UI test image, on a clean copy of HEAD. The rest (script-test and
# mac-pins) runs here. Any failure stops it, and the push with it.
#
#   scripts/prepush-in-docker.sh
#
# PREPUSH_SCRATCH  where the copy and its build are kept between pushes, so a
#                  push rebuilds only what changed (default .build/prepush)
# PREPUSH_DISK_LIMIT  a percent: when the disk holding the copy is this full
#                  or more, it stops before building (default 80). On the
#                  maintainers' machine that disk also holds the live
#                  database, so a build must never be what fills it.
# The container is named wsr-prepush-<checkout>: a build guard on the
# maintainers' machine caps containers named wsr-*.
set -eu
ROOT="$(git rev-parse --show-toplevel)"
cd "$ROOT"
IMAGE="wellspent-linux-uitest:$(cat Linux/UITests/Dockerfile Linux/UITests/packages.txt | sha256sum | cut -c1-12)"
OUT="${PREPUSH_SCRATCH:-$ROOT/.build/prepush}"
mkdir -p "$OUT/src" "$OUT/home"
limit="${PREPUSH_DISK_LIMIT:-80}"
used="$(df --output=pcent "$OUT" | tail -1 | tr -dc '0-9')"
if [ "$used" -ge "$limit" ]; then
    echo "prepush: the disk is ${used}% full, and builds stop at ${limit}%. Clear build folders first." >&2
    exit 1
fi
docker image inspect "$IMAGE" >/dev/null 2>&1 || docker build -q -t "$IMAGE" Linux/UITests
# The copy matches HEAD exactly, apart from its kept build folders. rsync
# --checksum without -t gives a new time only to files whose content
# changed, so a warm build never skips a rebuild it needs.
fresh="$(mktemp -d)"
trap 'rm -rf "$fresh"' EXIT
git archive HEAD | tar -x -C "$fresh"
rsync -rc --delete --exclude='/.build/' --exclude='/Server/.build/' "$fresh/" "$OUT/src/"
echo "prepush: the Swift half on $(git rev-parse --short HEAD), in $IMAGE"
# --cpus limits CPU time, not the cores the container sees, and Swift
# starts one compile per core it sees: 32 at once ran past 8 GB on a cold
# build. So the container sees at most 8 cores, or all of a smaller machine's.
cores="$(nproc)"
[ "$cores" -gt 8 ] && cores=8
docker run --rm --name "wsr-prepush-$(basename "$ROOT")" --cpuset-cpus="0-$((cores - 1))" --memory=8g \
    -v "$OUT:/b" -e HOME=/b/home "$IMAGE" \
    setpriv --reuid="$(id -u)" --regid="$(id -g)" --clear-groups sh -c 'cd /b/src && make gates wartable-test'
make script-test mac-pins
echo "prepush: every check passed on $(git rev-parse --short HEAD)"
