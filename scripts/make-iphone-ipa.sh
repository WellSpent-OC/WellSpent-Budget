#!/bin/sh
# Builds the live iPhone app for TestFlight: archived from iOS/project.yml's
# Release build, then exported by Xcode, signed for the App Store, as one .ipa.
# `make iphone-testflight` runs it, then the release check and App Store
# Connect's own check. It never uploads.
#
#   scripts/make-iphone-ipa.sh PROFILE VERSION BUILD OUT
#
# PROFILE is the iPhone App Store provisioning profile for app.wellspent.mac,
# kept outside the repo (default ~/.config/wellspent/apple). The team and the
# profile's name come out of it here, so neither is written in the repo. A copy
# goes where Xcode's export looks for profiles, so nobody has to install it by
# hand. The Apple Distribution certificate must be in the login keychain.
#
# WELLSPENT_FEATURES names the flags the build carries on, as the app reads
# them from its Info.plist ("extensions,properties"); empty is none.
# WELLSPENT_PROPERTIES_PATH, when set, links the private Properties package,
# and the build fails if the archive came out without it.
#
# Needs Xcode: DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer.
set -eu

profile="${1:?usage: make-iphone-ipa.sh PROFILE VERSION BUILD OUT}"
version="${2:?usage: make-iphone-ipa.sh PROFILE VERSION BUILD OUT}"
build="${3:?usage: make-iphone-ipa.sh PROFILE VERSION BUILD OUT}"
out="${4:?usage: make-iphone-ipa.sh PROFILE VERSION BUILD OUT}"

fail() {
    echo "$*" >&2
    exit 1
}

[ -f "$profile" ] || fail "No iPhone App Store profile at $profile."

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# What the profile says about itself.
security cms -D -i "$profile" > "$work/profile.plist" 2>/dev/null || fail "$profile does not read as a profile."
read_profile() {
    /usr/libexec/PlistBuddy -c "Print :$1" "$work/profile.plist" 2>/dev/null || true
}
uuid="$(read_profile UUID)"
team="$(read_profile TeamIdentifier:0)"
[ -n "$uuid" ] && [ -n "$team" ] || fail "$profile has no UUID or team."
case "$(read_profile Entitlements:application-identifier)" in
    "$team.app.wellspent.mac") ;;
    *) fail "$profile is not for app.wellspent.mac." ;;
esac

# Where Xcode's export finds profiles (Xcode 16 and later).
installed="$HOME/Library/Developer/Xcode/UserData/Provisioning Profiles"
mkdir -p "$installed"
cp "$profile" "$installed/$uuid.mobileprovision"

rm -rf "$out"
mkdir -p "$out"
archive="$out/WellSpentPhone.xcarchive"

xcodebuild archive \
    -project iOS/WellSpentPhone.xcodeproj -scheme WellSpentPhone -configuration Release \
    -destination 'generic/platform=iOS' -archivePath "$archive" \
    -derivedDataPath .build/xcode-iphone-release -clonedSourcePackagesDirPath .build/xcode-packages \
    DEVELOPMENT_TEAM="$team" PROVISIONING_PROFILE_SPECIFIER="$uuid" \
    MARKETING_VERSION="$version" CURRENT_PROJECT_VERSION="$build" \
    WELLSPENT_FEATURES="${WELLSPENT_FEATURES:-}"

# With the package path set, the archive must hold the package: otherwise
# Houses can never appear on a tester's phone, however the flags are set.
if [ -n "${WELLSPENT_PROPERTIES_PATH:-}" ]; then
    binary="$archive/Products/Applications/WellSpentPhone.app/WellSpentPhone"
    [ -f "$binary" ] || fail "No app binary in the archive at $binary."
    strings "$binary" | grep -q WellSpentProperties \
        || fail "WELLSPENT_PROPERTIES_PATH is set, but the archive does not link WellSpentProperties."
fi

# Xcode's export, signed with the same profile, for App Store Connect.
cat > "$work/ExportOptions.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key><string>app-store-connect</string>
    <key>destination</key><string>export</string>
    <key>signingStyle</key><string>manual</string>
    <key>signingCertificate</key><string>Apple Distribution</string>
    <key>teamID</key><string>$team</string>
    <key>provisioningProfiles</key>
    <dict>
        <key>app.wellspent.mac</key><string>$uuid</string>
    </dict>
    <key>uploadSymbols</key><true/>
</dict>
</plist>
EOF
xcodebuild -exportArchive -archivePath "$archive" -exportPath "$out" \
    -exportOptionsPlist "$work/ExportOptions.plist"

[ -f "$out/WellSpentPhone.ipa" ] || fail "The export made no WellSpentPhone.ipa."
echo "Built $out/WellSpentPhone.ipa, $version ($build)."
