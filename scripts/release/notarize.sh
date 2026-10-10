#!/usr/bin/env bash
# Notarizes and staples a signed Glint.app or .dmg.
#
# One-time setup stores App Store Connect credentials in the keychain:
#   xcrun notarytool store-credentials glint-notary --apple-id you@example.com --team-id TEAMID
# Then:
#   NOTARY_PROFILE=glint-notary scripts/release/notarize.sh build/Glint.app
source "$(dirname "$0")/common.sh"

TARGET="${1:-}"
[[ -e "$TARGET" ]] || die "pass a signed .app or .dmg"
require_env NOTARY_PROFILE

if [[ "$TARGET" == *.app ]]; then
  # notarytool needs an archive; staple the result onto the app itself.
  ZIP="$(mktemp -d)/$(basename "$TARGET" .app).zip"
  ditto -c -k --keepParent "$TARGET" "$ZIP"
  xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait
  rm -f "$ZIP"
else
  xcrun notarytool submit "$TARGET" --keychain-profile "$NOTARY_PROFILE" --wait
fi

xcrun stapler staple "$TARGET"
xcrun stapler validate "$TARGET"
if [[ "$TARGET" == *.app ]]; then
  spctl --assess --type execute --verbose=2 "$TARGET"
fi
echo "✓ Notarized $TARGET"
