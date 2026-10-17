#!/usr/bin/env bash
# Packs a signed, notarized Glint.app into Glint-<version>.dmg with an Applications link,
# and signs the DMG.
#
#   SIGN_IDENTITY="Developer ID Application: …" scripts/release/make_dmg.sh build/Glint.app build/release
#
# SIGN_IDENTITY=- packs an ad hoc signed app for an unnotarized preview build and leaves the
# DMG unsigned; Gatekeeper then asks users to approve the app once.
source "$(dirname "$0")/common.sh"

APP="${1:-}"
OUT="${2:-$RELEASE_ROOT/build/release}"
require_app "$APP"
require_env SIGN_IDENTITY

VERSION="$(app_version "$APP")"
DMG="$OUT/Glint-$VERSION.dmg"
STAGING="$(mktemp -d)"
trap 'rm -rf "$STAGING"' EXIT

mkdir -p "$OUT"
ditto "$APP" "$STAGING/Glint.app"
ln -s /Applications "$STAGING/Applications"
rm -f "$DMG"
hdiutil create -volname "Glint $VERSION" -srcfolder "$STAGING" -fs APFS -format ULFO -ov "$DMG" >/dev/null
if [[ "$SIGN_IDENTITY" != "-" ]]; then
  codesign --force --timestamp --sign "$SIGN_IDENTITY" "$DMG"
fi
echo "$DMG"
