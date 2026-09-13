#!/bin/sh
# The release version is the newest "## [x.y.z]" heading in CHANGELOG.md.
# Checks that the Xcode project and the CLI carry it; --apply writes it into
# both first. swift test runs the check too.
#
# Usage: Tools/version.sh [--apply]
set -eu

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CHANGELOG="$ROOT/CHANGELOG.md"
PROJECT="$ROOT/App/Etcetera/Etcetera.xcodeproj/project.pbxproj"
CLI="$ROOT/Sources/etcetera-cli/main.swift"

VERSION=$(sed -nE 's/^## \[([0-9]+\.[0-9]+\.[0-9]+[-+.0-9A-Za-z]*)\].*/\1/p' "$CHANGELOG" | head -n 1)
if [ -z "$VERSION" ]; then
    echo "CHANGELOG.md has no released version heading such as ## [1.0.0]" >&2
    exit 1
fi

if [ "${1:-}" = "--apply" ]; then
    # The project file quotes values with characters beyond digits and dots.
    case "$VERSION" in
        *[!0-9.]*) VALUE="\"$VERSION\"" ;;
        *) VALUE="$VERSION" ;;
    esac
    sed -i '' -E "s/(MARKETING_VERSION = )[^;]*;/\1$VALUE;/" "$PROJECT"
    sed -i '' -E "s/^(let cliVersion = \")[^\"]*\"/\1$VERSION\"/" "$CLI"
fi

status=0
for found in $(sed -nE 's/.*MARKETING_VERSION = "?([^";]*)"?;.*/\1/p' "$PROJECT"); do
    if [ "$found" != "$VERSION" ]; then
        echo "MARKETING_VERSION in the Xcode project is $found, CHANGELOG.md says $VERSION" >&2
        status=1
    fi
done
found=$(sed -nE 's/^let cliVersion = "([^"]*)".*/\1/p' "$CLI")
if [ "$found" != "$VERSION" ]; then
    echo "cliVersion in etcetera-cli is ${found:-missing}, CHANGELOG.md says $VERSION" >&2
    status=1
fi
if [ "$status" -ne 0 ]; then
    echo "Run Tools/version.sh --apply to copy the version from CHANGELOG.md." >&2
    exit "$status"
fi
echo "$VERSION"
