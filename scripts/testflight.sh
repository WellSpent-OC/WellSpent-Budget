#!/bin/sh
# Wraps the App Store build of WellSpent.app in a signed installer package, has App
# Store Connect check it, and uploads it. `make testflight` runs package and
# validate and never uploads. `make testflight-upload` runs upload alone.
#
#   scripts/testflight.sh package APP PKG   builds PKG around APP, signed with the
#                                           Mac Installer Distribution certificate
#   scripts/testflight.sh validate PKG      has App Store Connect check PKG, and
#                                           records that it passed
#   scripts/testflight.sh upload PKG        uploads a PKG that passed validate and
#                                           has not changed since
#
# Needs Xcode's altool: DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer.
# These come from the environment, or else from the KEYINFO file (default
# ~/.config/wellspent/apple/keyinfo.txt), a file of NAME=value lines:
#   INSTALLER_IDENTITY  the "3rd Party Mac Developer Installer" certificate by its
#                       full name as Keychain Access shows it. productbuild takes
#                       the name only, and the name holds the account holder's, so
#                       it never goes in this repo.
#   KEY_ID, ISSUER_ID   the App Store Connect API key and its issuer
# The key file AuthKey_<KEY_ID>.p8 sits in the KEYINFO folder. altool reads it
# from there, through API_PRIVATE_KEYS_DIR. This script never opens it.
set -eu

KEYINFO="${KEYINFO:-$HOME/.config/wellspent/apple/keyinfo.txt}"

fail() {
    echo "$*" >&2
    exit 1
}

# The setting named $1, from the environment or else from the KEYINFO file.
setting() {
    eval "value=\${$1:-}"
    if [ -z "$value" ] && [ -f "$KEYINFO" ]; then
        value="$(sed -n "s/^$1=//p" "$KEYINFO" | head -n 1)"
    fi
    [ -n "$value" ] || fail "No $1. Set it, or add a $1= line to $KEYINFO."
    printf '%s' "$value"
}

# altool with the API key. The key id and issuer id are identifiers, not secrets.
asc() {
    key_id="$(setting KEY_ID)"
    issuer_id="$(setting ISSUER_ID)"
    API_PRIVATE_KEYS_DIR="$(dirname "$KEYINFO")" \
        xcrun altool "$@" --platform macos --api-key "$key_id" --api-issuer "$issuer_id"
}

case "${1:-}" in
    package)
        app="${2:?usage: testflight.sh package APP PKG}"
        pkg="${3:?usage: testflight.sh package APP PKG}"
        identity="$(setting INSTALLER_IDENTITY)"
        rm -f "$pkg" "$pkg.validated"
        # The first run may show a keychain prompt for the signing key. Choose Always Allow.
        productbuild --sign "$identity" --component "$app" /Applications "$pkg"
        pkgutil --check-signature "$pkg"
        ;;
    validate)
        pkg="${2:?usage: testflight.sh validate PKG}"
        asc --validate-app "$pkg"
        # upload takes only this exact file. Its checksum is the record.
        (cd "$(dirname "$pkg")" && shasum -a 256 "$(basename "$pkg")") > "$pkg.validated"
        echo "Validated $pkg. Upload it with make testflight-upload."
        ;;
    upload)
        pkg="${2:?usage: testflight.sh upload PKG}"
        [ -f "$pkg.validated" ] || fail "$pkg has not passed validate. Run make testflight first."
        (cd "$(dirname "$pkg")" && shasum -a 256 --status -c "$(basename "$pkg").validated") \
            || fail "$pkg changed since it was validated. Run make testflight again."
        asc --upload-package "$pkg"
        ;;
    *)
        fail "usage: scripts/testflight.sh package APP PKG | validate PKG | upload PKG"
        ;;
esac
