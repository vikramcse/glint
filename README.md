# Glint

Glint is a native Mac app for on-device multimodal search. Press **⌥Space** and describe what you're looking for. Glint finds photos and screenshots, moments inside videos, things said in recordings, PDF pages and documents, and nothing leaves the Mac.

This repository implements the [PRD](PRD.md) as a Swift 6 package: every module in the architecture, the app shell, and the tooling the PRD requires (tests, retrieval evals, performance budgets, license tooling).

## Quick start

Requires macOS 15+ on Apple silicon and Xcode 26.

```sh
scripts/build_app.sh debug        # builds, signs ad hoc → build/Glint.app
open build/Glint.app              # onboarding appears on first launch
```

- To work in Xcode, open `Package.swift`.
- To run the app from the command line, run `swift run Glint`. That runs it without a bundle, so it has no Info.plist privacy strings.

| Task | Command |
| --- | --- |
| All tests (unit, integration, UI models, snapshots) | `swift test` |
| Performance budgets (100k chunks) | `GLINT_PERF=1 swift test -c release --filter GlintPerformanceTests` |
| Retrieval evals | `swift run -c release glint-eval sample /tmp/eval && swift run -c release glint-eval run /tmp/eval --baseline Evals/baseline.json` |
| Module boundaries | `scripts/check_imports.sh` |
| Format / lint | `xcrun swift-format lint --strict -r Sources Tests` · `swiftlint --strict` |
| Snapshot PNGs for review | `GLINT_SNAPSHOT_DIR=/tmp/snaps swift test --filter Snapshots` |

## Architecture

Glint runs as a single Swift process with no server. A background indexer and an interactive search path share one on-device index. Their only shared resources are the store and a priority gate that always favours search.

```
                 ┌────────────── GlintApp (composition root, AppKit shells) ──────────────┐
                 │  FloatingPanel · HotKeyCenter · QuickLook · player windows · MenuBar     │
                 └───────┬───────────────────────────┬───────────────────────────┬────────┘
                    GlintUI (SwiftUI + @Observable)   │                      GlintTelemetry
                         │                            │                      GlintLicensing
                    GlintSearch ◀── reads ── GlintStore ◀── writes ── GlintIndexer
                    (Metal vector scan,       (SQLite WAL,           (scan, FSEvents, queue,
                     RRF, filters, two-phase)  FTS5, f16 vectors)     pipeline, power policy)
                         │                                              │          │
                         └──────────── GlintEmbedding ◀─────────────────┘   GlintExtractors
                                 (providers, PriorityGate)                (text, PDF, image,
                                                                            audio, video)
                                        all depend inward on GlintCore
```

| Module | What's in it |
| --- | --- |
| `GlintCore` | Domain types, the four protocols (`EmbeddingProvider`, `ContentExtractor`, `VectorIndex`, `IndexingService`), `FeatureGateSnapshot`, errors, logging/signposts |
| `GlintExtractors` | One extractor per type. <ul><li>Text: encoding detection, 512/64-token chunks</li><li>PDF: per-page text, OCR for scanned pages, page renders, visual chunks</li><li>Image: downscale and Vision OCR</li><li>Audio: 16 kHz mono windows, waveform, optional on-device transcript</li><li>Video: 5 s clips at 1 fps plus the audio track</li></ul> |
| `GlintEmbedding` | <ul><li>`AppleOnDeviceEmbeddingProvider`, the interim provider (see ADR 0002)</li><li>`HashingEmbeddingProvider` for tests</li><li>`PriorityGate` and `GatedQueryEncoder`</li><li>`ModelCatalog`</li></ul> |
| `GlintStore` | SQLite wrapper, migrations, `IndexWriter` (single writer, one transaction per file), `IndexReader` (separate WAL reader), FTS5 for chunk text and file names, thumbnails |
| `GlintSearch` | <ul><li>`FlatVectorIndex`: a GPU-resident `Float16` matrix with a Metal kernel and an Accelerate fallback</li><li>`HybridRanker`: RRF, best chunk per file, recency boost</li><li>Two-phase `SearchEngine`, query tokens, snippets, retrieval metrics</li></ul> |
| `GlintIndexer` | Scanner, FSEvents watcher, priority queue (documents and images, then audio, then video), battery/Low Power/thermal pauses, content-hash dedupe, move/rename detection, Free-tier gating |
| `GlintLicensing` | Ed25519 offline-verified tokens, `Entitlements` (the one gating point), 14-day trial with clock-rollback protection, activation client, Keychain store |
| `GlintTelemetry` | Opt-in, bucketed events only, 10% search sampling, daily batch, 90-day rotating anonymous id, MetricKit |
| `GlintUI` | <ul><li>Search panel, main window (sidebar, grid/list, inspector)</li><li>Settings (six tabs), onboarding, upgrade sheet, menu bar content</li><li>View models</li></ul> |

### How search stays instant

1. **Keyword phase on every keystroke.** FTS5 matches chunk text and file names. File names are searchable seconds after the first scan, before any embedding.
2. **Semantic phase 40 ms after the last keystroke.** Any newer keystroke cancels it. When it lands, results are fused with reciprocal rank fusion and the selected row doesn't move (`ResultStabilizer`).
3. **Fast query path.** The query path holds only the small text encoder. Vectors live in unified memory, and a query is one Metal dispatch.
4. **Indexing yields to search.** The indexer waits for the `PriorityGate` and shrinks its batches while the user is typing.

Measured on an M5 in release (`GLINT_PERF=1`), against PRD budgets set for an M1 8 GB:

| Path | p95 | Budget |
| --- | --- | --- |
| Vector scan, 100k × 512 | 2.3 ms | 20 ms |
| Keyword results, 100k chunks | 13 ms | 30 ms |
| Merged results, 100k chunks | 26 ms | 150 ms |

### Retrieval quality

`glint-eval` indexes a corpus with the real extractors and model. It scores graded queries on Recall@10, MRR and nDCG@10, overall and per media type. Gates:

- No metric may drop more than 1 point overall, or more than 2 points for any media type.
- No must-pass query may leave the top 10.

The synthetic sample corpus (`glint-eval sample`) currently scores Recall@10 **0.96** overall, and 1.00 on images and PDFs, with a p50 query time of 2.7 ms. The 3,000-file persona corpus described in the PRD lives outside the repo.

## Licensing during development

```sh
swift run glint-license issue --email you@example.com      # prints a GLINT1-… key
swift run glint-license verify --key GLINT1-…
open "glint://activate?key=GLINT1-…"                      # or paste it in Settings › License
```

- **Signing keys:** the public key is compiled into `LicensePublicKey.swift`. The development private key is `secrets/license-dev-private.key`, which is git-ignored. Rotate both before release.
- **Activation:** until the M3 license server exists, a validly signed key activates offline (ADR 0005).
- **Secret storage:** ad hoc development builds keep license state in `~/Library/Application Support/Glint/license-dev.json` instead of the Keychain.

## Status against the PRD

**Done and tested**
- **Search:** panel with full keyboard flow, drag out, and drop a file to find similar items. The main window has a sidebar, search tokens, saved searches, an inspector and similar items.
- **Index:** five media types in one index. Free/Pro gating, with locked-but-visible results and an item limit that never deletes data.
- **App surfaces:** onboarding, Settings, menu bar item, and moment playback at the matched timestamp.
- **Licensing:** the license and trial lifecycle, with designed UI for all six license states.
- **Privacy:** opt-in telemetry whose payload is visible in Settings; Delete Index.
- **Platform:** String Catalog (231 keys), VoiceOver labels, light/dark mode, Liquid Glass on macOS 26.

**Not built yet (owner milestone)**
- EmbeddingGemma 2 provider via MLX-Swift and its parity gate (M0). The interim provider is behind the same protocol, and vectors re-embed automatically when the model changes.
- Model download from the CDN, plus model and quality-preset switching. Settings lists the models, but choosing one isn't wired up.
- Apple Photos library source via PhotoKit (Pro).
- License server and checkout (Paddle or Lemon Squeezy, M3). The purchase URL and telemetry endpoint are placeholders in `AppLinks`.
- Sparkle updates and notarization (M4).
- XCUITest suite. That needs an Xcode app target; UI behaviour is covered by view-model and snapshot tests for now.
- Shot-boundary detection, the quantized coarse scan for very large libraries, opening a PDF at the matched page, and the nightly fuzz corpus.
- Local API and MCP server (post-1.0 in the PRD).

## Decisions

Decisions are recorded as ADRs in [`docs/adr`](docs/adr):

1. SwiftPM and direct distribution
2. Interim embedding provider
3. System SQLite instead of GRDB
4. Search path performance
5. License secrets in development
