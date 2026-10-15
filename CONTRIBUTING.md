# Contributing to Glint

Thanks for helping. Bug reports, retrieval misses ("I searched X and expected Y") and pull requests are all welcome.

## Set up

Requires macOS 14+ on Apple silicon and Xcode 26.

```sh
brew install xcodegen swiftlint
xcodebuild -downloadComponent MetalToolchain   # MLX's GPU kernels need it
scripts/build_app.sh debug                      # → build/Glint.app
```

`swift build` and `swift test` compile every module and run every test that doesn't execute the model. Anything that runs EmbeddingGemma 2 needs `xcodebuild`, because MLX's Metal kernels can't be built by SwiftPM.

## Before you open a pull request

Run these. CI runs the same checks.

```sh
swift test
scripts/check_imports.sh
xcrun swift-format lint --strict -r Sources Tests
swiftlint --strict
```

If you touch search, ranking, extraction or the model, also run the retrieval evals against the matching baseline in `Evals/` (see the README). No metric may drop more than 1 point overall or 2 points for any media type, and no must-pass query may leave the top 10. For changes to the search path, run the performance budgets with `GLINT_PERF=1 swift test -c release --filter GlintPerformanceTests`.

## How the code is organised

- Each module in `Package.swift` depends inward on `GlintCore`. `scripts/check_imports.sh` enforces the graph, so a sideways import fails CI. If a change seems to need one, the type probably belongs in `GlintCore`.
- `GlintApp` is the only composition root. Services get their dependencies through initialisers, not singletons.
- New third-party dependencies need an ADR in `docs/adr`.
- Schema changes need a migration in `GlintStore/Schema.swift` and a test that upgrades an archived database.
- Nothing leaves the Mac. Don't add network calls beyond the model download and Sparkle updates.

## Pull requests

- Keep each PR to one change, and explain the why in the description.
- Add or update tests with the change. For UI, a snapshot or UI-model test is enough.
- Include eval or benchmark numbers when quality or speed changes.
- Make user-facing strings localisable (they go in `App/Localizable.xcstrings`).

By contributing, you agree that your contributions are licensed under the [MIT License](LICENSE).
