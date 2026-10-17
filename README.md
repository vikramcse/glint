<div align="center">

# Glint

**On-device multimodal search for the Mac.**

Press <kbd>⌥</kbd> <kbd>Space</kbd>, describe what you're looking for, and Glint finds it: photos and screenshots, moments inside videos, things said in recordings, PDF pages and documents. Nothing leaves your Mac.

<!-- Demo: add docs/media/demo.gif (15–30 s, ⌥Space → query → result opens at the moment) and uncomment.
<img src="docs/media/demo.gif" alt="Typing a description into Glint's search panel and opening the matching video at the right moment" width="720">
-->

[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
[![Platform](https://img.shields.io/badge/platform-macOS%2014%2B-lightgrey.svg)](#requirements)
[![Apple silicon](https://img.shields.io/badge/Apple%20silicon-required-black.svg)](#requirements)
[![Swift 6](https://img.shields.io/badge/Swift-6-F05138.svg?logo=swift&logoColor=white)](Package.swift)
[![Model: EmbeddingGemma 2](https://img.shields.io/badge/model-EmbeddingGemma%202-4285F4.svg)](docs/architecture.md#the-model-embeddinggemma-2)
[![MCP](https://img.shields.io/badge/MCP-server-8A2BE2.svg)](docs/local-api.md)

[Install](#install) ·
[Features](#features) ·
[For AI agents](#for-ai-agents) ·
[Architecture](docs/architecture.md) ·
[Benchmarks](docs/benchmarks.md) ·
[FAQ](#faq)

</div>

---

## Overview

Glint is a native macOS app that indexes your files into a single on-device vector space and lets you search them by meaning, not just by name. A query such as *"boarding pass for the Goa flight"* finds the screenshot; *"whiteboard with the Q3 roadmap"* finds the photo; *"dog barking"* finds the second in the video where it happens.

It is a single Swift process with no server and no cloud dependency. A background indexer and an interactive search path share one SQLite index. Embeddings come from [EmbeddingGemma 2](docs/architecture.md#the-model-embeddinggemma-2), ported to [MLX-Swift](https://github.com/ml-explore/mlx-swift) and running on the Apple silicon GPU.

| | |
| --- | --- |
| **What it searches** | Images (incl. HEIC and screenshots), video, audio, PDFs, text documents, the Apple Photos library, in folders, drives, network shares and S3 buckets |
| **How it searches** | Hybrid: SQLite FTS5 keyword search fused with GPU vector search |
| **Where it runs** | Entirely on your Mac. Network access is limited to the one-time model download, app updates, and reading from remote sources you add |
| **How fast** | Merged results in 26 ms p95 over 100k chunks (M5, release; [reproduce](docs/benchmarks.md#search-latency)) |
| **Who can use it** | People, through a Spotlight-style panel; scripts and AI agents, through a loopback API and an MCP server |

## Features

- **One search for every kind of file.** Text, images, video, audio and PDFs are embedded into the same space, so one query ranks across all of them.
- **Lands on the exact moment.** PDFs open at the matched page with terms highlighted; audio and video play from the matched timestamp.
- **Instant as you type.** Keyword results arrive on every keystroke; semantic results follow 40 ms after you stop typing, without reshuffling the row you've selected.
- **Find similar.** Drop any file on the panel to find items like it, whether or not it's indexed.
- **People.** Faces in photos and videos are grouped by person, like Google Photos. Click a face to see every photo and video that person is in; name people, and give two groups the same name to combine them.
- **Stays out of the way.** Indexing yields to search, pauses on Low Power Mode, low battery and serious thermal pressure, and halves its width on battery.
- **S3 buckets.** Add an S3-compatible bucket (AWS, R2, B2, MinIO), or a prefix in one. Files are downloaded one at a time to be indexed and then deleted; the index stays on your Mac and is searchable offline. See [docs/remote-sources.md](docs/remote-sources.md).
- **Keeps itself current.** FSEvents watches your folders; moves and renames are detected by content hash instead of re-indexing. Network shares (SMB, NFS, AFP) are also rescanned every 15 minutes and on reconnect, and what was indexed stays searchable while a share is disconnected.
- **Built for agents.** An opt-in, token-authenticated local API and a bundled `glint-mcp` server let Claude and other agents search your files.
- **A real Mac app.** AppKit and SwiftUI, VoiceOver labels, String Catalog localization, light and dark mode, Liquid Glass on macOS 26, Sparkle updates.

## How it works

A background indexer and an interactive search path share one SQLite index, and a priority gate makes indexing wait whenever you type.

1. **Index.** Each file is split into chunks (a text passage, a PDF page, an image, a 10-second audio window, a 5-second video clip), embedded by EmbeddingGemma 2 on the GPU, and committed with its OCR and transcript text. FSEvents keeps the index current; renames are detected by content hash.
2. **Search.** Keyword results from FTS5 arrive on every keystroke. 40 ms after you stop typing, the query is embedded and scored against every stored vector in one Metal dispatch.
3. **Rank.** Semantic hits are calibrated against your own library, so a search for something you don't have returns nothing instead of ten random photos. Keyword and semantic lists are then fused into one row per file.

[docs/architecture.md](docs/architecture.md) has the diagrams, the module graph, the model port and every technical decision. [docs/benchmarks.md](docs/benchmarks.md) has latency, retrieval-quality and face-grouping numbers.

## Requirements

### macOS

| macOS | Supported | Notes |
| --- | :---: | --- |
| macOS 26 Tahoe | ✅ | The search panel uses Liquid Glass |
| macOS 15 Sequoia | ✅ | The search panel uses the system material instead of Liquid Glass |
| macOS 14 Sonoma | ✅ | Minimum version; same as Sequoia |
| macOS 13 Ventura and earlier | ❌ | MLX, which runs the model, needs macOS 14, and the app's SwiftUI state (`@Observable`) and inspector panel arrive in 14 |

### Hardware

| Mac | Supported | Notes |
| --- | :---: | --- |
| Apple silicon (M1, M2, M3, M4, M5 and their Pro, Max and Ultra variants) | ✅ | MacBook Air, MacBook Pro, iMac, Mac mini, Mac Studio, Mac Pro |
| Intel Macs | ❌ | The app is built for arm64 only and doesn't run under Rosetta. See [Why does it require Apple silicon?](#faq) |

| Resource | Requirement |
| --- | --- |
| Memory | 8 GB or more. Search latency budgets are set for an M1 with 8 GB; idle use is about 550 MB, and the vision and audio models load only while indexing |
| Disk | About 1.5 GB for the EmbeddingGemma 2 model, plus the index and thumbnails, which grow with your library |
| Network | Only for the one-time model download; search and indexing run offline |

### Permissions and optional features

- **Folders you choose to index:** Glint reads only those.
- **Speech Recognition:** needed only to transcribe audio and video. Transcription runs on-device, so it works for languages that macOS can recognize offline; other languages aren't transcribed.
- **Battery:** indexing pauses below 20% battery, in Low Power Mode and when the Mac runs hot. Video can be set to index only when plugged in.

## Install

> [!NOTE]
> A signed, notarized download is coming soon. Until then, build from source; it takes a few minutes.

### Build tools

- A Mac that meets the [requirements](#requirements)
- Xcode 26 (with the Metal Toolchain component)
- [XcodeGen](https://github.com/yonaskolb/XcodeGen)

### Build and run

```sh
git clone https://github.com/vikramcse/glint.git && cd glint

brew install xcodegen
xcodebuild -downloadComponent MetalToolchain   # once: MLX's GPU kernels need it

scripts/build_app.sh release                    # → build/Glint.app (ad hoc signed)
open build/Glint.app
```

Onboarding asks which folders to index and offers the EmbeddingGemma 2 download (1.5 GB, SHA-256 verified). Search works immediately with a built-in fallback model while the download runs.

> [!NOTE]
> MLX's Metal kernels can't be compiled by `swift build`, so the app and anything that runs the model build with `xcodebuild`. Plain `swift build` and `swift test` still compile every module and run every test that doesn't execute the model.

Working in Xcode, running tests and evals, and releasing are covered in [docs/development.md](docs/development.md).

## For AI agents

Glint can act as a private, local retrieval tool for Claude and other agents. Turn on **Settings › Privacy › Allow apps and agents to search Glint**, then register the bundled MCP server:

```sh
claude mcp add glint -- /Applications/Glint.app/Contents/MacOS/glint-mcp
```

For Claude Desktop, add to `claude_desktop_config.json`:

```json
{ "mcpServers": { "glint": { "command": "/Applications/Glint.app/Contents/MacOS/glint-mcp" } } }
```

| MCP tool | Purpose |
| --- | --- |
| `search_files(query, kinds?, limit?, folders?, modified_after?)` | Natural-language search across the index |
| `find_similar(path, limit?)` | Files similar to a given file |
| `index_status()` | Indexing progress and counts per kind |
| `list_sources()` | Indexed folders and their state |

All tools are read-only. Results include the path, kind, score, snippet, and the matched page (PDF) or time range (audio and video).

The underlying HTTP API listens on `127.0.0.1` only, requires a bearer token, and rejects browser origins and DNS-rebinding hosts. Full reference: [docs/local-api.md](docs/local-api.md).

> [!TIP]
> **Agents working on this codebase:** start with `Package.swift` for the module graph, `Sources/GlintCore/Protocols.swift` for the contracts, and `docs/adr` for the reasoning. Run `swift test` and `scripts/check_imports.sh` before proposing changes, and run `glint-eval` against the matching baseline for anything touching ranking, extraction or the model. [CONTRIBUTING.md](CONTRIBUTING.md) has the full checklist.

## Privacy

- **Your files never leave your Mac.** Extraction, OCR, transcription, face recognition and embedding all run locally. Face fingerprints and names stay in the index and are removed with it.
- **Network access, all optional to the core experience:** the one-time model download from a pinned Hugging Face revision, Sparkle update checks (disabled in development builds), and, only for buckets you add, read-only listing and downloading from your own S3 storage. Downloaded copies are deleted once indexed; nothing is uploaded.
- **Credentials stay in your Keychain.** S3 secret keys are never written to the index, and are deleted when you remove the source.
- **No telemetry, no accounts, no analytics.**
- **The local API is off by default.** When on, it listens on loopback only, and its logs record routes and status codes, never queries or paths.
- **Deleting the index** removes everything Glint derived from your files.

## Project status

<table>
<tr><td valign="top" width="33%">

**✅ Done and tested**

- EmbeddingGemma 2 default, with parity gate and quality presets
- Five media types plus the Photos library in one index
- Search panel, main window, saved searches, find similar
- People: faces in photos and videos grouped by person, with naming and merging
- PDF at the matched page; media at the matched moment
- Local API and `glint-mcp`
- Unit, integration, snapshot, UI, parity, eval and perf suites
- Sparkle updates and release scripts

</td><td valign="top" width="33%">

**🚧 Known gaps**

- Audio search by description is weak (Recall@10 0.14 on the media benchmark)
- Idle memory is 550 MB against a 500 MB budget on an M5
- Dragging a Photos-library result out hands over a path that doesn't exist yet
- No decoded-video parity fixture yet
- Searching from a person's page searches the whole library, not just their photos
- Face recognition has no on/off switch in Settings yet

</td><td valign="top" width="33%">

**🗺️ Not built yet**

- Shot-boundary detection for video
- Quantized coarse scan for very large libraries
- Nightly fuzz corpus
- Signed public release (needs Developer ID, notary and Sparkle keys)

</td></tr>
</table>

## FAQ

<details>
<summary><b>Does Glint send my files or queries anywhere?</b></summary>

No. Everything runs on your Mac. The only network traffic is the one-time model download, Sparkle update checks, and reading from S3 buckets you add yourself. There is no telemetry. See [Privacy](#privacy).

</details>

<details>
<summary><b>Why does it require Apple silicon?</b></summary>

The model runs on MLX, which targets Apple silicon's GPU and unified memory, and the vector index lives in a shared-storage Metal buffer that both CPU and GPU access without copies. Intel Macs don't have that memory model.

</details>

<details>
<summary><b>How much disk and memory does it use?</b></summary>

The model is about 1.5 GB on disk. At rest, the resident text tower and the vector matrix (about 100 MB per 100k chunks) are the main memory costs; idle memory is currently around 550 MB on an M5. The vision and audio towers load only while indexing and unload when idle.

</details>

<details>
<summary><b>How long does the first index take?</b></summary>

It depends on the mix. On an M5, photos index at roughly 300 per minute, documents at over 1,000 per minute, audio at about 60 and video at about 13 items per minute, so a large video library takes the longest. File names are searchable within seconds, before any embedding. Indexing pauses in Low Power Mode, below 20% battery and at serious thermal pressure.

</details>

<details>
<summary><b>Why not use an approximate nearest-neighbour index like HNSW?</b></summary>

At personal-library scale an exact scan on the GPU is fast enough (2.3 ms for 100k vectors) and has no recall loss, no build time and no index to repair. A quantized coarse scan is planned for libraries that outgrow memory. See [ADR 0004](docs/adr/0004-search-path-performance.md).

</details>

<details>
<summary><b>How does People work, and how do I fix a wrong group?</b></summary>

Glint finds faces with Apple's Vision and matches them with SFace, a face-recognition model bundled with the app, all on your Mac. If one person shows up as two groups, give both the same name and they combine. Someone appears in People once they are in at least two photos or videos. If your library was indexed before People existed, click **Find People** to re-index its photos and videos; this takes about as long as the first index of them did.

</details>

<details>
<summary><b>Why does a search sometimes return nothing?</b></summary>

On purpose. Glint calibrates semantic matches against your library and drops ones that don't stand out, so a search for something you don't have comes back empty rather than full of near-random results. Keyword and file-name matches are always shown.

</details>

<details>
<summary><b>Which languages are supported?</b></summary>

Keyword search is language-neutral. EmbeddingGemma 2 is multilingual, and the tokenizer is tested on CJK, emoji and code. The built-in fallback model is English-only.

</details>

<details>
<summary><b>Can I use a different embedding model?</b></summary>

Yes, by adding an `EmbeddingProvider` conformance and a `ModelCatalog` entry. Vectors are tagged with their model's space, so switching models re-indexes cleanly without mixing vectors. New third-party dependencies need an ADR.

</details>

<details>
<summary><b>Why isn't Glint on the Mac App Store?</b></summary>

The App Sandbox conflicts with indexing arbitrary folders and external drives, so Glint is distributed directly, signed and notarized, with Sparkle updates. See [ADR 0001](docs/adr/0001-swiftpm-and-direct-distribution.md).

</details>

<details>
<summary><b>Why can't I build it with <code>swift build</code> alone?</b></summary>

SwiftPM can't compile MLX's Metal kernels. `swift build` and `swift test` still compile everything and run every test that doesn't execute the model; the app, model tests and benchmarks use `xcodebuild`.

</details>

<details>
<summary><b>Can I use EmbeddingGemma 2 commercially?</b></summary>

EmbeddingGemma 2 is released under Apache-2.0, which permits commercial use. Glint downloads the weights separately and does not redistribute them. Review the model's license yourself before relying on it.

</details>

## Contributing

Issues and pull requests are welcome, and so are retrieval misses: *"I searched X and expected Y"* is one of the most useful bug reports you can file. Read [CONTRIBUTING.md](CONTRIBUTING.md) for setup, the pre-PR checklist and how the code is organised.

## License

Glint is released under the [MIT License](LICENSE).

The EmbeddingGemma 2 model weights are **not** part of this repository. They are downloaded at runtime from Hugging Face and are covered by their own [Apache-2.0](https://www.apache.org/licenses/LICENSE-2.0) license. The face-recognition model, [SFace](https://github.com/opencv/opencv_zoo/tree/main/models/face_recognition_sface) from OpenCV Zoo, **is** bundled with the app (`Sources/GlintExtractors/Resources/SFace.mlmodelc`, converted to Core ML by `scripts/model/convert_sface.py`) under its [Apache-2.0](https://www.apache.org/licenses/LICENSE-2.0) license.

Third-party dependencies ([MLX-Swift](https://github.com/ml-explore/mlx-swift), [Sparkle](https://github.com/sparkle-project/Sparkle), and the test-only [swift-transformers](https://github.com/huggingface/swift-transformers)) are MIT- or Apache-licensed; see each project for details.

<div align="center">
<sub>Built with Swift, MLX and SQLite. Runs entirely on your Mac.</sub>
</div>
