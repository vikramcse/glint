#!/usr/bin/env bash
# Signs Glint.app with a Developer ID, inside out: Sparkle's helpers, the framework, any
# dylibs, glint-mcp, then the app, all with the hardened runtime and a secure timestamp.
#
#   SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" scripts/release/sign.sh build/Glint.app
source "$(dirname "$0")/common.sh"

APP="${1:-}"
require_app "$APP"
require_env SIGN_IDENTITY
ENTITLEMENTS="$RELEASE_ROOT/App/Glint.entitlements"

sign() { codesign --force --timestamp --options runtime --sign "$SIGN_IDENTITY" "$@"; }

SPARKLE="$APP/Contents/Frameworks/Sparkle.framework"
if [[ -d "$SPARKLE" ]]; then
  # Order from Sparkle's documentation for sandbox-free apps.
  for item in \
    "$SPARKLE/Versions/B/XPCServices/Installer.xpc" \
    "$SPARKLE/Versions/B/XPCServices/Downloader.xpc" \
    "$SPARKLE/Versions/B/Autoupdate" \
    "$SPARKLE/Versions/B/Updater.app"; do
    [[ -e "$item" ]] && sign "$item"
  done
  sign "$SPARKLE"
fi

for dylib in "$APP"/Contents/Frameworks/*.dylib; do
  [[ -e "$dylib" ]] && sign "$dylib"
done
# The MCP tool ships next to the app binary; an xcodebuild build leaves it ad hoc signed.
if [[ -e "$APP/Contents/MacOS/glint-mcp" ]]; then
  sign "$APP/Contents/MacOS/glint-mcp"
fi

sign --entitlements "$ENTITLEMENTS" "$APP"
codesign --verify --strict --deep "$APP"
echo "✓ Signed $APP"
