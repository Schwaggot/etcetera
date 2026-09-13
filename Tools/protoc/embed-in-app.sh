#!/bin/sh
# Xcode build phase: verifies protoc and copies it with its well-known type
# includes into Contents/Resources, signed to inherit the app sandbox.
# See SPEC 5.2.
set -eu

TOOLS="$SRCROOT/../../Tools/protoc"
"$TOOLS/fetch-protoc.sh"

DEST="$TARGET_BUILD_DIR/$UNLOCALIZED_RESOURCES_FOLDER_PATH"
mkdir -p "$DEST"
cp "$TOOLS/bin/protoc" "$DEST/protoc"
rm -rf "$DEST/include"
cp -R "$TOOLS/bin/include" "$DEST/include"
# Imports schema folders often lack; protoc searches them after the folder.
rm -rf "$DEST/googleapis"
cp -R "$TOOLS/../googleapis" "$DEST/googleapis"

if [ "${CODE_SIGNING_ALLOWED:-YES}" = "YES" ] && [ -n "${EXPANDED_CODE_SIGN_IDENTITY:-}" ]; then
    codesign --force --options runtime --timestamp=none \
        --entitlements "$TOOLS/protoc.entitlements" \
        --sign "$EXPANDED_CODE_SIGN_IDENTITY" "$DEST/protoc"
fi
