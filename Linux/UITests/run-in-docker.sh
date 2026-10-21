#!/bin/sh
# Builds the Linux app and runs its UI tests in the test image, so nothing
# opens on your screen and your own budgets are never touched. From the
# repository's top folder, with Docker:
#
#     Linux/UITests/run-in-docker.sh [test names]
#
# UITEST_CONTAINER  the container's name (default wsr-linux-uitest: a build
#                   guard on the maintainers' machine caps containers named
#                   wsr-*)
# UITEST_SCRATCH    where the build and the failure pictures are kept between
#                   runs (default .build/uitest in the repository)
# WELLSPENT_UI_TEST_MAILBOX_TOKEN  passed in from your environment when set,
#                   never on the command line, for the tests that make an
#                   account
set -eu
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
NAME="${UITEST_CONTAINER:-wsr-linux-uitest}"
SCRATCH="${UITEST_SCRATCH:-$ROOT/.build/uitest}"
# Named for what it's built from, so a changed package list builds a new one.
IMAGE="wellspent-linux-uitest:$(cat "$ROOT/Linux/UITests/Dockerfile" "$ROOT/Linux/UITests/packages.txt" | sha256sum | cut -c1-12)"

docker image inspect "$IMAGE" >/dev/null 2>&1 || docker build -q -t "$IMAGE" "$ROOT/Linux/UITests"
mkdir -p "$SCRATCH/home" "$SCRATCH/out"

# The source goes in read-only. The build, its home and the pictures go in the
# scratch folder, owned by you.
docker run --rm --name "$NAME" \
    -v "$ROOT:/src:ro" -v "$SCRATCH:/b" \
    --user "$(id -u):$(id -g)" -e HOME=/b/home -e WELLSPENT_UI_OUT=/b/out \
    ${WELLSPENT_UI_TEST_MAILBOX_TOKEN:+-e WELLSPENT_UI_TEST_MAILBOX_TOKEN} \
    "$IMAGE" sh -c '
        swift build --package-path /src/Linux --scratch-path /b/linux &&
        WELLSPENT_APP=/b/linux/debug/WellSpentLinux /src/Linux/UITests/run.sh "$@"
    ' sh "$@"
