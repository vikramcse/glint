# ADR 0001: One Swift package, bundled by script, distributed directly

**Status:** Accepted · 2026-10-10

## Context

Glint is built as Swift packages per module with dependencies pointing inward to `GlintCore`, one composition root in the app target, and a direct-download, non-sandboxed build (the sandbox conflicts with indexing arbitrary folders and drives).

## Decision

- A single `Package.swift` declares every module as a target (`GlintCore` … `GlintUI`), the app as an executable target (`GlintApp`, product `Glint`), and the tools (`glint-eval`, `glint-mcp`). Opening `Package.swift` in Xcode gives schemes for all of them.
- `scripts/build_app.sh` assembles `Glint.app`: binary, `App/Info.plist`, compiled String Catalog, generated icon, hardened-runtime signature (ad hoc by default, `SIGN_IDENTITY` for Developer ID). Notarization and Sparkle are added in the release pipeline (M4).
- `scripts/check_imports.sh` enforces the module table on source imports, so a sideways import fails CI even though SwiftPM would allow it through the app target.
- The app is a menu bar agent (`LSUIElement`) that shows in the Dock only while one of its windows is open, like other Spotlight-style utilities.

## Consequences

- No `.xcodeproj` to merge-conflict; CI and local builds use the same commands.
- XCUITest needs an Xcode app target; until one exists, UI behaviour is covered by view-model tests and rendered snapshots (`GlintUITests`).
