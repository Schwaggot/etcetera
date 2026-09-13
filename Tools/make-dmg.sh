#!/bin/sh
# Packs an app into a compressed disk image with an Applications link to drag
# it onto.
#
# Usage: Tools/make-dmg.sh path/to/Etcetera.app path/to/output.dmg
set -eu

APP="$1"
DMG="$2"
NAME="$(basename "$APP" .app)"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT

# ditto keeps the signature and extended attributes intact.
ditto "$APP" "$STAGE/$NAME.app"
ln -s /Applications "$STAGE/Applications"

mkdir -p "$(dirname "$DMG")"
rm -f "$DMG"
# hdiutil fails now and then with "Resource busy" on CI machines.
for attempt in 1 2 3; do
    if hdiutil create -volname "$NAME" -srcfolder "$STAGE" -format UDZO -ov "$DMG"; then
        exit 0
    fi
    echo "hdiutil failed on attempt $attempt, retrying" >&2
    sleep 5
done
exit 1
