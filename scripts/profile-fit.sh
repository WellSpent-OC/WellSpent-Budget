#!/bin/sh
# Checks that the provisioning profile inside a signed app fits that app. A
# profile that does not fit is the usual reason a TestFlight build will not
# open on a tester's device, and an upload does not always say so first. It
# checks that the profile:
# - is an App Store profile, listing no devices
# - belongs to the team that signed the app
# - allows every restricted permission the app claims, its app ID among them
# - lists the certificate that signed the app
# - has not expired
# It works for the Mac app and the iPhone app, reads the app only and changes
# nothing. release-check.sh runs it.
#
#   scripts/profile-fit.sh APP
#
# The tests hand it the pieces it would take out of an app, NOW being a time
# such as 2026-10-19T17:00:00Z:
#
#   scripts/profile-fit.sh --parts PROFILE.plist ENTITLEMENTS.plist TEAM CERTIFICATE.der NOW
set -eu

problems=0

problem() {
    echo "profile check: $*" >&2
    problems=$((problems + 1))
}

value() {
    /usr/libexec/PlistBuddy -c "Print :$1" "$2" 2>/dev/null || true
}

# A dictionary's own keys, one a line. PlistBuddy indents them four spaces.
keys() {
    /usr/libexec/PlistBuddy -c "Print${1:+ :$1}" "$2" 2>/dev/null | sed -n 's/^    \([^ ][^ ]*\) = .*/\1/p'
}

# Whether the profile's ALLOWED takes the app's CLAIMED: the same, or a prefix
# ending in * that it starts with, as in TEAM.*
allows() {
    case "$1" in
        *\*) case "$2" in "${1%\*}"*) return 0 ;; *) return 1 ;; esac ;;
        *) [ "$1" = "$2" ] ;;
    esac
}

# Whether every item of the app's array KEY is taken by an item of the
# profile's.
array_fits() {
    i=0
    while claimed="$(/usr/libexec/PlistBuddy -c "Print :$1:$i" "$entitlements" 2>/dev/null)"; do
        j=0
        found=no
        while allowed="$(/usr/libexec/PlistBuddy -c "Print :Entitlements:$1:$j" "$profile" 2>/dev/null)"; do
            if allows "$allowed" "$claimed"; then found=yes; break; fi
            j=$((j + 1))
        done
        [ "$found" = yes ] || return 1
        i=$((i + 1))
    done
}

if [ "${1:-}" = --parts ]; then
    profile="${2:?usage: scripts/profile-fit.sh --parts PROFILE ENTITLEMENTS TEAM CERTIFICATE NOW}"
    entitlements="${3:?}"
    team="${4:?}"
    certificate="${5:?}"
    now="${6:?}"
else
    app="${1:?usage: scripts/profile-fit.sh APP}"
    work="$(mktemp -d)"
    trap 'rm -rf "$work"' EXIT
    # An iPhone app keeps its Info.plist and profile at the top, a Mac app in Contents.
    if [ -f "$app/Info.plist" ]; then
        embedded="$app/embedded.mobileprovision"
    else
        embedded="$app/Contents/embedded.provisionprofile"
    fi
    profile="$work/profile.plist"
    entitlements="$work/entitlements.plist"
    security cms -D -i "$embedded" > "$profile" 2>/dev/null \
        || { echo "profile check: no readable provisioning profile in $app" >&2; exit 1; }
    codesign -d --entitlements :- "$app" > "$entitlements" 2>/dev/null \
        || { echo "profile check: the app's permissions cannot be read" >&2; exit 1; }
    team="$(codesign -dv "$app" 2>&1 | sed -n 's/^TeamIdentifier=//p')"
    codesign -d --extract-certificates="$work/certificate" "$app" 2>/dev/null || true
    certificate="$work/certificate0"
    now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
fi

[ -n "$(value TeamIdentifier:0 "$profile")" ] \
    || { echo "profile check: the provisioning profile cannot be read" >&2; exit 1; }

# An App Store profile lists no devices. One that does is for development.
[ -z "$(value ProvisionedDevices "$profile")" ] \
    || problem "the profile is for development: it lists devices"
[ "$(value ProvisionsAllDevices "$profile")" != true ] \
    || problem "the profile is for in-house use: it allows every device"

profile_team="$(value TeamIdentifier:0 "$profile")"
[ "$profile_team" = "$team" ] \
    || problem "the profile is for team \"$profile_team\", and the app was signed by team \"$team\""

# Every restricted permission must be in the profile. The sandbox's own keys,
# com.apple.security.*, are not restricted, so profiles never list them.
claims_app_id=no
for key in $(keys "" "$entitlements"); do
    case "$key" in
        com.apple.security.*) continue ;;
        com.apple.application-identifier | application-identifier) claims_app_id=yes ;;
    esac
    claimed="$(value "$key" "$entitlements")"
    allowed="$(value "Entitlements:$key" "$profile")"
    if [ -z "$allowed" ]; then
        problem "the profile does not allow $key"
    elif [ "${claimed%% *}" = Array ]; then
        array_fits "$key" || problem "the profile does not allow every $key the app claims"
    elif ! allows "$allowed" "$claimed"; then
        problem "the profile allows $key \"$allowed\", and the app claims \"$claimed\""
    fi
done
[ "$claims_app_id" = yes ] || problem "the app claims no app ID"

# The certificate that signed the app is one the profile lists.
signer="$(shasum -a 256 < "$certificate" 2>/dev/null | cut -d' ' -f1)"
listed=no
j=0
while listed_base64="$(plutil -extract "DeveloperCertificates.$j" raw -o - "$profile" 2>/dev/null)"; do
    if [ "$(printf '%s' "$listed_base64" | base64 -D | shasum -a 256 | cut -d' ' -f1)" = "$signer" ]; then
        listed=yes
        break
    fi
    j=$((j + 1))
done
[ "$listed" = yes ] || problem "the profile does not list the certificate that signed the app"

# Dates compare as their digits: 2027-10-13T16:47:05Z is 20271013164705.
expires="$(plutil -extract ExpirationDate raw -o - "$profile" 2>/dev/null || true)"
if [ -z "$expires" ]; then
    problem "the profile has no end date"
elif [ "$(printf '%s' "$expires" | tr -dc 0-9)" -le "$(printf '%s' "$now" | tr -dc 0-9)" ]; then
    problem "the profile ended on $expires"
fi

if [ "$problems" -gt 0 ]; then
    exit 1
fi
echo "profile check: the profile fits, for team $team, until $expires."
