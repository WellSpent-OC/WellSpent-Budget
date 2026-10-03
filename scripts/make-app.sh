#!/bin/sh
# Builds WellSpent.app from this package and signs it ad hoc. Run with `make app`.
#
# VERSION   the version people see, for example 0.1.0-beta.12 (default 0.0.0-dev)
# BUILD     the build number macOS compares between copies (default 1)
# ARCHS     the architectures to build, for example "arm64 x86_64" (default: this Mac's)
#
# An ad hoc signature is not an Apple Developer ID. macOS refuses to open the app
# the first time, until the person allows it in System Settings, Privacy and
# Security. The README says how.
set -eu

VERSION="${VERSION:-0.0.0-dev}"
BUILD="${BUILD:-1}"
ARCHS="${ARCHS:-$(uname -m)}"
OUT="${OUT:-.build/app}"
APP="$OUT/WellSpent.app"

arch_flags=""
for arch in $ARCHS; do arch_flags="$arch_flags --arch $arch"; done

# shellcheck disable=SC2086
swift build -c release --product WellSpentApp $arch_flags
# shellcheck disable=SC2086
bin="$(swift build -c release --product WellSpentApp $arch_flags --show-bin-path)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$bin/WellSpentApp" "$APP/Contents/MacOS/WellSpent"
cp Sources/WellSpentApp/Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
# The app looks its icon up in this bundle; inside an .app, Resources is where
# Bundle.main finds it.
cp -R "$bin/WellSpentBudget_WellSpentApp.bundle" "$APP/Contents/Resources/"

cat > "$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>WellSpent</string>
    <key>CFBundleDisplayName</key><string>WellSpent</string>
    <key>CFBundleIdentifier</key><string>app.wellspent.mac</string>
    <key>CFBundleExecutable</key><string>WellSpent</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$BUILD</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>NSPrincipalClass</key><string>NSApplication</string>
    <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
EOF

codesign --force --deep --sign - --identifier app.wellspent.mac "$APP"
codesign --verify --deep --strict "$APP"
echo "Built $APP ($VERSION, build $BUILD, $ARCHS)"
