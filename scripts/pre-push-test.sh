#!/bin/sh
# Tests scripts/hooks/pre-push in a throwaway repository, with make, swift,
# docker and scripts/prepush-in-docker.sh stood in for by stubs that write
# down that they ran. With swift on the PATH, the hook runs make prepush, as
# on a Mac. With no swift but docker, it runs prepush-in-docker.sh, and then
# only for a push of HEAD, since the container checks HEAD.
#
#   scripts/pre-push-test.sh
set -eu
hook="$(cd "$(dirname "$0")" && pwd)/hooks/pre-push"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
# Git's own variables would point the throwaway repository's commands at
# this one when the test runs inside a hook.
unset $(git rev-parse --local-env-vars)

repo="$tmp/repo"
git init -q "$repo"
git -C "$repo" -c user.name=Test -c user.email=test@example.com commit -q --allow-empty -m first
git -C "$repo" -c user.name=Test -c user.email=test@example.com commit -q --allow-empty -m second
head="$(git -C "$repo" rev-parse HEAD)"
before="$(git -C "$repo" rev-parse HEAD~1)"
mkdir -p "$repo/scripts" "$tmp/with-swift" "$tmp/no-swift"
printf '#!/bin/sh\necho in-docker >> "%s/ran"\n' "$tmp" > "$repo/scripts/prepush-in-docker.sh"
chmod +x "$repo/scripts/prepush-in-docker.sh"
# A PATH with the stubs and the system's own tools, minus any real swift.
for dir in with-swift no-swift; do
    printf '#!/bin/sh\necho "make $*" >> "%s/ran"\n' "$tmp" > "$tmp/$dir/make"
    printf '#!/bin/sh\nexit 0\n' > "$tmp/$dir/docker"
    chmod +x "$tmp/$dir/make" "$tmp/$dir/docker"
done
printf '#!/bin/sh\nexit 0\n' > "$tmp/with-swift/swift"
chmod +x "$tmp/with-swift/swift"
# Only the system tools the hook needs, linked one by one: a Mac's /usr/bin
# has a swift of its own, which would spoil the no-swift case.
mkdir -p "$tmp/system"
for tool in sh git cat; do
    ln -s "$(command -v "$tool")" "$tmp/system/$tool"
done
system=":$tmp/system"

failed=0
# run DIR SHA: runs the hook in the repository with DIR's stubs first on the
# PATH, for a push of SHA. Leaves what ran in $tmp/ran and the exit code in $code.
run() {
    : > "$tmp/ran"
    code=0
    (cd "$repo" && echo "refs/heads/main $2 refs/heads/main 0000000000000000000000000000000000000000" |
        PATH="$tmp/$1$system" sh "$hook" origin git@example.com:x.git) > "$tmp/out" 2>&1 || code=$?
}
check() {
    if [ "$1" = "$2" ]; then echo "pass: $3"; else echo "FAIL: $3: got [$1], wanted [$2]"; cat "$tmp/out"; failed=1; fi
}

run with-swift "$head"
check "$code" 0 "with swift, the push goes on"
check "$(cat "$tmp/ran")" "make prepush" "with swift, the hook runs make prepush"

run no-swift "$head"
check "$code" 0 "with no swift, a push of HEAD goes on"
check "$(cat "$tmp/ran")" "in-docker" "with no swift, the hook runs the checks in the container"

run no-swift "$before"
check "$code" 1 "with no swift, a push of anything but HEAD is refused"
check "$(cat "$tmp/ran")" "" "and nothing runs for it"

# A push that only deletes branches sends no commit, so there is nothing to
# check: it goes on, and nothing runs, with or without swift.
zero=0000000000000000000000000000000000000000
for dir in with-swift no-swift; do
    : > "$tmp/ran"
    code=0
    (cd "$repo" && echo "(delete) $zero refs/heads/old $before" |
        PATH="$tmp/$dir$system" sh "$hook" origin git@example.com:x.git) > "$tmp/out" 2>&1 || code=$?
    check "$code" 0 "$dir: a push that only deletes goes on"
    check "$(cat "$tmp/ran")" "" "$dir: and runs no checks"
done

# prepush-in-docker.sh on a disk at or past its limit stops before it builds
# anything: no image, no container.
mkdir -p "$tmp/full"
printf '#!/bin/sh\necho Use%%\necho " 85%%"\n' > "$tmp/full/df"
printf '#!/bin/sh\necho "docker $*" >> "%s/ran"\nexit 1\n' "$tmp" > "$tmp/full/docker"
chmod +x "$tmp/full/df" "$tmp/full/docker"
for tool in tail tr mkdir sha256sum cut; do
    [ -e "$tmp/system/$tool" ] || ln -s "$(command -v "$tool")" "$tmp/system/$tool"
done
mkdir -p "$repo/Linux/UITests"
: > "$repo/Linux/UITests/Dockerfile"
: > "$repo/Linux/UITests/packages.txt"
: > "$tmp/ran"
code=0
(cd "$repo" && PATH="$tmp/full:$tmp/system" PREPUSH_SCRATCH="$tmp/scratch" \
    sh "$(dirname "$hook")/../prepush-in-docker.sh") > "$tmp/out" 2>&1 || code=$?
check "$code" 1 "a disk past the limit stops the checks"
check "$(cat "$tmp/ran")" "" "and nothing is built"
check "$(grep -c 'builds stop at 80%' "$tmp/out")" 1 "it says why"

# With room on the disk, the container gets at most 8 cores to see, not
# only 8 cores' worth of time: Swift starts one compile per core it sees,
# and 32 at once ran past the container's memory on a cold build.
mkdir -p "$tmp/room"
printf '#!/bin/sh\necho Use%%\necho " 40%%"\n' > "$tmp/room/df"
printf '#!/bin/sh\necho "docker $*" >> "%s/ran"\nexit 0\n' "$tmp" > "$tmp/room/docker"
printf '#!/bin/sh\nexit 0\n' > "$tmp/room/rsync"
printf '#!/bin/sh\nexit 0\n' > "$tmp/room/make"
printf '#!/bin/sh\necho 32\n' > "$tmp/room/nproc"
chmod +x "$tmp/room/df" "$tmp/room/docker" "$tmp/room/rsync" "$tmp/room/make" "$tmp/room/nproc"
for tool in tar mktemp basename id rm; do
    [ -e "$tmp/system/$tool" ] || ln -s "$(command -v "$tool")" "$tmp/system/$tool"
done
: > "$tmp/ran"
code=0
(cd "$repo" && PATH="$tmp/room:$tmp/system" PREPUSH_SCRATCH="$tmp/scratch" \
    sh "$(dirname "$hook")/../prepush-in-docker.sh") > "$tmp/out" 2>&1 || code=$?
check "$code" 0 "with room on the disk, the checks run"
check "$(grep -c -- '^docker run .*--cpuset-cpus=0-7 ' "$tmp/ran")" 1 "the container sees 8 of 32 cores"
printf '#!/bin/sh\necho 4\n' > "$tmp/room/nproc"
: > "$tmp/ran"
(cd "$repo" && PATH="$tmp/room:$tmp/system" PREPUSH_SCRATCH="$tmp/scratch" \
    sh "$(dirname "$hook")/../prepush-in-docker.sh") > "$tmp/out" 2>&1 || true
check "$(grep -c -- '^docker run .*--cpuset-cpus=0-3 ' "$tmp/ran")" 1 "on a 4-core machine, all 4 and no more"

# From the hook, with a cold build folder: it stops at once and says how to
# warm it, since a cold build outlasts the push's connection to the remote,
# which then fails after the checks pass. Run directly, it builds, and the
# folder is warm for the next push.
cold="$tmp/cold-scratch"
rm -rf "$cold"
: > "$tmp/ran"
code=0
(cd "$repo" && PATH="$tmp/room:$tmp/system" PREPUSH_SCRATCH="$cold" PREPUSH_FROM_HOOK=1 \
    sh "$(dirname "$hook")/../prepush-in-docker.sh") > "$tmp/out" 2>&1 || code=$?
check "$code" 1 "from the hook, a cold folder stops the push"
check "$(cat "$tmp/ran")" "" "and builds nothing"
check "$(grep -c 'scripts/prepush-in-docker.sh' "$tmp/out")" 1 "it says to run the checks once first"
: > "$tmp/ran"
(cd "$repo" && PATH="$tmp/room:$tmp/system" PREPUSH_SCRATCH="$cold" \
    sh "$(dirname "$hook")/../prepush-in-docker.sh") > "$tmp/out" 2>&1 || true
check "$(grep -c '^docker run' "$tmp/ran")" 1 "run directly, a cold folder builds"
: > "$tmp/ran"
code=0
(cd "$repo" && PATH="$tmp/room:$tmp/system" PREPUSH_SCRATCH="$cold" PREPUSH_FROM_HOOK=1 \
    sh "$(dirname "$hook")/../prepush-in-docker.sh") > "$tmp/out" 2>&1 || code=$?
check "$code" 0 "after that, the hook's checks run"
check "$(grep -c '^docker run' "$tmp/ran")" 1 "and build in the warm folder"

exit "$failed"
