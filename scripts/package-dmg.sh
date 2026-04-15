#!/bin/zsh

set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONFIGURATION="${1:-Release}"
ARCH_INPUT="${2:-native}"
DIST_DIR="$PROJECT_ROOT/dist"

if [[ "$CONFIGURATION" != "Release" && "$CONFIGURATION" != "Debug" ]]; then
  echo "Unsupported configuration: $CONFIGURATION"
  echo "Usage: scripts/package-dmg.sh [Release|Debug] [native|arm64|x86_64|intel]"
  exit 1
fi

case "$ARCH_INPUT" in
  native)
    ARCH_NAME="$(uname -m)"
    ;;
  arm64)
    ARCH_NAME="arm64"
    ;;
  x86_64|intel)
    ARCH_NAME="x86_64"
    ;;
  *)
    echo "Unsupported architecture: $ARCH_INPUT"
    echo "Usage: scripts/package-dmg.sh [Release|Debug] [native|arm64|x86_64|intel]"
    exit 1
    ;;
esac

ARCH_LABEL="$ARCH_NAME"
if [[ "$ARCH_NAME" == "x86_64" ]]; then
  ARCH_LABEL="intel"
fi

APP_SOURCE_PATH="$DIST_DIR/HermitFlow-$ARCH_LABEL.app"
DMG_DEST_PATH="$DIST_DIR/HermitFlow-$ARCH_LABEL.dmg"
STAGING_DIR="$DIST_DIR/.dmg-$ARCH_LABEL"
VOLUME_NAME="HermitFlow-$ARCH_LABEL"

cleanup() {
  rm -rf "$STAGING_DIR"
}

trap cleanup EXIT

if [[ ! -d "$APP_SOURCE_PATH" ]]; then
  echo "App not found at: $APP_SOURCE_PATH"
  echo "Build the app first with: ./scripts/package.sh $CONFIGURATION $ARCH_INPUT"
  exit 1
fi

rm -rf "$STAGING_DIR" "$DMG_DEST_PATH"
mkdir -p "$STAGING_DIR"

echo "Preparing DMG contents for $ARCH_LABEL..."
ditto "$APP_SOURCE_PATH" "$STAGING_DIR/HermitFlow.app"
ln -s /Applications "$STAGING_DIR/Applications"

echo "Building DMG..."
hdiutil create \
  -volname "$VOLUME_NAME" \
  -srcfolder "$STAGING_DIR" \
  -ov \
  -format UDZO \
  "$DMG_DEST_PATH"

echo
echo "Done."
echo "Dmg: $DMG_DEST_PATH"
