#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
BUILD_DIR="${BUILD_DIR:-.build}"
PYTHON="${PYTHON:-python3}"
if ! "$PYTHON" -c 'import sys; from importlib.metadata import version; raise SystemExit(sys.version_info < (3, 10) or version("dmgbuild") != "1.6.7")' 2>/dev/null; then
    echo "DMG packaging requires Python 3.10+ and dmgbuild 1.6.7. See docs/DEVELOPMENT.md." >&2
    exit 1
fi
BUILD_DIR="$BUILD_DIR" ./build.sh "$@"
VERSION=$(tr -d '[:space:]' < VERSION)
DMG_PATH="$BUILD_DIR/CodexKeeper-$VERSION.dmg"
STAGING=$(mktemp -d "$BUILD_DIR/.keeper-dmg.XXXXXX")
trap 'rm -rf "$STAGING"' EXIT
"$PYTHON" -m dmgbuild -s dmg_settings.py -D "app=$BUILD_DIR/CodexKeeper.app" \
    "Codex Keeper" "$STAGING/CodexKeeper.dmg"
hdiutil verify "$STAGING/CodexKeeper.dmg"
mv -f "$STAGING/CodexKeeper.dmg" "$DMG_PATH"
echo "DMG created: $DMG_PATH"
