# ADR 0007: Sparkle 2 for in-app updates

**Status:** Accepted · 2026-10-10

## Context

Glint ships by direct distribution (Developer ID, notarized, not the Mac App Store) with updates through Sparkle, EdDSA-signed appcasts, and release notes shown in the app. The engineering standards require an ADR for any new third-party dependency.

## Decision

- Add `sparkle-project/Sparkle` (2.10 or later, MIT) as a SwiftPM binary dependency, linked only by the `GlintApp` target. `scripts/build_app.sh` embeds `Sparkle.framework` in `Glint.app/Contents/Frameworks`.
- `UpdaterController` wraps `SPUStandardUpdaterController` and implements the UI's `UpdateChecking` protocol. `GlintUI` never imports Sparkle; it shows "Check for Updates…" in the menu bar menu and in Settings › General only when `services.updates?.isAvailable` is true.
- The updater starts only when Info.plist has an https `SUFeedURL` and an `SUPublicEDKey`. Development builds leave both empty, so Sparkle never runs or shows errors there.
- Release notes are per-version HTML files (`ReleaseNotes/<version>.html`). `scripts/release/appcast.sh` embeds them in the appcast, and Sparkle shows them in its update window.
- Glint is a menu bar app, so scheduled checks use Sparkle's gentle reminders.

## Alternatives considered

- **Hand-rolled updater.** Rejected: signature verification, delta updates, and installation outside the sandbox are exactly what Sparkle solves, and it is the de facto standard for direct-download Mac apps.
- **Mac App Store updates.** Ruled out: Glint isn't distributed through the Mac App Store at 1.0.

## Consequences

- One binary framework ships in the app (about 3 MB).
- Release signing must sign Sparkle's helpers (XPC services, `Autoupdate`, `Updater.app`) inside out. `scripts/release/sign.sh` does this.
- Ad hoc local builds sign without the hardened runtime. Library validation refuses to load an ad hoc framework into an ad hoc process. Developer ID builds and release signing always use the hardened runtime.
- The EdDSA private key must be backed up. Losing it means shipped apps can't verify future updates.
