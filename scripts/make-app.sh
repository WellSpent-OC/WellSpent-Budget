#!/bin/sh
# Builds the Mac app from this package and signs it ad hoc. Run with `make app`.
#
# WELLSPENT_ENV  live or staging (default staging). Live builds WellSpent.app, the
#                app real budgets are kept in. Staging builds WellSpent Staging.app,
#                which has its own data folder, keychain names, settings and
#                server, and never connects to the live server.
# VERSION        the version people see, for example 0.1.0-beta.12 (default 0.0.0-dev)
# BUILD          the build number macOS compares between copies (default 1)
# ARCHS          the architectures to build, for example "arm64 x86_64" (default: this Mac's)
#
# Staging is the default because a test build mistaken for live could reach real
# budgets, and the reverse cannot. Only the beta workflow sets live.
#
# An ad hoc signature is not an Apple Developer ID. macOS refuses to open the app
# the first time, until the person allows it in System Settings, Privacy and
# Security. The README says how.
set -eu

WELLSPENT_ENV="${WELLSPENT_ENV:-staging}"
VERSION="${VERSION:-0.0.0-dev}"
BUILD="${BUILD:-1}"
ARCHS="${ARCHS:-$(uname -m)}"
OUT="${OUT:-.build/app}"

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
        echo "WELLSPENT_ENV must be live or staging, not $WELLSPENT_ENV" >&2
        exit 1
        ;;
esac
APP="$OUT/$NAME.app"

arch_flags=""
for arch in $ARCHS; do arch_flags="$arch_flags --arch $arch"; done

# shellcheck disable=SC2086
swift build -c release --product WellSpentApp $arch_flags
# shellcheck disable=SC2086
bin="$(swift build -c release --product WellSpentApp $arch_flags --show-bin-path)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$bin/WellSpentApp" "$APP/Contents/MacOS/$NAME"
cp Sources/WellSpentApp/Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
# The app looks its icon up in this bundle; inside an .app, Resources is where
# Bundle.main finds it.
cp -R "$bin/WellSpentBudget_WellSpentApp.bundle" "$APP/Contents/Resources/"

# WellSpentEnvironment is what the app reads to decide which build it is. Anything
# but "live" there, or no key at all, makes it staging.
cat > "$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>$NAME</string>
    <key>CFBundleDisplayName</key><string>$NAME</string>
    <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
    <key>CFBundleExecutable</key><string>$NAME</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$BUILD</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>NSPrincipalClass</key><string>NSApplication</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>WellSpentEnvironment</key><string>$WELLSPENT_ENV</string>
</dict>
</plist>
EOF

codesign --force --deep --sign - --identifier "$BUNDLE_ID" "$APP"
codesign --verify --deep --strict "$APP"
echo "Built $APP ($WELLSPENT_ENV, $VERSION, build $BUILD, $ARCHS)"
