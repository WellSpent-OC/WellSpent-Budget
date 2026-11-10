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
# The runner starts a disposable server from this checkout with its own
# synthetic mailbox. It does not need a deployed server or mailbox secret.
# UITEST_COVERAGE   when set, builds the app with coverage (in its own build
#                   folder) and ends with how much of the Linux app's own code
#                   the tests ran (coverage.sh), even when a test failed
# UITEST_PROPERTIES a checkout of the private Properties extension, with no
#                   spaces in its path. The app is built linked with it, in
#                   its own build folder, and the extension's Linux UI tests
#                   (UITests/Linux, such as test_houses) can be named here.
#                   A coverage run doesn't link it yet, and ignores it
set -eu
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
NAME="${UITEST_CONTAINER:-wsr-linux-uitest}"
SCRATCH="${UITEST_SCRATCH:-$ROOT/.build/uitest}"
# Named for what it's built from, so a changed package list builds a new one.
IMAGE="wellspent-linux-uitest:$(cat "$ROOT/Linux/UITests/Dockerfile" "$ROOT/Linux/UITests/packages.txt" | sha256sum | cut -c1-12)"

docker image inspect "$IMAGE" >/dev/null 2>&1 || docker build -q -t "$IMAGE" "$ROOT/Linux/UITests"
mkdir -p "$SCRATCH/home" "$SCRATCH/out"

PROPERTIES=""
if [ -n "${UITEST_PROPERTIES:-}" ]; then
    case "$UITEST_PROPERTIES" in *" "*) echo "UITEST_PROPERTIES can't have a space in it" >&2; exit 1 ;; esac
    [ -f "$UITEST_PROPERTIES/Package.swift" ] || { echo "UITEST_PROPERTIES is not a Properties checkout" >&2; exit 1; }
    PROPERTIES="-v $(cd "$UITEST_PROPERTIES" && pwd):/props:ro -e LINUX_PROPERTIES=/props
        -e PYTHONPATH=/props/UITests/Linux -e LINUX_BUILD=/b/linux-props"
fi

# The source goes in read-only. The build, its home and the pictures go in the
# scratch folder, owned by you: the container starts as root only to hand
# your user the one capability a failed step needs to read a stuck app's
# stacks (ptrace), then runs as you.
docker run --rm --name "$NAME" \
    --cpus=8 --memory=8g \
    -v "$ROOT:/src:ro" -v "$SCRATCH:/b" $PROPERTIES \
    -e HOME=/b/home -e WELLSPENT_UI_OUT=/b/out \
    --cap-add=SYS_PTRACE \
    --security-opt seccomp=unconfined --security-opt apparmor=unconfined \
    ${UITEST_COVERAGE:+-e UITEST_COVERAGE} \
    "$IMAGE" setpriv --reuid="$(id -u)" --regid="$(id -g)" --clear-groups \
        --inh-caps=+sys_ptrace --ambient-caps=+sys_ptrace sh -c '
        swift build --package-path /src/Server --scratch-path /b/server -j 8 || exit
        if [ -z "${UITEST_COVERAGE:-}" ]; then
            LINUX_BUILD="${LINUX_BUILD:-/b/linux}"
            # Only the app links Properties. The server depends on the root
            # package, which reads the same variable, so the server must not see it.
            WELLSPENT_PROPERTIES_PATH="${LINUX_PROPERTIES:-}" \
                swift build --package-path /src/Linux --scratch-path "$LINUX_BUILD" -j 8 &&
            WELLSPENT_APP="$LINUX_BUILD/debug/WellSpentLinux" \
                python3 /src/Server/scripts/with-ui-fixture.py --server /b/server/debug/WellSpentServer \
                -- /src/Linux/UITests/run.sh "$@"
            exit
        fi
        # Each copy of the app writes its counts as it quits, one file each.
        rm -rf /b/coverage && mkdir -p /b/coverage
        # SwiftPM counts Swift only, so the C helpers get the C compiler flags too.
        swift build --package-path /src/Linux --scratch-path /b/linux-coverage --enable-code-coverage -j 8 \
            -Xcc -fprofile-instr-generate -Xcc -fcoverage-mapping || exit
        status=0
        LLVM_PROFILE_FILE=/b/coverage/%p.profraw WELLSPENT_APP=/b/linux-coverage/debug/WellSpentLinux \
            python3 /src/Server/scripts/with-ui-fixture.py --server /b/server/debug/WellSpentServer \
            -- /src/Linux/UITests/run.sh "$@" || status=$?
        /src/Linux/UITests/coverage.sh /b/linux-coverage/debug/WellSpentLinux /b/coverage
        exit $status
    ' sh "$@"
