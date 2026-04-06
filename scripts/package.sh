#!/bin/zsh

set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PROJECT_PATH="$PROJECT_ROOT/HermitFlow.xcodeproj"
SCHEME="HermitFlow"
CONFIGURATION="${1:-Release}"
DERIVED_DATA_PARENT="$PROJECT_ROOT/.DerivedDataPackage"
DERIVED_DATA_PATH="$(mktemp -d "$DERIVED_DATA_PARENT.XXXXXX")"
BUILD_PRODUCTS_PATH="$DERIVED_DATA_PATH/Build/Products/$CONFIGURATION"
APP_SOURCE_PATH="$BUILD_PRODUCTS_PATH/HermitFlow.app"
DIST_DIR="$PROJECT_ROOT/dist"
APP_DEST_PATH="$DIST_DIR/HermitFlow.app"
PKG_DEST_PATH="$DIST_DIR/HermitFlow.pkg"
PKG_SCRIPTS_DIR="$PROJECT_ROOT/scripts/pkg"

if [[ "$CONFIGURATION" != "Release" && "$CONFIGURATION" != "Debug" ]]; then
  echo "Unsupported configuration: $CONFIGURATION"
  echo "Usage: scripts/package.sh [Release|Debug]"
  exit 1
fi

cleanup() {
  rm -rf "$DERIVED_DATA_PATH"
}

trap cleanup EXIT

mkdir -p "$DIST_DIR"
rm -rf "$APP_DEST_PATH" "$PKG_DEST_PATH"

echo "Building $SCHEME ($CONFIGURATION)..."
xcodebuild \
  -project "$PROJECT_PATH" \
  -scheme "$SCHEME" \
  -configuration "$CONFIGURATION" \
  -derivedDataPath "$DERIVED_DATA_PATH" \
  CODE_SIGNING_ALLOWED=NO \
  build

if [[ ! -d "$APP_SOURCE_PATH" ]]; then
  echo "Build succeeded but app was not found at: $APP_SOURCE_PATH"
  exit 1
fi

echo "Copying app to dist..."
ditto "$APP_SOURCE_PATH" "$APP_DEST_PATH"

echo "Building installer package..."
pkgbuild \
  --install-location /Applications \
  --scripts "$PKG_SCRIPTS_DIR" \
  --component "$APP_DEST_PATH" \
  "$PKG_DEST_PATH"

echo "Verifying installer metadata..."
PACKAGE_INFO="$(xar -xf "$PKG_DEST_PATH" PackageInfo && cat PackageInfo && rm -f PackageInfo)"
if [[ "$PACKAGE_INFO" != *'install-location="/Applications"'* ]]; then
  echo "Installer verification failed: install location is not /Applications"
  exit 1
fi

PAYLOAD_FILES="$(pkgutil --payload-files "$PKG_DEST_PATH")"
if [[ "$PAYLOAD_FILES" != *'./HermitFlow.app'* ]]; then
  echo "Installer verification failed: payload does not contain HermitFlow.app"
  exit 1
fi

echo
echo "Done."
echo "App: $APP_DEST_PATH"
echo "Pkg: $PKG_DEST_PATH"
