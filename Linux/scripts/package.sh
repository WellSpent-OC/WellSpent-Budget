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

# These must match AppEnvironment.swift: appName, dataFolderName and
# linuxAppIdentifier.
case "$WELLSPENT_ENV" in
    live)
        NAME="WellSpent"
        SLUG="wellspent"
        APPID="app.wellspent.linux"
        ;;
    staging)
        NAME="WellSpent Staging"
        SLUG="wellspent-staging"
        APPID="app.wellspent.linux.staging"
        ;;
    *)
        echo "WELLSPENT_ENV must be live or staging, not $WELLSPENT_ENV" >&2
        exit 1
        ;;
esac

swift build --package-path Linux -c release --static-swift-stdlib
BIN="$(swift build --package-path Linux -c release --show-bin-path)"

DEST="$OUT/$SLUG"
rm -rf "$DEST"
mkdir -p "$DEST"
cp "$BIN/WellSpentLinux" "$DEST/$SLUG"
# Debugging symbols are about half the file, and no one debugs an installed copy.
strip "$DEST/$SLUG"
# The resources sit beside the app, where it looks for them.
cp -R "$BIN/WellSpentLinux_WellSpentLinux.resources" "$DEST/"
printf '%s\n' "$WELLSPENT_ENV" > "$DEST/WellSpentLinux_WellSpentLinux.resources/environment"
cp Design/AppIcon/AppIcon.svg "$DEST/$SLUG.svg"
sed -e "s/@NAME@/$NAME/g" -e "s/@SLUG@/$SLUG/g" -e "s/@APPID@/$APPID/g" \
    Linux/scripts/install.sh.in > "$DEST/install.sh"
chmod +x "$DEST/install.sh" "$DEST/$SLUG"

tar -C "$OUT" -czf "$OUT/$SLUG.tar.gz" "$SLUG"
echo "Built $NAME: $DEST and $OUT/$SLUG.tar.gz"
