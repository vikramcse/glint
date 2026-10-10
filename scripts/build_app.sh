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
# Kept between runs: incremental builds only re-emit strings for files they recompile.
mkdir -p "$STRINGS"

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

# The hardened runtime's library validation refuses to load an ad hoc framework (Sparkle)
# into an ad hoc process, so local builds sign without it. Developer ID builds, and the
# release scripts, always use it (notarization requires it).
IDENTITY="${SIGN_IDENTITY:--}"
RUNTIME=()
[[ "$IDENTITY" != "-" ]] && RUNTIME=(--options runtime)

echo "▸ Frameworks"
# Sparkle ships as a binary xcframework; embed its macOS slice next to the executable.
SPARKLE_FRAMEWORK="$(find .build/artifacts -path '*Sparkle.xcframework/macos-*/Sparkle.framework' -maxdepth 6 -type d | head -1)"
if [[ -n "$SPARKLE_FRAMEWORK" ]]; then
  mkdir -p "$APP/Contents/Frameworks"
  ditto "$SPARKLE_FRAMEWORK" "$APP/Contents/Frameworks/Sparkle.framework"
  codesign --force ${RUNTIME[@]+"${RUNTIME[@]}"} --timestamp=none --sign "$IDENTITY" "$APP/Contents/Frameworks/Sparkle.framework"
fi

echo "▸ Signing"
codesign --force ${RUNTIME[@]+"${RUNTIME[@]}"} --timestamp=none \
  --entitlements App/Glint.entitlements \
  --sign "$IDENTITY" "$APP"
codesign --verify --strict "$APP"

echo "✓ $APP"
