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
# The container is named wsr-prepush-<checkout>: a build guard on the
# maintainers' machine caps containers named wsr-*.
set -eu
ROOT="$(git rev-parse --show-toplevel)"
cd "$ROOT"
IMAGE="wellspent-linux-uitest:$(cat Linux/UITests/Dockerfile Linux/UITests/packages.txt | sha256sum | cut -c1-12)"
docker image inspect "$IMAGE" >/dev/null 2>&1 || docker build -q -t "$IMAGE" Linux/UITests
OUT="${PREPUSH_SCRATCH:-$ROOT/.build/prepush}"
mkdir -p "$OUT/src" "$OUT/home"
# The copy matches HEAD exactly, apart from its kept build folders. rsync
# --checksum without -t gives a new time only to files whose content
# changed, so a warm build never skips a rebuild it needs.
fresh="$(mktemp -d)"
trap 'rm -rf "$fresh"' EXIT
git archive HEAD | tar -x -C "$fresh"
rsync -rc --delete --exclude='/.build/' --exclude='/Server/.build/' "$fresh/" "$OUT/src/"
echo "prepush: the Swift half on $(git rev-parse --short HEAD), in $IMAGE"
docker run --rm --name "wsr-prepush-$(basename "$ROOT")" --cpus=8 --memory=8g \
    -v "$OUT:/b" -e HOME=/b/home "$IMAGE" \
    setpriv --reuid="$(id -u)" --regid="$(id -g)" --clear-groups sh -c 'cd /b/src && make gates wartable-test'
make script-test mac-pins
echo "prepush: every check passed on $(git rev-parse --short HEAD)"
