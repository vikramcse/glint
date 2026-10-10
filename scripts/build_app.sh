#!/usr/bin/env bash
# Builds Glint.app: compiles, syncs and compiles the String Catalog, generates the icon,
# assembles the bundle and signs it (ad hoc unless SIGN_IDENTITY is set).
#
#   scripts/build_app.sh [debug|release]
#   SIGN_IDENTITY="Developer ID Application: …" scripts/build_app.sh release
set -euo pipefail

CONFIG="${1:-release}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD="$ROOT/build"
APP="$BUILD/Glint.app"
STRINGS="$BUILD/stringsdata"

cd "$ROOT"
rm -rf "$STRINGS" && mkdir -p "$STRINGS"

echo "▸ Compiling ($CONFIG)"
swift build -c "$CONFIG" --product Glint \
  -Xswiftc -emit-localized-strings -Xswiftc -emit-localized-strings-path -Xswiftc "$STRINGS"
BIN="$(swift build -c "$CONFIG" --show-bin-path)/Glint"

echo "▸ Assembling bundle"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Glint"
cp App/Info.plist "$APP/Contents/Info.plist"

echo "▸ String Catalog"
xcrun xcstringstool sync App/Localizable.xcstrings --stringsdata "$STRINGS"/*.stringsdata
xcrun xcstringstool compile App/Localizable.xcstrings --output-directory "$APP/Contents/Resources"

echo "▸ Icon"
if [[ ! -f "$BUILD/AppIcon.icns" || scripts/make_icon.swift -nt "$BUILD/AppIcon.icns" ]]; then
  rm -rf "$BUILD/AppIcon.iconset"
  swift scripts/make_icon.swift "$BUILD/AppIcon.iconset" >/dev/null
  iconutil -c icns "$BUILD/AppIcon.iconset" -o "$BUILD/AppIcon.icns"
fi
cp "$BUILD/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"

echo "▸ Signing"
codesign --force --options runtime --timestamp=none \
  --entitlements App/Glint.entitlements \
  --sign "${SIGN_IDENTITY:--}" "$APP"
codesign --verify --strict "$APP"

echo "✓ $APP"
