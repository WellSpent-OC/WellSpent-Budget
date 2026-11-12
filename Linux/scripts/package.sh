#!/bin/sh
# Builds the Linux app for one environment, ready to install. Run from the
# repository's top folder, on Linux with Swift 6 and the GTK 4 and libsecret
# headers (the Linux build image has them):
#
#     WELLSPENT_ENV=staging Linux/scripts/package.sh
#
# WELLSPENT_ENV  live or staging (default staging). Live is the app real budgets
#                are kept in. Staging has its own data folder, keyring entries,
#                settings and server, and never connects to the live server.
# OUT            where the result goes (default Linux/dist)
# SWIFT_SCRATCH_PATH optional external SwiftPM cache for a read-only checkout
# SWIFT_BUILD_JOBS   optional compiler job limit
# WELLSPENT_PROPERTIES_PATH  a checkout of the private Properties extension, so
#                Houses draws its real screens. A live build needs it, because
#                one without it quietly ships the Houses placeholder. A public
#                live build without the extension says so with
#                WELLSPENT_PROPERTIES_PATH=none.
# WELLSPENT_FEATURES  the flags this build carries on, names separated by
#                commas, such as "purchases". Default none. The Mac's
#                Info.plist list; on Linux a file beside the environment one.
#
# Staging is the default because a test build mistaken for live could reach real
# budgets, and the reverse cannot. The same rule as the Mac's make-app.sh.
#
# The result is a folder and a .tar.gz of it, holding the app, its resources, the
# icon and install.sh. Swift's own libraries are built in, so the computer it runs
# on needs only GTK 4 and libsecret, which desktop Linux has.
set -eu

WELLSPENT_ENV="${WELLSPENT_ENV:-staging}"
OUT="${OUT:-Linux/dist}"

# These must match AppEnvironment.swift: appName, dataFolderName,
# linuxAppIdentifier and inviteScheme. SCHEME is the build's own type of invite
# link, which its menu entry claims, so a click on one opens this build.
case "$WELLSPENT_ENV" in
    live)
        NAME="WellSpent"
        SLUG="wellspent"
        APPID="app.wellspent.linux"
        SCHEME="wellspent"
        ;;
    staging)
        NAME="WellSpent Staging"
        SLUG="wellspent-staging"
        APPID="app.wellspent.linux.staging"
        SCHEME="wellspent-staging"
        ;;
    *)
        echo "WELLSPENT_ENV must be live or staging, not $WELLSPENT_ENV" >&2
        exit 1
        ;;
esac

PROPERTIES="${WELLSPENT_PROPERTIES_PATH:-}"
if [ "$PROPERTIES" = none ]; then
    PROPERTIES=""
elif [ -n "$PROPERTIES" ] && [ ! -f "$PROPERTIES/Package.swift" ]; then
    echo "WELLSPENT_PROPERTIES_PATH is not a Properties checkout: $PROPERTIES" >&2
    exit 1
elif [ -n "$PROPERTIES" ]; then
    # Made whole here: SwiftPM would read a relative path from Linux/.
    PROPERTIES="$(cd "$PROPERTIES" && pwd)"
elif [ -z "$PROPERTIES" ] && [ "$WELLSPENT_ENV" = live ]; then
    echo "A live build needs WELLSPENT_PROPERTIES_PATH, or WELLSPENT_PROPERTIES_PATH=none to leave Houses out" >&2
    exit 1
fi
# Linux/Package.swift reads the path from the environment.
WELLSPENT_PROPERTIES_PATH="$PROPERTIES"
export WELLSPENT_PROPERTIES_PATH

set -- --package-path Linux -c release --static-swift-stdlib
if [ -n "${SWIFT_SCRATCH_PATH:-}" ]; then set -- "$@" --scratch-path "$SWIFT_SCRATCH_PATH"; fi
if [ -n "${SWIFT_BUILD_JOBS:-}" ]; then set -- "$@" -j "$SWIFT_BUILD_JOBS"; fi
swift build "$@"
BIN="$(swift build "$@" --show-bin-path)"

DEST="$OUT/$SLUG"
rm -rf "$DEST"
mkdir -p "$DEST"
cp "$BIN/WellSpentLinux" "$DEST/$SLUG"
# Debugging symbols are about half the file, and no one debugs an installed copy.
strip "$DEST/$SLUG"
# The resources sit beside the app, where it looks for them.
cp -R "$BIN/WellSpentLinux_WellSpentLinux.resources" "$DEST/"
printf '%s\n' "$WELLSPENT_ENV" > "$DEST/WellSpentLinux_WellSpentLinux.resources/environment"
printf '%s\n' "${WELLSPENT_FEATURES:-}" > "$DEST/WellSpentLinux_WellSpentLinux.resources/features"
cp Design/AppIcon/AppIcon.svg "$DEST/$SLUG.svg"
sed -e "s/@NAME@/$NAME/g" -e "s/@SLUG@/$SLUG/g" -e "s/@APPID@/$APPID/g" -e "s/@SCHEME@/$SCHEME/g" \
    Linux/scripts/install.sh.in > "$DEST/install.sh"
chmod +x "$DEST/install.sh" "$DEST/$SLUG"

tar -C "$OUT" -czf "$OUT/$SLUG.tar.gz" "$SLUG"
if [ -n "$PROPERTIES" ]; then HOUSES="Houses linked from $PROPERTIES"; else HOUSES="Houses is the placeholder"; fi
echo "Built $NAME: $DEST and $OUT/$SLUG.tar.gz. $HOUSES."
