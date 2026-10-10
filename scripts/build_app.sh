#!/usr/bin/env bash
# Builds Glint.app with xcodebuild (MLX's Metal kernels can't be built by `swift build`),
# syncs and compiles the String Catalog, generates the icon, embeds glint-mcp and the
# resource bundles (MLX's default.metallib among them), and signs the bundle — ad hoc unless
# SIGN_IDENTITY is set.
#
#   scripts/build_app.sh [debug|release]
#   SIGN_IDENTITY="Developer ID Application: …" scripts/build_app.sh release
#
# One-time setup: xcodebuild -downloadComponent MetalToolchain
set -euo pipefail

case "${1:-release}" in
  debug) CONFIG=Debug ;;
  *) CONFIG=Release ;;
esac
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD="$ROOT/build"
APP="$BUILD/Glint.app"
DERIVED="$BUILD/DerivedData"
PRODUCTS="$DERIVED/Build/Products/$CONFIG"

cd "$ROOT"
for scheme in Glint glint-mcp; do
  echo "▸ Building $scheme ($CONFIG)"
  xcodebuild build -scheme "$scheme" -configuration "$CONFIG" -destination 'platform=macOS' \
    -derivedDataPath "$DERIVED" -quiet 2>&1 | grep -vE "iOSSimulator|DVTErrorPresenter|^$" || true
  test -x "$PRODUCTS/$scheme" || { echo "✗ $scheme did not build"; exit 1; }
done

echo "▸ Assembling bundle"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$PRODUCTS/Glint" "$APP/Contents/MacOS/Glint"
cp "$PRODUCTS/glint-mcp" "$APP/Contents/MacOS/glint-mcp"
cp App/Info.plist "$APP/Contents/Info.plist"
for bundle in "$PRODUCTS"/*.bundle; do
  cp -R "$bundle" "$APP/Contents/Resources/"
done
test -f "$APP/Contents/Resources/mlx-swift_Cmlx.bundle/Contents/Resources/default.metallib" \
  || { echo "✗ MLX metallib missing — run: xcodebuild -downloadComponent MetalToolchain"; exit 1; }

echo "▸ String Catalog"
STRINGS=$(find "$DERIVED/Build/Intermediates.noindex" -path "*$CONFIG*" -name "*.stringsdata" \
  \( -path "*GlintUI.build*" -o -path "*GlintApp.build*" -o -path "*Glint.build*" \) | sort -u)
if [[ -n "$STRINGS" ]]; then
  # shellcheck disable=SC2086
  xcrun xcstringstool sync App/Localizable.xcstrings --stringsdata $STRINGS
fi
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
SPARKLE_FRAMEWORK="$(find "$PRODUCTS" -maxdepth 3 -name Sparkle.framework -type d | head -1)"
if [[ -n "$SPARKLE_FRAMEWORK" ]]; then
  mkdir -p "$APP/Contents/Frameworks"
  ditto "$SPARKLE_FRAMEWORK" "$APP/Contents/Frameworks/Sparkle.framework"
  codesign --force ${RUNTIME[@]+"${RUNTIME[@]}"} --timestamp=none --sign "$IDENTITY" "$APP/Contents/Frameworks/Sparkle.framework"
fi

echo "▸ Signing"
codesign --force ${RUNTIME[@]+"${RUNTIME[@]}"} --timestamp=none --sign "$IDENTITY" "$APP/Contents/MacOS/glint-mcp"
codesign --force ${RUNTIME[@]+"${RUNTIME[@]}"} --timestamp=none \
  --entitlements App/Glint.entitlements \
  --sign "$IDENTITY" "$APP"
codesign --verify --strict "$APP"

echo "✓ $APP"
