#!/bin/sh
# Builds the Mac app from this package. `make app` signs it ad hoc. `make testflight`
# signs it for the Mac App Store, which is what TestFlight takes.
#
# WELLSPENT_ENV  live or staging (default staging). Live builds WellSpent.app, the
#                app real budgets are kept in. Staging builds WellSpent Staging.app,
#                which has its own data folder, keychain names, settings and
#                server, and never connects to the live server.
# VERSION        the version people see, for example 0.1.0-beta.12 (default 0.0.0-dev)
# BUILD          the build number macOS compares between copies (default 1)
# ARCHS          the architectures to build, for example "arm64 x86_64" (default: this Mac's)
# OUT            where the .app lands (default .build/app)
# SCRATCH        where SwiftPM builds (default .build)
# SIGN           adhoc (default) or appstore, see below
#
# Staging is the default because a test build mistaken for live could reach real
# budgets, and the reverse cannot. Only the beta workflow and `make testflight`
# set live.
#
# SIGN=adhoc: an ad hoc signature is not an Apple Developer ID. macOS refuses to
# open the app the first time, until the person allows it in System Settings,
# Privacy and Security. The README says how.
#
# SIGN=appstore: live only, because the provisioning profile covers
# app.wellspent.mac alone. The app is sandboxed, signed with the Apple
# Distribution certificate, and carries the profile, the Info.plist keys App Store
# Connect insists on, and Apple's data move (see container-migration.plist below).
# It needs Xcode's tools: DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer.
# These come from outside the repo:
#   PROFILE            the Mac App Store provisioning profile (default
#                      ~/.config/wellspent/apple/WellSpent_Mac_App_Store.provisionprofile)
#   CODESIGN_IDENTITY  the Apple Distribution certificate as its 40 digit SHA-1 hash,
#                      from the environment or a CODESIGN_IDENTITY= line in KEYINFO
#   KEYINFO            a file of NAME=value lines (default ~/.config/wellspent/apple/keyinfo.txt)
#   TEAM_ID            the Apple Developer team that owns the bundle id (default GBF27ALM9A)
# Certificate names hold the account holder's name, so they never go in this repo.
set -eu

WELLSPENT_ENV="${WELLSPENT_ENV:-staging}"
VERSION="${VERSION:-0.0.0-dev}"
BUILD="${BUILD:-1}"
ARCHS="${ARCHS:-$(uname -m)}"
OUT="${OUT:-.build/app}"
SCRATCH="${SCRATCH:-.build}"
SIGN="${SIGN:-adhoc}"
TEAM_ID="${TEAM_ID:-GBF27ALM9A}"
APPLE_DIR="$HOME/.config/wellspent/apple"
PROFILE="${PROFILE:-$APPLE_DIR/WellSpent_Mac_App_Store.provisionprofile}"
KEYINFO="${KEYINFO:-$APPLE_DIR/keyinfo.txt}"
CODESIGN_IDENTITY="${CODESIGN_IDENTITY:-}"

fail() {
    echo "$*" >&2
    exit 1
}

# These must match AppEnvironment.swift, which a test checks.
case "$WELLSPENT_ENV" in
    live)
        NAME="WellSpent"
        BUNDLE_ID="app.wellspent.mac"
        ;;
    staging)
        NAME="WellSpent Staging"
        BUNDLE_ID="app.wellspent.mac.staging"
        ;;
    *)
        fail "WELLSPENT_ENV must be live or staging, not $WELLSPENT_ENV"
        ;;
esac
APP="$OUT/$NAME.app"

case "$SIGN" in
    adhoc) ;;
    appstore)
        [ "$WELLSPENT_ENV" = live ] || fail "SIGN=appstore builds live only: the profile covers app.wellspent.mac"
        # App Store Connect takes versions and build numbers of digits and periods
        # only, up to three numbers and 18 characters, and a build number must be
        # higher than every one uploaded before it.
        for value in "$VERSION" "$BUILD"; do
            printf '%s' "$value" | grep -Eq '^[0-9]+(\.[0-9]+){0,2}$' && [ ${#value} -le 18 ] \
                || fail "App Store Connect wants digits and periods, like 0.1.0 or 202610171830, not $value"
        done
        [ -f "$PROFILE" ] || fail "No provisioning profile at $PROFILE. Set PROFILE."
        if [ -z "$CODESIGN_IDENTITY" ] && [ -f "$KEYINFO" ]; then
            CODESIGN_IDENTITY="$(sed -n 's/^CODESIGN_IDENTITY=//p' "$KEYINFO" | head -n 1)"
        fi
        [ -n "$CODESIGN_IDENTITY" ] || fail "No CODESIGN_IDENTITY. Set it, or add a CODESIGN_IDENTITY= line to $KEYINFO."
        xcodebuild -version > /dev/null 2>&1 \
            || fail "SIGN=appstore needs Xcode's tools: DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer"
        ;;
    *)
        fail "SIGN must be adhoc or appstore, not $SIGN"
        ;;
esac

arch_flags=""
for arch in $ARCHS; do arch_flags="$arch_flags --arch $arch"; done

# shellcheck disable=SC2086
swift build -c release --product WellSpentApp --scratch-path "$SCRATCH" $arch_flags
# shellcheck disable=SC2086
bin="$(swift build -c release --product WellSpentApp --scratch-path "$SCRATCH" $arch_flags --show-bin-path)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$bin/WellSpentApp" "$APP/Contents/MacOS/$NAME"
printf 'APPL????' > "$APP/Contents/PkgInfo"
cp Sources/WellSpentApp/Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
if [ "$SIGN" = adhoc ]; then
    # The app looks its icon up in this bundle, and inside an .app, Resources is
    # where Bundle.main finds it. The App Store build leaves it out: a .app gets
    # its Dock icon from CFBundleIconFile anyway, and this bundle has no Info.plist.
    cp -R "$bin/WellSpentBudget_WellSpentApp.bundle" "$APP/Contents/Resources/"
fi

# WellSpentEnvironment is what the app reads to decide which build it is. Anything
# but "live" there, or no key at all, makes it staging. App Store Connect refuses
# an upload without LSApplicationCategoryType.
cat > "$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key><string>en</string>
    <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
    <key>CFBundleName</key><string>$NAME</string>
    <key>CFBundleDisplayName</key><string>$NAME</string>
    <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
    <key>CFBundleExecutable</key><string>$NAME</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$BUILD</string>
    <key>CFBundleSupportedPlatforms</key><array><string>MacOSX</string></array>
    <key>LSApplicationCategoryType</key><string>public.app-category.finance</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>NSPrincipalClass</key><string>NSApplication</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>WellSpentEnvironment</key><string>$WELLSPENT_ENV</string>
</dict>
</plist>
EOF

if [ "$SIGN" = appstore ]; then
    plist="$APP/Contents/Info.plist"
    # The toolchain stamps Xcode writes, taken from the Xcode in use. App Store
    # Connect reads them to see what built the app.
    xcode_version="$(xcodebuild -version | sed -n 's/^Xcode //p')"
    xcode_build="$(xcodebuild -version | sed -n 's/^Build version //p')"
    sdk_version="$(xcrun --sdk macosx --show-sdk-version)"
    sdk_build="$(xcrun --sdk macosx --show-sdk-build-version)"
    dt_xcode="$(printf '%s' "$xcode_version" | awk -F. '{ printf "%02d%d%d", $1, $2, $3 }')"
    add() {
        /usr/libexec/PlistBuddy -c "Add :$1 $2 $3" "$plist"
    }
    add DTXcode string "$dt_xcode"
    add DTXcodeBuild string "$xcode_build"
    add DTSDKName string "macosx$sdk_version"
    add DTSDKBuild string "$sdk_build"
    add DTPlatformName string macosx
    add DTPlatformVersion string "$sdk_version"
    add DTPlatformBuild string "$sdk_build"
    add DTCompiler string com.apple.compilers.llvm.clang.1_0
    add BuildMachineOSBuild string "$(sw_vers -buildVersion)"

    # Apple's data move. A sandboxed app sees its container, not
    # ~/Library/Application Support or ~/Library/Preferences, so its first launch
    # would open empty beside the real budgets. This file has macOS move the live
    # data folder and the two settings files into the container when it makes
    # it. That happens once, so every sandboxed live build carries this file.
    cat > "$APP/Contents/Resources/container-migration.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Move</key>
    <array>
        <string>${ApplicationSupport}/WellSpent</string>
        <string>${Library}/Preferences/app.wellspent.mac.plist</string>
        <string>${Library}/Preferences/WellSpentApp.plist</string>
    </array>
</dict>
</plist>
EOF

    # TestFlight needs the profile in the bundle. A downloaded file carries a
    # quarantine attribute App Store Connect rejects, so attributes go before signing.
    cp "$PROFILE" "$APP/Contents/embedded.provisionprofile"
    xattr -cr "$APP"
    # The installer puts the app in place as root, so every file must be readable by
    # everyone, or macOS cannot check the signature for the person running it. The
    # profile's own copy outside the repo is private, and cp kept that mode. App
    # Store Connect refuses such a package (error 90255).
    chmod -R u+rwX,go+rX,go-w "$APP"

    # The sandbox, the two things the app does outside it (talk to the server and
    # read a statement the person picked), and the two identifiers TestFlight
    # matches against the profile. Every key here must be in the profile's allow
    # list, so nothing else goes in.
    entitlements="$OUT/$NAME.entitlements"
    cat > "$entitlements" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>com.apple.security.app-sandbox</key><true/>
    <key>com.apple.security.network.client</key><true/>
    <key>com.apple.security.files.user-selected.read-only</key><true/>
    <key>com.apple.application-identifier</key><string>$TEAM_ID.$BUNDLE_ID</string>
    <key>com.apple.developer.team-identifier</key><string>$TEAM_ID</string>
</dict>
</plist>
EOF
    # No --deep: Apple says not to, and the app has no nested code. The first run
    # may show a keychain prompt for the signing key. Choose Always Allow.
    codesign --force --sign "$CODESIGN_IDENTITY" --identifier "$BUNDLE_ID" --entitlements "$entitlements" "$APP"
    codesign --verify --strict --verbose=2 "$APP"
else
    codesign --force --deep --sign - --identifier "$BUNDLE_ID" "$APP"
    codesign --verify --deep --strict "$APP"
fi
echo "Built $APP ($WELLSPENT_ENV, $VERSION, build $BUILD, $ARCHS, $SIGN)"
