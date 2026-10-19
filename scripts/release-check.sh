#!/bin/sh
# Checks a built WellSpent app before it goes to TestFlight: that it is the
# release it claims to be, and the live app. `make testflight` (the Mac) and
# `make iphone-testflight` run it right after the app is built, on the exact
# commit that ships. Any problem stops the build, so a wrong binary never
# reaches App Store Connect.
#
#   scripts/release-check.sh APP VERSION BUILD
#
# For both apps it checks the version and build number, the bundle ID, that the
# build is live, and that the provisioning profile fits the app (profile-fit.sh).
# For the Mac app: its one invite link type, every icon size, the signature, and
# the sandbox. For the iPhone app, told apart by its Info.plist sitting at the
# top of the app: iPhone only, the oldest iOS, the icon, the privacy file, a
# profile that is not a development one, and the signature. It reads the app and
# changes nothing.
set -eu

app="${1:?usage: scripts/release-check.sh APP VERSION BUILD}"
version="${2:?usage: scripts/release-check.sh APP VERSION BUILD}"
build="${3:?usage: scripts/release-check.sh APP VERSION BUILD}"
# An iPhone app keeps its Info.plist at the top, a Mac app in Contents.
if [ -f "$app/Info.plist" ]; then
    platform=iphone
    plist="$app/Info.plist"
else
    platform=mac
    plist="$app/Contents/Info.plist"
fi
problems=0

problem() {
    echo "release check: $*" >&2
    problems=$((problems + 1))
}

value() {
    /usr/libexec/PlistBuddy -c "Print :$1" "$2" 2>/dev/null || true
}

expect() {
    got="$(value "$1" "$plist")"
    [ "$got" = "$2" ] || problem "$1 is \"$got\", not \"$2\""
}

[ -f "$plist" ] || { echo "release check: no Info.plist in $app" >&2; exit 1; }

expect CFBundleShortVersionString "$version"
expect CFBundleVersion "$build"
expect CFBundleIdentifier app.wellspent.mac
expect WellSpentEnvironment live

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

if [ "$platform" = iphone ]; then
    expect MinimumOSVersion 17.0
    expect UIDeviceFamily:0 1
    [ -z "$(value UIDeviceFamily:1 "$plist")" ] || problem "the app claims more than the iPhone"
    expect CFBundleIcons:CFBundlePrimaryIcon:CFBundleIconName AppIcon
    [ -f "$app/Assets.car" ] || problem "no compiled icon in the app"
    if [ -f "$app/PrivacyInfo.xcprivacy" ]; then
        plutil -lint -s "$app/PrivacyInfo.xcprivacy" || problem "the privacy file does not read"
    else
        problem "no privacy file in the app"
    fi
    profile="$app/embedded.mobileprovision"
    if [ -f "$profile" ]; then
        # The profile fits the app: its team, its permissions, its certificate, its date.
        "$(dirname "$0")/profile-fit.sh" "$app" || problem "the provisioning profile does not fit the app"
        # And a release never carries a development profile, whatever the app claims.
        security cms -D -i "$profile" > "$work/profile.plist" 2>/dev/null || true
        [ "$(value Entitlements:get-task-allow "$work/profile.plist")" != true ] \
            || problem "the profile is a development one, not the App Store's"
    else
        problem "no provisioning profile in the app"
    fi
    codesign --verify --deep --strict "$app" 2>/dev/null || problem "the signature does not verify"
    if [ "$problems" -gt 0 ]; then
        echo "release check: $problems problem(s), so nothing goes to App Store Connect." >&2
        exit 1
    fi
    echo "release check: $app is $version ($build), live, iPhone only from iOS 17, signed, with its icon and privacy file."
    exit 0
fi

expect CFBundleIconFile AppIcon
expect CFBundleURLTypes:0:CFBundleURLSchemes:0 wellspent
[ -z "$(value CFBundleURLTypes:0:CFBundleURLSchemes:1 "$plist")" ] \
    || problem "the app claims more than one invite link type"
[ -z "$(value CFBundleURLTypes:1 "$plist")" ] || problem "the app claims more than one link group"

# Every icon size macOS asks for, from the icon file in the app itself.
icns="$app/Contents/Resources/AppIcon.icns"
if [ -f "$icns" ] && iconutil -c iconset "$icns" -o "$work/AppIcon.iconset" 2>/dev/null; then
    for points in 16 32 128 256 512; do
        for file in "icon_${points}x${points}.png" "icon_${points}x${points}@2x.png"; do
            [ -f "$work/AppIcon.iconset/$file" ] || problem "the icon has no $file"
        done
    done
else
    problem "no readable AppIcon.icns in the app"
fi

[ -f "$app/Contents/embedded.provisionprofile" ] || problem "no provisioning profile in the app"
# The profile fits the app: its team, its permissions, its certificate, its date.
"$(dirname "$0")/profile-fit.sh" "$app" || problem "the provisioning profile does not fit the app"

# Signed, not changed since, and sandboxed.
codesign --verify --deep --strict "$app" 2>/dev/null || problem "the signature does not verify"
if codesign -d --entitlements :- "$app" > "$work/entitlements.plist" 2>/dev/null; then
    [ "$(value com.apple.security.app-sandbox "$work/entitlements.plist")" = true ] \
        || problem "the app is not sandboxed"
else
    problem "the app's entitlements cannot be read"
fi

if [ "$problems" -gt 0 ]; then
    echo "release check: $problems problem(s), so nothing was packaged." >&2
    exit 1
fi
echo "release check: $app is $version ($build), live, signed and sandboxed, with every icon size."
