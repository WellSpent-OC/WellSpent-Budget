#!/bin/sh
# Tests the Linux release's packaging, with no Swift: make linux-release, which
# needs a vX.Y.Z tag and hands Linux/scripts/package.sh the release's version
# and the TestFlight flags; package.sh, with a stand-in swift, which writes the
# version beside the environment and names the .tar.gz for it; and install.sh,
# which stops before installing anything when the computer lacks a library.
#
#   scripts/linux-release-test.sh
set -eu
root="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
# Git's own variables would point the throwaway repository at this one when the
# test runs inside a hook.
unset $(git rev-parse --local-env-vars)

failed=0
check() {
    if [ "$1" = "$2" ]; then echo "pass: $3"; else echo "FAIL: $3: got [$1], wanted [$2]"; failed=1; fi
}

# make linux-release, in a repository holding this Makefile and a package.sh
# that writes down what it was handed.
repo="$tmp/repo"
mkdir -p "$repo/Linux/scripts"
cp "$root/Makefile" "$repo/"
cat > "$repo/Linux/scripts/package.sh" <<'EOF'
#!/bin/sh
echo "$WELLSPENT_ENV $VERSION $WELLSPENT_FEATURES" > "$(dirname "$0")/ran"
EOF
chmod +x "$repo/Linux/scripts/package.sh"
git -C "$repo" init -q
git -C "$repo" -c user.name=Test -c user.email=test@example.com add -A
git -C "$repo" -c user.name=Test -c user.email=test@example.com commit -q -m first
flags="$(sed -n 's/^TESTFLIGHT_FEATURES ?= //p' "$root/Makefile")"

code=0
make -s -C "$repo" linux-release > "$tmp/out" 2>&1 || code=$?
check "$code" 2 "with no release tag, make linux-release stops"
check "$(grep -c 'check out its vX.Y.Z tag' "$tmp/out")" 1 "and says why"
check "$([ -f "$repo/Linux/scripts/ran" ] && echo ran || echo not)" not "and packages nothing"

git -C "$repo" tag v0.4.0
code=0
make -s -C "$repo" linux-release > "$tmp/out" 2>&1 || code=$?
check "$code" 0 "on a v0.4.0 tag, make linux-release goes on"
check "$(cat "$repo/Linux/scripts/ran" 2>/dev/null)" "live 0.4.0 $flags" \
    "it packages the live app, at the tag's version, with the TestFlight flags"

# package.sh, with a stand-in swift that makes the app and its resources.
pack="$tmp/pack"
mkdir -p "$pack/Linux/scripts" "$pack/Design/AppIcon" "$tmp/bin" "$tmp/build"
cp "$root/Linux/scripts/package.sh" "$root/Linux/scripts/install.sh.in" "$pack/Linux/scripts/"
echo '<svg/>' > "$pack/Design/AppIcon/AppIcon.svg"
cat > "$tmp/bin/swift" <<EOF
#!/bin/sh
for argument in "\$@"; do [ "\$argument" = --show-bin-path ] && { echo "$tmp/build"; exit 0; }; done
mkdir -p "$tmp/build/WellSpentLinux_WellSpentLinux.resources"
printf '#!/bin/sh\n' > "$tmp/build/WellSpentLinux"
EOF
printf '#!/bin/sh\nexit 0\n' > "$tmp/bin/strip"
chmod +x "$tmp/bin/swift" "$tmp/bin/strip"
resources="$pack/Linux/dist/wellspent-staging/WellSpentLinux_WellSpentLinux.resources"

(cd "$pack" && PATH="$tmp/bin:$PATH" WELLSPENT_ENV=staging VERSION=0.4.0 Linux/scripts/package.sh) > "$tmp/out" 2>&1
check "$(cat "$resources/version" 2>/dev/null)" 0.4.0 "package.sh writes the version beside the environment"
check "$(ls "$pack/Linux/dist" | grep -c "^wellspent-staging-0.4.0-linux-$(uname -m).tar.gz$")" 1 \
    "and names the .tar.gz for the version and the chip"

(cd "$pack" && PATH="$tmp/bin:$PATH" WELLSPENT_ENV=staging Linux/scripts/package.sh) > "$tmp/out" 2>&1
check "$(cat "$resources/version" 2>/dev/null)" 0.0.0-dev "with no version, it's a development build"

# install.sh, from that package, with a stand-in ldd saying what's missing.
app="$pack/Linux/dist/wellspent-staging"
(cd "$pack" && PATH="$tmp/bin:$PATH" WELLSPENT_ENV=staging VERSION=0.4.0 Linux/scripts/package.sh) > /dev/null 2>&1
mkdir -p "$tmp/missing" "$tmp/found"
printf '#!/bin/sh\necho "\tlibsqlite3.so.0 => not found"\necho "\tlibcurl.so.4 => not found"\n' > "$tmp/missing/ldd"
printf '#!/bin/sh\necho "\tlibc.so.6 => /lib/libc.so.6"\n' > "$tmp/found/ldd"
chmod +x "$tmp/missing/ldd" "$tmp/found/ldd"

code=0
HOME="$tmp/home-missing" XDG_DATA_HOME="" PATH="$tmp/missing:$PATH" sh "$app/install.sh" > "$tmp/out" 2>&1 || code=$?
check "$code" 1 "a computer missing a library stops the install"
check "$(grep -c 'sudo apt install libsqlite3-0 libcurl4' "$tmp/out")" 1 "it names the apt packages"
check "$(grep -c 'sudo dnf install sqlite-libs libcurl' "$tmp/out")" 1 "and the dnf ones"
check "$([ -e "$tmp/home-missing/.local/opt" ] && echo installed || echo not)" not "and installs nothing"

code=0
HOME="$tmp/home-found" XDG_DATA_HOME="" PATH="$tmp/found:$PATH" sh "$app/install.sh" > "$tmp/out" 2>&1 || code=$?
check "$code" 0 "a computer with every library installs"
check "$(tail -1 "$tmp/out")" "WellSpent Staging 0.4.0 is installed. It is in the app menu." "and names the version"

exit "$failed"
