# Releasing Glint

These scripts take a built `Glint.app` from any build (`scripts/build_app.sh release`, or `xcodebuild` once the Xcode project lands) and turn it into a notarized DMG plus a Sparkle appcast.

| Script | Does |
| --- | --- |
| `sign.sh APP` | Developer ID signature, inside out (Sparkle helpers, framework, app), hardened runtime |
| `notarize.sh APP\|DMG` | `notarytool submit --wait`, then staple and validate |
| `make_dmg.sh APP [OUT]` | `Glint-<version>.dmg` with an Applications link, signed |
| `appcast.sh DIR` | `appcast.xml` with EdDSA signatures and embedded release notes |
| `release.sh APP [DIR]` | All of the above, in order |

## One-time setup

1. **Developer ID certificate.** Install "Developer ID Application: … (TEAMID)" in your keychain. This needs a paid Apple Developer account.
2. **Notary credentials:**

   ```sh
   xcrun notarytool store-credentials glint-notary --apple-id you@example.com --team-id TEAMID
   ```

   This prompts for an app-specific password and stores it in your keychain.
3. **Sparkle EdDSA keys.** Run once and keep the private key safe:

   ```sh
   swift package resolve
   "$(find .build/artifacts -path '*Sparkle/bin' -type d | head -1)/generate_keys"
   ```

   The private key goes into your login keychain. The tool prints the public key; put it in `App/Info.plist` as `SUPublicEDKey`. For CI, export it with `generate_keys -x sparkle-private.key` and set `SPARKLE_ED_KEY_FILE`.
4. **Feed URL.** Set `SUFeedURL` in `App/Info.plist` to where `appcast.xml` will be hosted, for example `https://example.com/glint/appcast.xml`.

   Until both `SUFeedURL` (https) and `SUPublicEDKey` are set, the app hides "Check for Updates…" and never starts Sparkle.

## Each release

1. Bump `CFBundleShortVersionString` and `CFBundleVersion` in `App/Info.plist`.
2. Write `ReleaseNotes/<version>.html`. It is shown in Sparkle's update window.
3. Build, then run:

   ```sh
   SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" \
   NOTARY_PROFILE=glint-notary \
   DOWNLOAD_URL_PREFIX=https://example.com/glint/ \
   scripts/release/release.sh build/Glint.app
   ```

4. Upload `build/release/*.dmg`, the matching `.html` notes and `appcast.xml` to `DOWNLOAD_URL_PREFIX`.

Keep previous DMGs in the updates folder. `generate_appcast` uses them to build delta updates.
