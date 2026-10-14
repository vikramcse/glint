# Glint

Glint is a native Mac app for on-device multimodal search. Press **⌥Space** and describe what you're looking for. Glint finds photos and screenshots, moments inside videos, things said in recordings, PDF pages and documents, and nothing leaves the Mac.

Glint is free and open source under the [MIT License](LICENSE). This repository holds a Swift 6 package with every module in the architecture, an Xcode app target generated from `project.yml`, and the tooling around them: tests, a model parity gate, retrieval evals, performance budgets and release scripts.

## Quick start

Requires macOS 15+ on Apple silicon and Xcode 26. One-time setup:

```sh
brew install xcodegen
xcodebuild -downloadComponent MetalToolchain   # MLX's GPU kernels need it
```

Then:

```sh
scripts/build_app.sh debug        # generates Xcode/Glint.xcodeproj, builds, signs ad hoc → build/Glint.app
open build/Glint.app              # onboarding offers the EmbeddingGemma 2 download (1.5 GB)
```

- **Xcode:** run `mkdir -p Xcode && xcodegen generate --project Xcode`, then open `Xcode/Glint.xcodeproj` (app, `glint-mcp`, UI tests). The modules and unit tests live in `Package.swift`.
- **Why `xcodebuild`:** MLX's Metal kernels can't be built by `swift build`. Plain `swift build`/`swift test` still compile everything and run every test that doesn't execute the model.

| Task | Command |
| --- | --- |
| Unit, integration, UI-model and snapshot tests | `swift test` |
| UI tests (XCUITest, real app, isolated data) | `xcodebuild test -project Xcode/Glint.xcodeproj -scheme Glint -destination 'platform=macOS,arch=arm64' ARCHS=arm64` |
| EmbeddingGemma 2 parity gate | see `Tests/GlintEmbeddingTests/EmbeddingGemma2ParityTests.swift` (needs the checkpoint and `scripts/model/make_parity_fixtures.py`) |
| Performance budgets (100k chunks) | `GLINT_PERF=1 swift test -c release --filter GlintPerformanceTests` |
| Retrieval evals | `glint-eval sample /tmp/eval && glint-eval run /tmp/eval --model gemma --model-dir <checkpoint> --baseline Evals/baseline-embeddinggemma2.json` |
| Mixed library eval (photos and papers in one index; answers live in one modality) | `scripts/mixed_bench.py && glint-eval run Evals/mixed --model gemma --model-dir <checkpoint> --baseline Evals/baseline-mixed-embeddinggemma2.json` |
| Media library eval (photos, papers, videos and audio in one index; downloads MSR-VTT and Clotho clips) | `scripts/media_bench.py && glint-eval run Evals/media --model gemma --model-dir <checkpoint> --baseline Evals/baseline-media-embeddinggemma2.json` |
| Themed photo library eval (one trip's trains, searched for details) | `scripts/coco_theme_bench.py && glint-eval run Evals/coco-train --model gemma --model-dir <checkpoint> --baseline Evals/baseline-coco-train-embeddinggemma2.json` |
| Module boundaries | `scripts/check_imports.sh` |
| Format / lint | `xcrun swift-format lint --strict -r Sources Tests` · `swiftlint --strict` |
| Release (sign, notarize, DMG, appcast) | `scripts/release/release.sh` (see `scripts/release/README.md`) |

## Architecture

Glint runs as a single Swift process with no server. A background indexer and an interactive search path share one on-device index. Their only shared resources are the store and a priority gate that always favours search.

```
                 ┌────────────── GlintApp (composition root, AppKit shells) ──────────────┐
                 │  FloatingPanel · HotKeyCenter · QuickLook · player windows · MenuBar     │
                 └───────┬───────────────────────────┬────────────────────────────────────┘
                    GlintUI (SwiftUI + @Observable)   │
                         │                            │
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
| `GlintCore` | Domain types, the four protocols (`EmbeddingProvider`, `ContentExtractor`, `VectorIndex`, `IndexingService`), errors, logging/signposts |
| `GlintExtractors` | One extractor per type. <ul><li>Text: encoding detection, 512/64-token chunks</li><li>PDF: per-page text, OCR for scanned pages, page renders, visual chunks</li><li>Image: downscale and Vision OCR</li><li>Audio: 16 kHz mono windows, waveform, optional on-device transcript</li><li>Video: 5 s clips at 1 fps plus the audio track</li></ul> |
| `GlintEmbedding` | <ul><li>`EmbeddingGemma2Provider`: EmbeddingGemma 2 ported to MLX-Swift (text, vision, audio towers; 8-bit resident text tower; media towers load on demand), with a parity gate against the Python reference (ADR 0006)</li><li>`ModelStore`: pinned, resumable, SHA-256-verified model download</li><li>`AppleOnDeviceEmbeddingProvider`: built-in fallback until the download finishes (ADR 0002)</li><li>`PriorityGate`, `GatedQueryEncoder`, `ModelCatalog`, `HashingEmbeddingProvider` for tests</li></ul> |
| `GlintStore` | SQLite wrapper, migrations, `IndexWriter` (single writer, one transaction per file), `IndexReader` (separate WAL reader), FTS5 for chunk text and file names, thumbnails |
| `GlintSearch` | <ul><li>`FlatVectorIndex`: a GPU-resident `Float16` matrix with a Metal kernel and an Accelerate fallback</li><li>`HybridRanker`: RRF, best chunk per file, recency boost</li><li>Two-phase `SearchEngine`, query tokens, snippets, retrieval metrics</li></ul> |
| `GlintIndexer` | Scanner, FSEvents watcher, priority queue (documents and images, then audio, then video), battery/Low Power/thermal pauses, content-hash dedupe, move/rename detection |
| `GlintUI` | <ul><li>Search panel, main window (sidebar, grid/list, inspector), PDF window at the matched page</li><li>Settings (six tabs, model download and presets), onboarding, menu bar content</li><li>View models</li></ul> |
| `GlintLocalAPI` · `glint-mcp` | Loopback JSON API with bearer token and an MCP server over stdio for agents ([docs/local-api.md](docs/local-api.md)) |

### How search stays instant

1. **Keyword phase on every keystroke.** FTS5 matches chunk text and file names. File names are searchable seconds after the first scan, before any embedding.
2. **Semantic phase 40 ms after the last keystroke.** Any newer keystroke cancels it. When it lands, results are fused with reciprocal rank fusion and the selected row doesn't move (`ResultStabilizer`).
3. **Fast query path.** The query path holds only the small text encoder. Vectors live in unified memory, and a query is one Metal dispatch.
4. **Indexing yields to search.** The indexer waits for the `PriorityGate` and shrinks its batches while the user is typing.

Measured on an M5 in release (`GLINT_PERF=1`), against budgets set for an M1 8 GB:

| Path | p95 | Budget |
| --- | --- | --- |
| Vector scan, 100k × 512 | 2.3 ms | 20 ms |
| Keyword results, 100k chunks | 13 ms | 30 ms |
| Merged results, 100k chunks | 26 ms | 150 ms |

### Retrieval quality

`glint-eval` indexes a corpus with the real extractors and model. It scores graded queries on Recall@10, MRR and nDCG@10, overall and per media type. Gates:

- No metric may drop more than 1 point overall, or more than 2 points for any media type.
- No must-pass query may leave the top 10.

On the synthetic sample corpus (`glint-eval sample`), M5, Release:

| Model | Recall@10 | MRR | nDCG@10 | Search p50 / p95 |
| --- | --- | --- | --- | --- |
| EmbeddingGemma 2 (default, 512 d, 8-bit text tower) | 1.000 | 1.000 | 0.997 | 8.1 / 11.6 ms |
| Built-in fallback | 0.962 | 0.949 | 0.948 | 2.7 / 3.1 ms |

The larger 3,000-file persona corpus lives outside the repo.

## Status

**Done and tested**
- **Model:** EmbeddingGemma 2 is the default: downloaded once (1.5 GB, verified), text/vision/audio towers matching the Python reference at cosine ≥ 0.9998, 8-bit resident text tower, quality presets. The built-in model covers the time before the download finishes.
- **Search:** panel with full keyboard flow, drag out, and drop a file to find similar items. The main window has a sidebar, search tokens, saved searches, an inspector and similar items. PDFs open at the matched page with terms highlighted.
- **Index:** five media types in one index, plus the Apple Photos library.
- **App surfaces:** onboarding, Settings, menu bar item, moment playback at the matched timestamp, per-folder indexing status.
- **Distribution:** Sparkle updates; sign/notarize/DMG/appcast scripts.
- **Agents:** local API and `glint-mcp` (opt-in).
- **Quality gates:** unit, integration, UI-model, snapshot and XCUITest suites; model parity gate; retrieval evals; performance budgets.
- **Platform:** String Catalog, VoiceOver labels, light/dark mode, Liquid Glass on macOS 26.

**Needs accounts before a signed release**
- Apple Developer ID and notary credentials; Sparkle EdDSA keys and an appcast host.
- Optionally a CDN mirror of the model (`GlintModelBaseURL`); downloads come from the pinned Hugging Face revision until then.

**Open items**
- Idle memory is 550 MB on an M5 against the 500 MB budget; the tokenizer's in-memory vocabulary is the next thing to measure.
- Video parity is covered through the shared image path; a decoded-video fixture is a follow-up. Shot-boundary detection, the quantized coarse scan for very large libraries and the nightly fuzz corpus are not built.
- Dragging a Photos-library result out of Glint hands over a path that doesn't exist yet (the original should be exported first).

## Decisions

Decisions are recorded as ADRs in [`docs/adr`](docs/adr):

1. SwiftPM and direct distribution
2. Interim embedding provider (now the fallback)
3. System SQLite instead of GRDB
4. Search path performance
5. *(withdrawn)*
6. EmbeddingGemma 2 on MLX-Swift, built with Xcode
7. Sparkle for in-app updates
8. Indexing pipeline

## Contributing

Issues and pull requests are welcome. See [CONTRIBUTING.md](CONTRIBUTING.md) for how to build, test and send a change.

## License

Glint is released under the [MIT License](LICENSE). EmbeddingGemma 2 weights are downloaded separately and are covered by their own Apache-2.0 license.
