#!/bin/sh
# Checks that a built Mac or iPhone app holds no encryption code but Apple's
# own. The export answer the apps give App Store Connect, that they use only the
# encryption within Apple's operating systems, is true only while that holds.
# BoringSSL, which swift-crypto's CryptoExtras brings, or swift-crypto's own
# algorithms in place of CryptoKit's, would make it false.
#
#   scripts/crypto-check.sh APP
#
# It reads every Mach-O file in the bundle, because a debug build keeps the
# app's code in <app>.debug.dylib beside a small stub, and a framework would sit
# in Frameworks. It reads their text with strings, not their symbols, because a
# release binary is stripped: BoringSSL's own strings and Swift's type names
# survive that. swift-crypto's small helpers, such as its constant-time compare,
# are not encryption and are allowed. release-check.sh runs it, and so does CI.
set -eu

app="${1:?usage: scripts/crypto-check.sh APP}"
[ -d "$app" ] || { echo "crypto check: no app at $app" >&2; exit 1; }

# BoringSSL and the module that brings it, and swift-crypto's own algorithm
# types, such as OpenSSLAESGCMImpl, which it compiles only without CryptoKit.
pattern='boringssl|cryptoextras|cryptoboringwrapper|openssl[a-z0-9]*impl'

files="$(mktemp)"
trap 'rm -f "$files"' EXIT
find "$app" -type f > "$files"

problems=0
checked=0
while IFS= read -r file; do
    case "$(file -b "$file")" in *Mach-O*) ;; *) continue ;; esac
    checked=$((checked + 1))
    # Every byte, not only sections: Apple's strings reads just the sections
    # with -a, and a symbol table is in none. swift-crypto keeps its helpers,
    # such as the constant-time compare, in a Swift folder named
    # Sources/Crypto/Util/BoringSSL, and a debug build carries that folder's
    # path. The path is not BoringSSL, so it is let through. BoringSSL's own
    # sources live in Sources/CCryptoBoringSSL, which is still caught.
    # Its input is /dev/null, not the loop's file list: llvm-strings, unlike
    # Apple's, would read "-" as that input.
    hits="$(strings - "$file" < /dev/null | grep -i -E "$pattern" | grep -v '/Sources/Crypto/Util/BoringSSL/' \
        | sort -u | head -n 5 || true)"
    [ -n "$hits" ] || continue
    echo "crypto check: ${file#"$app"/} holds encryption that is not Apple's own, such as:" >&2
    printf '%s\n' "$hits" | sed 's/^/    /' >&2
    problems=$((problems + 1))
done < "$files"

[ "$checked" -gt 0 ] || { echo "crypto check: no code at all in $app" >&2; exit 1; }
[ "$problems" -eq 0 ] || exit 1
echo "crypto check: $checked code file(s) in $app hold Apple's encryption only."
