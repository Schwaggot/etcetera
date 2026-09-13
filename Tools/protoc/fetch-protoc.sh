#!/bin/sh
# Fetches the protoc release named in VERSION (osx-universal_binary) into
# Tools/protoc/bin and verifies it. See SPEC 5.2 and 6.1. Bump VERSION,
# ZIP_SHA256, and protoc.sha256 together.
set -eu

HERE="$(cd "$(dirname "$0")" && pwd)"
VERSION="$(tr -d '[:space:]' < "$HERE/VERSION")"
[ -n "$VERSION" ] || { echo "error: $HERE/VERSION is empty." >&2; exit 1; }
ZIP_SHA256="99ea004549c139f46da5638187a85bbe422d78939be0fa01af1aa8ab672e395f"
BIN="$HERE/bin/protoc"

if [ -x "$BIN" ] && "$HERE/verify-protoc.sh" >/dev/null 2>&1; then
    exit 0
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
URL="https://github.com/protocolbuffers/protobuf/releases/download/v$VERSION/protoc-$VERSION-osx-universal_binary.zip"
curl -fsSL -o "$TMP/protoc.zip" "$URL"
echo "$ZIP_SHA256  $TMP/protoc.zip" | shasum -a 256 -c - >/dev/null
unzip -q "$TMP/protoc.zip" -d "$TMP/x"

mkdir -p "$HERE/bin"
cp "$TMP/x/bin/protoc" "$BIN"
chmod 755 "$BIN"
# protoc resolves well-known type imports from include/ next to itself.
rm -rf "$HERE/bin/include"
cp -R "$TMP/x/include" "$HERE/bin/include"

"$HERE/verify-protoc.sh"
