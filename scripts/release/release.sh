#!/usr/bin/env bash
# Full release from a built Glint.app: sign, notarize, DMG, notarize DMG, appcast.
# Works with any build (scripts/build_app.sh or xcodebuild) — pass the .app path.
#
#   SIGN_IDENTITY="Developer ID Application: …" NOTARY_PROFILE=glint-notary \
#   DOWNLOAD_URL_PREFIX=https://downloads.glint.app/ \
#   scripts/release/release.sh path/to/Glint.app [updates-folder]
source "$(dirname "$0")/common.sh"

APP="${1:-}"
UPDATES="${2:-$RELEASE_ROOT/build/release}"
require_app "$APP"
require_env SIGN_IDENTITY NOTARY_PROFILE DOWNLOAD_URL_PREFIX

VERSION="$(app_version "$APP")"
FEED="$(/usr/libexec/PlistBuddy -c "Print :SUFeedURL" "$APP/Contents/Info.plist" 2>/dev/null || true)"
KEY="$(/usr/libexec/PlistBuddy -c "Print :SUPublicEDKey" "$APP/Contents/Info.plist" 2>/dev/null || true)"
[[ "$FEED" == https://* && -n "$KEY" ]] || die "set SUFeedURL and SUPublicEDKey in App/Info.plist before releasing"
[[ -f "$RELEASE_ROOT/ReleaseNotes/$VERSION.html" ]] || echo "warning: no ReleaseNotes/$VERSION.html; the update window will have no notes" >&2

DIR="$(dirname "$0")"
"$DIR/sign.sh" "$APP"
"$DIR/notarize.sh" "$APP"
DMG="$("$DIR/make_dmg.sh" "$APP" "$UPDATES" | tail -1)"
"$DIR/notarize.sh" "$DMG"
"$DIR/appcast.sh" "$UPDATES"
echo "✓ Glint $VERSION released to $UPDATES"
