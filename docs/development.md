# Development

Setup is in [CONTRIBUTING.md](../CONTRIBUTING.md). This page lists the commands for every test, eval and release task.

## Commands

| Task | Command |
| --- | --- |
| Unit, integration, UI-model and snapshot tests | `swift test` |
| UI tests (XCUITest, real app, isolated data) | `xcodebuild test -project Xcode/Glint.xcodeproj -scheme Glint -destination 'platform=macOS,arch=arm64' ARCHS=arm64` |
| Model parity gate | `Tests/GlintEmbeddingTests/EmbeddingGemma2ParityTests.swift` (needs the checkpoint and `scripts/model/make_parity_fixtures.py`) |
| Performance budgets (100k chunks) | `GLINT_PERF=1 swift test -c release --filter GlintPerformanceTests` |
| Module boundaries | `scripts/check_imports.sh` |
| Format and lint | `xcrun swift-format lint --strict -r Sources Tests` · `swiftlint --strict` |
| Release (sign, notarize, DMG, appcast) | `scripts/release/release.sh` (see `scripts/release/README.md`) |

<details>
<summary><b>Retrieval evals</b></summary>

Replace `<checkpoint>` with the EmbeddingGemma 2 model directory.

| Eval | Command |
| --- | --- |
| Sample corpus | `glint-eval sample /tmp/eval && glint-eval run /tmp/eval --model gemma --model-dir <checkpoint> --baseline Evals/baseline-embeddinggemma2.json` |
| Mixed (photos and papers) | `scripts/mixed_bench.py && glint-eval run Evals/mixed --model gemma --model-dir <checkpoint> --baseline Evals/baseline-mixed-embeddinggemma2.json` |
| Media (photos, papers, video, audio; downloads MSR-VTT and Clotho clips, needs `uv`) | `scripts/media_bench.py && glint-eval run Evals/media --model gemma --model-dir <checkpoint> --baseline Evals/baseline-media-embeddinggemma2.json` |
| Themed photos (one trip's trains) | `scripts/coco_theme_bench.py && glint-eval run Evals/coco-train --model gemma --model-dir <checkpoint> --baseline Evals/baseline-coco-train-embeddinggemma2.json` |
| Indexing throughput | `glint-eval bench --model …` |
| Face grouping (needs the [LFW](https://vis-www.cs.umass.edu/lfw/) photos, one folder per person) | `glint-eval faces <lfw-dir> --people 150 --per 8 --strangers 2000` |

</details>

<details>
<summary><b>Continuous integration</b></summary>

CI runs on every pull request and push to `main`. To run it on any other commit, tag it with `ci-<name>` and push the tag, or run `gh workflow run CI --ref <branch>`. A tag containing `perf` or `model` also runs those jobs on the self-hosted reference Macs. CI builds with warnings as errors and runs the same checks as the table above.

</details>


## Working in Xcode

```sh
mkdir -p Xcode && xcodegen generate --project Xcode
open Xcode/Glint.xcodeproj
```

The generated project contains the app, `glint-mcp` and the UI tests. Modules and unit tests live in `Package.swift`. Build anything you time in **Release**: Debug MLX is 3–4× slower.

## Repository layout

```text
glint/
├── App/                  # Info.plist, entitlements, assets, String Catalog
├── Sources/
│   ├── GlintCore/        # domain types and protocols
│   ├── GlintExtractors/  # per-type content extraction
│   ├── GlintEmbedding/   # EmbeddingGemma 2 port, model download, fallback, PriorityGate
│   ├── GlintStore/       # SQLite, FTS5, migrations, thumbnails
│   ├── GlintSearch/      # vector scan, ranking, search engine
│   ├── GlintIndexer/     # scanning, watching, pipeline, power policy
│   ├── GlintUI/          # SwiftUI views and view models
│   ├── GlintLocalAPI/    # loopback HTTP API
│   ├── GlintRemote/      # S3 client (SigV4), Keychain secrets
│   ├── GlintMCP/         # MCP server library
│   ├── GlintMCPTool/     # glint-mcp executable
│   ├── GlintEval/        # glint-eval executable
│   └── GlintApp/         # composition root, AppKit shells
├── Tests/                # unit, integration, snapshot, parity and performance tests
├── UITests/              # XCUITest suite
├── Evals/                # benchmark corpora and baselines
├── docs/                 # ADRs and the local API reference
├── scripts/              # build, benchmarks, model fixtures, release
├── Package.swift         # module graph
└── project.yml           # XcodeGen spec for the app target
```

