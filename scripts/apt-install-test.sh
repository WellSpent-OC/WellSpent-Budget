#!/bin/sh
# Tests scripts/apt-install.sh with apt-get and timeout stood in for by stubs,
# on sources files in a throwaway folder (APT_ETC). The stub apt-get writes
# down the host its sources name at each update, and fails the first
# FAIL_UPDATES updates. On GitHub the first try uses Azure's mirror. When it
# fails, the next tries use archive.ubuntu.com, Ubuntu's own: a mirror that
# stalls one night stalls every try. Off GitHub, with no mirror named, the
# image's own hosts are used throughout.
#
#   scripts/apt-install-test.sh
set -eu
script="$(cd "$(dirname "$0")" && pwd)/apt-install.sh"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin"
cat > "$tmp/bin/apt-get" <<'STUB'
#!/bin/sh
case " $* " in
    *" update "*)
        host=$(grep -o 'http://[^/]*/' "$APT_ETC/sources.list" | head -1)
        echo "$host" >> "$LOG"
        n=$(wc -l < "$LOG")
        [ "$n" -gt "${FAIL_UPDATES:-0}" ] || exit 100 ;;
esac
exit 0
STUB
printf '#!/bin/sh\nshift\nexec "$@"\n' > "$tmp/bin/timeout"
chmod +x "$tmp/bin/apt-get" "$tmp/bin/timeout"

failed=0
check() {
    if [ "$1" = "$2" ]; then echo "pass: $3"; else echo "FAIL: $3: got [$1], wanted [$2]"; cat "$tmp/out"; failed=1; fi
}
# run FAILS [VAR=VALUE...]: a fresh sources file naming Ubuntu's own hosts,
# then the script with FAILS updates failing. Leaves the hosts each update
# saw in $tmp/log, joined by spaces, and the exit code in $code.
run() {
    fails=$1; shift
    mkdir -p "$tmp/etc/sources.list.d"
    printf 'deb http://archive.ubuntu.com/ubuntu noble main\ndeb http://security.ubuntu.com/ubuntu noble-security main\n' \
        > "$tmp/etc/sources.list"
    : > "$tmp/log"
    code=0
    env -u GITHUB_ACTIONS -u APT_MIRROR PATH="$tmp/bin:$PATH" APT_ETC="$tmp/etc" LOG="$tmp/log" \
        FAIL_UPDATES="$fails" APT_RETRY_WAIT=0 "$@" sh "$script" somepackage > "$tmp/out" 2>&1 || code=$?
    hosts=$(tr '\n' ' ' < "$tmp/log" | sed 's/ $//')
}
azure=http://azure.archive.ubuntu.com/
ubuntu=http://archive.ubuntu.com/

run 0 GITHUB_ACTIONS=true
check "$code" 0 "on GitHub, a first try that works is the only one"
check "$hosts" "$azure" "and it uses Azure's mirror"

run 1 GITHUB_ACTIONS=true
check "$code" 0 "on GitHub, a failed first try is tried again"
check "$hosts" "$azure $ubuntu" "on Ubuntu's own archive"

run 3 GITHUB_ACTIONS=true
check "$code" 1 "three failed tries give up"
check "$hosts" "$azure $ubuntu $ubuntu" "the last two on Ubuntu's own archive"
check "$(grep -c 'giving up' "$tmp/out")" 1 "and say so"

run 1 APT_MIRROR=$azure
check "$hosts" "$azure $ubuntu" "a mirror named by APT_MIRROR falls back the same way"

run 1
check "$code" 0 "off GitHub, a failed try is tried again"
check "$hosts" "$ubuntu $ubuntu" "on the image's own hosts throughout"

exit "$failed"
