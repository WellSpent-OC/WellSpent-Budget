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
# WELLSPENT_UI_NO_SKIPS  passed in when set: "true" fails the run on a skip
# UITEST_COVERAGE   when set, builds the app with coverage (in its own build
#                   folder) and ends with how much of the Linux app's own code
#                   the tests ran (coverage.sh), even when a test failed
set -eu
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
NAME="${UITEST_CONTAINER:-wsr-linux-uitest}"
SCRATCH="${UITEST_SCRATCH:-$ROOT/.build/uitest}"
# Named for what it's built from, so a changed package list builds a new one.
IMAGE="wellspent-linux-uitest:$(cat "$ROOT/Linux/UITests/Dockerfile" "$ROOT/Linux/UITests/packages.txt" | sha256sum | cut -c1-12)"

docker image inspect "$IMAGE" >/dev/null 2>&1 || docker build -q -t "$IMAGE" "$ROOT/Linux/UITests"
mkdir -p "$SCRATCH/home" "$SCRATCH/out"

# The source goes in read-only. The build, its home and the pictures go in the
# scratch folder, owned by you: the container starts as root only to hand
# your user the one capability a failed step needs to read a stuck app's
# stacks (ptrace), then runs as you.
docker run --rm --name "$NAME" \
    -v "$ROOT:/src:ro" -v "$SCRATCH:/b" \
    -e HOME=/b/home -e WELLSPENT_UI_OUT=/b/out \
    --cap-add=SYS_PTRACE \
    ${WELLSPENT_UI_TEST_MAILBOX_TOKEN:+-e WELLSPENT_UI_TEST_MAILBOX_TOKEN} \
    ${WELLSPENT_UI_NO_SKIPS:+-e WELLSPENT_UI_NO_SKIPS} \
    ${UITEST_COVERAGE:+-e UITEST_COVERAGE} \
    "$IMAGE" setpriv --reuid="$(id -u)" --regid="$(id -g)" --clear-groups \
        --inh-caps=+sys_ptrace --ambient-caps=+sys_ptrace sh -c '
        if [ -z "${UITEST_COVERAGE:-}" ]; then
            swift build --package-path /src/Linux --scratch-path /b/linux &&
            WELLSPENT_APP=/b/linux/debug/WellSpentLinux /src/Linux/UITests/run.sh "$@"
            exit
        fi
        # Each copy of the app writes its counts as it quits, one file each.
        rm -rf /b/coverage && mkdir -p /b/coverage
        swift build --package-path /src/Linux --scratch-path /b/linux-coverage --enable-code-coverage || exit
        status=0
        LLVM_PROFILE_FILE=/b/coverage/%p.profraw WELLSPENT_APP=/b/linux-coverage/debug/WellSpentLinux \
            /src/Linux/UITests/run.sh "$@" || status=$?
        /src/Linux/UITests/coverage.sh /b/linux-coverage/debug/WellSpentLinux /b/coverage
        exit $status
    ' sh "$@"
