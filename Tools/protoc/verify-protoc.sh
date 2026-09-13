#!/bin/sh
# Verifies the vendored protoc binary against its recorded checksum.
set -eu

HERE="$(cd "$(dirname "$0")" && pwd)"
EXPECTED="$(cat "$HERE/protoc.sha256")"
ACTUAL="$(shasum -a 256 "$HERE/bin/protoc" | cut -d' ' -f1)"
if [ "$EXPECTED" != "$ACTUAL" ]; then
    echo "error: protoc checksum mismatch (expected $EXPECTED, got $ACTUAL). Run Tools/protoc/fetch-protoc.sh." >&2
    exit 1
fi
