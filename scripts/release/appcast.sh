#!/usr/bin/env bash
# Generates (or updates) appcast.xml for every DMG in the updates folder, with EdDSA
# signatures and release notes.
#
# Release notes: put ReleaseNotes/<version>.html in the repo; it is copied next to the DMG
# as Glint-<version>.html, which generate_appcast links from the appcast and Sparkle shows
# in its update window.
#
# Signing key: by default generate_appcast reads the EdDSA private key from the login
# keychain (created once with Sparkle's generate_keys). In CI set SPARKLE_ED_KEY_FILE.
#
#   DOWNLOAD_URL_PREFIX=https://downloads.glint.app/ scripts/release/appcast.sh build/release
source "$(dirname "$0")/common.sh"

UPDATES="${1:-$RELEASE_ROOT/build/release}"
[[ -d "$UPDATES" ]] || die "pass the folder that holds the release DMGs"
require_env DOWNLOAD_URL_PREFIX

for dmg in "$UPDATES"/Glint-*.dmg; do
  [[ -e "$dmg" ]] || die "no Glint-*.dmg in $UPDATES"
  version="$(basename "$dmg" .dmg)"
  version="${version#Glint-}"
  notes="$RELEASE_ROOT/ReleaseNotes/$version.html"
  [[ -f "$notes" ]] && cp "$notes" "$UPDATES/Glint-$version.html"
done

args=(--download-url-prefix "$DOWNLOAD_URL_PREFIX" --embed-release-notes)
[[ -n "${SPARKLE_ED_KEY_FILE:-}" ]] && args+=(--ed-key-file "$SPARKLE_ED_KEY_FILE")
"$(sparkle_tool generate_appcast)" "${args[@]}" "$UPDATES"
echo "✓ $UPDATES/appcast.xml — upload the folder's DMGs and appcast.xml to $DOWNLOAD_URL_PREFIX"
